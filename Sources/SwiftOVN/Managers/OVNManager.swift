import Foundation
import NIO
import Logging

public actor OVNManager: OVNManaging {
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

    public init(socketPath: String, database: String = OVNDatabase.northbound, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), database: database, eventLoopGroup: eventLoopGroup, logger: logger)
    }
    
    // MARK: - Connection Management
    
    public func connect() async throws {
        try await connection.connect()
        logger.info("Connected to OVN database: \(database)")
    }
    
    public func disconnect() async throws {
        try await connection.disconnect()
        logger.info("Disconnected from OVN database")
    }
    
    public var isConnected: Bool {
        get async {
            return await connection.isConnected
        }
    }
    
    // MARK: - Database Operations
    
    public func listDatabases() async throws -> [String] {
        return try await connection.listDatabases()
    }
    
    public func getDatabaseSchema(database: String) async throws -> JSONValue {
        return try await connection.getDatabaseSchema(database: database)
    }
    
    // MARK: - Logical Switch Operations
    
    public func getLogicalSwitches() async throws -> [OVNLogicalSwitch] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitch, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalSwitch.self)
        }
    }
    
    public func getLogicalSwitch(named name: String) async throws -> OVNLogicalSwitch? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitch.self)
    }
    
    public func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws -> String {
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
    
    public func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: logicalSwitch)
        
        let count = try await connection.update(table: OVNTable.logicalSwitch, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Updated logical switch: \(logicalSwitch.name)")
    }
    
    public func deleteLogicalSwitch(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(uuid)")
        }
        
        logger.info("Deleted logical switch: \(uuid)")
    }
    
    public func deleteLogicalSwitch(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalSwitch, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch not found: \(name)")
        }
        
        logger.info("Deleted logical switch: \(name)")
    }
    
    // MARK: - Logical Switch Port Operations
    
    public func getLogicalSwitchPorts() async throws -> [OVNLogicalSwitchPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalSwitchPort, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalSwitchPort.self)
        }
    }
    
    public func getLogicalSwitchPort(named name: String) async throws -> OVNLogicalSwitchPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalSwitchPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalSwitchPort.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that ovn-northd ignores (no Port_Binding, no dataplane). Use createLogicalSwitchPort(_:onSwitch:) so the port is attached to its switch.")
    public func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws -> String {
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
    public func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort, onSwitch switchName: String) async throws -> String {
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
    
    public func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalSwitchPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(uuid)")
        }
        
        logger.info("Updated logical switch port: \(port.name)")
    }
    
    public func deleteLogicalSwitchPort(uuid: String) async throws {
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

    public func deleteLogicalSwitchPort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVNTable.logicalSwitchPort, where: condition) else {
            throw OVNManagerError.operationFailed("Logical switch port not found: \(name)")
        }

        try await deleteLogicalSwitchPort(uuid: uuid)

        logger.info("Deleted logical switch port: \(name)")
    }
    
    // MARK: - Logical Router Operations
    
    public func getLogicalRouters() async throws -> [OVNLogicalRouter] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouter, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalRouter.self)
        }
    }
    
    public func getLogicalRouter(named name: String) async throws -> OVNLogicalRouter? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouter.self)
    }
    
    public func createLogicalRouter(_ router: OVNLogicalRouter) async throws -> String {
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
    
    public func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: router)
        
        let count = try await connection.update(table: OVNTable.logicalRouter, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Updated logical router: \(router.name)")
    }
    
    public func deleteLogicalRouter(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(uuid)")
        }
        
        logger.info("Deleted logical router: \(uuid)")
    }
    
    public func deleteLogicalRouter(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.logicalRouter, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router not found: \(name)")
        }
        
        logger.info("Deleted logical router: \(name)")
    }
    
    // MARK: - Logical Router Port Operations
    
    public func getLogicalRouterPorts() async throws -> [OVNLogicalRouterPort] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterPort, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalRouterPort.self)
        }
    }
    
    public func getLogicalRouterPort(named name: String) async throws -> OVNLogicalRouterPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.logicalRouterPort, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLogicalRouterPort.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createLogicalRouterPort(_:onRouter:) so the port is attached to its router.")
    public func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws -> String {
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
    public func createLogicalRouterPort(_ port: OVNLogicalRouterPort, onRouter routerName: String) async throws -> String {
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

    public func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVNTable.logicalRouterPort, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Logical router port not found: \(uuid)")
        }
        
        logger.info("Updated logical router port: \(port.name)")
    }
    
    public func deleteLogicalRouterPort(uuid: String) async throws {
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

    public func deleteLogicalRouterPort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVNTable.logicalRouterPort, where: condition) else {
            throw OVNManagerError.operationFailed("Logical router port not found: \(name)")
        }

        try await deleteLogicalRouterPort(uuid: uuid)

        logger.info("Deleted logical router port: \(name)")
    }

    // MARK: - Logical Router Static Route Operations

    public func getStaticRoutes() async throws -> [OVNLogicalRouterStaticRoute] {
        let rows = try await connection.selectAll(from: OVNTable.logicalRouterStaticRoute, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalRouterStaticRoute.self)
        }
    }

    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createStaticRoute(_:onRouter:) so the route is attached to its router.")
    public func createStaticRoute(_ route: OVNLogicalRouterStaticRoute) async throws -> String {
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
    public func createStaticRoute(_ route: OVNLogicalRouterStaticRoute, onRouter routerName: String) async throws -> String {
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

    public func updateStaticRoute(uuid: String, _ route: OVNLogicalRouterStaticRoute) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: route)

        let count = try await connection.update(table: OVNTable.logicalRouterStaticRoute, in: database, where: [condition], row: row)

        if count == 0 {
            throw OVNManagerError.operationFailed("Static route not found: \(uuid)")
        }

        logger.info("Updated static route: \(uuid)")
    }

    public func deleteStaticRoute(uuid: String) async throws {
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

    // MARK: - ACL Operations
    
    public func getACLs() async throws -> [OVNACL] {
        let rows = try await connection.selectAll(from: OVNTable.acl, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNACL.self)
        }
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createACL(_:onSwitch:) or createACL(_:onPortGroup:) so the ACL is attached.")
    public func createACL(_ acl: OVNACL) async throws -> String {
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
    public func createACL(_ acl: OVNACL, onSwitch switchName: String) async throws -> String {
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
    public func createACL(_ acl: OVNACL, onPortGroup portGroupName: String) async throws -> String {
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
    
    public func updateACL(uuid: String, _ acl: OVNACL) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: acl)
        
        let count = try await connection.update(table: OVNTable.acl, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("ACL not found: \(uuid)")
        }
        
        logger.info("Updated ACL: \(uuid)")
    }
    
    public func deleteACL(uuid: String) async throws {
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

    public func getPortGroups() async throws -> [OVNPortGroup] {
        let rows = try await connection.selectAll(from: OVNTable.portGroup, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNPortGroup.self)
        }
    }

    public func getPortGroup(named name: String) async throws -> OVNPortGroup? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.portGroup, in: database, where: [condition])

        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNPortGroup.self)
    }

    /// Creates a port group, mirroring `ovn-nbctl pg-add`. Port_Group is a
    /// root table, so the row persists until it is explicitly deleted.
    public func createPortGroup(_ portGroup: OVNPortGroup) async throws -> String {
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

    public func updatePortGroup(uuid: String, _ portGroup: OVNPortGroup) async throws {
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
    public func addPorts(_ portUUIDs: [String], toPortGroup name: String) async throws {
        try await mutatePorts(portUUIDs, portGroup: name, mutator: "insert")
    }

    /// Removes logical switch ports from the group's membership without
    /// rewriting the whole `ports` set.
    public func removePorts(_ portUUIDs: [String], fromPortGroup name: String) async throws {
        try await mutatePorts(portUUIDs, portGroup: name, mutator: "delete")
    }

    public func deletePortGroup(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.portGroup, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(uuid)")
        }

        logger.info("Deleted port group: \(uuid)")
    }

    public func deletePortGroup(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let count = try await connection.delete(from: OVNTable.portGroup, in: database, where: [condition])

        if count == 0 {
            throw OVNManagerError.operationFailed("Port group not found: \(name)")
        }

        logger.info("Deleted port group: \(name)")
    }

    // MARK: - Load Balancer Operations
    
    public func getLoadBalancers() async throws -> [OVNLoadBalancer] {
        let rows = try await connection.selectAll(from: OVNTable.loadBalancer, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLoadBalancer.self)
        }
    }
    
    public func getLoadBalancer(named name: String) async throws -> OVNLoadBalancer? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVNLoadBalancer.self)
    }
    
    public func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws -> String {
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
    
    public func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: loadBalancer)
        
        let count = try await connection.update(table: OVNTable.loadBalancer, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Updated load balancer: \(loadBalancer.name)")
    }
    
    public func deleteLoadBalancer(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.loadBalancer, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Load balancer not found: \(uuid)")
        }
        
        logger.info("Deleted load balancer: \(uuid)")
    }
    
    public func deleteLoadBalancer(named name: String) async throws {
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
    public func attachLoadBalancer(uuid: String, toSwitch switchName: String) async throws {
        try await attachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Attached load balancer \(uuid) to switch: \(switchName)")
    }

    /// Attaches an existing load balancer to the named logical router
    /// (Logical_Router.load_balancer), mirroring `ovn-nbctl lr-lb-add`.
    public func attachLoadBalancer(uuid: String, toRouter routerName: String) async throws {
        try await attachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Attached load balancer \(uuid) to router: \(routerName)")
    }

    /// Detaches a load balancer from the named logical switch, mirroring
    /// `ovn-nbctl ls-lb-del`. The load balancer row itself is kept.
    public func detachLoadBalancer(uuid: String, fromSwitch switchName: String) async throws {
        try await detachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalSwitch, parentDescription: "Logical switch", parentName: switchName)
        logger.info("Detached load balancer \(uuid) from switch: \(switchName)")
    }

    /// Detaches a load balancer from the named logical router, mirroring
    /// `ovn-nbctl lr-lb-del`. The load balancer row itself is kept.
    public func detachLoadBalancer(uuid: String, fromRouter routerName: String) async throws {
        try await detachLoadBalancer(uuid: uuid, parentTable: OVNTable.logicalRouter, parentDescription: "Logical router", parentName: routerName)
        logger.info("Detached load balancer \(uuid) from router: \(routerName)")
    }

    // MARK: - NAT Operations
    
    public func getNATRules() async throws -> [OVNNAT] {
        let rows = try await connection.selectAll(from: OVNTable.nat, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNNAT.self)
        }
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNATRule(_:onRouter:) so the rule is attached to its router.")
    public func createNATRule(_ nat: OVNNAT) async throws -> String {
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
    public func createNATRule(_ nat: OVNNAT, onRouter routerName: String) async throws -> String {
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
    
    public func updateNATRule(uuid: String, _ nat: OVNNAT) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: nat)
        
        let count = try await connection.update(table: OVNTable.nat, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NAT rule not found: \(uuid)")
        }
        
        logger.info("Updated NAT rule: \(uuid)")
    }
    
    public func deleteNATRule(uuid: String) async throws {
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
    
    // MARK: - DHCP Operations
    
    public func getDHCPOptions() async throws -> [OVNDHCPOptions] {
        let rows = try await connection.selectAll(from: OVNTable.dhcpOptions, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNDHCPOptions.self)
        }
    }
    
    public func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws -> String {
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
    
    public func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: dhcp)
        
        let count = try await connection.update(table: OVNTable.dhcpOptions, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Updated DHCP options: \(uuid)")
    }
    
    public func deleteDHCPOptions(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVNTable.dhcpOptions, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("DHCP options not found: \(uuid)")
        }
        
        logger.info("Deleted DHCP options: \(uuid)")
    }
    
    // MARK: - Monitoring
    
    public func startMonitoring(tables: [String]) async throws -> String {
        var monitorRequests: [String: OVSDBMonitorRequest] = [:]
        
        for table in tables {
            monitorRequests[table] = OVSDBMonitorRequest()
        }
        
        return try await connection.startMonitoring(database: database, tables: monitorRequests).monitorId
    }
    
    public func stopMonitoring(monitorId: String) async throws {
        try await connection.stopMonitoring(monitorId: monitorId)
    }
    
    nonisolated public func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error> {
        return AsyncThrowingStream { continuation in
            Task {
                let updates = connection.monitorUpdates()
                do {
                    for try await update in updates {
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
    
    // MARK: - Southbound Operations
    
    public func getChassis() async throws -> [OVNChassis] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassis, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNChassis.self)
        }
    }
    
    public func getChassisPrivate() async throws -> [OVNChassisPrivate] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Chassis Private operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.chassisPrivate, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNChassisPrivate.self)
        }
    }
    
    public func getPortBindings() async throws -> [OVNPortBinding] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Port Binding operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.portBinding, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNPortBinding.self)
        }
    }
    
    public func getLogicalFlows() async throws -> [OVNLogicalFlow] {
        guard database == OVNDatabase.southbound else {
            throw OVNManagerError.operationFailed("Logical Flow operations require southbound database")
        }
        
        let rows = try await connection.selectAll(from: OVNTable.logicalFlow, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVNLogicalFlow.self)
        }
    }
}

