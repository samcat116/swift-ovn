import Foundation
import NIO
import Logging

public actor OVSManager: OVSManaging {
    private let connection: OVSDBConnection
    private let logger: Logger
    private let database: String
    
    public init(endpoint: OVSDBEndpoint, database: String = OVSDatabase.openVSwitch, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = OVSDBConnection(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.database = database
        self.logger = logger ?? Logger(label: "ovn-manager.ovs")
    }

    public init(socketPath: String, database: String = OVSDatabase.openVSwitch, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), database: database, eventLoopGroup: eventLoopGroup, logger: logger)
    }
    
    // MARK: - Connection Management
    
    public func connect() async throws {
        try await connection.connect()
        logger.info("Connected to OVS database: \(database)")
    }
    
    public func disconnect() async throws {
        try await connection.disconnect()
        logger.info("Disconnected from OVS database")
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
    
    // MARK: - Bridge Operations
    
    public func getBridges() async throws -> [OVSBridge] {
        let rows = try await connection.selectAll(from: OVSTable.bridge, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSBridge.self)
        }
    }
    
    public func getBridge(named name: String) async throws -> OVSBridge? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.bridge, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSBridge.self)
    }
    
    /// Creates a bridge with its bridge-named internal port/interface pair
    /// and attaches it to the Open_vSwitch root row (Open_vSwitch.bridges) in
    /// a single OVSDB transaction, mirroring `ovs-vsctl add-br`. The internal
    /// pair is what makes `ovs-vswitchd` instantiate the bridge's Linux
    /// netdev — a bare Bridge row commits fine but never gets a datapath or a
    /// host-visible device. Bridge, Port, and Interface are not root tables,
    /// so unreferenced rows are garbage-collected when the transaction
    /// commits. Any UUIDs in `bridge.ports` are replaced by the new internal
    /// port. Returns the new bridge's UUID.
    public func createBridge(_ bridge: OVSBridge) async throws -> String {
        let operations = OVSDBReferenceTransactions.insertBridgeAttached(
            bridgeRow: try createRow(from: bridge),
            portRow: try createRow(from: OVSPort(name: bridge.name, interfaces: [])),
            interfaceRow: try createRow(from: OVSInterface(name: bridge.name, interfaceType: "internal"))
        )

        let results = try await connection.transact(in: database, operations: operations)
        let uuidValue = try OVSDBConnection.uuid(fromInsertResults: results, at: 2)

        logger.info("Created bridge: \(bridge.name)")
        return uuidValue
    }
    
    public func updateBridge(uuid: String, _ bridge: OVSBridge) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: bridge)
        
        let count = try await connection.update(table: OVSTable.bridge, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Bridge not found: \(uuid)")
        }
        
        logger.info("Updated bridge: \(bridge.name)")
    }
    
    public func deleteBridge(uuid: String) async throws {
        // Detaching from Open_vSwitch.bridges in the same transaction is
        // required: deleting a strongly-referenced row alone is rejected by
        // ovsdb-server. The bridge's now-unreferenced ports, interfaces,
        // controllers, etc. are garbage-collected at commit.
        let count = try await connection.deleteDetaching(
            from: OVSTable.bridge,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.openVSwitch, column: "bridges")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Bridge not found: \(uuid)")
        }

        logger.info("Deleted bridge: \(uuid)")
    }

    public func deleteBridge(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVSTable.bridge, where: condition) else {
            throw OVNManagerError.operationFailed("Bridge not found: \(name)")
        }

        try await deleteBridge(uuid: uuid)

        logger.info("Deleted bridge: \(name)")
    }
    
    // MARK: - Port Operations
    
    public func getPorts() async throws -> [OVSPort] {
        let rows = try await connection.selectAll(from: OVSTable.port, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSPort.self)
        }
    }
    
    public func getPort(named name: String) async throws -> OVSPort? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.port, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSPort.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createPort(_:withInterface:onBridge:) so the port is attached to its bridge.")
    public func createPort(_ port: OVSPort) async throws -> String {
        let row = try createRow(from: port)
        let result = try await connection.insert(into: OVSTable.port, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created port: \(port.name)")
        return uuidValue
    }

    /// Creates a port with its initial interface and attaches it to the
    /// named bridge in a single OVSDB transaction, mirroring
    /// `ovs-vsctl add-port`. Port and Interface are not root tables —
    /// unreferenced rows are garbage-collected at commit — and
    /// Port.interfaces requires at least one interface, so all three steps
    /// must commit together. Any UUIDs in `port.interfaces` are replaced by
    /// the newly created interface. Returns the new port's UUID.
    public func createPort(_ port: OVSPort, withInterface interface: OVSInterface, onBridge bridgeName: String) async throws -> String {
        let bridgeCondition = OVSDBCondition(column: "name", function: "==", value: .string(bridgeName))

        guard try await rowUUID(in: OVSTable.bridge, where: bridgeCondition) != nil else {
            throw OVNManagerError.operationFailed("Bridge not found: \(bridgeName)")
        }

        let interfaceRow = try createRow(from: interface)
        var portRow = try createRow(from: port)
        portRow["interfaces"] = .array([.string("named-uuid"), .string("new_interface")])

        let operations = [
            // Abort the whole transaction if the bridge vanished between the
            // check above and this transaction, so the inserts below can
            // never commit as orphans.
            OVSDBOperation(
                op: "wait",
                table: OVSTable.bridge,
                whereConditions: [bridgeCondition],
                columns: ["name"],
                rows: [["name": .string(bridgeName)]],
                until: "==",
                timeout: 0
            ),
            OVSDBOperation(
                op: "insert",
                table: OVSTable.interface,
                row: interfaceRow,
                uuidName: "new_interface"
            ),
            OVSDBOperation(
                op: "insert",
                table: OVSTable.port,
                row: portRow,
                uuidName: "new_port"
            ),
            OVSDBOperation(
                op: "mutate",
                table: OVSTable.bridge,
                whereConditions: [bridgeCondition],
                mutations: [OVSDBMutation(
                    column: "ports",
                    mutator: "insert",
                    value: .array([.string("named-uuid"), .string("new_port")])
                )]
            )
        ]

        let results = try await connection.transact(in: database, operations: operations)
        let uuidValue = try OVSDBConnection.uuid(fromInsertResults: results, at: 2)

        logger.info("Created port: \(port.name) with interface: \(interface.name) on bridge: \(bridgeName)")
        return uuidValue
    }
    
    public func updatePort(uuid: String, _ port: OVSPort) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: port)
        
        let count = try await connection.update(table: OVSTable.port, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Port not found: \(uuid)")
        }
        
        logger.info("Updated port: \(port.name)")
    }
    
    public func deletePort(uuid: String) async throws {
        // The port's interfaces become unreferenced and are garbage-collected
        // at commit, matching `ovs-vsctl del-port`.
        let count = try await connection.deleteDetaching(
            from: OVSTable.port,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.bridge, column: "ports")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Port not found: \(uuid)")
        }

        logger.info("Deleted port: \(uuid)")
    }

    public func deletePort(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVSTable.port, where: condition) else {
            throw OVNManagerError.operationFailed("Port not found: \(name)")
        }

        try await deletePort(uuid: uuid)

        logger.info("Deleted port: \(name)")
    }
    
    // MARK: - Interface Operations
    
    public func getInterfaces() async throws -> [OVSInterface] {
        let rows = try await connection.selectAll(from: OVSTable.interface, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSInterface.self)
        }
    }
    
    public func getInterface(named name: String) async throws -> OVSInterface? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.interface, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSInterface.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createInterface(_:onPort:) to add an interface to an existing port, or createPort(_:withInterface:onBridge:) to create a port with its first interface.")
    public func createInterface(_ interface: OVSInterface) async throws -> String {
        let row = try createRow(from: interface)
        let result = try await connection.insert(into: OVSTable.interface, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created interface: \(interface.name)")
        return uuidValue
    }

    /// Creates an interface and attaches it to the named port
    /// (Port.interfaces) in a single OVSDB transaction — the way additional
    /// members are added to a bond port. Interface is not a root table, so
    /// an unreferenced row is garbage-collected when the transaction commits.
    public func createInterface(_ interface: OVSInterface, onPort portName: String) async throws -> String {
        let portCondition = OVSDBCondition(column: "name", function: "==", value: .string(portName))

        guard try await rowUUID(in: OVSTable.port, where: portCondition) != nil else {
            throw OVNManagerError.operationFailed("Port not found: \(portName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVSTable.interface,
            in: database,
            row: try createRow(from: interface),
            uuidName: "new_interface",
            parentTable: OVSTable.port,
            parentColumn: "interfaces",
            parentCondition: portCondition
        )

        logger.info("Created interface: \(interface.name) on port: \(portName)")
        return uuidValue
    }
    
    public func updateInterface(uuid: String, _ interface: OVSInterface) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: interface)
        
        let count = try await connection.update(table: OVSTable.interface, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Interface not found: \(uuid)")
        }
        
        logger.info("Updated interface: \(interface.name)")
    }
    
    /// Deletes an interface, detaching it from its port in the same
    /// transaction. Note: Port.interfaces requires at least one interface,
    /// so deleting a port's last interface is rejected by ovsdb-server —
    /// delete the port instead.
    public func deleteInterface(uuid: String) async throws {
        let count = try await connection.deleteDetaching(
            from: OVSTable.interface,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.port, column: "interfaces")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Interface not found: \(uuid)")
        }

        logger.info("Deleted interface: \(uuid)")
    }

    public func deleteInterface(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVSTable.interface, where: condition) else {
            throw OVNManagerError.operationFailed("Interface not found: \(name)")
        }

        try await deleteInterface(uuid: uuid)

        logger.info("Deleted interface: \(name)")
    }
    
    // MARK: - Controller Operations
    
    public func getControllers() async throws -> [OVSController] {
        let rows = try await connection.selectAll(from: OVSTable.controller, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSController.self)
        }
    }
    
    public func getController(target: String) async throws -> OVSController? {
        let condition = OVSDBCondition(column: "target", function: "==", value: .string(target))
        let rows = try await connection.select(from: OVSTable.controller, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSController.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createController(_:onBridge:) so the controller is attached to its bridge.")
    public func createController(_ controller: OVSController) async throws -> String {
        let row = try createRow(from: controller)
        let result = try await connection.insert(into: OVSTable.controller, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created controller: \(controller.target)")
        return uuidValue
    }

    /// Creates a controller and attaches it to the named bridge
    /// (Bridge.controller) in a single OVSDB transaction, mirroring
    /// `ovs-vsctl set-controller`. Controller is not a root table, so an
    /// unreferenced row is garbage-collected when the transaction commits.
    public func createController(_ controller: OVSController, onBridge bridgeName: String) async throws -> String {
        let bridgeCondition = OVSDBCondition(column: "name", function: "==", value: .string(bridgeName))

        guard try await rowUUID(in: OVSTable.bridge, where: bridgeCondition) != nil else {
            throw OVNManagerError.operationFailed("Bridge not found: \(bridgeName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVSTable.controller,
            in: database,
            row: try createRow(from: controller),
            uuidName: "new_controller",
            parentTable: OVSTable.bridge,
            parentColumn: "controller",
            parentCondition: bridgeCondition
        )

        logger.info("Created controller: \(controller.target) on bridge: \(bridgeName)")
        return uuidValue
    }
    
    public func updateController(uuid: String, _ controller: OVSController) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: controller)
        
        let count = try await connection.update(table: OVSTable.controller, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Controller not found: \(uuid)")
        }
        
        logger.info("Updated controller: \(controller.target)")
    }
    
    public func deleteController(uuid: String) async throws {
        let count = try await connection.deleteDetaching(
            from: OVSTable.controller,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.bridge, column: "controller")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Controller not found: \(uuid)")
        }

        logger.info("Deleted controller: \(uuid)")
    }

    public func deleteController(target: String) async throws {
        let condition = OVSDBCondition(column: "target", function: "==", value: .string(target))
        guard let uuid = try await rowUUID(in: OVSTable.controller, where: condition) else {
            throw OVNManagerError.operationFailed("Controller not found: \(target)")
        }

        try await deleteController(uuid: uuid)

        logger.info("Deleted controller: \(target)")
    }
    
    // MARK: - Flow Operations (Note: These would typically use ovs-ofctl commands, not OVSDB)
    
    public func getFlows(bridge: String, table: Int? = nil) async throws -> [OVSFlow] {
        // This is a simplified implementation
        // In practice, you'd use ovs-ofctl dump-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        return []
    }
    
    public func addFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl add-flow command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func deleteFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl del-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func deleteAllFlows(bridge: String) async throws {
        // This would typically use ovs-ofctl del-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    public func modifyFlow(bridge: String, flow: OVSFlow) async throws {
        // This would typically use ovs-ofctl mod-flows command
        logger.warning("Flow operations typically require ovs-ofctl commands, not OVSDB")
        throw OVNManagerError.operationFailed("Flow operations not implemented via OVSDB")
    }
    
    // MARK: - Mirror Operations
    
    public func getMirrors() async throws -> [OVSMirror] {
        let rows = try await connection.selectAll(from: OVSTable.mirror, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSMirror.self)
        }
    }
    
    public func getMirror(named name: String) async throws -> OVSMirror? {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        let rows = try await connection.select(from: OVSTable.mirror, in: database, where: [condition])
        
        guard let firstRow = rows.first else { return nil }
        return try parseRow(firstRow, as: OVSMirror.self)
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createMirror(_:onBridge:) so the mirror is attached to its bridge.")
    public func createMirror(_ mirror: OVSMirror) async throws -> String {
        let row = try createRow(from: mirror)
        let result = try await connection.insert(into: OVSTable.mirror, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created mirror: \(mirror.name)")
        return uuidValue
    }

    /// Creates a mirror and attaches it to the named bridge (Bridge.mirrors)
    /// in a single OVSDB transaction. Mirror is not a root table, so an
    /// unreferenced row is garbage-collected when the transaction commits.
    public func createMirror(_ mirror: OVSMirror, onBridge bridgeName: String) async throws -> String {
        let bridgeCondition = OVSDBCondition(column: "name", function: "==", value: .string(bridgeName))

        guard try await rowUUID(in: OVSTable.bridge, where: bridgeCondition) != nil else {
            throw OVNManagerError.operationFailed("Bridge not found: \(bridgeName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVSTable.mirror,
            in: database,
            row: try createRow(from: mirror),
            uuidName: "new_mirror",
            parentTable: OVSTable.bridge,
            parentColumn: "mirrors",
            parentCondition: bridgeCondition
        )

        logger.info("Created mirror: \(mirror.name) on bridge: \(bridgeName)")
        return uuidValue
    }
    
    public func updateMirror(uuid: String, _ mirror: OVSMirror) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: mirror)
        
        let count = try await connection.update(table: OVSTable.mirror, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Mirror not found: \(uuid)")
        }
        
        logger.info("Updated mirror: \(mirror.name)")
    }
    
    public func deleteMirror(uuid: String) async throws {
        let count = try await connection.deleteDetaching(
            from: OVSTable.mirror,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.bridge, column: "mirrors")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("Mirror not found: \(uuid)")
        }

        logger.info("Deleted mirror: \(uuid)")
    }

    public func deleteMirror(named name: String) async throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(name))
        guard let uuid = try await rowUUID(in: OVSTable.mirror, where: condition) else {
            throw OVNManagerError.operationFailed("Mirror not found: \(name)")
        }

        try await deleteMirror(uuid: uuid)

        logger.info("Deleted mirror: \(name)")
    }
    
    // MARK: - NetFlow Operations
    
    public func getNetFlows() async throws -> [OVSNetFlow] {
        let rows = try await connection.selectAll(from: OVSTable.netflow, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSNetFlow.self)
        }
    }
    
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNetFlow(_:onBridge:) so the NetFlow config is attached to its bridge.")
    public func createNetFlow(_ netflow: OVSNetFlow) async throws -> String {
        let row = try createRow(from: netflow)
        let result = try await connection.insert(into: OVSTable.netflow, in: database, row: row)

        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }

        logger.info("Created NetFlow")
        return uuidValue
    }

    /// Creates a NetFlow configuration and attaches it to the named bridge
    /// (Bridge.netflow) in a single OVSDB transaction. NetFlow is not a root
    /// table, so an unreferenced row is garbage-collected when the
    /// transaction commits. Bridge.netflow holds at most one row, so this
    /// fails if the bridge already has a NetFlow configuration.
    public func createNetFlow(_ netflow: OVSNetFlow, onBridge bridgeName: String) async throws -> String {
        let bridgeCondition = OVSDBCondition(column: "name", function: "==", value: .string(bridgeName))

        guard try await rowUUID(in: OVSTable.bridge, where: bridgeCondition) != nil else {
            throw OVNManagerError.operationFailed("Bridge not found: \(bridgeName)")
        }

        let uuidValue = try await connection.insertAttached(
            into: OVSTable.netflow,
            in: database,
            row: try createRow(from: netflow),
            uuidName: "new_netflow",
            parentTable: OVSTable.bridge,
            parentColumn: "netflow",
            parentCondition: bridgeCondition
        )

        logger.info("Created NetFlow on bridge: \(bridgeName)")
        return uuidValue
    }
    
    public func updateNetFlow(uuid: String, _ netflow: OVSNetFlow) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: netflow)
        
        let count = try await connection.update(table: OVSTable.netflow, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("NetFlow not found: \(uuid)")
        }
        
        logger.info("Updated NetFlow: \(uuid)")
    }
    
    public func deleteNetFlow(uuid: String) async throws {
        let count = try await connection.deleteDetaching(
            from: OVSTable.netflow,
            in: database,
            uuid: uuid,
            parentReferences: [OVSDBParentReference(table: OVSTable.bridge, column: "netflow")]
        )

        if count == 0 {
            throw OVNManagerError.operationFailed("NetFlow not found: \(uuid)")
        }

        logger.info("Deleted NetFlow: \(uuid)")
    }
    
    // MARK: - QoS Operations
    
    public func getQoSPolicies() async throws -> [OVSQoS] {
        let rows = try await connection.selectAll(from: OVSTable.qos, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSQoS.self)
        }
    }
    
    public func createQoSPolicy(_ qos: OVSQoS) async throws -> String {
        let row = try createRow(from: qos)
        let result = try await connection.insert(into: OVSTable.qos, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created QoS policy")
        return uuidValue
    }
    
    public func updateQoSPolicy(uuid: String, _ qos: OVSQoS) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: qos)
        
        let count = try await connection.update(table: OVSTable.qos, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("QoS policy not found: \(uuid)")
        }
        
        logger.info("Updated QoS policy: \(uuid)")
    }
    
    public func deleteQoSPolicy(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.qos, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("QoS policy not found: \(uuid)")
        }
        
        logger.info("Deleted QoS policy: \(uuid)")
    }
    
    // MARK: - Queue Operations
    
    public func getQueues() async throws -> [OVSQueue] {
        let rows = try await connection.selectAll(from: OVSTable.queue, in: database)
        return try rows.compactMap { row in
            try parseRow(row, as: OVSQueue.self)
        }
    }
    
    public func createQueue(_ queue: OVSQueue) async throws -> String {
        let row = try createRow(from: queue)
        let result = try await connection.insert(into: OVSTable.queue, in: database, row: row)
        
        guard case .object(let resultObject) = result,
              let uuid = resultObject["uuid"],
              case .array(let uuidArray) = uuid,
              uuidArray.count == 2,
              case .string(let uuidValue) = uuidArray[1] else {
            throw OVNManagerError.invalidResponse("Invalid UUID in insert response")
        }
        
        logger.info("Created queue")
        return uuidValue
    }
    
    public func updateQueue(uuid: String, _ queue: OVSQueue) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let row = try createRow(from: queue)
        
        let count = try await connection.update(table: OVSTable.queue, in: database, where: [condition], row: row)
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Queue not found: \(uuid)")
        }
        
        logger.info("Updated queue: \(uuid)")
    }
    
    public func deleteQueue(uuid: String) async throws {
        let condition = OVSDBCondition(column: "_uuid", function: "==", value: .array([.string("uuid"), .string(uuid)]))
        let count = try await connection.delete(from: OVSTable.queue, in: database, where: [condition])
        
        if count == 0 {
            throw OVNManagerError.operationFailed("Queue not found: \(uuid)")
        }
        
        logger.info("Deleted queue: \(uuid)")
    }
    
    // MARK: - Statistics Operations

    nonisolated public func getBridgeStatistics(bridge: String) async throws -> StatisticsDictionary {
        // Bridge statistics are available in the status column
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(bridge))
        let rows = try await connection.select(from: OVSTable.bridge, in: database, where: [condition], columns: ["status", "other_config"])

        guard let firstRow = rows.first else {
            return [:]
        }

        var result: StatisticsDictionary = [:]
        result["status"] = firstRow["status"]
        result["other_config"] = firstRow["other_config"]
        return result
    }

    nonisolated public func getPortStatistics(port: String) async throws -> StatisticsDictionary {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(port))
        let rows = try await connection.select(from: OVSTable.port, in: database, where: [condition], columns: ["status", "external_ids", "other_config"])

        guard let firstRow = rows.first else {
            return [:]
        }

        var result: StatisticsDictionary = [:]
        result["status"] = firstRow["status"]
        result["external_ids"] = firstRow["external_ids"]
        result["other_config"] = firstRow["other_config"]
        return result
    }

    nonisolated public func getInterfaceStatistics(interface: String) async throws -> StatisticsDictionary {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string(interface))
        let rows = try await connection.select(from: OVSTable.interface, in: database, where: [condition], columns: ["status", "external_ids", "statistics"])

        guard let firstRow = rows.first else {
            return [:]
        }

        var result: StatisticsDictionary = [:]
        result["status"] = firstRow["status"]
        result["external_ids"] = firstRow["external_ids"]
        result["statistics"] = firstRow["statistics"]
        return result
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
            let task = Task {
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
            // Cancel the forwarding task if the consumer drops the stream, so it
            // doesn't outlive them waiting on the underlying connection.
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

// MARK: - Helper Methods

private extension OVSManager {
    /// Looks up a row's _uuid via a narrow select, avoiding full-row model
    /// decoding (which currently chokes on OVSDB's bare-atom/empty-set
    /// representations for some columns). Returns nil when no row matches.
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

    func parseRow<T: Codable>(_ row: OVSDBRow, as type: T.Type) throws -> T {
        return try OVSDBRowDecoder.decode(type, from: row)
    }

    func createRow<T: Codable>(from object: T) throws -> OVSDBRow {
        return try OVSDBRowEncoder.makeRow(from: object, hints: .ovs)
    }
}