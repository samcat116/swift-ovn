import Foundation
import NIO
import Logging

public actor OVSDBConnection {
    private let client: JSONRPCClient
    private let logger: Logger
    private var activeMonitors: Set<String> = []
    
    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.client = JSONRPCClient(
            socketPath: socketPath,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.ovsdb-connection")
    }
    
    public func connect() async throws {
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
    
    public func disconnect() async throws {
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
    
    public func listDatabases() async throws -> [String] {
        logger.debug("Listing databases")
        return try await client.listDatabases()
    }
    
    public func getDatabaseSchema(database: String) async throws -> JSONValue {
        logger.debug("Getting schema for database: \(database)")
        return try await client.getSchema(database: database)
    }
    
    // MARK: - Table Operations
    
    public func selectAll(from table: String, in database: String, columns: [String]? = nil) async throws -> [OVSDBRow] {
        let operation = OVSDBOperation(
            op: "select",
            table: table,
            whereConditions: [],  // Empty where clause to select all rows
            columns: columns
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
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
        
        return try rowsArray.map { jsonValue in
            guard case .object(let rowObject) = jsonValue else {
                throw OVNManagerError.invalidResponse("Invalid row format")
            }
            return rowObject
        }
    }
    
    public func select(
        from table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        columns: [String]? = nil
    ) async throws -> [OVSDBRow] {
        let operation = OVSDBOperation(
            op: "select",
            table: table,
            whereConditions: conditions,
            columns: columns
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
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
        
        return try rowsArray.map { jsonValue in
            guard case .object(let rowObject) = jsonValue else {
                throw OVNManagerError.invalidResponse("Invalid row format")
            }
            return rowObject
        }
    }
    
    public func insert(into table: String, in database: String, row: OVSDBRow) async throws -> JSONValue {
        let operation = OVSDBOperation(
            op: "insert",
            table: table,
            row: row
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first else {
            throw OVNManagerError.invalidResponse("No result from insert operation")
        }
        
        return firstResult
    }
    
    public func update(
        table: String,
        in database: String,
        where conditions: [OVSDBCondition],
        row: OVSDBRow
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "update",
            table: table,
            whereConditions: conditions,
            row: row
        )
        
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
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "delete",
            table: table,
            whereConditions: conditions
        )
        
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
    ) async throws -> Int {
        let operation = OVSDBOperation(
            op: "mutate",
            table: table,
            whereConditions: conditions,
            mutations: mutations
        )
        
        let results = try await client.transact(database: database, operations: [operation])
        
        guard let firstResult = results.first,
              case .object(let resultObject) = firstResult,
              let count = resultObject["count"],
              case .number(let countValue) = count else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
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
    ) async throws -> (monitorId: String, initialUpdates: [OVSDBUpdate]) {
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
    
    public func stopMonitoring(monitorId: String) async throws {
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
    nonisolated public func monitorUpdates(monitorId: String? = nil) -> AsyncThrowingStream<OVSDBUpdate, Error> {
        let clientStream = client.monitorUpdates()
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await (id, tableUpdates) in clientStream {
                        if let monitorId, monitorId != id {
                            continue
                        }
                        for update in Self.parseTableUpdates(tableUpdates) {
                            continuation.yield(update)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
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