// MARK: - Helper Methods

private extension OVNManager {
    /// Looks up a row's _uuid via a narrow select so existence checks don't
    /// fetch and decode entire rows. Returns nil when no row matches.
    func rowUUID(in table: String, where condition: OVSDBCondition) async throws -> String? {
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
    func attachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws {
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

    func detachLoadBalancer(uuid: String, parentTable: String, parentDescription: String, parentName: String) async throws {
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
    func mutatePorts(_ portUUIDs: [String], portGroup name: String, mutator: String) async throws {
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

    /// Builds a `wait` op per port UUID that aborts the enclosing transaction
    /// unless that `Logical_Switch_Port` still exists at commit. `Port_Group`'s
    /// `ports` is a weak reference set, so ovsdb-server would otherwise silently
    /// drop a stale UUID and report the write as succeeding. Used by any
    /// transaction that writes the `ports` column (create, update, mutate).
    func portExistenceWaitOps(_ portUUIDs: [String]) -> [OVSDBOperation] {
        portUUIDs.map { uuid in
            let portCondition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
            return OVSDBOperation(
                op: "wait",
                table: OVNTable.logicalSwitchPort,
                whereConditions: [portCondition],
                columns: ["_uuid"],
                rows: [],
                until: "!=",
                timeout: 0
            )
        }
    }

    func parseRow<T: Codable>(_ row: OVSDBRow, as type: T.Type) throws -> T {
        return try OVSDBRowDecoder.decode(type, from: row)
    }

    func createRow<T: Codable>(from object: T) throws -> OVSDBRow {
        return try OVSDBRowEncoder.makeRow(from: object, hints: .ovn)
    }
}