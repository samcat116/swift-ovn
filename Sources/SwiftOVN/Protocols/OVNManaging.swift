import Foundation
import NIO

// MARK: - OVN Management Protocol

public protocol OVNManaging: Sendable {
    // Connection Management
    func connect() async throws
    func disconnect() async throws
    var isConnected: Bool { get async }
    
    // Database Operations
    func listDatabases() async throws -> [String]
    func getDatabaseSchema(database: String) async throws -> JSONValue
    
    // Logical Switch Operations
    func getLogicalSwitches() async throws -> [OVNLogicalSwitch]
    func getLogicalSwitch(named name: String) async throws -> OVNLogicalSwitch?
    func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws -> String
    func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws
    func deleteLogicalSwitch(uuid: String) async throws
    func deleteLogicalSwitch(named name: String) async throws
    
    // Logical Switch Port Operations
    func getLogicalSwitchPorts() async throws -> [OVNLogicalSwitchPort]
    func getLogicalSwitchPort(named name: String) async throws -> OVNLogicalSwitchPort?
    @available(*, deprecated, message: "Creates an orphan row that ovn-northd ignores (no Port_Binding, no dataplane). Use createLogicalSwitchPort(_:onSwitch:) so the port is attached to its switch.")
    func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws -> String
    func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort, onSwitch switchName: String) async throws -> String
    func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws
    func deleteLogicalSwitchPort(uuid: String) async throws
    func deleteLogicalSwitchPort(named name: String) async throws
    
    // Logical Router Operations
    func getLogicalRouters() async throws -> [OVNLogicalRouter]
    func getLogicalRouter(named name: String) async throws -> OVNLogicalRouter?
    func createLogicalRouter(_ router: OVNLogicalRouter) async throws -> String
    func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws
    func deleteLogicalRouter(uuid: String) async throws
    func deleteLogicalRouter(named name: String) async throws
    
    // Logical Router Port Operations
    func getLogicalRouterPorts() async throws -> [OVNLogicalRouterPort]
    func getLogicalRouterPort(named name: String) async throws -> OVNLogicalRouterPort?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createLogicalRouterPort(_:onRouter:) so the port is attached to its router.")
    func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws -> String
    func createLogicalRouterPort(_ port: OVNLogicalRouterPort, onRouter routerName: String) async throws -> String
    func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws
    func deleteLogicalRouterPort(uuid: String) async throws
    func deleteLogicalRouterPort(named name: String) async throws

    // Logical Router Static Route Operations
    func getStaticRoutes() async throws -> [OVNLogicalRouterStaticRoute]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createStaticRoute(_:onRouter:) so the route is attached to its router.")
    func createStaticRoute(_ route: OVNLogicalRouterStaticRoute) async throws -> String
    func createStaticRoute(_ route: OVNLogicalRouterStaticRoute, onRouter routerName: String) async throws -> String
    func updateStaticRoute(uuid: String, _ route: OVNLogicalRouterStaticRoute) async throws
    func deleteStaticRoute(uuid: String) async throws

    // Gateway Chassis Operations
    func getGatewayChassis() async throws -> [OVNGatewayChassis]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createGatewayChassis(_:onRouterPort:) so the binding is attached to its router port.")
    func createGatewayChassis(_ chassis: OVNGatewayChassis) async throws -> String
    func createGatewayChassis(_ chassis: OVNGatewayChassis, onRouterPort routerPortName: String) async throws -> String
    func updateGatewayChassis(uuid: String, _ chassis: OVNGatewayChassis) async throws
    func deleteGatewayChassis(uuid: String) async throws

    // HA Chassis Group Operations
    func getHAChassisGroups() async throws -> [OVNHAChassisGroup]
    func getHAChassisGroup(named name: String) async throws -> OVNHAChassisGroup?
    func createHAChassisGroup(_ group: OVNHAChassisGroup) async throws -> String
    func updateHAChassisGroup(uuid: String, _ group: OVNHAChassisGroup) async throws
    func deleteHAChassisGroup(uuid: String) async throws

    // HA Chassis Operations
    func getHAChassis() async throws -> [OVNHAChassis]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createHAChassis(_:inGroup:) so the member is attached to its group.")
    func createHAChassis(_ chassis: OVNHAChassis) async throws -> String
    func createHAChassis(_ chassis: OVNHAChassis, inGroup groupName: String) async throws -> String
    func updateHAChassis(uuid: String, _ chassis: OVNHAChassis) async throws
    func deleteHAChassis(uuid: String) async throws

    // ACL Operations
    func getACLs() async throws -> [OVNACL]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createACL(_:onSwitch:) or createACL(_:onPortGroup:) so the ACL is attached.")
    func createACL(_ acl: OVNACL) async throws -> String
    func createACL(_ acl: OVNACL, onSwitch switchName: String) async throws -> String
    func createACL(_ acl: OVNACL, onPortGroup portGroupName: String) async throws -> String
    func updateACL(uuid: String, _ acl: OVNACL) async throws
    func deleteACL(uuid: String) async throws

    // Port Group Operations
    func getPortGroups() async throws -> [OVNPortGroup]
    func getPortGroup(named name: String) async throws -> OVNPortGroup?
    func createPortGroup(_ portGroup: OVNPortGroup) async throws -> String
    func updatePortGroup(uuid: String, _ portGroup: OVNPortGroup) async throws
    func addPorts(_ portUUIDs: [String], toPortGroup name: String) async throws
    func removePorts(_ portUUIDs: [String], fromPortGroup name: String) async throws
    func deletePortGroup(uuid: String) async throws
    func deletePortGroup(named name: String) async throws

    // Load Balancer Operations
    func getLoadBalancers() async throws -> [OVNLoadBalancer]
    func getLoadBalancer(named name: String) async throws -> OVNLoadBalancer?
    func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws -> String
    func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws
    func deleteLoadBalancer(uuid: String) async throws
    func deleteLoadBalancer(named name: String) async throws
    func attachLoadBalancer(uuid: String, toSwitch switchName: String) async throws
    func attachLoadBalancer(uuid: String, toRouter routerName: String) async throws
    func detachLoadBalancer(uuid: String, fromSwitch switchName: String) async throws
    func detachLoadBalancer(uuid: String, fromRouter routerName: String) async throws

    // NAT Operations
    func getNATRules() async throws -> [OVNNAT]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNATRule(_:onRouter:) so the rule is attached to its router.")
    func createNATRule(_ nat: OVNNAT) async throws -> String
    func createNATRule(_ nat: OVNNAT, onRouter routerName: String) async throws -> String
    func updateNATRule(uuid: String, _ nat: OVNNAT) async throws
    func deleteNATRule(uuid: String) async throws
    
    // DHCP Operations
    func getDHCPOptions() async throws -> [OVNDHCPOptions]
    func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws -> String
    func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws
    func deleteDHCPOptions(uuid: String) async throws
    
    // Monitoring
    func startMonitoring(tables: [String]) async throws -> String
    func stopMonitoring(monitorId: String) async throws
    nonisolated func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error>
    
    // Southbound Operations
    func getChassis() async throws -> [OVNChassis]
    func getChassisPrivate() async throws -> [OVNChassisPrivate]
    func getPortBindings() async throws -> [OVNPortBinding]
    func getLogicalFlows() async throws -> [OVNLogicalFlow]
}

