#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO
import Logging

/// Not an actor: every stored property is an immutable `let`, and all state
/// lives behind `OVSDBConnection` (which *is* an actor). Isolating this type
/// too would add an executor hop to every call while protecting nothing.
public final class OVNManager: OVNManaging {
    private let connection: OVSDBConnection
    private let logger: Logger
    private let database: String
    
    /// Manages `database` over a connection to the OVSDB cluster at `remotes`.
    ///
    /// - Parameters:
    ///   - remotes: The servers of one OVN database cluster, tried in order —
    ///     the equivalent of `ovn-nbctl --db=tcp:a:6641,tcp:b:6641,tcp:c:6641`.
    ///   - reconnect: How a lost session is re-established. See
    ///     `OVSDBReconnectPolicy`.
    ///   - leaderOnly: Whether to insist on the remote that reports itself the
    ///     RAFT leader of `database`. On by default, because writes are only
    ///     accepted by the leader; it has no effect on a single remote, and a
    ///     server too old to answer through `_Server` is used anyway.
    public init(
        remotes: OVSDBRemotes,
        database: String = OVNDatabase.northbound,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnly: Bool = true,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.connection = OVSDBConnection(
            remotes: remotes,
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnly ? database : nil,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.database = database
        self.logger = logger ?? Logger(label: "ovn-manager.ovn")
    }

    public convenience init(
        endpoint: OVSDBEndpoint,
        database: String = OVNDatabase.northbound,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnly: Bool = true,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            remotes: OVSDBRemotes(endpoint),
            database: database,
            reconnect: reconnect,
            leaderOnly: leaderOnly,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }

    public convenience init(socketPath: String, database: String = OVNDatabase.northbound, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), database: database, eventLoopGroup: eventLoopGroup, logger: logger)
    }
    
    // MARK: - Connection Management
    
    public func connect() async throws(OVNManagerError) {
        try await connection.connect()
        logger.info("Connected to OVN database: \(database)")
    }
    
    public func disconnect() async throws(OVNManagerError) {
        try await connection.disconnect()
        logger.info("Disconnected from OVN database")
    }
    
    public var isConnected: Bool {
        get async {
            return await connection.isConnected
        }
    }

    public nonisolated var connectionState: OVSDBConnectionState {
        return connection.connectionState
    }

    public nonisolated func connectionStates() -> AsyncStream<OVSDBConnectionState> {
        return connection.connectionStates()
    }
    
    // MARK: - Database Operations
    
    public func listDatabases() async throws(OVNManagerError) -> [String] {
        return try await connection.listDatabases()
    }
    
    public func getDatabaseSchema(database: String) async throws(OVNManagerError) -> JSONValue {
        return try await connection.getDatabaseSchema(database: database)
    }
    
    // MARK: - Logical Switch Operations
    
    public func getLogicalSwitches() async throws(OVNManagerError) -> [OVNLogicalSwitch] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitch, in: database)
        return try parseRows(rows, as: OVNLogicalSwitch.self)
    }
    
    public func getLogicalSwitch(named name: String) async throws(OVNManagerError) -> OVNLogicalSwitch? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitch.self)
    }
    
    public func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws(OVNManagerError) -> String {
        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(logicalSwitch.name))

        guard try await rowUUID(in: OVNTable.logicalSwitch, where: nameCondition) == nil else {
            throw OVNManagerError.operationFailed("Logical switch already exists: \(logicalSwitch.name)")
        }

        let row = try createRow(from: logicalSwitch)

        // The NB schema doesn't enforce unique switch names, so guard against
        // a duplicate racing in between the check above and the insert: abort
        // the transaction unless no row with this name exists (the same
        // technique ovn-nbctl ls-add uses to refuse duplicates).
        let operations: [OVSDBOperation] = [
            .wait(
                OVNTable.logicalSwitch,
                where: [nameCondition],
                columns: ["name"],
                rows: [],
                until: "==",
                timeout: 0
            ),
            .insert(into: OVNTable.logicalSwitch, row: row)
        ]

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count >= 2,
              case .object(let insertResult) = results[1],
              let uuid = insertResult["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created logical switch: \(logicalSwitch.name)")
        return uuidValue
    }
    
    public func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: logicalSwitch)
        
        let count = try await connection.update(table: OVNTable.logicalSwitch, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Updated logical switch: \(logicalSwitch.name)")
    }
    
    public func deleteLogicalSwitch(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Deleted logical switch: \(uuid)")
    }
    
    public func deleteLogicalSwitch(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(name)")
        }
        
        logger.info("Deleted logical switch: \(name)")
    }
    
    // MARK: - Logical Switch Port Operations
    
    public func getLogicalSwitchPorts() async throws(OVNManagerError) -> [OVNLogicalSwitchPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitchPort, in: database)
        return try parseRows(rows, as: OVNLogicalSwitchPort.self)
    }
    
    public func getLogicalSwitchPort(named name: String) async throws(OVNManagerError) -> OVNLogicalSwitchPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitchPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitchPort.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that ovn-northd ignores (no Port_Binding, no dataplane). Use createLogicalSwitchPort(_:onSwitch:) so the port is attached to its switch.")
    public func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws(OVNManagerError) -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVNTable.logicalSwitchPort, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created logical switch port: \(port.name)")
        return uuidValue
    }

    /// Creates a logical switch port and attaches it to the named logical
    /// switch in a single OVSDB transaction, mirroring `ovn-nbctl lsp-add`.
    /// A port whose UUID is not referenced by `Logical_Switch.ports` is an
    /// orphan that ovn-northd ignores, so the two steps must never diverge.
    public func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort, onSwitch switchName: String) async throws(OVNManagerError) -> String {
        let switchCondition = OVSDBCondition(column: "name", function: "==", value: .string(switchName))

        guard try await rowUUID(in: OVNTable.logicalSwitch, where: switchCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical switch not found: \(switchName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.logicalSwitchPort,
            in: database,
            row: try createRow(from: port),
            uuidName: "new_lsp",
            parentTable: OVNTable.logicalSwitch,
            parentColumn: "ports",
            parentCondition: switchCondition
        )

        logger.info("Created logical switch port: \(port.name) on switch: \(switchName)")
        return uuidValue
    }
    
    public func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalSwitchPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(uuid)")
        }
        
        logger.info("Updated logical switch port: \(port.name)")
    }
    
    public func deleteLogicalSwitchPort(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.logicalSwitchPort,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalSwitch, column: "ports")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(uuid)")
        }

        logger.info("Deleted logical switch port: \(uuid)")
    }

    public func deleteLogicalSwitchPort(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVNTable.logicalSwitchPort, where: condition) else {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(name)")
        }

        try await deleteLogicalSwitchPort(uuid: uuid)

        logger.info("Deleted logical switch port: \(name)")
    }
    
    // MARK: - Logical Router Operations
    
    public func getLogicalRouters() async throws(OVNManagerError) -> [OVNLogicalRouter] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouter, in: database)
        return try parseRows(rows, as: OVNLogicalRouter.self)
    }
    
    public func getLogicalRouter(named name: String) async throws(OVNManagerError) -> OVNLogicalRouter? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouter.self)
    }
    
    public func createLogicalRouter(_ router: OVNLogicalRouter) async throws(OVNManagerError) -> String {
        let row = try createRow(from: router)
        let result = try await connection.insert(into: OVNTable.logicalRouter, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created logical router: \(router.name)")
        return uuidValue
    }
    
    public func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: router)
        
        let count = try await connection.update(table: OVNTable.logicalRouter, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Updated logical router: \(router.name)")
    }
    
    public func deleteLogicalRouter(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Deleted logical router: \(uuid)")
    }
    
    public func deleteLogicalRouter(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(name)")
        }
        
        logger.info("Deleted logical router: \(name)")
    }
    
    // MARK: - Logical Router Port Operations
    
    public func getLogicalRouterPorts() async throws(OVNManagerError) -> [OVNLogicalRouterPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterPort, in: database)
        return try parseRows(rows, as: OVNLogicalRouterPort.self)
    }
    
    public func getLogicalRouterPort(named name: String) async throws(OVNManagerError) -> OVNLogicalRouterPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouterPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouterPort.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createLogicalRouterPort(_:onRouter:) so the port is attached to its router.")
    public func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws(OVNManagerError) -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVNTable.logicalRouterPort, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created logical router port: \(port.name)")
        return uuidValue
    }

    /// Creates a logical router port and attaches it to the named logical
    /// router in a single OVSDB transaction, mirroring `ovn-nbctl lrp-add`.
    /// Logical_Router_Port is not a root table, so an unreferenced row is
    /// garbage-collected when the transaction commits.
    public func createLogicalRouterPort(_ port: OVNLogicalRouterPort, onRouter routerName: String) async throws(OVNManagerError) -> String {
        let routerCondition = OVSDBCondition(column: "name", function: "==", value: .string(routerName))

        guard try await rowUUID(in: OVNTable.logicalRouter, where: routerCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical router not found: \(routerName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.logicalRouterPort,
            in: database,
            row: try createRow(from: port),
            uuidName: "new_lrp",
            parentTable: OVNTable.logicalRouter,
            parentColumn: "ports",
            parentCondition: routerCondition
        )

        logger.info("Created logical router port: \(port.name) on router: \(routerName)")
        return uuidValue
    }

    public func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalRouterPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(uuid)")
        }
        
        logger.info("Updated logical router port: \(port.name)")
    }
    
    public func deleteLogicalRouterPort(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.logicalRouterPort,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalRouter, column: "ports")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(uuid)")
        }

        logger.info("Deleted logical router port: \(uuid)")
    }

    public func deleteLogicalRouterPort(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVNTable.logicalRouterPort, where: condition) else {
            throw OVNManagerError.operationFailed("Logical router port not found: \(name)")
        }

        try await deleteLogicalRouterPort(uuid: uuid)

        logger.info("Deleted logical router port: \(name)")
    }

    // MARK: - Logical Router Static Route Operations

    public func getStaticRoutes() async throws(OVNManagerError) -> [OVNLogicalRouterStaticRoute] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterStaticRoute, in: database)
        return try parseRows(rows, as: OVNLogicalRouterStaticRoute.self)
    }

    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createStaticRoute(_:onRouter:) so the route is attached to its router.")
    public func createStaticRoute(_ route: OVNLogicalRouterStaticRoute) async throws(OVNManagerError) -> String {
        let row = try createRow(from: route)
        let result = try await connection.insert(into: OVNTable.logicalRouterStaticRoute, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created static route: \(route.ip_prefix)")
        return uuidValue
    }

    /// Creates a static route and attaches it to the named logical router
    /// (Logical_Router.static_routes) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl lr-route-add`. Logical_Router_Static_Route is not a root
    /// table, so an unreferenced row is garbage-collected when the transaction
    /// commits.
    public func createStaticRoute(_ route: OVNLogicalRouterStaticRoute, onRouter routerName: String) async throws(OVNManagerError) -> String {
        let routerCondition = OVSDBCondition(column: "name", function: "==", value: .string(routerName))

        guard try await rowUUID(in: OVNTable.logicalRouter, where: routerCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical router not found: \(routerName)")
        }

        // bfd is a weak reference: a session UUID that is stale at commit would
        // be dropped from the insert, leaving the route unmonitored with no
        // error to show for it.
        let guardOps = rowExistenceWaitOps(route.bfd.map { [$0] } ?? [], in: OVNTable.bfd)
        let attachOps = OVSDBReferenceTransactions.insertAttached(
            row: try createRow(from: route),
            into: OVNTable.logicalRouterStaticRoute,
            uuidName: "new_route",
            parentTable: OVNTable.logicalRouter,
            parentColumn: "static_routes",
            parentCondition: routerCondition
        )

        let results = try await connection.transact(in: database, operations: guardOps + attachOps)

        // attachOps is wait(router) → insert → mutate, so the insert's result
        // sits one past the guards.
        let uuidValue = try OVSDBConnection.uuid(fromInsertResults: results, at: guardOps.count + 1)

        logger.info("Created static route: \(route.ip_prefix) on router: \(routerName)")
        return uuidValue
    }

    public func updateStaticRoute(uuid: String, _ route: OVNLogicalRouterStaticRoute) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: route)

        // A full-row update rewrites the weak-reference bfd, so guard it
        // exactly as create does.
        var operations = rowExistenceWaitOps(route.bfd.map { [$0] } ?? [], in: OVNTable.bfd)
        let updateIndex = operations.count
        operations.append(.update(
            OVNTable.logicalRouterStaticRoute,
            where: [condition],
            row: row
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count > updateIndex,
              case .object(let updateResult) = results[updateIndex],
              case .number(let count)? = updateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("Static route not found: \(uuid)")
        }

        logger.info("Updated static route: \(uuid)")
    }

    public func deleteStaticRoute(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.logicalRouterStaticRoute,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalRouter, column: "static_routes")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Static route not found: \(uuid)")
        }

        logger.info("Deleted static route: \(uuid)")
    }

    // MARK: - Logical Router Policy Operations

    public func getPolicies() async throws(OVNManagerError) -> [OVNLogicalRouterPolicy] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterPolicy, in: database)
        return try parseRows(rows, as: OVNLogicalRouterPolicy.self)
    }

    /// Creates a policy and attaches it to the named logical router
    /// (Logical_Router.policies) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl lr-policy-add`. Logical_Router_Policy is not a root table, so
    /// an unreferenced row is garbage-collected when the transaction commits.
    public func createPolicy(_ policy: OVNLogicalRouterPolicy, onRouter routerName: String) async throws(OVNManagerError) -> String {
        let routerCondition = OVSDBCondition(column: "name", function: "==", value: .string(routerName))

        guard try await rowUUID(in: OVNTable.logicalRouter, where: routerCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical router not found: \(routerName)")
        }

        // output_port and bfd_sessions are weak references, so a UUID whose row
        // is stale at commit would be dropped from the insert — leaving a
        // reroute policy with no egress port, or an unmonitored next hop, and
        // no error to show for either.
        let guardOps = rowExistenceWaitOps(policy.output_port.map { [$0] } ?? [], in: OVNTable.logicalRouterPort)
            + rowExistenceWaitOps(policy.bfd_sessions ?? [], in: OVNTable.bfd)
        let attachOps = OVSDBReferenceTransactions.insertAttached(
            row: try createRow(from: policy, in: OVNTable.logicalRouterPolicy),
            into: OVNTable.logicalRouterPolicy,
            uuidName: "new_policy",
            parentTable: OVNTable.logicalRouter,
            parentColumn: "policies",
            parentCondition: routerCondition
        )

        let results = try await connection.transact(in: database, operations: guardOps + attachOps)

        // attachOps is wait(router) → insert → mutate, so the insert's result
        // sits one past the guards.
        let uuidValue = try OVSDBConnection.uuid(fromInsertResults: results, at: guardOps.count + 1)

        logger.info("Created router policy: \(policy.priority) \(policy.match) on router: \(routerName)")
        return uuidValue
    }

    public func updatePolicy(uuid: String, _ policy: OVNLogicalRouterPolicy) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: policy, in: OVNTable.logicalRouterPolicy)

        // A full-row update rewrites the weak references output_port and
        // bfd_sessions, so guard them exactly as create does.
        var operations = rowExistenceWaitOps(policy.output_port.map { [$0] } ?? [], in: OVNTable.logicalRouterPort)
            + rowExistenceWaitOps(policy.bfd_sessions ?? [], in: OVNTable.bfd)
        let updateIndex = operations.count
        operations.append(.update(
            OVNTable.logicalRouterPolicy,
            where: [condition],
            row: row
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count > updateIndex,
              case .object(let updateResult) = results[updateIndex],
              case .number(let count)? = updateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("Router policy not found: \(uuid)")
        }

        logger.info("Updated router policy: \(uuid)")
    }

    public func deletePolicy(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.logicalRouterPolicy,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalRouter, column: "policies")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Router policy not found: \(uuid)")
        }

        logger.info("Deleted router policy: \(uuid)")
    }

    // MARK: - Gateway Chassis Operations

    public func getGatewayChassis() async throws(OVNManagerError) -> [OVNGatewayChassis] {
        let rows = try await connection.selectAll(from: OVNTable.gatewayChassis, in: database)
        return try parseRows(rows, as: OVNGatewayChassis.self)
    }

    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createGatewayChassis(_:onRouterPort:) so the binding is attached to its router port.")
    public func createGatewayChassis(_ chassis: OVNGatewayChassis) async throws(OVNManagerError) -> String {
        let row = try createRow(from: chassis)
        let result = try await connection.insert(into: OVNTable.gatewayChassis, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created gateway chassis: \(chassis.name)")
        return uuidValue
    }

    /// Creates a gateway chassis and attaches it to the named logical router
    /// port (Logical_Router_Port.gateway_chassis) in a single OVSDB
    /// transaction, mirroring `ovn-nbctl lrp-set-gateway-chassis`.
    /// Gateway_Chassis is not a root table, so an unreferenced row is
    /// garbage-collected when the transaction commits.
    public func createGatewayChassis(_ chassis: OVNGatewayChassis, onRouterPort routerPortName: String) async throws(OVNManagerError) -> String {
        let portCondition = OVSDBCondition(column: "name", function: "==", value: .string(routerPortName))

        guard try await rowUUID(in: OVNTable.logicalRouterPort, where: portCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical router port not found: \(routerPortName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.gatewayChassis,
            in: database,
            row: try createRow(from: chassis),
            uuidName: "new_gw_chassis",
            parentTable: OVNTable.logicalRouterPort,
            parentColumn: "gateway_chassis",
            parentCondition: portCondition
        )

        logger.info("Created gateway chassis: \(chassis.name) on router port: \(routerPortName)")
        return uuidValue
    }

    public func updateGatewayChassis(uuid: String, _ chassis: OVNGatewayChassis) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: chassis)

        let count = try await connection.update(table: OVNTable.gatewayChassis, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Gateway chassis not found: \(uuid)")
        }

        logger.info("Updated gateway chassis: \(uuid)")
    }

    public func deleteGatewayChassis(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.gatewayChassis,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalRouterPort, column: "gateway_chassis")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Gateway chassis not found: \(uuid)")
        }

        logger.info("Deleted gateway chassis: \(uuid)")
    }

    // MARK: - HA Chassis Group Operations

    public func getHAChassisGroups() async throws(OVNManagerError) -> [OVNHAChassisGroup] {
        let rows = try await connection.selectAll(from: OVNTable.haChassisGroup, in: database)
        return try parseRows(rows, as: OVNHAChassisGroup.self)
    }

    public func getHAChassisGroup(named name: String) async throws(OVNManagerError) -> OVNHAChassisGroup? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.haChassisGroup, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNHAChassisGroup.self)
    }

    /// Creates an HA chassis group. HA_Chassis_Group is a root table, so the
    /// row persists on its own; attach members with `createHAChassis(_:inGroup:)`
    /// and reference it from a port's `ha_chassis_group` column.
    public func createHAChassisGroup(_ group: OVNHAChassisGroup) async throws(OVNManagerError) -> String {
        let row = try createRow(from: group)
        let result = try await connection.insert(into: OVNTable.haChassisGroup, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created HA chassis group: \(group.name)")
        return uuidValue
    }

    public func updateHAChassisGroup(uuid: String, _ group: OVNHAChassisGroup) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: group)

        let count = try await connection.update(table: OVNTable.haChassisGroup, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("HA chassis group not found: \(uuid)")
        }

        logger.info("Updated HA chassis group: \(group.name)")
    }

    public func deleteHAChassisGroup(uuid: String) async throws(OVNManagerError) {
        // The ha_chassis_group columns on Logical_Router_Port and
        // Logical_Switch_Port are strong references, so ovsdb-server rejects
        // deleting the group while a port still points at it. Detach those
        // port columns in the same transaction before deleting. The group's
        // HA_Chassis members become orphans and are garbage-collected.
        let count = try await connection.deleteDetaching(
            from: OVNTable.haChassisGroup,
            in: database,
            uuid: uuid,
            parentReferences: [
                OVSDBParentReference(table: OVNTable.logicalRouterPort, column: "ha_chassis_group"),
                OVSDBParentReference(table: OVNTable.logicalSwitchPort, column: "ha_chassis_group")
            ]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("HA chassis group not found: \(uuid)")
        }

        logger.info("Deleted HA chassis group: \(uuid)")
    }

    // MARK: - HA Chassis Operations

    public func getHAChassis() async throws(OVNManagerError) -> [OVNHAChassis] {
        let rows = try await connection.selectAll(from: OVNTable.haChassis, in: database)
        return try parseRows(rows, as: OVNHAChassis.self)
    }

    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createHAChassis(_:inGroup:) so the member is attached to its group.")
    public func createHAChassis(_ chassis: OVNHAChassis) async throws(OVNManagerError) -> String {
        let row = try createRow(from: chassis)
        let result = try await connection.insert(into: OVNTable.haChassis, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created HA chassis: \(chassis.chassis_name)")
        return uuidValue
    }

    /// Creates an HA chassis and attaches it to the named HA chassis group
    /// (HA_Chassis_Group.ha_chassis) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl ha-chassis-group-add-chassis`. HA_Chassis is not a root
    /// table, so an unreferenced row is garbage-collected when the transaction
    /// commits.
    public func createHAChassis(_ chassis: OVNHAChassis, inGroup groupName: String) async throws(OVNManagerError) -> String {
        let groupCondition = OVSDBCondition(column: "name", function: "==", value: .string(groupName))

        guard try await rowUUID(in: OVNTable.haChassisGroup, where: groupCondition) != nil else {
            throw OVNManagerError.operationFailed("HA chassis group not found: \(groupName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.haChassis,
            in: database,
            row: try createRow(from: chassis),
            uuidName: "new_ha_chassis",
            parentTable: OVNTable.haChassisGroup,
            parentColumn: "ha_chassis",
            parentCondition: groupCondition
        )

        logger.info("Created HA chassis: \(chassis.chassis_name) in group: \(groupName)")
        return uuidValue
    }

    public func updateHAChassis(uuid: String, _ chassis: OVNHAChassis) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: chassis)

        let count = try await connection.update(table: OVNTable.haChassis, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("HA chassis not found: \(uuid)")
        }

        logger.info("Updated HA chassis: \(uuid)")
    }

    public func deleteHAChassis(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.haChassis,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.haChassisGroup, column: "ha_chassis")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("HA chassis not found: \(uuid)")
        }

        logger.info("Deleted HA chassis: \(uuid)")
    }

    // MARK: - ACL Operations
    
    public func getACLs() async throws(OVNManagerError) -> [OVNACL] {
        let rows = try await connection.selectAll(from: OVNTable.acl, in: database)
        return try parseRows(rows, as: OVNACL.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createACL(_:onSwitch:) or createACL(_:onPortGroup:) so the ACL is attached.")
    public func createACL(_ acl: OVNACL) async throws(OVNManagerError) -> String {
        let row = try createRow(from: acl)
        let result = try await connection.insert(into: OVNTable.acl, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created ACL")
        return uuidValue
    }

    /// Creates an ACL and attaches it to the named logical switch
    /// (Logical_Switch.acls) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl acl-add`. ACL is not a root table, so an unreferenced row
    /// is garbage-collected when the transaction commits.
    public func createACL(_ acl: OVNACL, onSwitch switchName: String) async throws(OVNManagerError) -> String {
        let switchCondition = OVSDBCondition(column: "name", function: "==", value: .string(switchName))

        guard try await rowUUID(in: OVNTable.logicalSwitch, where: switchCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical switch not found: \(switchName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.acl,
            in: database,
            row: try createRow(from: acl),
            uuidName: "new_acl",
            parentTable: OVNTable.logicalSwitch,
            parentColumn: "acls",
            parentCondition: switchCondition
        )

        logger.info("Created ACL on switch: \(switchName)")
        return uuidValue
    }

    /// Creates an ACL and attaches it to the named port group
    /// (Port_Group.acls) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl acl-add ... pg`.
    public func createACL(_ acl: OVNACL, onPortGroup portGroupName: String) async throws(OVNManagerError) -> String {
        let groupCondition = OVSDBCondition(column: "name", function: "==", value: .string(portGroupName))

        guard try await rowUUID(in: OVNTable.portGroup, where: groupCondition) != nil else {
            throw OVNManagerError.operationFailed("Port group not found: \(portGroupName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.acl,
            in: database,
            row: try createRow(from: acl),
            uuidName: "new_acl",
            parentTable: OVNTable.portGroup,
            parentColumn: "acls",
            parentCondition: groupCondition
        )

        logger.info("Created ACL on port group: \(portGroupName)")
        return uuidValue
    }
    
    public func updateACL(uuid: String, _ acl: OVNACL) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: acl)
        
        let count = try await connection.update(table: OVNTable.acl, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("ACL not found: \(uuid)")
        }
        
        logger.info("Updated ACL: \(uuid)")
    }
    
    public func deleteACL(uuid: String) async throws(OVNManagerError) {
        // ACLs are strongly referenced from Logical_Switch.acls and
        // Port_Group.acls; ovsdb-server rejects the delete while either
        // reference remains, so detach from both in the same transaction.
        let count = try await connection.deleteDetaching(
            from: OVNTable.acl,
            in: database,
            uuid: uuid,
            parentReferences: [
                OVSDBParentReference(table: OVNTable.logicalSwitch, column: "acls"),
                OVSDBParentReference(table: OVNTable.portGroup, column: "acls")
            ]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("ACL not found: \(uuid)")
        }

        logger.info("Deleted ACL: \(uuid)")
    }

    // MARK: - Port Group Operations

    public func getPortGroups() async throws(OVNManagerError) -> [OVNPortGroup] {
        let rows = try await connection.selectAll(from: OVNTable.portGroup, in: database)
        return try parseRows(rows, as: OVNPortGroup.self)
    }

    public func getPortGroup(named name: String) async throws(OVNManagerError) -> OVNPortGroup? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.portGroup, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNPortGroup.self)
    }

    /// Creates a port group, mirroring `ovn-nbctl pg-add`. Port_Group is a
    /// root table, so the row persists until it is explicitly deleted.
    public func createPortGroup(_ portGroup: OVNPortGroup) async throws(OVNManagerError) -> String {
        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(portGroup.name))

        guard try await rowUUID(in: OVNTable.portGroup, where: nameCondition) == nil else {
            throw OVNManagerError.operationFailed("Port group already exists: \(portGroup.name)")
        }

        // `ports` is a weak reference set, so any initial member whose port row
        // is stale at commit would be silently dropped from the insert. Guard
        // each supplied port so a stale UUID aborts the whole insert instead of
        // creating a group with missing membership.
        let uuidValue = try await insertUniquelyNamed(
            row: try createRow(from: portGroup),
            into: OVNTable.portGroup,
            nameCondition: nameCondition,
            guardOperations: portExistenceWaitOps(portGroup.ports ?? [])
        )

        logger.info("Created port group: \(portGroup.name)")
        return uuidValue
    }

    public func updatePortGroup(uuid: String, _ portGroup: OVNPortGroup) async throws(OVNManagerError) {
        // A full-row update rewrites the weak-reference `ports` set, so guard
        // each supplied port the same way create/mutate do: a stale UUID aborts
        // the update rather than being silently dropped from the new set.
        let count = try await updateGuarded(
            row: try createRow(from: portGroup),
            in: OVNTable.portGroup,
            uuid: uuid,
            guardOperations: portExistenceWaitOps(portGroup.ports ?? [])
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(uuid)")
        }

        logger.info("Updated port group: \(portGroup.name)")
    }

    /// Adds logical switch ports to the group's membership without rewriting
    /// the whole `ports` set, mirroring `ovn-nbctl pg-set-ports` incrementally.
    /// Throws if any requested port no longer exists, so a stale UUID can't be
    /// silently dropped from this weak reference set (see `mutatePorts`).
    public func addPorts(_ portUUIDs: [String], toPortGroup name: String) async throws(OVNManagerError) {
        try await mutatePorts(portUUIDs, portGroup: name, mutator: "insert")
    }

    /// Removes logical switch ports from the group's membership without
    /// rewriting the whole `ports` set.
    public func removePorts(_ portUUIDs: [String], fromPortGroup name: String) async throws(OVNManagerError) {
        try await mutatePorts(portUUIDs, portGroup: name, mutator: "delete")
    }

    public func deletePortGroup(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.portGroup, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(uuid)")
        }

        logger.info("Deleted port group: \(uuid)")
    }

    public func deletePortGroup(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.portGroup, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(name)")
        }

        logger.info("Deleted port group: \(name)")
    }

    // MARK: - Address Set Operations

    public func getAddressSets() async throws(OVNManagerError) -> [OVNAddressSet] {
        let rows = try await connection.selectAll(from: OVNTable.addressSet, in: database)
        return try parseRows(rows, as: OVNAddressSet.self)
    }

    public func getAddressSet(named name: String) async throws(OVNManagerError) -> OVNAddressSet? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.addressSet, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNAddressSet.self)
    }

    /// Creates an address set. `Address_Set` is a root table, so the row
    /// persists until it is explicitly deleted, and `addresses` holds plain
    /// strings rather than references — no attach or existence guard is needed.
    ///
    /// The name check ahead of the insert is only there for the error message:
    /// the NB schema indexes `name`, so a duplicate racing in behind the check
    /// is rejected by ovsdb-server rather than creating a second set.
    public func createAddressSet(_ addressSet: OVNAddressSet) async throws(OVNManagerError) -> String {
        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(addressSet.name))

        guard try await rowUUID(in: OVNTable.addressSet, where: nameCondition) == nil else {
            throw OVNManagerError.operationFailed("Address set already exists: \(addressSet.name)")
        }

        let row = try createRow(from: addressSet)
        let result = try await connection.insert(into: OVNTable.addressSet, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created address set: \(addressSet.name)")
        return uuidValue
    }

    /// Replaces the whole row, including the `addresses` set. Use
    /// `addAddresses(_:toAddressSet:)`/`removeAddresses(_:fromAddressSet:)` for
    /// a membership change, so a concurrent writer's members are not lost.
    public func updateAddressSet(uuid: String, _ addressSet: OVNAddressSet) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: addressSet)

        let count = try await connection.update(table: OVNTable.addressSet, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Address set not found: \(uuid)")
        }

        logger.info("Updated address set: \(addressSet.name)")
    }

    /// Adds addresses to the set's membership without rewriting the whole
    /// `addresses` column, mirroring `ovn-nbctl add Address_Set ... addresses`.
    /// Inserting an address that is already a member is a no-op, as it is for
    /// any OVSDB set.
    public func addAddresses(_ addresses: [String], toAddressSet name: String) async throws(OVNManagerError) {
        try await mutateAddresses(addresses, addressSet: name, mutator: "insert")
    }

    /// Removes addresses from the set's membership without rewriting the whole
    /// `addresses` column. Removing an address that is not a member is a no-op.
    public func removeAddresses(_ addresses: [String], fromAddressSet name: String) async throws(OVNManagerError) {
        try await mutateAddresses(addresses, addressSet: name, mutator: "delete")
    }

    public func deleteAddressSet(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.addressSet, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Address set not found: \(uuid)")
        }

        logger.info("Deleted address set: \(uuid)")
    }

    public func deleteAddressSet(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.addressSet, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Address set not found: \(name)")
        }

        logger.info("Deleted address set: \(name)")
    }

    // MARK: - Load Balancer Operations
    
    public func getLoadBalancers() async throws(OVNManagerError) -> [OVNLoadBalancer] {
        let rows = try await connection.selectAll(from: OVNTable.loadBalancer, in: database)
        return try parseRows(rows, as: OVNLoadBalancer.self)
    }
    
    public func getLoadBalancer(named name: String) async throws(OVNManagerError) -> OVNLoadBalancer? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLoadBalancer.self)
    }
    
    public func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws(OVNManagerError) -> String {
        let row = try createRow(from: loadBalancer)
        let result = try await connection.insert(into: OVNTable.loadBalancer, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created load balancer: \(loadBalancer.name)")
        return uuidValue
    }
    
    public func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: loadBalancer)
        
        let count = try await connection.update(table: OVNTable.loadBalancer, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Updated load balancer: \(loadBalancer.name)")
    }
    
    public func deleteLoadBalancer(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Deleted load balancer: \(uuid)")
    }
    
    public func deleteLoadBalancer(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(name)")
        }
        
        logger.info("Deleted load balancer: \(name)")
    }

    /// Attaches an existing load balancer to the named logical switch
    /// (Logical_Switch.load_balancer), mirroring `ovn-nbctl ls-lb-add`.
    /// Load_Balancer is a root table, so rows survive unattached — but a
    /// load balancer has no effect until a switch or router references it.
    public func attachLoadBalancer(uuid: String, toSwitch switchName: String) async throws(OVNManagerError) {
        try await attachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Attached load balancer \(uuid) to switch: \(switchName)")
    }

    /// Attaches an existing load balancer to the named logical router
    /// (Logical_Router.load_balancer), mirroring `ovn-nbctl lr-lb-add`.
    public func attachLoadBalancer(uuid: String, toRouter routerName: String) async throws(OVNManagerError) {
        try await attachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Attached load balancer \(uuid) to router: \(routerName)")
    }

    /// Detaches a load balancer from the named logical switch, mirroring
    /// `ovn-nbctl ls-lb-del`. The load balancer row itself is kept.
    public func detachLoadBalancer(uuid: String, fromSwitch switchName: String) async throws(OVNManagerError) {
        try await detachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Detached load balancer \(uuid) from switch: \(switchName)")
    }

    /// Detaches a load balancer from the named logical router, mirroring
    /// `ovn-nbctl lr-lb-del`. The load balancer row itself is kept.
    public func detachLoadBalancer(uuid: String, fromRouter routerName: String) async throws(OVNManagerError) {
        try await detachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Detached load balancer \(uuid) from router: \(routerName)")
    }

    // MARK: - Load Balancer Health Check Operations

    public func getLoadBalancerHealthChecks() async throws(OVNManagerError) -> [OVNLoadBalancerHealthCheck] {
        let rows = try await connection.selectAll(from: OVNTable.loadBalancerHealthCheck, in: database)
        return try parseRows(rows, as: OVNLoadBalancerHealthCheck.self)
    }

    /// Creates a health check and attaches it to a load balancer
    /// (Load_Balancer.health_check) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl lb-add-health-check`. Load_Balancer_Health_Check is not a
    /// root table, so an unreferenced row is garbage-collected when the
    /// transaction commits — there is deliberately no unattached create.
    ///
    /// The load balancer is identified by UUID rather than by name because the
    /// NB schema puts no index on `Load_Balancer.name`: two load balancers may
    /// legally carry the same name, and a name lookup would attach the check
    /// to an arbitrary one of them.
    ///
    /// The check still needs a matching `ip_port_mappings` entry on the load
    /// balancer before ovn-controller probes anything; this call only writes
    /// the check row.
    public func createLoadBalancerHealthCheck(_ healthCheck: OVNLoadBalancerHealthCheck, onLoadBalancer loadBalancerUUID: String) async throws(OVNManagerError) -> String {
        let lbCondition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(loadBalancerUUID)]))

        guard try await rowUUID(in: OVNTable.loadBalancer, where: lbCondition) != nil else {
            throw OVNManagerError.operationFailed("Load balancer not found: \(loadBalancerUUID)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.loadBalancerHealthCheck,
            in: database,
            row: try createRow(from: healthCheck),
            uuidName: "new_health_check",
            parentTable: OVNTable.loadBalancer,
            parentColumn: "health_check",
            parentCondition: lbCondition
        )

        logger.info("Created health check for \(healthCheck.vip) on load balancer: \(loadBalancerUUID)")
        return uuidValue
    }

    public func updateLoadBalancerHealthCheck(uuid: String, _ healthCheck: OVNLoadBalancerHealthCheck) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: healthCheck)

        let count = try await connection.update(table: OVNTable.loadBalancerHealthCheck, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer health check not found: \(uuid)")
        }

        logger.info("Updated load balancer health check: \(uuid)")
    }

    /// Deletes a health check, removing it from its load balancer's
    /// `health_check` set in the same transaction — that is a strong
    /// reference, so ovsdb-server would otherwise reject the delete.
    public func deleteLoadBalancerHealthCheck(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.loadBalancerHealthCheck,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.loadBalancer, column: "health_check")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer health check not found: \(uuid)")
        }

        logger.info("Deleted load balancer health check: \(uuid)")
    }

    // MARK: - Load Balancer Group Operations

    public func getLoadBalancerGroups() async throws(OVNManagerError) -> [OVNLoadBalancerGroup] {
        let rows = try await connection.selectAll(from: OVNTable.loadBalancerGroup, in: database)
        return try parseRows(rows, as: OVNLoadBalancerGroup.self)
    }

    public func getLoadBalancerGroup(named name: String) async throws(OVNManagerError) -> OVNLoadBalancerGroup? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.loadBalancerGroup, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLoadBalancerGroup.self)
    }

    /// Creates a load balancer group, mirroring `ovn-nbctl lb-group-add`.
    /// Load_Balancer_Group is a root table, so the row persists until it is
    /// explicitly deleted, and it has no effect until a switch or router
    /// references it.
    public func createLoadBalancerGroup(_ group: OVNLoadBalancerGroup) async throws(OVNManagerError) -> String {
        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(group.name))

        guard try await rowUUID(in: OVNTable.loadBalancerGroup, where: nameCondition) == nil else {
            throw OVNManagerError.operationFailed("Load balancer group already exists: \(group.name)")
        }

        // `load_balancer` is a weak reference set, so an initial member whose
        // row is stale at commit would be silently dropped from the insert.
        let uuidValue = try await insertUniquelyNamed(
            row: try createRow(from: group),
            into: OVNTable.loadBalancerGroup,
            nameCondition: nameCondition,
            guardOperations: loadBalancerExistenceWaitOps(group.load_balancer ?? [])
        )

        logger.info("Created load balancer group: \(group.name)")
        return uuidValue
    }

    public func updateLoadBalancerGroup(uuid: String, _ group: OVNLoadBalancerGroup) async throws(OVNManagerError) {
        // A full-row update rewrites the weak-reference `load_balancer` set, so
        // guard each member the same way create and mutate do.
        let count = try await updateGuarded(
            row: try createRow(from: group),
            in: OVNTable.loadBalancerGroup,
            uuid: uuid,
            guardOperations: loadBalancerExistenceWaitOps(group.load_balancer ?? [])
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer group not found: \(uuid)")
        }

        logger.info("Updated load balancer group: \(group.name)")
    }

    /// Adds load balancers to a group's membership without rewriting the whole
    /// `load_balancer` set, mirroring `ovn-nbctl lb-group-add-lb`. Throws if
    /// any requested load balancer no longer exists, so a stale UUID can't be
    /// silently dropped from this weak reference set.
    public func addLoadBalancers(_ loadBalancerUUIDs: [String], toGroup name: String) async throws(OVNManagerError) {
        try await mutateLoadBalancerGroupMembers(loadBalancerUUIDs, group: name, mutator: "insert")
    }

    /// Removes load balancers from a group's membership without rewriting the
    /// whole `load_balancer` set, mirroring `ovn-nbctl lb-group-del-lb`. The
    /// load balancer rows themselves are kept.
    public func removeLoadBalancers(_ loadBalancerUUIDs: [String], fromGroup name: String) async throws(OVNManagerError) {
        try await mutateLoadBalancerGroupMembers(loadBalancerUUIDs, group: name, mutator: "delete")
    }

    /// Deletes a load balancer group, detaching it from every switch and
    /// router that references it in the same transaction. The group is a root
    /// table row, so it is never garbage-collected — but
    /// `Logical_Switch.load_balancer_group` and
    /// `Logical_Router.load_balancer_group` are *strong* references, so
    /// ovsdb-server rejects the delete while either still names the group. The
    /// member load balancers are untouched; membership is a weak reference.
    public func deleteLoadBalancerGroup(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.loadBalancerGroup,
            in: database,
            uuid: uuid,
            parentReferences: [
                OVSDBParentReference(table: OVNTable.logicalSwitch, column: "load_balancer_group"),
                OVSDBParentReference(table: OVNTable.logicalRouter, column: "load_balancer_group"),
            ]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer group not found: \(uuid)")
        }

        logger.info("Deleted load balancer group: \(uuid)")
    }

    public func deleteLoadBalancerGroup(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))

        guard let uuid = try await rowUUID(in: OVNTable.loadBalancerGroup, where: condition) else {
            throw OVNManagerError.operationFailed("Load balancer group not found: \(name)")
        }

        try await deleteLoadBalancerGroup(uuid: uuid)
    }

    /// Attaches a load balancer group to the named logical switch
    /// (Logical_Switch.load_balancer_group), mirroring
    /// `ovn-nbctl ls-lb-group-add`. Every load balancer in the group applies to
    /// the switch, including ones added to the group afterwards.
    public func attachLoadBalancerGroup(uuid: String, toSwitch switchName: String) async throws(OVNManagerError) {
        try await attachLoadBalancerGroup(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Attached load balancer group \(uuid) to switch: \(switchName)")
    }

    /// Attaches a load balancer group to the named logical router
    /// (Logical_Router.load_balancer_group), mirroring
    /// `ovn-nbctl lr-lb-group-add`.
    public func attachLoadBalancerGroup(uuid: String, toRouter routerName: String) async throws(OVNManagerError) {
        try await attachLoadBalancerGroup(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Attached load balancer group \(uuid) to router: \(routerName)")
    }

    /// Detaches a load balancer group from the named logical switch. The group
    /// row itself is kept.
    public func detachLoadBalancerGroup(uuid: String, fromSwitch switchName: String) async throws(OVNManagerError) {
        try await detachLoadBalancerGroup(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Detached load balancer group \(uuid) from switch: \(switchName)")
    }

    /// Detaches a load balancer group from the named logical router. The group
    /// row itself is kept.
    public func detachLoadBalancerGroup(uuid: String, fromRouter routerName: String) async throws(OVNManagerError) {
        try await detachLoadBalancerGroup(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Detached load balancer group \(uuid) from router: \(routerName)")
    }

    // MARK: - NAT Operations
    
    public func getNATRules() async throws(OVNManagerError) -> [OVNNAT] {
        let rows = try await connection.selectAll(from: OVNTable.nat, in: database)
        return try parseRows(rows, as: OVNNAT.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNATRule(_:onRouter:) so the rule is attached to its router.")
    public func createNATRule(_ nat: OVNNAT) async throws(OVNManagerError) -> String {
        let row = try createRow(from: nat)
        let result = try await connection.insert(into: OVNTable.nat, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created NAT rule")
        return uuidValue
    }

    /// Creates a NAT rule and attaches it to the named logical router
    /// (Logical_Router.nat) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl lr-nat-add`. NAT is not a root table, so an unreferenced
    /// row is garbage-collected when the transaction commits.
    public func createNATRule(_ nat: OVNNAT, onRouter routerName: String) async throws(OVNManagerError) -> String {
        let routerCondition = OVSDBCondition(column: "name", function: "==", value: .string(routerName))

        guard try await rowUUID(in: OVNTable.logicalRouter, where: routerCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical router not found: \(routerName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.nat,
            in: database,
            row: try createRow(from: nat),
            uuidName: "new_nat",
            parentTable: OVNTable.logicalRouter,
            parentColumn: "nat",
            parentCondition: routerCondition
        )

        logger.info("Created NAT rule on router: \(routerName)")
        return uuidValue
    }
    
    public func updateNATRule(uuid: String, _ nat: OVNNAT) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: nat)
        
        let count = try await connection.update(table: OVNTable.nat, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NAT rule not found: \(uuid)")
        }
        
        logger.info("Updated NAT rule: \(uuid)")
    }
    
    public func deleteNATRule(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.nat,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalRouter, column: "nat")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("NAT rule not found: \(uuid)")
        }

        logger.info("Deleted NAT rule: \(uuid)")
    }
    
    // MARK: - QoS Operations

    /// Rows of the Northbound `QoS` table. Unrelated to `OVSManager`'s
    /// `getQoSPolicies()`, which reads the Open_vSwitch table of the same name.
    public func getQoSRules() async throws(OVNManagerError) -> [OVNQoS] {
        let rows = try await connection.selectAll(from: OVNTable.qos, in: database)
        return try parseRows(rows, as: OVNQoS.self)
    }

    /// Creates a QoS rule and attaches it to the named logical switch
    /// (Logical_Switch.qos_rules) in a single OVSDB transaction, mirroring
    /// `ovn-nbctl qos-add`. QoS is not a root table, so an unreferenced row is
    /// garbage-collected when the transaction commits — there is deliberately
    /// no unattached create.
    public func createQoSRule(_ qos: OVNQoS, onSwitch switchName: String) async throws(OVNManagerError) -> String {
        let switchCondition = OVSDBCondition(column: "name", function: "==", value: .string(switchName))

        guard try await rowUUID(in: OVNTable.logicalSwitch, where: switchCondition) != nil else {
            throw OVNManagerError.operationFailed("Logical switch not found: \(switchName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.qos,
            in: database,
            row: try createRow(from: qos),
            uuidName: "new_qos",
            parentTable: OVNTable.logicalSwitch,
            parentColumn: "qos_rules",
            parentCondition: switchCondition
        )

        logger.info("Created QoS rule on switch: \(switchName)")
        return uuidValue
    }

    public func updateQoSRule(uuid: String, _ qos: OVNQoS) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: qos)

        let count = try await connection.update(table: OVNTable.qos, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("QoS rule not found: \(uuid)")
        }

        logger.info("Updated QoS rule: \(uuid)")
    }

    public func deleteQoSRule(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.qos,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.logicalSwitch, column: "qos_rules")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("QoS rule not found: \(uuid)")
        }

        logger.info("Deleted QoS rule: \(uuid)")
    }

    // MARK: - BFD Operations

    /// Rows of the Northbound `BFD` table — the sessions referenced by
    /// `Logical_Router_Static_Route.bfd` and `Logical_Router_Policy.bfd_sessions`.
    public func getBFDSessions() async throws(OVNManagerError) -> [OVNBFD] {
        let rows = try await connection.selectAll(from: OVNTable.bfd, in: database)
        return try parseRows(rows, as: OVNBFD.self)
    }

    /// Creates a BFD session. `BFD` is a root table, so the row stands on its
    /// own — but it monitors nothing until a static route or a router policy
    /// references it.
    ///
    /// The schema indexes `(logical_port, dst_ip)`: a second session for a pair
    /// that already has one is rejected by ovsdb-server, surfacing as
    /// `operationFailed` carrying the constraint violation.
    public func createBFDSession(_ bfd: OVNBFD) async throws(OVNManagerError) -> String {
        let row = try createRow(from: bfd)
        let result = try await connection.insert(into: OVNTable.bfd, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created BFD session: \(bfd.logical_port) -> \(bfd.dst_ip)")
        return uuidValue
    }

    /// Rewrites a BFD session. `status` is never written — see `OVNBFD.status`.
    public func updateBFDSession(uuid: String, _ bfd: OVNBFD) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: bfd)

        let count = try await connection.update(table: OVNTable.bfd, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("BFD session not found: \(uuid)")
        }

        logger.info("Updated BFD session: \(uuid)")
    }

    /// Deletes a BFD session. Both columns that reference one are *weak*, so
    /// ovsdb-server drops the reference from any static route or router policy
    /// still naming this session rather than rejecting the delete — no
    /// detaching transaction is needed, but whatever the session monitored is
    /// left unmonitored.
    public func deleteBFDSession(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.bfd, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("BFD session not found: \(uuid)")
        }

        logger.info("Deleted BFD session: \(uuid)")
    }

    // MARK: - DNS Operations

    /// Rows of the Northbound `DNS` table. Each row is a *set* of records, not
    /// a single one.
    public func getDNS() async throws(OVNManagerError) -> [OVNDNS] {
        let rows = try await connection.selectAll(from: OVNTable.dns, in: database)
        return try parseRows(rows, as: OVNDNS.self)
    }

    /// Creates a DNS record set. `DNS` is a root table, so the row survives
    /// unattached — `attachDNS(uuid:toSwitch:)` is what puts it in front of a
    /// switch's queries.
    public func createDNS(_ dns: OVNDNS) async throws(OVNManagerError) -> String {
        let row = try createRow(from: dns)
        let result = try await connection.insert(into: OVNTable.dns, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created DNS record set with \(dns.records.count) record(s)")
        return uuidValue
    }

    public func updateDNS(uuid: String, _ dns: OVNDNS) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: dns)

        let count = try await connection.update(table: OVNTable.dns, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("DNS record set not found: \(uuid)")
        }

        logger.info("Updated DNS record set: \(uuid)")
    }

    /// Deletes a DNS record set. `Logical_Switch.dns_records` is a weak
    /// reference set, so ovsdb-server drops the UUID from every switch still
    /// naming it instead of rejecting the delete.
    public func deleteDNS(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.dns, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("DNS record set not found: \(uuid)")
        }

        logger.info("Deleted DNS record set: \(uuid)")
    }

    /// Attaches an existing DNS record set to the named logical switch
    /// (`Logical_Switch.dns_records`), which is what makes OVN answer that
    /// switch's ports with those records.
    public func attachDNS(uuid: String, toSwitch switchName: String) async throws(OVNManagerError) {
        try await attachReference(
            uuid: uuid,
            childTable: OVNTable.dns,
            childDescription: "DNS record set",
            parentTable: OVNTable.logicalSwitch,
            parentColumn: "dns_records",
            parentDescription: "Logical switch",
            parentName: switchName
        )
        logger.info("Attached DNS record set \(uuid) to switch: \(switchName)")
    }

    /// Detaches a DNS record set from the named logical switch. The `DNS` row
    /// itself is kept.
    public func detachDNS(uuid: String, fromSwitch switchName: String) async throws(OVNManagerError) {
        try await detachReference(
            uuid: uuid,
            parentTable: OVNTable.logicalSwitch,
            parentColumn: "dns_records",
            parentDescription: "Logical switch",
            parentName: switchName
        )
        logger.info("Detached DNS record set \(uuid) from switch: \(switchName)")
    }

    // MARK: - Meter Operations

    public func getMeters() async throws(OVNManagerError) -> [OVNMeter] {
        let rows = try await connection.selectAll(from: OVNTable.meter, in: database)
        return try parseRows(rows, as: OVNMeter.self)
    }

    public func getMeter(named name: String) async throws(OVNManagerError) -> OVNMeter? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.meter, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNMeter.self)
    }

    /// Creates a meter and its bands in a single OVSDB transaction, mirroring
    /// `ovn-nbctl meter-add`. `Meter` is a root table, but `Meter.bands` has a
    /// schema minimum of one, so a band-less meter is a constraint violation
    /// ovsdb-server refuses — hence bands are a parameter of the create rather
    /// than something attached afterwards, and there is no create that takes a
    /// meter alone. Whatever `meter.bands` holds is ignored: the column is
    /// written with the bands inserted here.
    ///
    /// The name check is only there for a better error message. `Meter.name` is
    /// indexed, so ovsdb-server rejects a duplicate that races in after the
    /// check; no `wait` op is needed to close the window (unlike
    /// `createLogicalSwitch`, whose table has no index on `name`).
    public func createMeter(_ meter: OVNMeter, withBands bands: [OVNMeterBand]) async throws(OVNManagerError) -> String {
        guard !bands.isEmpty else {
            throw OVNManagerError.operationFailed("Meter needs at least one band: \(meter.name)")
        }

        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(meter.name))

        guard try await rowUUID(in: OVNTable.meter, where: nameCondition) == nil else {
            throw OVNManagerError.operationFailed("Meter already exists: \(meter.name)")
        }

        // A loop rather than `map`: `Sequence.map` is `rethrows`, which erases
        // the typed throw back to `any Error`.
        var bandRows: [OVSDBRow] = []
        bandRows.reserveCapacity(bands.count)
        for band in bands {
            bandRows.append(try createRow(from: band))
        }

        let uuidValue = try await connection.insertWithChildren(
            into: OVNTable.meter,
            in: database,
            row: try createRow(from: meter),
            uuidName: "new_meter",
            referenceColumn: "bands",
            childRows: bandRows,
            childTable: OVNTable.meterBand,
            childUUIDNamePrefix: "new_meter_band_"
        )

        logger.info("Created meter: \(meter.name) with \(bands.count) band(s)")
        return uuidValue
    }

    /// The single-band case, which is what ACL log rate limiting needs: one
    /// meter, one `drop` band. See `createMeter(_:withBands:)`.
    public func createMeter(_ meter: OVNMeter, withBand band: OVNMeterBand) async throws(OVNManagerError) -> String {
        return try await createMeter(meter, withBands: [band])
    }

    /// Updates a meter's columns. A nil column on the model is left untouched;
    /// note that passing an empty `bands` would clear a column whose schema
    /// minimum is one, which ovsdb-server rejects. Use
    /// `createMeterBand(_:onMeter:)` and `deleteMeterBand(uuid:)` to change the
    /// band set.
    public func updateMeter(uuid: String, _ meter: OVNMeter) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: meter)

        let count = try await connection.update(table: OVNTable.meter, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Meter not found: \(uuid)")
        }

        logger.info("Updated meter: \(meter.name)")
    }

    /// Deletes a meter. Its bands become unreferenced and are
    /// garbage-collected with it, and `OVNACL.meter` holds a meter *name*
    /// rather than a reference, so no ACL column has to be detached — a
    /// dangling name just stops rate-limiting that ACL's logs.
    ///
    /// `Copp.meters` does hold strong references to `Meter`, so ovsdb-server
    /// refuses to delete a meter a Copp row still names. That reference has to
    /// be removed first; SwiftOVN has no Copp model to do it with.
    public func deleteMeter(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.meter, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Meter not found: \(uuid)")
        }

        logger.info("Deleted meter: \(uuid)")
    }

    public func deleteMeter(named name: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.meter, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Meter not found: \(name)")
        }

        logger.info("Deleted meter: \(name)")
    }

    // MARK: - Meter Band Operations

    public func getMeterBands() async throws(OVNManagerError) -> [OVNMeterBand] {
        let rows = try await connection.selectAll(from: OVNTable.meterBand, in: database)
        return try parseRows(rows, as: OVNMeterBand.self)
    }

    /// Adds a band to an existing meter (`Meter.bands`) in a single OVSDB
    /// transaction. `Meter_Band` is not a root table, so an unreferenced row is
    /// garbage-collected when the transaction commits — there is deliberately
    /// no unattached create.
    public func createMeterBand(_ band: OVNMeterBand, onMeter meterName: String) async throws(OVNManagerError) -> String {
        let meterCondition = OVSDBCondition(column: "name", function: "==", value: .string(meterName))

        guard try await rowUUID(in: OVNTable.meter, where: meterCondition) != nil else {
            throw OVNManagerError.operationFailed("Meter not found: \(meterName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.meterBand,
            in: database,
            row: try createRow(from: band),
            uuidName: "new_meter_band",
            parentTable: OVNTable.meter,
            parentColumn: "bands",
            parentCondition: meterCondition
        )

        logger.info("Created meter band on meter: \(meterName)")
        return uuidValue
    }

    public func updateMeterBand(uuid: String, _ band: OVNMeterBand) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: band)

        let count = try await connection.update(table: OVNTable.meterBand, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Meter band not found: \(uuid)")
        }

        logger.info("Updated meter band: \(uuid)")
    }

    /// Detaches the band from its meter and deletes it in one transaction. A
    /// meter's *last* band cannot be removed this way: emptying `Meter.bands`
    /// violates its schema minimum of one, so ovsdb-server aborts the
    /// transaction — delete the meter instead.
    public func deleteMeterBand(uuid: String) async throws(OVNManagerError) {
        let count = try await connection.deleteDetaching(
            from: OVNTable.meterBand,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVNTable.meter, column: "bands")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Meter band not found: \(uuid)")
        }

        logger.info("Deleted meter band: \(uuid)")
    }

    // MARK: - DHCP Operations

    public func getDHCPOptions() async throws(OVNManagerError) -> [OVNDHCPOptions] {
        let rows = try await connection.selectAll(from: OVNTable.dhcpOptions, in: database)
        return try parseRows(rows, as: OVNDHCPOptions.self)
    }
    
    public func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws(OVNManagerError) -> String {
        let row = try createRow(from: dhcp)
        let result = try await connection.insert(into: OVNTable.dhcpOptions, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created DHCP options")
        return uuidValue
    }
    
    public func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: dhcp)
        
        let count = try await connection.update(table: OVNTable.dhcpOptions, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Updated DHCP options: \(uuid)")
    }
    
    public func deleteDHCPOptions(uuid: String) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.dhcpOptions, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Deleted DHCP options: \(uuid)")
    }
    
    // MARK: - Global Configuration and Sync Barrier

    /// Reads the singleton `NB_Global` row, or nil if the database has none
    /// (an empty database that ovn-northd has never connected to).
    public func getNBGlobal() async throws(OVNManagerError) -> OVNNBGlobal? {
        try requireNorthbound("NB_Global")

        let rows = try await connection.selectAll(from: OVNTable.nbGlobal, in: database)
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNNBGlobal.self)
    }

    /// Sets the given `NB_Global.options` entries, leaving every other key
    /// untouched (`ovn-nbctl set NB_Global . options:key=value`).
    ///
    /// The merge is not politeness: ovn-northd keeps generated state in this
    /// map — `svc_monitor_mac`, `mac_prefix`, `e2e_base_mac` and friends are
    /// written there on first run and never regenerated — so replacing the
    /// column wholesale would silently reconfigure the deployment. Use
    /// `removeNBGlobalOptions(_:)` to drop a key.
    ///
    /// An empty `options` is a no-op rather than an empty mutation.
    public func updateNBGlobalOptions(_ options: [String: String]) async throws(OVNManagerError) {
        try requireNorthbound("NB_Global")
        guard !options.isEmpty else { return }

        let count = try await connection.mutate(
            table: OVNTable.nbGlobal,
            in: database,
            where: [],
            mutations: OVSDBColumnTransactions.upsertMapEntries(options, column: "options")
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("NB_Global row not found")
        }

        logger.info("Updated NB_Global options: \(options.keys.sorted().joined(separator: ", "))")
    }

    /// Removes the given keys from `NB_Global.options`, whatever they map to.
    /// Keys that are not set are ignored — a delete mutation reports the rows
    /// it matched, not the entries it removed.
    ///
    /// An empty `keys` is a no-op rather than an empty mutation.
    public func removeNBGlobalOptions(_ keys: [String]) async throws(OVNManagerError) {
        try requireNorthbound("NB_Global")
        guard !keys.isEmpty else { return }

        let count = try await connection.mutate(
            table: OVNTable.nbGlobal,
            in: database,
            where: [],
            mutations: [OVSDBColumnTransactions.removeMapEntries(keys: keys, column: "options")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("NB_Global row not found")
        }

        logger.info("Removed NB_Global options: \(keys.sorted().joined(separator: ", "))")
    }

    /// Turns IPsec encryption of chassis-to-chassis tunnel traffic on or off
    /// (`NB_Global.ipsec`). ovn-northd copies the flag to `SB_Global.ipsec`,
    /// where the per-chassis IPsec daemons pick it up.
    public func setNBGlobalIPsec(_ enabled: Bool) async throws(OVNManagerError) {
        try requireNorthbound("NB_Global")

        let count = try await connection.update(
            table: OVNTable.nbGlobal,
            in: database,
            where: [],
            row: ["ipsec": .boolean(enabled)]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("NB_Global row not found")
        }

        logger.info("Set NB_Global ipsec: \(enabled)")
    }

    /// Increments `NB_Global.nb_cfg` and returns the value it reached.
    ///
    /// This is the barrier's starting point: every write this client committed
    /// before the increment is ordered before it, so a later `sb_cfg`/`hv_cfg`
    /// of at least the returned value means those writes have been processed.
    /// `waitForNorthd(timeout:)` and `waitForHypervisors(timeout:)` do the
    /// increment themselves; call this directly only to start a barrier you
    /// intend to observe some other way.
    @discardableResult
    public func incrementNBCfg() async throws(OVNManagerError) -> Int {
        try requireNorthbound("NB_Global")

        let operations = OVSDBColumnTransactions.increment(column: "nb_cfg", in: OVNTable.nbGlobal)
        let results = try await connection.transact(in: database, operations: operations)

        guard results.count >= 2,
              case .object(let mutateResult) = results[0],
              case .number(let count)? = mutateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("NB_Global row not found")
        }

        guard case .object(let selectResult) = results[1],
              case .array(let rows)? = selectResult["rows"],
              case .object(let row)? = rows.first,
              case .number(let value)? = row["nb_cfg"] else {
            throw OVNManagerError.invalidResponse("Invalid nb_cfg in increment response")
        }

        let target = Int(value)
        logger.debug("Incremented NB_Global nb_cfg to \(target)")
        return target
    }

    /// Increments `nb_cfg` and waits until ovn-northd reports having translated
    /// that generation of the northbound database into southbound logical flows
    /// (`sb_cfg >= nb_cfg`), returning the `sb_cfg` value observed. This is
    /// `ovn-nbctl --wait=sb`.
    ///
    /// Northd having caught up does not mean any packet is forwarded
    /// differently yet — the flows still have to reach the hypervisors, which
    /// is what `waitForHypervisors(timeout:)` waits for. It does return much
    /// sooner, and is the right barrier when what you need is that the
    /// southbound database reflects your write.
    ///
    /// Throws `timeoutError` if the counter does not reach the target in time.
    /// The wait is driven by a monitor on `NB_Global` for the duration of the
    /// call, so the rows also appear on any `monitorUpdates()` stream open on
    /// this manager.
    @discardableResult
    public func waitForNorthd(timeout: TimeAmount = .seconds(60)) async throws(OVNManagerError) -> Int {
        let target = try await incrementNBCfg()
        return try await waitForCfg(column: "sb_cfg", atLeast: target, timeout: timeout)
    }

    /// Increments `nb_cfg` and waits until every chassis has acknowledged that
    /// generation (`hv_cfg >= nb_cfg`), returning the `hv_cfg` value observed.
    /// This is `ovn-nbctl --wait=hv`, and the only barrier that means the
    /// dataplane itself has caught up.
    ///
    /// `hv_cfg` is the minimum over all chassis, so a single hypervisor that is
    /// down or partitioned holds it back indefinitely while the rest of the
    /// deployment is fine — hence the timeout, and hence why a caller that only
    /// needs the southbound database to be current should prefer
    /// `waitForNorthd(timeout:)`.
    ///
    /// Throws `timeoutError` if the counter does not reach the target in time.
    @discardableResult
    public func waitForHypervisors(timeout: TimeAmount = .seconds(60)) async throws(OVNManagerError) -> Int {
        let target = try await incrementNBCfg()
        return try await waitForCfg(column: "hv_cfg", atLeast: target, timeout: timeout)
    }

    // MARK: - Monitoring

    public func startMonitoring(tables: [String]) async throws(OVNManagerError) -> String {
        var monitorRequests: [String: OVSDBMonitorRequest] = [:]
        
        for table in tables {
            monitorRequests[table] = OVSDBMonitorRequest()
        }
        
        return try await connection.startMonitoring(database: database, tables: monitorRequests).monitorId
    }
    
    /// Starts a conditional monitor on this manager's database, filtering rows
    /// server-side and resuming from `since` where the server supports it.
    ///
    /// See `OVSDBConnection.startConditionalMonitoring` for the method
    /// negotiation, what `resumed` means for the returned updates, and why a
    /// request carrying conditions is refused rather than downgraded when the
    /// server is too old for `monitor_cond`.
    public func startConditionalMonitoring(
        tables: [String: OVSDBMonitorRequest],
        monitorId: String? = nil,
        since lastTransactionId: String? = nil
    ) async throws(OVNManagerError) -> OVSDBMonitorSession {
        return try await connection.startConditionalMonitoring(
            database: database,
            tables: tables,
            monitorId: monitorId,
            since: lastTransactionId
        )
    }

    /// Replaces the `where` conditions of a running conditional monitor
    /// (`monitor_cond_change`) without restarting it.
    public func updateMonitorConditions(
        monitorId: String,
        conditions: [String: [OVSDBCondition]]
    ) async throws(OVNManagerError) {
        try await connection.updateMonitorConditions(monitorId: monitorId, conditions: conditions)
    }

    /// The transaction id to resume a `monitor_cond_since` monitor from, as of
    /// the last batch delivered to `monitorTableUpdates()`. See
    /// `OVSDBConnection.lastTransactionId(forMonitor:)` for when to prefer the id
    /// carried by the batch itself.
    public func lastTransactionId(forMonitor monitorId: String) async -> String? {
        return await connection.lastTransactionId(forMonitor: monitorId)
    }

    public func stopMonitoring(monitorId: String) async throws(OVNManagerError) {
        try await connection.stopMonitoring(monitorId: monitorId)
    }

    /// Streams row changes a notification at a time, keeping one transaction's
    /// rows together and carrying the transaction id to resume a
    /// `monitor_cond_since` monitor from. The stream to use with
    /// `startConditionalMonitoring`, and the one to use across a reconnect: each
    /// batch's `origin` says whether it continues the consumer's rows or replaces
    /// them (see `OVSDBConnection.monitorTableUpdates(monitorId:)`).
    ///
    /// Buffering and failure behave as `monitorUpdates()`'.
    nonisolated public func monitorTableUpdates(monitorId: String? = nil) -> AsyncThrowingStream<OVSDBTableUpdates, Error> {
        // Subscribed here rather than inside the task, so a stream created before
        // the monitor is started really is subscribed by the time it is returned.
        let batches = connection.monitorTableUpdates(monitorId: monitorId)
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                do {
                    for try await batch in batches {
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

    /// Streams row changes from this manager's monitors.
    ///
    /// Buffering is bounded (`OVSDBSocketConnection.notificationBufferSize`); a
    /// consumer that falls further behind gets
    /// `OVNManagerError.notificationsDropped` rather than driving the process
    /// out of memory. Restart the monitor to resynchronize.
    ///
    /// Unlike the throwing methods on this type, the stream's failure type is
    /// `any Error` rather than `OVNManagerError`: every `AsyncThrowingStream`
    /// initializer is constrained to `Failure == any Error`, so a typed-failure
    /// stream cannot be built. Only `OVNManagerError` is ever thrown, so match
    /// on it in the `catch`.
    nonisolated public func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error> {
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                let updates = connection.monitorUpdates()
                do {
                    for try await update in updates {
                        if case .dropped = continuation.yield(update) {
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
            // Cancel the forwarding task if the consumer drops the stream, so it
            // doesn't outlive them waiting on the underlying connection.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
    
    // MARK: - Southbound Operations

    public func getChassis() async throws(OVNManagerError) -> [OVNChassis] {
        try await southboundRows(OVNChassis.self, from: OVNTable.chassis, describedAs: "Chassis")
    }

    public func getChassisPrivate() async throws(OVNManagerError) -> [OVNChassisPrivate] {
        try await southboundRows(OVNChassisPrivate.self, from: OVNTable.chassisPrivate, describedAs: "Chassis Private")
    }

    public func getPortBindings() async throws(OVNManagerError) -> [OVNPortBinding] {
        try await southboundRows(OVNPortBinding.self, from: OVNTable.portBinding, describedAs: "Port Binding")
    }

    public func getLogicalFlows() async throws(OVNManagerError) -> [OVNLogicalFlow] {
        try await southboundRows(OVNLogicalFlow.self, from: OVNTable.logicalFlow, describedAs: "Logical Flow")
    }

    public func getAdvertisedRoutes() async throws(OVNManagerError) -> [OVNAdvertisedRoute] {
        try await southboundRows(OVNAdvertisedRoute.self, from: OVNTable.advertisedRoute, describedAs: "Advertised Route")
    }

    public func getLearnedRoutes() async throws(OVNManagerError) -> [OVNLearnedRoute] {
        try await southboundRows(OVNLearnedRoute.self, from: OVNTable.learnedRoute, describedAs: "Learned Route")
    }

    /// The Southbound `Service_Monitor` rows: one per load balancer backend
    /// covered by a `Load_Balancer_Health_Check`, carrying the `status` the
    /// probing chassis reported. This is the only way to observe whether OVN
    /// currently considers a backend up.
    public func getServiceMonitors() async throws(OVNManagerError) -> [OVNServiceMonitor] {
        try await southboundRows(OVNServiceMonitor.self, from: OVNTable.serviceMonitor, describedAs: "Service Monitor")
    }

    /// Reads the singleton `SB_Global` row, or nil if the database has none.
    ///
    /// Its `nb_cfg` is the generation of northbound configuration ovn-northd
    /// has published here — the value each chassis copies onwards once it has
    /// installed the flows. `NB_Global.sb_cfg` is the same progress reported
    /// back on the northbound side, which is what `waitForNorthd(timeout:)`
    /// waits on, so this is a read for inspecting the southbound side rather
    /// than a second way to run the barrier.
    public func getSBGlobal() async throws(OVNManagerError) -> OVNSBGlobal? {
        try await southboundRow(OVNSBGlobal.self, from: OVNTable.sbGlobal, describedAs: "SB_Global")
    }

    /// The `Encap` rows: how each chassis can be reached, which is what
    /// `OVNChassis.encaps`, `OVNPortBinding.encap` and
    /// `OVNPortBinding.additional_encap` refer to.
    ///
    /// A row's `chassis_name` names its owner, so grouping by that column
    /// answers "which tunnel types is this hypervisor offering" without
    /// resolving UUIDs at all.
    public func getEncaps() async throws(OVNManagerError) -> [OVNEncap] {
        try await southboundRows(OVNEncap.self, from: OVNTable.encap, describedAs: "Encap")
    }

    // MARK: Datapaths

    /// The `Datapath_Binding` rows — the logical switches and routers every
    /// port binding, logical flow and route in this database is scoped to.
    ///
    /// Reading this is what makes the rest of the Southbound database legible:
    /// `OVNPortBinding.datapath`, `OVNLogicalFlow.logical_datapath`,
    /// `OVNAdvertisedRoute.datapath`, `OVNLearnedRoute.datapath` and
    /// `OVNMACBinding.datapath` are UUIDs into it, and only these rows say which
    /// Northbound switch or router each one means.
    public func getDatapathBindings() async throws(OVNManagerError) -> [OVNDatapathBinding] {
        try await southboundRows(OVNDatapathBinding.self, from: OVNTable.datapathBinding, describedAs: "Datapath Binding")
    }

    /// The `Logical_DP_Group` rows, which resolve
    /// `OVNLogicalFlow.logical_dp_group`.
    ///
    /// Needed far more often than its obscurity suggests: ovn-northd emits one
    /// flow per *group* wherever it can, so a large share of logical flows have
    /// `logical_datapath` unset and name a group instead. Without these rows
    /// those flows appear to belong to no datapath at all.
    public func getLogicalDPGroups() async throws(OVNManagerError) -> [OVNLogicalDPGroup] {
        try await southboundRows(OVNLogicalDPGroup.self, from: OVNTable.logicalDPGroup, describedAs: "Logical DP Group")
    }

    // MARK: Address bindings

    /// The `MAC_Binding` rows: IP-to-MAC bindings a logical router learned by
    /// ARP or neighbour discovery. The dynamic counterpart of
    /// `getSBStaticMACBindings()`.
    public func getMACBindings() async throws(OVNManagerError) -> [OVNMACBinding] {
        try await southboundRows(OVNMACBinding.self, from: OVNTable.macBinding, describedAs: "MAC Binding")
    }

    /// The Southbound `Static_MAC_Binding` rows: IP-to-MAC bindings configured
    /// on a router port rather than learned.
    public func getSBStaticMACBindings() async throws(OVNManagerError) -> [OVNSBStaticMACBinding] {
        try await southboundRows(OVNSBStaticMACBinding.self, from: OVNTable.staticMACBinding, describedAs: "Static MAC Binding")
    }

    /// The `Advertised_MAC_Binding` rows: IP/MAC pairs OVN announces to the
    /// outside fabric where EVPN is enabled.
    public func getAdvertisedMACBindings() async throws(OVNManagerError) -> [OVNAdvertisedMACBinding] {
        try await southboundRows(OVNAdvertisedMACBinding.self, from: OVNTable.advertisedMACBinding, describedAs: "Advertised MAC Binding")
    }

    /// The `FDB` rows: MACs a logical switch learned from traffic, on ports
    /// whose port security is off.
    ///
    /// These rows identify their datapath and port by tunnel key rather than by
    /// UUID, so joining them means matching `dp_key` against
    /// `OVNDatapathBinding.tunnel_key` and `port_key` against
    /// `OVNPortBinding.tunnel_key`.
    public func getFDBEntries() async throws(OVNManagerError) -> [OVNFDB] {
        try await southboundRows(OVNFDB.self, from: OVNTable.fdb, describedAs: "FDB")
    }

    // MARK: Multicast

    /// The `Multicast_Group` rows ovn-northd computed from configuration.
    public func getMulticastGroups() async throws(OVNManagerError) -> [OVNMulticastGroup] {
        try await southboundRows(OVNMulticastGroup.self, from: OVNTable.multicastGroup, describedAs: "Multicast Group")
    }

    /// The `IGMP_Group` rows a chassis learned by snooping, one per
    /// address/datapath/chassis combination.
    public func getIGMPGroups() async throws(OVNManagerError) -> [OVNIGMPGroup] {
        try await southboundRows(OVNIGMPGroup.self, from: OVNTable.igmpGroup, describedAs: "IGMP Group")
    }

    /// The `IP_Multicast` rows: per-datapath multicast snooping configuration,
    /// and the query parameters ovn-controller originates with.
    public func getIPMulticast() async throws(OVNManagerError) -> [OVNIPMulticast] {
        try await southboundRows(OVNIPMulticast.self, from: OVNTable.ipMulticast, describedAs: "IP Multicast")
    }

    // MARK: Control-plane events and routing state

    /// The `Controller_Event` rows ovn-controller punted to the control plane —
    /// today `empty_lb_backends`, a packet for a load balancer VIP with nothing
    /// left behind it.
    ///
    /// The table explicitly permits duplicates, so a consumer must deduplicate
    /// on `OVNControllerEvent.seq_num` rather than assume one row per event.
    public func getControllerEvents() async throws(OVNManagerError) -> [OVNControllerEvent] {
        try await southboundRows(OVNControllerEvent.self, from: OVNTable.controllerEvent, describedAs: "Controller Event")
    }

    /// The `ECMP_Nexthop` rows: next hops currently active for
    /// symmetric-reply ECMP routes.
    public func getECMPNexthops() async throws(OVNManagerError) -> [OVNECMPNexthop] {
        try await southboundRows(OVNECMPNexthop.self, from: OVNTable.ecmpNexthop, describedAs: "ECMP Nexthop")
    }

    /// The Southbound `BFD` rows: the sessions ovn-controller is actually
    /// running, and their state. Distinct from `getBFDSessions()`, which reads
    /// the Northbound requests — see `OVNSBBFD`.
    public func getSBBFDSessions() async throws(OVNManagerError) -> [OVNSBBFD] {
        try await southboundRows(OVNSBBFD.self, from: OVNTable.bfd, describedAs: "BFD")
    }

    // MARK: Southbound copies of northbound configuration

    /// The Southbound `Load_Balancer` rows — see `OVNSBLoadBalancer`, which
    /// records the datapaths a load balancer applies to rather than being
    /// referenced from them.
    public func getSBLoadBalancers() async throws(OVNManagerError) -> [OVNSBLoadBalancer] {
        try await southboundRows(OVNSBLoadBalancer.self, from: OVNTable.loadBalancer, describedAs: "Load Balancer")
    }

    /// The Southbound `Address_Set` rows. More of these exist than there are
    /// Northbound address sets: ovn-northd also generates one per Northbound
    /// port group.
    public func getSBAddressSets() async throws(OVNManagerError) -> [OVNSBAddressSet] {
        try await southboundRows(OVNSBAddressSet.self, from: OVNTable.addressSet, describedAs: "Address Set")
    }

    /// The Southbound `Port_Group` rows, whose `ports` are logical port *names*
    /// rather than the reference set the Northbound table holds.
    public func getSBPortGroups() async throws(OVNManagerError) -> [OVNSBPortGroup] {
        try await southboundRows(OVNSBPortGroup.self, from: OVNTable.portGroup, describedAs: "Port Group")
    }

    /// The Southbound `DNS` rows the `dns_lookup` action answers from.
    public func getSBDNS() async throws(OVNManagerError) -> [OVNSBDNS] {
        try await southboundRows(OVNSBDNS.self, from: OVNTable.dns, describedAs: "DNS")
    }

    /// The Southbound `Meter` rows, as `OVNLogicalFlow.controller_meter` names
    /// them. A Northbound meter with `fair` set appears here once per
    /// attachment point, under a name ovn-northd generated.
    public func getSBMeters() async throws(OVNManagerError) -> [OVNSBMeter] {
        try await southboundRows(OVNSBMeter.self, from: OVNTable.meter, describedAs: "Meter")
    }

    /// The Southbound `Meter_Band` rows, resolving `OVNSBMeter.bands`.
    public func getSBMeterBands() async throws(OVNManagerError) -> [OVNSBMeterBand] {
        try await southboundRows(OVNSBMeterBand.self, from: OVNTable.meterBand, describedAs: "Meter Band")
    }

    /// The Southbound `Mirror` rows, resolving `OVNPortBinding.mirror_rules`.
    public func getSBMirrors() async throws(OVNManagerError) -> [OVNSBMirror] {
        try await southboundRows(OVNSBMirror.self, from: OVNTable.mirror, describedAs: "Mirror")
    }

    /// The Southbound `Gateway_Chassis` rows, resolving
    /// `OVNPortBinding.gateway_chassis`.
    public func getSBGatewayChassis() async throws(OVNManagerError) -> [OVNSBGatewayChassis] {
        try await southboundRows(OVNSBGatewayChassis.self, from: OVNTable.gatewayChassis, describedAs: "Gateway Chassis")
    }

    /// The Southbound `HA_Chassis` rows, resolving
    /// `OVNSBHAChassisGroup.ha_chassis`.
    public func getSBHAChassis() async throws(OVNManagerError) -> [OVNSBHAChassis] {
        try await southboundRows(OVNSBHAChassis.self, from: OVNTable.haChassis, describedAs: "HA Chassis")
    }

    /// The Southbound `HA_Chassis_Group` rows, resolving
    /// `OVNPortBinding.ha_chassis_group`. Their `ref_chassis` is the part with
    /// no Northbound equivalent: the chassis whose traffic depends on the group.
    public func getSBHAChassisGroups() async throws(OVNManagerError) -> [OVNSBHAChassisGroup] {
        try await southboundRows(OVNSBHAChassisGroup.self, from: OVNTable.haChassisGroup, describedAs: "HA Chassis Group")
    }

    /// The Southbound `Chassis_Template_Var` rows: what each chassis resolves a
    /// flow's `^variable` references to.
    public func getSBChassisTemplateVars() async throws(OVNManagerError) -> [OVNSBChassisTemplateVar] {
        try await southboundRows(OVNSBChassisTemplateVar.self, from: OVNTable.chassisTemplateVar, describedAs: "Chassis Template Var")
    }

    /// The `ACL_ID` rows: the small integers standing in for `allow-established`
    /// ACLs. A row's own `_uuid` is the Northbound `ACL` it belongs to.
    public func getACLIDs() async throws(OVNManagerError) -> [OVNACLID] {
        try await southboundRows(OVNACLID.self, from: OVNTable.aclID, describedAs: "ACL ID")
    }

    /// The Southbound `DHCP_Options` rows: the dictionary of DHCPv4 options this
    /// OVN version supports, with their codes and value types. Not DHCP
    /// configuration — that is the Northbound table `getDHCPOptions()` reads.
    public func getSBDHCPOptions() async throws(OVNManagerError) -> [OVNSBDHCPOptions] {
        try await southboundRows(OVNSBDHCPOptions.self, from: OVNTable.dhcpOptions, describedAs: "DHCP Options")
    }

    /// The `DHCPv6_Options` dictionary, the IPv6 twin of `getSBDHCPOptions()`.
    public func getSBDHCPv6Options() async throws(OVNManagerError) -> [OVNSBDHCPv6Options] {
        try await southboundRows(OVNSBDHCPv6Options.self, from: OVNTable.dhcpv6Options, describedAs: "DHCPv6 Options")
    }

    // MARK: ovsdb-server's own configuration

    /// The `Connection` rows, resolving `OVNSBGlobal.connections`. Their
    /// `is_connected` and `status` are ephemeral columns ovsdb-server maintains
    /// live, so this reports which configured remotes are actually up.
    public func getConnections() async throws(OVNManagerError) -> [OVNSBConnection] {
        try await southboundRows(OVNSBConnection.self, from: OVNTable.connection, describedAs: "Connection")
    }

    /// The singleton `SSL` row, resolving `OVNSBGlobal.ssl`, or nil if the
    /// database has none. This is ovsdb-server's own TLS material — paths on
    /// *its* host — not the `OVSDBTLSConfiguration` this client connects with.
    public func getSSL() async throws(OVNManagerError) -> OVNSBSSL? {
        try await southboundRow(OVNSBSSL.self, from: OVNTable.ssl, describedAs: "SSL")
    }

    /// The `RBAC_Role` rows: which restrictions ovsdb-server is enforcing on
    /// each connection role.
    public func getRBACRoles() async throws(OVNManagerError) -> [OVNRBACRole] {
        try await southboundRows(OVNRBACRole.self, from: OVNTable.rbacRole, describedAs: "RBAC Role")
    }

    /// The `RBAC_Permission` rows, resolving `OVNRBACRole.permissions`.
    public func getRBACPermissions() async throws(OVNManagerError) -> [OVNRBACPermission] {
        try await southboundRows(OVNRBACPermission.self, from: OVNTable.rbacPermission, describedAs: "RBAC Permission")
    }

    // MARK: - Southbound Writes
    //
    // The Southbound database is ovn-northd's output, and writing what another
    // process owns is normally a mistake: northd overwrites it on its next
    // recompute. These two operations are the exceptions — neither has a
    // Northbound equivalent, and each is an operational intervention rather
    // than an edit. They are separated from the reads above for that reason.

    /// Evicts a chassis, mirroring `ovn-sbctl chassis-del`: the standard way to
    /// remove a hypervisor that is not coming back.
    ///
    /// Destructive, and not a way to make a *live* chassis go away —
    /// ovn-controller re-registers its own `Chassis` row within seconds, so
    /// against a running hypervisor this deletes rows that immediately return,
    /// having in the meantime unbound every port on it.
    ///
    /// Three tables in one transaction, because nothing else cleans them up:
    ///
    /// - The chassis's `Encap` rows. Not a root table, so ovsdb-server would
    ///   collect them once `Chassis.encaps` no longer referenced them; deleted
    ///   explicitly anyway, matching `ovn-sbctl`, so the outcome does not depend
    ///   on when collection runs.
    /// - Its `Chassis_Private` row, which is the one that actually matters.
    ///   `Chassis_Private` *is* a root table and is keyed by name rather than by
    ///   a reference, so deleting the `Chassis` row leaves it behind — and
    ///   ovn-northd derives `NB_Global.hv_cfg` from the minimum `nb_cfg` across
    ///   every `Chassis_Private` row, skipping only ones marked remote. A
    ///   leftover row pins that minimum at the dead chassis's last value
    ///   forever, which stalls `waitForHypervisors(timeout:)` for good.
    /// - The `Chassis` row itself. Every reference to it —
    ///   `Port_Binding.chassis`, `Gateway_Chassis.chassis`, `HA_Chassis.chassis`,
    ///   `IGMP_Group.chassis` — is weak, so those columns clear themselves
    ///   rather than blocking the delete. Ports bound to it therefore go
    ///   unbound, which is the point of an eviction and also its blast radius.
    ///
    /// Identified by name rather than UUID because name is what ties the three
    /// tables together: `Chassis_Private` and `Encap.chassis_name` have no UUID
    /// reference to follow back.
    ///
    /// Throws `operationFailed` if no chassis by that name exists.
    public func deleteChassis(named name: String) async throws(OVNManagerError) {
        try requireSouthbound("Chassis")

        let nameCondition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let ownerCondition = OVSDBCondition(column: "chassis_name", function: "==", value: .string(name))

        let operations: [OVSDBOperation] = [
            .delete(from: OVNTable.encap, where: [ownerCondition]),
            .delete(from: OVNTable.chassisPrivate, where: [nameCondition]),
            .delete(from: OVNTable.chassis, where: [nameCondition]),
        ]

        let results = try await connection.transact(in: database, operations: operations)

        // The `Chassis` delete is the one that decides whether the chassis
        // existed: a chassis with no encaps and no Chassis_Private row is
        // unusual but legal, so a zero count on either of those says nothing.
        let chassisIndex = operations.count - 1
        guard results.count > chassisIndex,
              case .object(let deleteResult) = results[chassisIndex],
              case .number(let count)? = deleteResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid delete response format")
        }

        if count == 0 {
            throw OVNManagerError.operationFailed("Chassis not found: \(name)")
        }

        logger.info("Deleted chassis: \(name)")
    }

    /// Binds a port to a chassis by writing `Port_Binding.chassis` directly, or
    /// unbinds it when `chassisName` is nil.
    ///
    /// This is ovn-controller's column: on the chassis where a port's VIF
    /// appears, ovn-controller claims the port by writing itself here, and it
    /// will re-claim a port whose binding was moved out from under it. Setting
    /// it by hand is therefore for the cases where no ovn-controller will do it:
    /// completing a migration whose source hypervisor died, or clearing a
    /// binding that is stuck on a chassis that is gone. To *ask* OVN to move a
    /// port, set `requested_chassis` instead and let ovn-controller rebind it —
    /// see `setPortBindingRequestedChassis(logicalPort:chassisNamed:)`.
    ///
    /// Throws `operationFailed` if the port binding or the named chassis does
    /// not exist.
    public func setPortBindingChassis(logicalPort: String, chassisNamed chassisName: String?) async throws(OVNManagerError) {
        try await setPortBindingChassisColumn("chassis", logicalPort: logicalPort, chassisNamed: chassisName)
    }

    /// Sets `Port_Binding.requested_chassis` — where the port *should* end up —
    /// or clears it when `chassisName` is nil.
    ///
    /// This is how a live migration is driven from the Southbound side: the
    /// requested chassis is the destination, `chassis` stays the current holder,
    /// and ovn-controller moves the binding when the VIF actually appears there.
    /// Because it expresses intent rather than fact, this is the safer of the
    /// two writes — nothing is unbound by setting it.
    ///
    /// ovn-northd normally derives the column from
    /// `Logical_Switch_Port.options:requested-chassis`, and will overwrite what
    /// is written here on its next recompute of that port. Setting the
    /// Northbound option is the durable way to express the same thing; this is
    /// the immediate one.
    ///
    /// Throws `operationFailed` if the port binding or the named chassis does
    /// not exist.
    public func setPortBindingRequestedChassis(logicalPort: String, chassisNamed chassisName: String?) async throws(OVNManagerError) {
        try await setPortBindingChassisColumn("requested_chassis", logicalPort: logicalPort, chassisNamed: chassisName)
    }
}

// MARK: - Helper Methods

private extension OVNManager {
    /// Rejects a northbound-only operation issued against another database.
    /// `NB_Global` exists only in `OVN_Northbound` (the southbound row is
    /// `SB_Global`), so without this the call would come back as an ovsdb
    /// "unknown table" rejection naming neither database.
    func requireNorthbound(_ description: String) throws(OVNManagerError) {
        guard database == OVNDatabase.northbound else {
            throw OVNManagerError.operationFailed("\(description) operations require northbound database")
        }
    }

    /// The mirror image, for the southbound-only tables. Worth rejecting locally
    /// rather than letting the request go out: eleven table names exist in both
    /// databases with different columns, so a southbound read issued against
    /// northbound would not fail as an unknown table — it would come back with
    /// the wrong row shape and surface as a `decodingError` naming a column.
    func requireSouthbound(_ description: String) throws(OVNManagerError) {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("\(description) operations require southbound database")
        }
    }

    /// Every southbound read is the same three steps — reject a northbound
    /// manager, select the whole table, decode each row — so they are written
    /// once here and each getter stays a single line.
    func southboundRows<T: Codable>(
        _ type: T.Type,
        from table: String,
        describedAs description: String
    ) async throws(OVNManagerError) -> [T] {
        try requireSouthbound(description)

        let rows = try await connection.selectAll(from: table, in: database)
        return try parseRows(rows, as: type)
    }

    /// `southboundRows` for a `maxRows: 1` table, where "no row" is a normal
    /// answer rather than an error.
    func southboundRow<T: Codable>(
        _ type: T.Type,
        from table: String,
        describedAs description: String
    ) async throws(OVNManagerError) -> T? {
        return try await southboundRows(type, from: table, describedAs: description).first
    }

    /// Writes one of `Port_Binding`'s two chassis columns, resolving the chassis
    /// name to the UUID the column actually holds.
    ///
    /// Both columns are *weak* references, which is the reason for the `wait`
    /// guard: had the chassis been deleted between the lookup and the write,
    /// ovsdb-server would drop the dangling UUID and report the update as
    /// succeeding, leaving the caller believing a port was bound when it had
    /// been silently unbound instead. The guard turns that race into a failed
    /// transaction.
    ///
    /// A nil `chassisName` writes the empty set, which is how RFC 7047 spells an
    /// unset optional column; there is nothing to guard in that case.
    func setPortBindingChassisColumn(
        _ column: String,
        logicalPort: String,
        chassisNamed chassisName: String?
    ) async throws(OVNManagerError) {
        try requireSouthbound("Port Binding")

        var guardOperations: [OVSDBOperation] = []
        let value: JSONValue

        if let chassisName {
            let chassisCondition = OVSDBCondition(column: "name", function: "==", value: .string(chassisName))
            guard let chassisUUID = try await rowUUID(in: OVNTable.chassis, where: chassisCondition) else {
                throw OVNManagerError.operationFailed("Chassis not found: \(chassisName)")
            }
            guardOperations = rowExistenceWaitOps([chassisUUID], in: OVNTable.chassis)
            value = .array([.string("uuid"), .string(chassisUUID)])
        } else {
            value = .array([.string("set"), .array([])])
        }

        let portCondition = OVSDBCondition(column: "logical_port", function: "==", value: .string(logicalPort))

        var operations = guardOperations
        let updateIndex = operations.count
        operations.append(.update(OVNTable.portBinding, where: [portCondition], row: [column: value]))

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count > updateIndex,
              case .object(let updateResult) = results[updateIndex],
              case .number(let count)? = updateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }

        if count == 0 {
            throw OVNManagerError.operationFailed("Port binding not found: \(logicalPort)")
        }

        logger.info("Set Port_Binding.\(column) of \(logicalPort) to \(chassisName ?? "unset")")
    }

    /// Waits for one of `NB_Global`'s sequence-number columns to reach `target`,
    /// returning the value observed.
    ///
    /// Driven by a monitor rather than by polling or an OVSDB `wait` op: a
    /// `wait` can only test `==`/`!=` against literal column values, and these
    /// counters are compared with `>=`. Equality would be wrong as well as
    /// inexpressible — `sb_cfg` follows whatever `nb_cfg` currently is, so
    /// another client's increment can carry it straight past `target`.
    ///
    /// The monitor is started *after* the increment that set `target`, so its
    /// initial update already answers the case where northd (or the last
    /// hypervisor) got there first and no further update is coming.
    func waitForCfg(column: String, atLeast target: Int, timeout: TimeAmount) async throws(OVNManagerError) -> Int {
        let monitorId = UUID().uuidString
        // Create the stream before starting the monitor, or an update that
        // lands in between is lost (see `OVSDBConnection.monitorUpdates`).
        let updates = connection.monitorUpdates(monitorId: monitorId)

        let (_, initialUpdates) = try await connection.startMonitoring(
            database: database,
            tables: [OVNTable.nbGlobal: OVSDBMonitorRequest(columns: [column])],
            monitorId: monitorId
        )

        let outcome: Result<Int, OVNManagerError>
        if let initial = Self.cfgValue(of: column, in: initialUpdates), initial >= target {
            outcome = .success(initial)
        } else {
            do {
                let reached = try await Self.firstCfgValue(of: column, atLeast: target, in: updates, timeout: timeout)
                outcome = .success(reached)
            } catch {
                outcome = .failure(error)
            }
        }

        // Best effort: the wait is over either way, and a monitor that could
        // not be cancelled (a closed connection, most likely) must not mask
        // what the wait actually produced.
        try? await connection.stopMonitoring(monitorId: monitorId)
        return try outcome.get()
    }

    /// The column's value in the first `NB_Global` update that carries it. A
    /// monitor's modify update only carries the columns that changed, so an
    /// update without this one says nothing about it.
    static func cfgValue(of column: String, in update: OVSDBUpdate) -> Int? {
        guard update.table == OVNTable.nbGlobal,
              case .number(let value)? = update.new?[column] else {
            return nil
        }
        return Int(value)
    }

    static func cfgValue(of column: String, in updates: [OVSDBUpdate]) -> Int? {
        for update in updates {
            if let value = cfgValue(of: column, in: update) { return value }
        }
        return nil
    }

    /// The first value of `column` on the stream that is at least `target`,
    /// or `timeoutError` if none arrives in time.
    ///
    /// The timeout is a sibling task rather than a deadline checked between
    /// updates, because the interesting failure is exactly the one where *no*
    /// update arrives: a chassis that is down never advances `hv_cfg`, so the
    /// loop would otherwise wait forever inside `next()`.
    static func firstCfgValue(
        of column: String,
        atLeast target: Int,
        in updates: AsyncThrowingStream<OVSDBUpdate, Error>,
        timeout: TimeAmount
    ) async throws(OVNManagerError) -> Int {
        let reached: Int?
        do {
            reached = try await withThrowingTaskGroup(of: Int?.self) { group in
                group.addTask {
                    for try await update in updates {
                        guard let value = cfgValue(of: column, in: update), value >= target else { continue }
                        return value
                    }
                    // The stream finished without the counter getting there:
                    // the connection closed under us. Reported as a timeout
                    // rather than invented as a success.
                    return nil
                }
                group.addTask {
                    try await Task.sleep(for: .nanoseconds(max(0, timeout.nanoseconds)))
                    return nil
                }

                // Whichever finishes first decides; the loser is cancelled,
                // which unsubscribes the stream consumer.
                defer { group.cancelAll() }
                return try await group.next() ?? nil
            }
        } catch {
            throw OVNManagerError.wrapping(error) {
                .connectionFailed("Monitor stream failed while waiting for \(column): \($0)")
            }
        }

        guard let reached else { throw OVNManagerError.timeoutError }
        return reached
    }

    /// Looks up a row's _uuid via a narrow select so existence checks don't
    /// fetch and decode entire rows. Returns nil when no row matches.
    func rowUUID(in table: String, where condition: OVSDBCondition) async throws(OVNManagerError) -> String? {
        let rows = try await connection.select(from: table, in: database, where: [condition], columns: ["_uuid"])

        guard let row = rows.first else { return nil }
        guard case .array(let uuidArray)? = row["_uuid"],
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid _uuid in select response")
        }
        return uuidValue
    }

    /// Binds the `load_balancer` column of whichever parent table the caller
    /// named — `Logical_Switch` or `Logical_Router` — to the shared
    /// reference helpers below.
    func attachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await attachReference(
            uuid: uuid,
            childTable: OVNTable.loadBalancer,
            childDescription: "Load balancer",
            parentTable: parentTable,
            parentColumn: "load_balancer",
            parentDescription: parentDescription,
            parentName: parentName
        )
    }

    func detachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await detachReference(
            uuid: uuid,
            parentTable: parentTable,
            parentColumn: "load_balancer",
            parentDescription: parentDescription,
            parentName: parentName
        )
    }

    /// The same binding for `load_balancer_group`, which sits beside
    /// `load_balancer` on both parent tables.
    func attachLoadBalancerGroup(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await attachReference(
            uuid: uuid,
            childTable: OVNTable.loadBalancerGroup,
            childDescription: "Load balancer group",
            parentTable: parentTable,
            parentColumn: "load_balancer_group",
            parentDescription: parentDescription,
            parentName: parentName
        )
    }

    func detachLoadBalancerGroup(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await detachReference(
            uuid: uuid,
            parentTable: parentTable,
            parentColumn: "load_balancer_group",
            parentDescription: parentDescription,
            parentName: parentName
        )
    }

    /// Adds a root-table row's UUID to a name-keyed parent's reference column
    /// (`Logical_Switch.load_balancer`, `Logical_Switch.dns_records`,
    /// `Logical_Router.load_balancer_group`, …).
    ///
    /// Most such columns are weak references: mutating in a UUID whose row no
    /// longer exists at commit is silently dropped rather than rejected, so
    /// the child's existence is re-checked with a wait op inside the same
    /// transaction. `load_balancer_group` is the strong one, which
    /// ovsdb-server would reject at commit instead — the wait op just gets
    /// there first, aborting the transaction either way.
    func attachReference(
        uuid: String,
        childTable: String,
        childDescription: String,
        parentTable: String,
        parentColumn: String,
        parentDescription: String,
        parentName: String
    ) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let childCondition = OVSDBCondition(column: "_uuid", function: "==", value: uuidAtom)

        guard try await rowUUID(in: childTable, where: childCondition) != nil else {
            throw OVNManagerError.operationFailed("\(childDescription) not found: \(uuid)")
        }

        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))
        var operations = rowExistenceWaitOps([uuid], in: childTable)
        operations.append(.mutate(
            parentTable,
            where: [parentCondition],
            mutations: [OVSDBMutation(column: parentColumn, mutator: "insert", value: uuidAtom)]
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard case .object(let mutateResult)? = results.last,
              case .number(let count)? = mutateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("\(parentDescription) not found: \(parentName)")
        }
    }

    /// Removes a UUID from a parent's reference column. No existence guard on
    /// the child, weak or strong: deleting a stale UUID from a set is a
    /// harmless no-op.
    func detachReference(
        uuid: String,
        parentTable: String,
        parentColumn: String,
        parentDescription: String,
        parentName: String
    ) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))

        let count = try await connection.mutate(
            table: parentTable,
            in: database,
            where: [parentCondition],
            mutations: [OVSDBMutation(column: parentColumn, mutator: "delete", value: uuidAtom)]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("\(parentDescription) not found: \(parentName)")
        }
    }

    /// Inserts or deletes a set of UUIDs in a weak reference column of the row
    /// named `name`, via a single mutate op. A no-op (empty UUID list) is
    /// skipped so the caller never issues an empty mutation.
    ///
    /// ovsdb-server silently drops a UUID whose row no longer exists at commit
    /// from a weak reference column, so an `insert` of a stale UUID would
    /// report the parent row matched while applying no membership change. For
    /// inserts we therefore guard each added UUID with a same-transaction wait
    /// op that aborts the transaction unless the row still exists at commit
    /// (mirroring the attach guard). Deletes need no such guard — removing a
    /// stale UUID is a harmless no-op.
    func mutateWeakReferenceSet(
        _ uuids: [String],
        referencing referencedTable: String,
        column: String,
        inTable table: String,
        named name: String,
        description: String,
        mutator: String
    ) async throws(OVNManagerError) {
        guard !uuids.isEmpty else { return }

        let atoms = uuids.map { JSONValue.array([.string("uuid"), .string($0)]) }
        let set = JSONValue.array([.string("set"), .array(atoms)])

        var operations = mutator == "insert" ? rowExistenceWaitOps(uuids, in: referencedTable) : []

        let rowCondition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        operations.append(.mutate(
            table,
            where: [rowCondition],
            mutations: [OVSDBMutation(column: column, mutator: mutator, value: set)]
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard case .object(let mutateResult)? = results.last,
              case .number(let count)? = mutateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("\(description) not found: \(name)")
        }
    }

    /// The `Port_Group.ports` membership mutation (a weak `Logical_Switch_Port`
    /// reference set).
    func mutatePorts(_ portUUIDs: [String], portGroup name: String, mutator: String) async throws(OVNManagerError) {
        try await mutateWeakReferenceSet(
            portUUIDs,
            referencing: OVNTable.logicalSwitchPort,
            column: "ports",
            inTable: OVNTable.portGroup,
            named: name,
            description: "Port group",
            mutator: mutator
        )
    }

    /// The `Load_Balancer_Group.load_balancer` membership mutation (a weak
    /// `Load_Balancer` reference set).
    func mutateLoadBalancerGroupMembers(_ loadBalancerUUIDs: [String], group name: String, mutator: String) async throws(OVNManagerError) {
        try await mutateWeakReferenceSet(
            loadBalancerUUIDs,
            referencing: OVNTable.loadBalancer,
            column: "load_balancer",
            inTable: OVNTable.loadBalancerGroup,
            named: name,
            description: "Load balancer group",
            mutator: mutator
        )
    }

    /// Inserts or deletes addresses in an address set's `addresses` column via
    /// a single mutate op, so incremental membership changes never
    /// read-modify-write the whole set. A no-op (empty list) is skipped so the
    /// caller never issues an empty mutation.
    ///
    /// Unlike `Port_Group.ports`, this column holds plain strings rather than
    /// references, so there is nothing whose existence needs guarding: a
    /// member's validity is checked by ovsdb-server against the column type,
    /// and by ovn-northd when it translates the referencing match.
    func mutateAddresses(_ addresses: [String], addressSet name: String, mutator: String) async throws(OVNManagerError) {
        guard !addresses.isEmpty else { return }

        let addressSetValue = JSONValue.array([.string("set"), .array(addresses.map { .string($0) })])
        let setCondition = OVSDBCondition(column: "name", function: "==", value: .string(name))

        let count = try await connection.mutate(
            table: OVNTable.addressSet,
            in: database,
            where: [setCondition],
            mutations: [OVSDBMutation(column: "addresses", mutator: mutator, value: addressSetValue)]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Address set not found: \(name)")
        }
    }

    /// Inserts a row into a table whose `name` column the schema indexes,
    /// after `guardOperations`. The caller has already checked the name is
    /// free; the wait op appended here closes the race between that check and
    /// the insert, aborting the transaction unless no row with that name
    /// exists at commit. Returns the new row's UUID.
    func insertUniquelyNamed(
        row: OVSDBRow,
        into table: String,
        nameCondition: OVSDBCondition,
        guardOperations: [OVSDBOperation]
    ) async throws(OVNManagerError) -> String {
        var operations = guardOperations
        operations.append(.wait(
            table,
            where: [nameCondition],
            columns: ["name"],
            rows: [],
            until: "==",
            timeout: 0
        ))
        let insertIndex = operations.count
        operations.append(.insert(into: table, row: row))

        let results = try await connection.transact(in: database, operations: operations)
        return try OVSDBConnection.uuid(fromInsertResults: results, at: insertIndex)
    }

    /// Updates the row with `uuid` after `guardOperations`, returning how many
    /// rows the update matched. Separate from `connection.update` only because
    /// the guards have to share the update's transaction.
    func updateGuarded(
        row: OVSDBRow,
        in table: String,
        uuid: String,
        guardOperations: [OVSDBOperation]
    ) async throws(OVNManagerError) -> Int {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))

        var operations = guardOperations
        let updateIndex = operations.count
        operations.append(.update(table, where: [condition], row: row))

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count > updateIndex,
              case .object(let updateResult) = results[updateIndex],
              case .number(let count)? = updateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid update response format")
        }
        return Int(count)
    }

    /// Builds a `wait` op per UUID that aborts the enclosing transaction unless
    /// a row with that UUID still exists in `table` at commit. Every weak
    /// reference column needs this guard: ovsdb-server silently drops a stale
    /// UUID from one and reports the write as succeeding.
    func rowExistenceWaitOps(_ uuids: [String], in table: String) -> [OVSDBOperation] {
        uuids.map { uuid in
            let rowCondition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
            return OVSDBOperation.wait(
                table,
                where: [rowCondition],
                columns: ["_uuid"],
                rows: [],
                until: "!=",
                timeout: 0
            )
        }
    }

    /// The `Logical_Switch_Port` guards for `Port_Group.ports`, which is a weak
    /// reference set. Used by any transaction that writes that column (create,
    /// update, mutate).
    func portExistenceWaitOps(_ portUUIDs: [String]) -> [OVSDBOperation] {
        rowExistenceWaitOps(portUUIDs, in: OVNTable.logicalSwitchPort)
    }

    /// The `Load_Balancer` guards for `Load_Balancer_Group.load_balancer`,
    /// which is a weak reference set like `Port_Group.ports`.
    func loadBalancerExistenceWaitOps(_ loadBalancerUUIDs: [String]) -> [OVSDBOperation] {
        rowExistenceWaitOps(loadBalancerUUIDs, in: OVNTable.loadBalancer)
    }

    /// Decodes a row into its model. `OVSDBRowDecoder` is a general `Decoder`
    /// and so throws `DecodingError`; this is the boundary where that becomes
    /// `OVNManagerError.decodingError`, keeping the manager API closed over one
    /// error type.
    func parseRow<T: Codable>(_ row: OVSDBRow, as type: T.Type) throws(OVNManagerError) -> T {
        do {
            return try OVSDBRowDecoder.decode(type, from: row)
        } catch {
            throw OVNManagerError.wrapping(error) { .decodingError($0) }
        }
    }

    /// Decodes every row of a table select. Separate from `parseRow` because
    /// `Sequence.map` is `rethrows`, which erases a typed throw back to
    /// `any Error` — the loop has to be written out to keep it.
    func parseRows<T: Codable>(_ rows: [OVSDBRow], as type: T.Type) throws(OVNManagerError) -> [T] {
        var models: [T] = []
        models.reserveCapacity(rows.count)
        for row in rows {
            models.append(try parseRow(row, as: type))
        }
        return models
    }

    func createRow<T: Codable>(from object: T) throws(OVNManagerError) -> OVSDBRow {
        return try OVSDBRowEncoder.makeRow(from: object, hints: .ovn)
    }

    /// The table-scoped variant, required for a table where a column's wire form
    /// differs from the same column name elsewhere in the database — today just
    /// `Logical_Router_Policy.output_port`. See `ColumnHints.ovn(table:)`.
    func createRow<T: Codable>(from object: T, in table: String) throws(OVNManagerError) -> OVSDBRow {
        return try OVSDBRowEncoder.makeRow(from: object, hints: .ovn(table: table))
    }
}
