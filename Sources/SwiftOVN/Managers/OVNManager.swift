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

        let row = try createRow(from: portGroup)

        // `ports` is a weak reference set, so any initial member whose port row
        // is stale at commit would be silently dropped from the insert. Guard
        // each supplied port so a stale UUID aborts the whole insert instead of
        // creating a group with missing membership.
        var operations = portExistenceWaitOps(portGroup.ports ?? [])

        // Guard against a duplicate name racing in between the check above and
        // the insert: the wait op aborts the transaction unless no row with
        // this name still exists at commit.
        operations.append(OVSDBOperation(
            op: "wait",
            table: OVNTable.portGroup,
            whereConditions: [nameCondition],
            columns: ["name"],
            rows: [],
            until: "==",
            timeout: 0
        ))
        let insertIndex = operations.count
        operations.append(OVSDBOperation(
            op: "insert",
            table: OVNTable.portGroup,
            row: row
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard results.count > insertIndex,
              case .object(let insertResult) = results[insertIndex],
              let uuid = insertResult["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created port group: \(portGroup.name)")
        return uuidValue
    }

    public func updatePortGroup(uuid: String, _ portGroup: OVNPortGroup) async throws(OVNManagerError) {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: portGroup)

        // A full-row update rewrites the weak-reference `ports` set, so guard
        // each supplied port the same way create/mutate do: a stale UUID aborts
        // the update rather than being silently dropped from the new set.
        var operations = portExistenceWaitOps(portGroup.ports ?? [])
        let updateIndex = operations.count
        operations.append(OVSDBOperation(
            op: "update",
            table: OVNTable.portGroup,
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

    /// Reads the singleton `SB_Global` row, or nil if the database has none.
    ///
    /// Its `nb_cfg` is the generation of northbound configuration ovn-northd
    /// has published here — the value each chassis copies onwards once it has
    /// installed the flows. `NB_Global.sb_cfg` is the same progress reported
    /// back on the northbound side, which is what `waitForNorthd(timeout:)`
    /// waits on, so this is a read for inspecting the southbound side rather
    /// than a second way to run the barrier.
    public func getSBGlobal() async throws(OVNManagerError) -> OVNSBGlobal? {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("SB_Global operations require southbound database")
        }

        let rows = try await connection.selectAll(from: OVNTable.sbGlobal, in: database)
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNSBGlobal.self)
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

    /// The load_balancer columns are weak references: mutating in a UUID
    /// whose row no longer exists at commit is silently dropped rather than
    /// rejected, so the load balancer's existence is re-checked with a wait
    /// op inside the same transaction.
    func attachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let lbCondition = OVSDBCondition(column: "_uuid", function: "==", value: uuidAtom)

        guard try await rowUUID(in: OVNTable.loadBalancer, where: lbCondition) != nil else {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }

        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))
        let operations = [
            OVSDBOperation(
                op: "wait",
                table: OVNTable.loadBalancer,
                whereConditions: [lbCondition],
                columns: ["name"],
                rows: [],
                until: "!=",
                timeout: 0
            ),
            OVSDBOperation(
                op: "mutate",
                table: parentTable,
                whereConditions: [parentCondition],
                mutations: [OVSDBMutation(column: "load_balancer", mutator: "insert", value: uuidAtom)]
            )
        ]

        let results = try await connection.transact(in: database, operations: operations)

        guard case .object(let mutateResult)? = results.last,
              case .number(let count)? = mutateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("\(parentDescription) not found: \(parentName)")
        }
    }

    func detachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws(OVNManagerError) {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])
        let parentCondition = OVSDBCondition(column: "name", function: "==", value: .string(parentName))

        let count = try await connection.mutate(
            table: parentTable,
            in: database,
            where: [parentCondition],
            mutations: [OVSDBMutation(column: "load_balancer", mutator: "delete", value: uuidAtom)]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("\(parentDescription) not found: \(parentName)")
        }
    }

    /// Inserts or deletes a set of Logical_Switch_Port UUIDs in a port
    /// group's `ports` column via a single mutate op. A no-op (empty UUID
    /// list) is skipped so the caller never issues an empty mutation.
    ///
    /// `Port_Group.ports` is a weak reference set: ovsdb-server silently drops
    /// a UUID whose Logical_Switch_Port no longer exists at commit, so an
    /// `insert` of a stale UUID would report the port group matched while
    /// applying no membership change. For inserts we therefore guard each
    /// added port with a same-transaction wait op that aborts the transaction
    /// unless the port row still exists at commit (mirroring the load-balancer
    /// attach guard). Deletes need no such guard — removing a stale UUID is a
    /// harmless no-op.
    func mutatePorts(_ portUUIDs: [String], portGroup name: String, mutator: String) async throws(OVNManagerError) {
        guard !portUUIDs.isEmpty else { return }

        let portAtoms = portUUIDs.map { JSONValue.array([.string("uuid"), .string($0)]) }
        let portSet = JSONValue.array([.string("set"), .array(portAtoms)])

        // Deletes need no guard — removing a stale UUID is a harmless no-op.
        var operations = mutator == "insert" ? portExistenceWaitOps(portUUIDs) : []

        let groupCondition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        operations.append(OVSDBOperation(
            op: "mutate",
            table: OVNTable.portGroup,
            whereConditions: [groupCondition],
            mutations: [OVSDBMutation(column: "ports", mutator: mutator, value: portSet)]
        ))

        let results = try await connection.transact(in: database, operations: operations)

        guard case .object(let mutateResult)? = results.last,
              case .number(let count)? = mutateResult["count"] else {
            throw OVNManagerError.invalidResponse("Invalid mutate response format")
        }
        if Int(count) == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(name)")
        }
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
