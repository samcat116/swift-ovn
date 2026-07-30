#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO
import Logging

public actor OVSDBConnection {
    /// What this connection knows about one of its monitors: the method it was
    /// established with — which decides how its notifications are shaped and
    /// whether its conditions can be changed — and how far its updates have been
    /// followed.
    private struct MonitorState {
        /// What the monitor was asked for, kept so it can be re-established on
        /// the session after a reconnect. An id on its own was enough while a
        /// dropped connection was terminal; it is not now, because it would name
        /// a monitor the server has thrown away.
        let database: String
        let tables: [String: OVSDBMonitorRequest]
        var method: OVSDBMonitorMethod
        var lastTransactionId: String?
    }

    private let client: JSONRPCClient
    private let logger: Logger
    private var monitors: [String: MonitorState] = [:]
    /// The most capable monitor method this server has accepted, so later
    /// monitors do not repeat the negotiation. Cleared on disconnect, and on a
    /// reconnect that may have landed on a different member of a clustered
    /// database.
    private var negotiatedMethod: OVSDBMonitorMethod?
    /// Watches for the transport reconnecting and re-establishes `monitors` on
    /// the new session. One task per connection, not per monitor stream, so the
    /// monitors are re-created once however many consumers there are.
    private var monitorRecovery: Task<Void, Never>?

    /// See `OVSDBSocketConnection.init(remotes:reconnect:leaderOnlyDatabase:…)`
    /// for what the cluster parameters mean.
    public init(
        remotes: OVSDBRemotes,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.client = JSONRPCClient(
            remotes: remotes,
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnlyDatabase,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.ovsdb-connection")
    }

    public init(
        endpoint: OVSDBEndpoint,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            remotes: OVSDBRemotes(endpoint),
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnlyDatabase,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }

    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
    }

    /// Runs the connection over a caller-supplied transport (e.g. a mock in
    /// tests), as `JSONRPCClient.init(transport:)` does.
    public init(transport: any OVSDBTransport, logger: Logger? = nil) {
        self.client = JSONRPCClient(transport: transport, logger: logger)
        self.logger = logger ?? Logger(label: "ovn-manager.ovsdb-connection")
    }

    public func connect() async throws(OVNManagerError) {
        try await client.connect()

        // Send initial echo request to establish OVSDB connection
        do {
            _ = try await client.echo()
            logger.info("Connected to OVSDB")
        } catch {
            logger.error("Failed to establish OVSDB connection: \(error)")
            throw error
        }

        startMonitorRecovery()
    }

    public func disconnect() async throws(OVNManagerError) {
        monitorRecovery?.cancel()
        monitorRecovery = nil

        // Cancel all active monitors
        for monitorId in monitors.keys {
            try? await client.cancelMonitor(monitorId: monitorId)
        }
        monitors.removeAll()
        negotiatedMethod = nil

        try await client.disconnect()
        logger.info("Disconnected from OVSDB")
    }

    /// Whether a session is up right now. See
    /// `OVSDBSocketConnection.isConnectionActive` for why this flickers once
    /// reconnection is enabled, and prefer `connectionState`.
    public var isConnected: Bool {
        get async {
            return client.isConnected
        }
    }

    /// See `OVSDBSocketConnection.connectionState`.
    nonisolated public var connectionState: OVSDBConnectionState {
        return client.connectionState
    }

    /// See `OVSDBSocketConnection.connectionStates()`.
    nonisolated public func connectionStates() -> AsyncStream<OVSDBConnectionState> {
        return client.connectionStates()
    }

    // MARK: - Monitor recovery

    /// Starts the task that re-creates this connection's monitors whenever the
    /// transport reconnects.
    private func startMonitorRecovery() {
        guard monitorRecovery == nil else { return }
        let events = client.notificationEvents()
        monitorRecovery = Task { [weak self] in
            for await event in events {
                guard case .reconnected = event else { continue }
                await self?.reestablishMonitors()
            }
        }
    }

    /// Re-establishes every monitor on the session that just came up, under the
    /// same IDs, resuming from the last transaction id delivered where the
    /// monitor's method allows it.
    ///
    /// The updates the re-established monitors reply with are deliberately
    /// dropped, and consumers are told the stream has a hole
    /// (`OVNManagerError.monitorInterrupted`) instead. Handing a snapshot — or a
    /// `monitor_cond_since` delta — to a stream from here would race the live
    /// updates already flowing on the new monitor, since the two would reach a
    /// consumer by different paths; ordering them means routing every consumer's
    /// updates through this connection rather than straight from the transport.
    /// Resuming still pays for itself even discarded: it is the difference
    /// between the server sending what changed and re-sending a whole Southbound
    /// database.
    private func reestablishMonitors() async {
        let existing = monitors
        guard !existing.isEmpty else { return }
        // The new session may be a different member of the cluster, which need
        // not implement the method the previous one did.
        negotiatedMethod = nil
        logger.info("Connection re-established; restarting \(existing.count) monitor(s)")

        for (monitorId, state) in existing {
            do {
                switch state.method {
                case .monitor:
                    // Nothing to resume from: plain `monitor` reports no
                    // transaction ids.
                    _ = try await startMonitoring(
                        database: state.database,
                        tables: state.tables,
                        monitorId: monitorId
                    )
                case .monitorCond, .monitorCondSince:
                    let session = try await startConditionalMonitoring(
                        database: state.database,
                        tables: state.tables,
                        monitorId: monitorId,
                        since: state.lastTransactionId
                    )
                    let outcome = session.resumed ? "resumed" : "from a full snapshot"
                    logger.info("Restarted monitor \(monitorId) on \(state.database) \(outcome)")
                }
            } catch {
                // The new session may itself have died already; the next
                // reconnect runs this again, so there is nothing to retry here.
                logger.error("Failed to restart monitor \(monitorId) on \(state.database): \(error)")
            }
        }
    }

    // MARK: - Database Operations
    
    public func listDatabases() async throws(OVNManagerError) -> [String] {
        logger.debug("Listing databases")
        return try await client.listDatabases()
    }

    public func getDatabaseSchema(database: String) async throws(OVNManagerError) -> JSONValue {
        logger.debug("Getting schema for database: \(database)")
        return try await client.getSchema(database: database)
    }

    /// Converts `database` to `schema`. See `JSONRPCClient.convert(database:schema:)`
    /// — this migrates the stored data and discards what the new schema has no
    /// place for.
    public func convertDatabase(_ database: String, to schema: JSONValue) async throws(OVNManagerError) {
        try await client.convert(database: database, schema: schema)
    }

    // MARK: - Session

    /// Declares whether this connection wants `update` notifications about
    /// databases being added and removed. See
    /// `JSONRPCClient.setDatabaseChangeAware(_:)`.
    public func setDatabaseChangeAware(_ aware: Bool) async throws(OVNManagerError) {
        try await client.setDatabaseChangeAware(aware)
    }

    /// The UUID of the server on the other end — which cluster member this
    /// connection landed on.
    public func serverID() async throws(OVNManagerError) -> String {
        return try await client.getServerID()
    }

    // MARK: - Locking

    /// Requests ownership of the lock named `id`, returning true if this
    /// connection owns it as of the reply and false if the request was queued.
    /// See `JSONRPCClient.lock(id:)`.
    @discardableResult
    public func lock(id: String) async throws(OVNManagerError) -> Bool {
        return try await client.lock(id: id)
    }

    /// Takes the lock named `id` from its current owner.
    /// See `JSONRPCClient.steal(id:)`.
    @discardableResult
    public func steal(lockID id: String) async throws(OVNManagerError) -> Bool {
        return try await client.steal(id: id)
    }

    /// Releases the lock named `id`, or withdraws a queued request for it.
    public func unlock(id: String) async throws(OVNManagerError) {
        try await client.unlock(id: id)
    }

    /// Streams this connection's lock ownership changes. Create the stream
    /// before calling `lock(id:)`. See `JSONRPCClient.lockUpdates()`.
    nonisolated public func lockUpdates() -> AsyncThrowingStream<OVSDBLockNotification, Error> {
        return client.lockUpdates()
    }

    // MARK: - Table Operations

    /// Executes multiple operations in a single OVSDB transaction and returns
    /// the per-operation results. Throws if any operation reports an error —
    /// ovsdb-server returns operation errors inside a successful JSON-RPC
    /// response (RFC 7047 §4.1.3), so callers cannot rely on the RPC layer
    /// alone to detect a failed/aborted transaction.
    ///
    /// Pass `onRequestID` to learn the id of the request while it is in flight,
    /// so `cancel(requestID:)` can abandon it — the only way out of a
    /// transaction parked on a `wait` operation short of its timeout.
    public func transact(
        in database: String,
        operations: [OVSDBOperation],
        onRequestID: (@Sendable (JSONRPCIdentifier) -> Void)? = nil
    ) async throws(OVNManagerError) -> [JSONValue] {
        let results = try await client.transact(
            database: database,
            operations: operations,
            onRequestID: onRequestID
        )

        for (index, result) in results.enumerated() {
            guard case .object(let resultObject) = result,
                  let error = resultObject["error"],
                  case .string(let errorName) = error else {
                continue
            }
            var message = "Transaction operation \(index) failed: \(errorName)"
            if case .string(let details)? = resultObject["details"] {
                message += " (\(details))"
            }
            throw OVNManagerError.operationFailed(message)
        }

        return results
    }

    /// Asks the server to abandon the in-flight request `requestID`, as
    /// reported by `transact(in:operations:onRequestID:)`. See
    /// `JSONRPCClient.cancel(requestID:)`.
    public func cancel(requestID: JSONRPCIdentifier) async throws(OVNManagerError) {
        try await client.cancel(requestID: requestID)
    }

    /// Inserts a row and adds its UUID to a parent row's reference column in
    /// the same transaction (see `OVSDBReferenceTransactions`), so the new
    /// row is never garbage-collected as an orphan. Returns the new row's
    /// UUID.
    public func insertAttached(
        into table: String,
        in database: String,
        row: OVSDBRow,
        uuidName: String,
        parentTable: String,
        parentColumn: String,
        parentCondition: OVSDBCondition?
    ) async throws(OVNManagerError) -> String {
        let operations = OVSDBReferenceTransactions.insertAttached(
            row: row,
            into: table,
            uuidName: uuidName,
            parentTable: parentTable,
            parentColumn: parentColumn,
            parentCondition: parentCondition
        )

        let results = try await transact(in: database, operations: operations)

        // The insert result follows the wait op, if there is one.
        let insertIndex = parentCondition == nil ? 0 : 1
        return try Self.uuid(fromInsertResults: results, at: insertIndex)
    }

    /// Inserts the child rows a parent's reference column must point at and
    /// then the parent itself, in one transaction (see
    /// `OVSDBReferenceTransactions.insertWithChildren`). Returns the parent
    /// row's UUID; the children's UUIDs are readable from the parent's
    /// reference column.
    public func insertWithChildren(
        into table: String,
        in database: String,
        row: OVSDBRow,
        uuidName: String,
        referenceColumn: String,
        childRows: [OVSDBRow],
        childTable: String,
        childUUIDNamePrefix: String
    ) async throws(OVNManagerError) -> String {
        let operations = OVSDBReferenceTransactions.insertWithChildren(
            row: row,
            into: table,
            uuidName: uuidName,
            referenceColumn: referenceColumn,
            childRows: childRows,
            childTable: childTable,
            childUUIDNamePrefix: childUUIDNamePrefix
        )

        let results = try await transact(in: database, operations: operations)

        // The parent insert is the last operation of the transaction.
        return try Self.uuid(fromInsertResults: results, at: childRows.count)
    }

    /// Removes the row's UUID from each referencing parent column and deletes
    /// the row in one transaction (see `OVSDBReferenceTransactions`), so
    /// neither a dangling reference nor a rejected delete of a
    /// strongly-referenced row is possible. Returns the number of rows
    /// deleted.
    public func deleteDetaching(
        from table: String,
        in database: String,
        uuid: String,
        parentReferences: [OVSDBParentReference]
    ) async throws(OVNManagerError) -> Int {
        let operations = OVSDBReferenceTransactions.deleteDetaching(
            uuid: uuid,
            from: table,
            parentReferences: parentReferences
        )

        let results = try await transact(in: database, operations: operations)

        guard case .object(let deleteResult)? = results.last,
              case .number(let count)? = deleteResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid delete response format")
        }
        return Int(count)
    }

    /// Extracts the new row's UUID from the result of an insert operation at
    /// the given index within a transaction's results.
    static func uuid(fromInsertResults results: [JSONValue], at index: Int) throws(OVNManagerError) -> String {
        guard results.count > index,
              case .object(let insertResult) = results[index],
              case .array(let uuidArray)? = insertResult["uuid"],
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        return uuidValue
    }

    public func selectAll(from table: String, in database: String, columns: [String]? = nil) async throws(OVNManagerError) -> [OVSDBRow] {
        // An empty where clause selects every row.
        let operation = OVSDBOperation.select(from: table, columns: columns)

        let results = try await client.transact(database: database, operations: [operation])
        return try Self.rows(fromSelectResults: results)
    }

    public func select(
        from table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        columns: [String]? = nil
    ) async throws(OVNManagerError) -> [OVSDBRow] {
        let operation = OVSDBOperation.select(from: table, where: conditions, columns: columns)

        let results = try await client.transact(database: database, operations: [operation])
        return try Self.rows(fromSelectResults: results)
    }

    /// Extracts the rows from a single-`select` transaction's results.
    private static func rows(fromSelectResults results: [JSONValue]) throws(OVNManagerError) -> [OVSDBRow] {
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult else {
            throw OVNManagerError.invalidResponse("Invalid select response format")
        }

        // Check if there's an error in the response
        if let error = resultObject["error"], case .string(let errorMessage) = error {
            throw OVNManagerError.operationFailed("Select operation failed: \(errorMessage)")
        }

        guard let rows = resultObject["rows"],
              case .array(let rowsArray) = rows else {
            throw OVNManagerError.invalidResponse("Invalid select response format: missing rows field")
        }

        // A loop rather than `map`: `Sequence.map` is `rethrows`, which erases a
        // typed throw back to `any Error`.
        var rowObjects: [OVSDBRow] = []
        rowObjects.reserveCapacity(rowsArray.count)
        for jsonValue in rowsArray {
            guard case .object(let rowObject) = jsonValue else {
                throw OVNManagerError.invalidResponse("Invalid row format")
            }
            rowObjects.append(rowObject)
        }
        return rowObjects
    }

    public func insert(into table: String, in database: String, row: OVSDBRow) async throws(OVNManagerError) -> JSONValue {
        let operation = OVSDBOperation.insert(into: table, row: row)

        let results = try await client.transact(database: database, operations: [operation])

        guard let firstResult = results.first else {
            throw OVNManagerError.invalidResponse("No result from insert operation")
        }

        // Check if there's an error in the response
        if case .object(let resultObject) = firstResult,
           let error = resultObject["error"], case .string(let errorMessage) = error {
            var message = "Insert operation failed: \(errorMessage)"
            if case .string(let details)? = resultObject["details"] {
                message += " (\(details))"
            }
            throw OVNManagerError.operationFailed(message)
        }

        return firstResult
    }
    
    public func update(
        table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        row: OVSDBRow
    ) async throws(OVNManagerError) -> Int {
        let operation = OVSDBOperation.update(table, where: conditions, row: row)
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }
        
        // Check if there's an error in the response
        if let error = resultObject["error"], case .string(let errorMessage) = error {
            throw OVNManagerError.operationFailed("Update operation failed: \(errorMessage)")
        }
        
        // Look for count field
        guard let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid update response format: missing count field")
        }
        
        return Int(countValue)
    }
    
    public func delete(
        from table: String,
        in database: String,
        where conditions: [OVSDBCondition]
    ) async throws(OVNManagerError) -> Int {
        let operation = OVSDBOperation.delete(from: table, where: conditions)
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult else {
            throw OVNManagerError.invalidResponse("Invalid delete response format")
        }
        
        // Check if there's an error in the response
        if let error = resultObject["error"], case .string(let errorMessage) = error {
            throw OVNManagerError.operationFailed("Delete operation failed: \(errorMessage)")
        }
        
        // Look for count field
        guard let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid delete response format: missing count field")
        }
        
        return Int(countValue)
    }
    
    public func mutate(
        table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        mutations: [OVSDBMutation]
    ) async throws(OVNManagerError) -> Int {
        let operation = OVSDBOperation.mutate(table, where: conditions, mutations: mutations)
        
        let results = try await client.transact(database: database, operations: [operation])

        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }

        // Check if there's an error in the response
        if let error = resultObject["error"], case .string(let errorMessage) = error {
            throw OVNManagerError.operationFailed("Mutate operation failed: \(errorMessage)")
        }

        guard let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format: missing count field")
        }

        return Int(countValue)
    }
    
    // MARK: - Monitoring
    
    /// Starts a monitor and returns its ID together with the initial database
    /// contents (the monitor reply carries one insert-style update per
    /// existing row when `select.initial` is requested).
    ///
    /// To observe subsequent changes without missing any, create the
    /// `monitorUpdates()` stream *before* calling this method.
    ///
    /// The monitor is remembered, so a reconnect re-creates it on the new session
    /// under the same ID and `stopMonitoring(monitorId:)` keeps working across
    /// one. What a reconnect cannot do is replay what happened while the
    /// connection was down — see `monitorUpdates()`.
    public func startMonitoring(
        database: String,
        tables: [String: OVSDBMonitorRequest],
        monitorId: String? = nil
    ) async throws(OVNManagerError) -> (monitorId: String, initialUpdates: [OVSDBUpdate]) {
        let id = monitorId ?? UUID().uuidString

        let session = try await startMonitor(
            .monitor,
            database: database,
            monitorId: id,
            tables: tables,
            since: nil
        )

        monitors[id] = MonitorState(
            database: database,
            tables: tables,
            method: .monitor,
            lastTransactionId: nil
        )

        logger.info("Started monitoring database \(database) with ID: \(id) (\(session.initialUpdates.count) initial rows)")

        return (monitorId: id, initialUpdates: session.initialUpdates)
    }

    /// Starts a monitor with the most capable method the server supports,
    /// preferring `monitor_cond_since` — what every production OVN client uses —
    /// then `monitor_cond`, then RFC 7047 `monitor`.
    ///
    /// `since` is a transaction id a previous session ended on (from an earlier
    /// session's `lastTransactionId`, or from `lastTransactionId(forMonitor:)`).
    /// When the server can resume from it the returned session's `resumed` is
    /// true and `initialUpdates` holds only what changed since — the whole point
    /// of the method, because the alternative on a large Southbound database is
    /// re-downloading all of it. When `resumed` is false the updates are a
    /// complete snapshot and any row state carried across the reconnect must be
    /// discarded, not merged.
    ///
    /// The fallback is not silent about filtering: plain `monitor` cannot
    /// evaluate a `where` condition, so if the server supports neither
    /// conditional method while any request carries conditions, this throws
    /// rather than start a monitor that would deliver every row as though it
    /// matched. Requests without conditions fall back happily.
    ///
    /// Which method was used decides how the changes are shaped: `.monitor`
    /// updates carry `old`/`new`, the conditional ones carry a `kind` and, for a
    /// modify, a `diff` (see `OVSDBUpdate`). Feature detection happens once per
    /// connection; later monitors reuse the method that worked.
    ///
    /// To observe subsequent changes without missing any, create the
    /// `monitorTableUpdates()` stream *before* calling this method.
    public func startConditionalMonitoring(
        database: String,
        tables: [String: OVSDBMonitorRequest],
        monitorId: String? = nil,
        since lastTransactionId: String? = nil
    ) async throws(OVNManagerError) -> OVSDBMonitorSession {
        let id = monitorId ?? UUID().uuidString
        let isFiltered = Self.carryConditions(tables)
        var method = negotiatedMethod ?? .monitorCondSince

        // A server already known to support neither conditional method: nothing
        // to attempt, and nothing registered yet to unregister.
        if isFiltered, method == .monitor {
            throw Self.conditionsUnsupported(database: database)
        }

        while true {
            // Registered *before* the request goes out. ovsdb-server can put the
            // first `update3` on the wire immediately behind its reply, and the
            // read loop hands that notification to the update stream while this
            // method is still suspended — so a monitor registered afterwards
            // would have that notification's transaction id recorded against a
            // monitor that did not exist yet, and lose the newest resume point.
            // A rejected attempt sends no notifications, so resetting the
            // transaction id per attempt cannot discard one.
            monitors[id] = MonitorState(
                database: database,
                tables: tables,
                method: method,
                lastTransactionId: nil
            )

            do {
                let session = try await startMonitor(
                    method,
                    database: database,
                    monitorId: id,
                    tables: tables,
                    since: lastTransactionId
                )

                negotiatedMethod = method
                // Only if no `update3` has already reported a newer one: the
                // reply's id is the older of the two.
                if monitors[id]?.lastTransactionId == nil {
                    monitors[id]?.lastTransactionId = session.lastTransactionId
                }

                logger.info(
                    """
                    Started monitoring database \(database) with ID: \(id) via \(method) \
                    (\(session.initialUpdates.count) rows, \
                    \(session.resumed ? "resumed from \(lastTransactionId ?? "?")" : "full snapshot"))
                    """
                )
                return session
            } catch {
                // The monitor never started, so it must not be left registered —
                // `disconnect()` would try to cancel it.
                guard error.indicatesUnknownMethod, let next = method.fallback else {
                    monitors.removeValue(forKey: id)
                    throw error
                }
                if isFiltered, next == .monitor {
                    monitors.removeValue(forKey: id)
                    throw Self.conditionsUnsupported(database: database)
                }
                logger.info("Server does not implement \(method); falling back to \(next)")
                method = next
            }
        }
    }

    /// Issues one monitor request with the given method and parses its reply.
    private func startMonitor(
        _ method: OVSDBMonitorMethod,
        database: String,
        monitorId: String,
        tables: [String: OVSDBMonitorRequest],
        since lastTransactionId: String?
    ) async throws(OVNManagerError) -> OVSDBMonitorSession {
        switch method {
        case .monitorCondSince:
            let reply = try await client.monitorCondSince(
                database: database,
                monitorId: monitorId,
                requests: tables,
                since: lastTransactionId ?? OVSDBMonitorMethod.initialTransactionId
            )
            return OVSDBMonitorSession(
                monitorId: monitorId,
                method: method,
                resumed: reply.found,
                lastTransactionId: reply.lastTransactionId,
                initialUpdates: Self.parseTableUpdates(reply.tableUpdates, method: method, isReply: true)
            )
        case .monitorCond:
            let tableUpdates = try await client.monitorCond(
                database: database,
                monitorId: monitorId,
                requests: tables
            )
            return OVSDBMonitorSession(
                monitorId: monitorId,
                method: method,
                initialUpdates: Self.parseTableUpdates(tableUpdates, method: method, isReply: true)
            )
        case .monitor:
            // `where` has to come off the requests, not just be ignored:
            // ovsdb-server rejects the whole `monitor` request over an
            // unexpected member, even an empty one.
            let tableUpdates = try await client.monitor(
                database: database,
                monitorId: monitorId,
                requests: tables.mapValues { $0.droppingConditions() }
            )
            return OVSDBMonitorSession(
                monitorId: monitorId,
                method: method,
                initialUpdates: Self.parseTableUpdates(tableUpdates, method: method, isReply: true)
            )
        }
    }

    /// Replaces the `where` conditions of a running conditional monitor
    /// (`monitor_cond_change`). Rows that newly match arrive as inserts and rows
    /// that stopped matching as deletes, without the resynchronization that
    /// cancelling the monitor and starting another would cost.
    ///
    /// A table left out of `conditions` keeps the conditions it has; passing an
    /// empty list for a table makes it match every row again. Throws if the
    /// monitor is unknown to this connection, or was established with plain
    /// `monitor`, which has no conditions to change.
    public func updateMonitorConditions(
        monitorId: String,
        conditions: [String: [OVSDBCondition]]
    ) async throws(OVNManagerError) {
        guard let state = monitors[monitorId] else {
            throw OVNManagerError.operationFailed("No monitor with ID \(monitorId) on this connection")
        }
        guard state.method.usesRowUpdate2 else {
            throw OVNManagerError.operationFailed(
                """
                Monitor \(monitorId) was established with plain 'monitor', which has no \
                conditions to change; it has to be restarted with startConditionalMonitoring \
                against a server that implements monitor_cond.
                """
            )
        }

        try await client.monitorCondChange(monitorId: monitorId, conditions: conditions)

        logger.info("Changed conditions of monitor \(monitorId) on \(conditions.count) table(s)")
    }

    /// The method a monitor on this connection was established with, or nil if
    /// this connection has no such monitor.
    public func monitorMethod(forMonitor monitorId: String) -> OVSDBMonitorMethod? {
        return monitors[monitorId]?.method
    }

    /// The transaction id to resume a `monitor_cond_since` monitor from, as of
    /// the last batch this connection *delivered* to `monitorTableUpdates()`.
    /// Nil for a monitor established with `monitor_cond` or `monitor`, neither of
    /// which reports transaction ids.
    ///
    /// This tracks what was handed to the stream, not what a consumer finished
    /// with, and with several concurrent streams it follows whichever is furthest
    /// along. A consumer whose processing can fail — and which therefore must not
    /// resume past a batch it did not finish — should keep the
    /// `lastTransactionId` of the batch it last processed instead.
    public func lastTransactionId(forMonitor monitorId: String) -> String? {
        return monitors[monitorId]?.lastTransactionId
    }

    /// Records the transaction id an `update3` reported for a monitor. Called by
    /// `monitorTableUpdates()` as it delivers each batch.
    func record(transactionId: String, forMonitor monitorId: String) {
        monitors[monitorId]?.lastTransactionId = transactionId
    }

    public func stopMonitoring(monitorId: String) async throws(OVNManagerError) {
        // Forgotten first: whether or not the cancel reaches the server, this
        // monitor must not be re-created by the next reconnect.
        monitors.removeValue(forKey: monitorId)

        try await client.cancelMonitor(monitorId: monitorId)

        logger.info("Stopped monitoring with ID: \(monitorId)")
    }

    /// Whether any of these table requests asks the server to filter rows, and
    /// so cannot be served by plain `monitor`.
    private static func carryConditions(_ tables: [String: OVSDBMonitorRequest]) -> Bool {
        return tables.values.contains { !($0.whereConditions?.isEmpty ?? true) }
    }

    private static func conditionsUnsupported(database: String) -> OVNManagerError {
        return .operationFailed(
            """
            Cannot monitor \(database) conditionally: this server implements neither monitor_cond \
            nor monitor_cond_since, so the requested 'where' conditions cannot be evaluated. \
            Monitoring with plain 'monitor' instead would deliver every row of the requested \
            tables as if it matched.
            """
        )
    }

    /// Streams row changes from all monitors on this connection, optionally
    /// filtered to a single monitor ID.
    ///
    /// Changes from a conditional monitor are included, one row at a time like
    /// the rest — but a `modify` from one reports its changed columns in `diff`
    /// with `old` and `new` nil (see `OVSDBUpdate`), and the transaction id
    /// needed to resume the monitor is not per-row and so is not here. Use
    /// `monitorTableUpdates()` for either.
    ///
    /// Create the stream *before* calling `startMonitoring` so no update is
    /// missed; updates are buffered while the consumer is between iterations.
    /// The stream lives until the connection closes or the consumer cancels.
    ///
    /// Buffering is bounded (`OVSDBSocketConnection.notificationBufferSize`) so
    /// a consumer that stops draining cannot exhaust memory. One that falls
    /// that far behind gets `OVNManagerError.notificationsDropped`: rows were
    /// lost, so restart the monitor to resynchronize from a fresh snapshot
    /// instead of continuing from an incomplete view.
    ///
    /// A reconnect ends the stream with `OVNManagerError.monitorInterrupted` for
    /// the same reason: the monitors have been re-created on the new session
    /// automatically, but the changes made while the connection was down were
    /// never sent to anyone. Recover by re-reading the rows and taking a new
    /// stream — do not call `startMonitoring` again, or the monitor will be
    /// duplicated.
    ///
    /// Everything this stream can fail with is an `OVNManagerError`, but the
    /// failure type stays `any Error`: every `AsyncThrowingStream` initializer
    /// is constrained to `Failure == any Error`, so a typed-failure stream
    /// cannot be built. Match on `OVNManagerError` in the `catch`.
    nonisolated public func monitorUpdates(monitorId: String? = nil) -> AsyncThrowingStream<OVSDBUpdate, Error> {
        let batches = monitorTableUpdates(monitorId: monitorId)
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                do {
                    for try await batch in batches {
                        for update in batch.updates {
                            if case .dropped = continuation.yield(update) {
                                continuation.finish(throwing: OVNManagerError.notificationsDropped(count: 1))
                                return
                            }
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OVNManagerError.wrapping(error) {
                        .connectionFailed("Monitor stream failed: \($0)")
                    })
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Streams row changes a notification at a time, keeping the rows of one
    /// OVSDB transaction together and carrying the transaction id to resume a
    /// `monitor_cond_since` monitor from.
    ///
    /// This is the stream to use with `startConditionalMonitoring`: `update3`'s
    /// transaction id has nowhere to go in a per-row element, and it is only a
    /// valid resume point once every update in the batch has been processed.
    /// `monitorUpdates()` flattens these batches for callers that do not need
    /// either.
    ///
    /// The rules are `monitorUpdates()`': create the stream *before* starting the
    /// monitor so nothing is missed, filter to one monitor with `monitorId`, and
    /// a consumer that falls further behind than
    /// `OVSDBSocketConnection.notificationBufferSize` gets
    /// `OVNManagerError.notificationsDropped` rather than driving the process out
    /// of memory. On that error the monitor has to be restarted — though with
    /// `monitor_cond_since` and the last transaction id this consumer processed,
    /// restarting no longer means re-downloading the database.
    ///
    /// A reconnect ends the stream with `OVNManagerError.monitorInterrupted`. The
    /// monitor itself has already been re-established on the new session (resumed
    /// from the last transaction id this connection delivered, where its method
    /// allows), but the changes made while the connection was down reached nobody:
    /// take a new stream, and re-read whatever rows this consumer replicates —
    /// or resume from the last transaction id *it* processed, with
    /// `startConditionalMonitoring(since:)` under a new monitor id.
    ///
    /// Everything this stream can fail with is an `OVNManagerError`, but the
    /// failure type stays `any Error`: every `AsyncThrowingStream` initializer is
    /// constrained to `Failure == any Error`, so a typed-failure stream cannot be
    /// built. Match on `OVNManagerError` in the `catch`.
    nonisolated public func monitorTableUpdates(monitorId: String? = nil) -> AsyncThrowingStream<OVSDBTableUpdates, Error> {
        let notifications = client.monitorNotifications()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                do {
                    for try await notification in notifications {
                        if let monitorId, monitorId != notification.monitorId {
                            continue
                        }

                        let batch = OVSDBTableUpdates(
                            monitorId: notification.monitorId,
                            method: notification.method,
                            lastTransactionId: notification.lastTransactionId,
                            updates: Self.parseTableUpdates(
                                notification.tableUpdates,
                                method: notification.method
                            )
                        )

                        // Recorded before the yield, so that the connection's
                        // idea of where the monitor has got to never runs ahead
                        // of what it handed out.
                        if let transactionId = notification.lastTransactionId {
                            await self.record(transactionId: transactionId, forMonitor: notification.monitorId)
                        }

                        if case .dropped = continuation.yield(batch) {
                            continuation.finish(throwing: OVNManagerError.notificationsDropped(count: 1))
                            return
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: OVNManagerError.wrapping(error) {
                        .connectionFailed("Monitor stream failed: \($0)")
                    })
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    /// Parses a monitor reply or notification's row payload, in whichever of the
    /// two forms `method` uses.
    ///
    /// `isReply` marks the rows of a monitor's *reply* as `.initial`: they
    /// describe rows that already existed rather than changes. `<table-updates2>`
    /// says so itself, but RFC 7047's `<table-updates>` makes an initial row
    /// look exactly like an insert, so the caller has to supply what the wire
    /// does not carry.
    static func parseTableUpdates(
        _ value: JSONValue,
        method: OVSDBMonitorMethod,
        isReply: Bool = false
    ) -> [OVSDBUpdate] {
        return method.usesRowUpdate2
            ? parseTableUpdates2(value)
            : parseTableUpdates(value, areInitialRows: isReply)
    }

    /// Parses an RFC 7047 §4.1.6 table-updates object
    /// (`{table: {row-uuid: {"old": ..., "new": ...}}}`) into row updates.
    static func parseTableUpdates(_ value: JSONValue, areInitialRows: Bool = false) -> [OVSDBUpdate] {
        guard case .object(let tables) = value else {
            return []
        }

        var updates: [OVSDBUpdate] = []
        for (tableName, tableValue) in tables {
            guard case .object(let rows) = tableValue else { continue }
            for (rowUUID, rowValue) in rows {
                guard case .object(let rowUpdate) = rowValue else { continue }
                let old = row(rowUpdate["old"])
                let new = row(rowUpdate["new"])
                let kind = areInitialRows && old == nil && new != nil
                    ? OVSDBUpdate.Kind.initial
                    : OVSDBUpdate.kind(old: old, new: new)
                updates.append(
                    OVSDBUpdate(table: tableName, uuid: rowUUID, kind: kind, old: old, new: new)
                )
            }
        }
        return updates
    }

    /// Parses an ovsdb-server(7) table-updates2 object
    /// (`{table: {row-uuid: <row-update2>}}`), the form `monitor_cond` and
    /// `monitor_cond_since` replies and their `update2`/`update3` notifications
    /// take.
    ///
    /// Each row update names its change instead of pairing `old` with `new`, and
    /// a `modify` carries only the changed columns — kept as `diff` rather than
    /// turned into a row this layer cannot reconstruct (see `OVSDBUpdate`).
    static func parseTableUpdates2(_ value: JSONValue) -> [OVSDBUpdate] {
        guard case .object(let tables) = value else {
            return []
        }

        var updates: [OVSDBUpdate] = []
        for (tableName, tableValue) in tables {
            guard case .object(let rows) = tableValue else { continue }
            for (rowUUID, rowValue) in rows {
                guard case .object(let rowUpdate) = rowValue,
                      let update = parseRowUpdate2(rowUpdate, table: tableName, uuid: rowUUID) else {
                    continue
                }
                updates.append(update)
            }
        }
        return updates
    }

    /// Parses one `<row-update2>`, which holds exactly one of `initial`,
    /// `insert`, `modify` and `delete`. Returns nil for an object holding none of
    /// them, which is not a row update at all.
    private static func parseRowUpdate2(
        _ rowUpdate: [String: JSONValue],
        table: String,
        uuid: String
    ) -> OVSDBUpdate? {
        if let value = rowUpdate["initial"] {
            return OVSDBUpdate(table: table, uuid: uuid, kind: .initial, new: row(value))
        }
        if let value = rowUpdate["insert"] {
            return OVSDBUpdate(table: table, uuid: uuid, kind: .insert, new: row(value))
        }
        if let value = rowUpdate["modify"] {
            return OVSDBUpdate(table: table, uuid: uuid, kind: .modify, diff: row(value))
        }
        if let value = rowUpdate["delete"] {
            // ovsdb-server sends `"delete": null` — the client is assumed to have
            // the row already — so `old` is usually nil here. A server that does
            // send the row has it kept.
            return OVSDBUpdate(table: table, uuid: uuid, kind: .delete, old: row(value))
        }
        return nil
    }

    /// The value as a row, or nil if it is not a JSON object (`null`, most often).
    private static func row(_ value: JSONValue?) -> OVSDBRow? {
        guard case .object(let row)? = value else { return nil }
        return row
    }
}