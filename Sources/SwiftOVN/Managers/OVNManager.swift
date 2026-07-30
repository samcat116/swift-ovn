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
    
    public init(endpoint: OVSDBEndpoint, database: String = OVNDatabase.northbound, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = OVSDBConnection(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.database = database
        self.logger = logger ?? Logger(label: "ovn-manager.ovn")
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
        let operations = [
            OVSDBOperation(
                op: "wait",
                table: OVNTable.logicalSwitch,
                whereConditions: [nameCondition],
                columns: ["name"],
                rows: [],
                until: "==",
                timeout: 0
            ),
            OVSDBOperation(
                op: "insert",
                table: OVNTable.logicalSwitch,
                row: row
            )
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

        let uuidValue = try await connection.insertAttached(
            into: OVNTable.logicalRouterStaticRoute,
            in: database,
            row: try createRow(from: route),
            uuidName: "new_route",
            parentTable: OVNTable.logicalRouter,
            parentColumn: "static_routes",
            parentCondition: routerCondition
        )

        logger.info("Created static route: \(route.ip_prefix) on router: \(routerName)")
        return uuidValue
    }

    public func updateStaticRoute(uuid: String, _ route: OVNLogicalRouterStaticRoute) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: route)

        let count = try await connection.update(table: OVNTable.logicalRouterStaticRoute, in: database, where: [condition], row: row)

        if count == 0 {
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

        // output_port is a weak reference, so a UUID whose router port is stale
        // at commit would be dropped from the insert — leaving a reroute policy
        // with no egress port and no error to show for it.
        let guardOps = rowExistenceWaitOps(policy.output_port.map { [$0] } ?? [], in: OVNTable.logicalRouterPort)
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

        // A full-row update rewrites the weak-reference output_port, so guard it
        // exactly as create does.
        var operations = rowExistenceWaitOps(policy.output_port.map { [$0] } ?? [], in: OVNTable.logicalRouterPort)
        let updateIndex = operations.count
        operations.append(OVSDBOperation(
            op: "update",
            table: OVNTable.logicalRouterPolicy,
            whereConditions: [condition],
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
        try await detachReference(uuid: uuid, column: "load_balancer", parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Detached load balancer \(uuid) from switch: \(switchName)")
    }

    /// Detaches a load balancer from the named logical router, mirroring
    /// `ovn-nbctl lr-lb-del`. The load balancer row itself is kept.
    public func detachLoadBalancer(uuid: String, fromRouter routerName: String) async throws(OVNManagerError) {
        try await detachReference(uuid: uuid, column: "load_balancer", parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
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
        try await detachReference(uuid: uuid, column: "load_balancer_group", parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Detached load balancer group \(uuid) from switch: \(switchName)")
    }

    /// Detaches a load balancer group from the named logical router. The group
    /// row itself is kept.
    public func detachLoadBalancerGroup(uuid: String, fromRouter routerName: String) async throws(OVNManagerError) {
        try await detachReference(uuid: uuid, column: "load_balancer_group", parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
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
    
    // MARK: - Monitoring
    
    public func startMonitoring(tables: [String]) async throws(OVNManagerError) -> String {
        var monitorRequests: [String: OVSDBMonitorRequest] = [:]
        
        for table in tables {
            monitorRequests[table] = OVSDBMonitorRequest()
        }
        
        return try await connection.startMonitoring(database: database, tables: monitorRequests).monitorId
    }
    
    public func stopMonitoring(monitorId: String) async throws(OVNManagerError) {
        try await connection.stopMonitoring(monitorId: monitorId)
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
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassis, in: database)
        return try parseRows(rows, as: OVNChassis.self)
    }
    
    public func getChassisPrivate() async throws(OVNManagerError) -> [OVNChassisPrivate] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis Private operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassisPrivate, in: database)
        return try parseRows(rows, as: OVNChassisPrivate.self)
    }
    
    public func getPortBindings() async throws(OVNManagerError) -> [OVNPortBinding] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Port Binding operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.portBinding, in: database)
        return try parseRows(rows, as: OVNPortBinding.self)
    }
    
    public func getLogicalFlows() async throws(OVNManagerError) -> [OVNLogicalFlow] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Logical Flow operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.logicalFlow, in: database)
        return try parseRows(rows, as: OVNLogicalFlow.self)
    }

    public func getAdvertisedRoutes() async throws(OVNManagerError) -> [OVNAdvertisedRoute] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Advertised Route operations require southbound database")
        }

        let rows = try await connection.selectAll(from: OVNTable.advertisedRoute, in: database)
        return try parseRows(rows, as: OVNAdvertisedRoute.self)
    }

    public func getLearnedRoutes() async throws(OVNManagerError) -> [OVNLearnedRoute] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Learned Route operations require southbound database")
        }

        let rows = try await connection.selectAll(from: OVNTable.learnedRoute, in: database)
        return try parseRows(rows, as: OVNLearnedRoute.self)
    }

    /// The Southbound `Service_Monitor` rows: one per load balancer backend
    /// covered by a `Load_Balancer_Health_Check`, carrying the `status` the
    /// probing chassis reported. This is the only way to observe whether OVN
    /// currently considers a backend up.
    public func getServiceMonitors() async throws(OVNManagerError) -> [OVNServiceMonitor] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Service Monitor operations require southbound database")
        }

        let rows = try await connection.selectAll(from: OVNTable.serviceMonitor, in: database)
        return try parseRows(rows, as: OVNServiceMonitor.self)
    }
}