// MARK: - OVN Database Constants

public enum OVNDatabase {
    public static let northbound = "OVN_Northbound"
    public static let southbound = "OVN_Southbound"
}

public enum OVNTable {
    // Northbound tables
    public static let logicalSwitch = "Logical_Switch"
    public static let logicalSwitchPort = "Logical_Switch_Port"
    public static let logicalRouter = "Logical_Router"
    public static let logicalRouterPort = "Logical_Router_Port"
    public static let logicalRouterStaticRoute = "Logical_Router_Static_Route"
    public static let gatewayChassis = "Gateway_Chassis"
    public static let haChassis = "HA_Chassis"
    public static let haChassisGroup = "HA_Chassis_Group"
    public static let acl = "ACL"
    public static let portGroup = "Port_Group"
    public static let loadBalancer = "Load_Balancer"
    public static let nat = "NAT"
    public static let dhcpOptions = "DHCP_Options"
    
    // Southbound tables
    public static let chassis = "Chassis"
    public static let chassisPrivate = "Chassis_Private"
    public static let portBinding = "Port_Binding"
    public static let logicalFlow = "Logical_Flow"
    public static let encap = "Encap"
}

// MARK: - Helper Extensions

public extension OVNManaging {
    /// Connects using the endpoint the manager was constructed with. The
    /// database (northbound/southbound) is fixed at construction time, so
    /// there is no socket path to pass here.
    func connectToNorthbound() async throws {
        try await connect()
    }

    func connectToSouthbound() async throws {
        try await connect()
    }
}