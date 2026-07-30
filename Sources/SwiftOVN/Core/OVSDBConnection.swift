#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO
import Logging

public actor OVSDBConnection {
    private let client: JSONRPCClient
    private let logger: Logger
    private var activeMonitors: Set<String> = []
    
    public init(endpoint: OVSDBEndpoint, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.client = JSONRPCClient(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.ovsdb-connection")
    }

    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
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
    }

    public func disconnect() async throws(OVNManagerError) {
        // Cancel all active monitors
        let monitors = activeMonitors
        for monitorId in monitors {
            try? await client.cancelMonitor(monitorId: monitorId)
        }
        activeMonitors.removeAll()

        try await client.disconnect()
        logger.info("Disconnected from OVSDB")
    }
    
    public var isConnected: Bool {
        get async {
            return client.isConnected
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
    public func startMonitoring(
        database: String,
        tables: [String: OVSDBMonitorRequest],
        monitorId: String? = nil
    ) async throws(OVNManagerError) -> (monitorId: String, initialUpdates: [OVSDBUpdate]) {
        let id = monitorId ?? UUID().uuidString

        let initialState = try await client.monitor(
            database: database,
            monitorId: id,
            requests: tables
        )

        activeMonitors.insert(id)

        let initialUpdates = Self.parseTableUpdates(initialState)

        logger.info("Started monitoring database \(database) with ID: \(id) (\(initialUpdates.count) initial rows)")

        return (monitorId: id, initialUpdates: initialUpdates)
    }
    
    public func stopMonitoring(monitorId: String) async throws(OVNManagerError) {
        try await client.cancelMonitor(monitorId: monitorId)

        activeMonitors.remove(monitorId)

        logger.info("Stopped monitoring with ID: \(monitorId)")
    }
    
    /// Streams row changes from all monitors on this connection, optionally
    /// filtered to a single monitor ID.
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
    /// Everything this stream can fail with is an `OVNManagerError`, but the
    /// failure type stays `any Error`: every `AsyncThrowingStream` initializer
    /// is constrained to `Failure == any Error`, so a typed-failure stream
    /// cannot be built. Match on `OVNManagerError` in the `catch`.
    nonisolated public func monitorUpdates(monitorId: String? = nil) -> AsyncThrowingStream<OVSDBUpdate, Error> {
        let clientStream = client.monitorUpdates()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                do {
                    for try await (id, tableUpdates) in clientStream {
                        if let monitorId, monitorId != id {
                            continue
                        }
                        for update in Self.parseTableUpdates(tableUpdates) {
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

    /// Parses an RFC 7047 table-updates object
    /// (`{table: {row-uuid: {"old": ..., "new": ...}}}`) into row updates.
    static func parseTableUpdates(_ value: JSONValue) -> [OVSDBUpdate] {
        guard case .object(let tables) = value else {
            return []
        }

        var updates: [OVSDBUpdate] = []
        for (tableName, tableValue) in tables {
            guard case .object(let rows) = tableValue else { continue }
            for (rowUUID, rowValue) in rows {
                guard case .object(let rowUpdate) = rowValue else { continue }
                let old = rowUpdate["old"].flatMap { value -> OVSDBRow? in
                    if case .object(let obj) = value { return obj }
                    return nil
                }
                let new = rowUpdate["new"].flatMap { value -> OVSDBRow? in
                    if case .object(let obj) = value { return obj }
                    return nil
                }
                updates.append(OVSDBUpdate(table: tableName, uuid: rowUUID, old: old, new: new))
            }
        }
        return updates
    }
}