// MARK: - Helper Methods

private extension OVNManager {
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

    /// Adds a row's UUID to a parent row's reference column via a single
    /// mutate, guarded by a wait op that re-checks the referenced row still
    /// exists at commit.
    ///
    /// The guard is what a weak column needs: mutating a UUID into
    /// `load_balancer` after its row has gone is silently dropped rather than
    /// rejected, so without it the attach would report success and change
    /// nothing. A strong column (`load_balancer_group`) would instead be
    /// rejected by ovsdb-server at commit; the wait op just gets there first,
    /// aborting the transaction either way.
    func attachReference(
        uuid: String,
        referencedTable: String,
        referencedDescription: String,
        column: String,
        parentTable: String,
        parentDescription: String,
        parentName: String
    ) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let rowCondition = OVSDBCondition(column: "_uuid", function: "==", value: uuidAtom)

        guard try await rowUUID(in: referencedTable, where: rowCondition) != nil else {
            throw OVNManagerError.operationFailed("\(referencedDescription) not found: \(uuid)")
        }

        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))
        var operations = rowExistenceWaitOps([uuid], in: referencedTable)
        operations.append(OVSDBOperation(
            op: "mutate",
            table: parentTable,
            whereConditions: [parentCondition],
            mutations: [OVSDBMutation(column: column, mutator: "insert", value: uuidAtom)]
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

    /// Removes a UUID from a parent row's reference column. Neither a weak nor
    /// a strong column needs an existence guard here: removing a UUID that
    /// names no row is a harmless no-op.
    func detachReference(uuid: String, column: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))

        let count = try await connection.mutate(
            table: parentTable,
            in: database,
            where: [parentCondition],
            mutations: [OVSDBMutation(column: column, mutator: "delete", value: uuidAtom)]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("\(parentDescription) not found: \(parentName)")
        }
    }

    func attachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await attachReference(
            uuid: uuid,
            referencedTable: OVNTable.loadBalancer,
            referencedDescription: "Load balancer",
            column: "load_balancer",
            parentTable: parentTable,
            parentDescription: parentDescription,
            parentName: parentName
        )
    }

    func attachLoadBalancerGroup(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        try await attachReference(
            uuid: uuid,
            referencedTable: OVNTable.loadBalancerGroup,
            referencedDescription: "Load balancer group",
            column: "load_balancer_group",
            parentTable: parentTable,
            parentDescription: parentDescription,
            parentName: parentName
        )
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
        operations.append(OVSDBOperation(
            op: "mutate",
            table: table,
            whereConditions: [rowCondition],
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
        operations.append(OVSDBOperation(
            op: "wait",
            table: table,
            whereConditions: [nameCondition],
            columns: ["name"],
            rows: [],
            until: "==",
            timeout: 0
        ))
        let insertIndex = operations.count
        operations.append(OVSDBOperation(
            op: "insert",
            table: table,
            row: row
        ))

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
        operations.append(OVSDBOperation(
            op: "update",
            table: table,
            whereConditions: [condition],
            row: row
        ))

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
            return OVSDBOperation(
                op: "wait",
                table: table,
                whereConditions: [rowCondition],
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
