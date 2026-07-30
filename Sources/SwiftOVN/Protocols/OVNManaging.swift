#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO

// MARK: - OVN Management Protocol

/// Manages an OVN database (northbound or southbound) over OVSDB.
///
/// Every throwing requirement is `throws(OVNManagerError)`, so a `catch` binds
/// that type directly and a `switch` over it needs no `default`. Errors from
/// the layers underneath — `DecodingError` while decoding a row, NIO channel
/// and TLS failures from the transport — are wrapped into `decodingError`,
/// `encodingError` or `connectionFailed` before they reach a caller; nothing
/// else escapes.
///
/// `monitorUpdates()` is the one exception, and only because the standard
/// library forces it: see that method's documentation.
public protocol OVNManaging: Sendable {
    // Connection Management
    func connect() async throws(OVNManagerError)
    func disconnect() async throws(OVNManagerError)
    var isConnected: Bool { get async }
    
    // Database Operations
    func listDatabases() async throws(OVNManagerError) -> [String]
    func getDatabaseSchema(database: String) async throws(OVNManagerError) -> JSONValue
    
    // Logical Switch Operations
    func getLogicalSwitches() async throws(OVNManagerError) -> [OVNLogicalSwitch]
    func getLogicalSwitch(named name: String) async throws(OVNManagerError) -> OVNLogicalSwitch?
    func createLogicalSwitch(_ logicalSwitch: OVNLogicalSwitch) async throws(OVNManagerError) -> String
    func updateLogicalSwitch(uuid: String, _ logicalSwitch: OVNLogicalSwitch) async throws(OVNManagerError)
    func deleteLogicalSwitch(uuid: String) async throws(OVNManagerError)
    func deleteLogicalSwitch(named name: String) async throws(OVNManagerError)
    
    // Logical Switch Port Operations
    func getLogicalSwitchPorts() async throws(OVNManagerError) -> [OVNLogicalSwitchPort]
    func getLogicalSwitchPort(named name: String) async throws(OVNManagerError) -> OVNLogicalSwitchPort?
    @available(*, deprecated, message: "Creates an orphan row that ovn-northd ignores (no Port_Binding, no dataplane). Use createLogicalSwitchPort(_:onSwitch:) so the port is attached to its switch.")
    func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort) async throws(OVNManagerError) -> String
    func createLogicalSwitchPort(_ port: OVNLogicalSwitchPort, onSwitch switchName: String) async throws(OVNManagerError) -> String
    func updateLogicalSwitchPort(uuid: String, _ port: OVNLogicalSwitchPort) async throws(OVNManagerError)
    func deleteLogicalSwitchPort(uuid: String) async throws(OVNManagerError)
    func deleteLogicalSwitchPort(named name: String) async throws(OVNManagerError)
    
    // Logical Router Operations
    func getLogicalRouters() async throws(OVNManagerError) -> [OVNLogicalRouter]
    func getLogicalRouter(named name: String) async throws(OVNManagerError) -> OVNLogicalRouter?
    func createLogicalRouter(_ router: OVNLogicalRouter) async throws(OVNManagerError) -> String
    func updateLogicalRouter(uuid: String, _ router: OVNLogicalRouter) async throws(OVNManagerError)
    func deleteLogicalRouter(uuid: String) async throws(OVNManagerError)
    func deleteLogicalRouter(named name: String) async throws(OVNManagerError)
    
    // Logical Router Port Operations
    func getLogicalRouterPorts() async throws(OVNManagerError) -> [OVNLogicalRouterPort]
    func getLogicalRouterPort(named name: String) async throws(OVNManagerError) -> OVNLogicalRouterPort?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createLogicalRouterPort(_:onRouter:) so the port is attached to its router.")
    func createLogicalRouterPort(_ port: OVNLogicalRouterPort) async throws(OVNManagerError) -> String
    func createLogicalRouterPort(_ port: OVNLogicalRouterPort, onRouter routerName: String) async throws(OVNManagerError) -> String
    func updateLogicalRouterPort(uuid: String, _ port: OVNLogicalRouterPort) async throws(OVNManagerError)
    func deleteLogicalRouterPort(uuid: String) async throws(OVNManagerError)
    func deleteLogicalRouterPort(named name: String) async throws(OVNManagerError)

    // Logical Router Static Route Operations
    func getStaticRoutes() async throws(OVNManagerError) -> [OVNLogicalRouterStaticRoute]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createStaticRoute(_:onRouter:) so the route is attached to its router.")
    func createStaticRoute(_ route: OVNLogicalRouterStaticRoute) async throws(OVNManagerError) -> String
    func createStaticRoute(_ route: OVNLogicalRouterStaticRoute, onRouter routerName: String) async throws(OVNManagerError) -> String
    func updateStaticRoute(uuid: String, _ route: OVNLogicalRouterStaticRoute) async throws(OVNManagerError)
    func deleteStaticRoute(uuid: String) async throws(OVNManagerError)

    // Logical Router Policy Operations
    func getPolicies() async throws(OVNManagerError) -> [OVNLogicalRouterPolicy]
    func createPolicy(_ policy: OVNLogicalRouterPolicy, onRouter routerName: String) async throws(OVNManagerError) -> String
    func updatePolicy(uuid: String, _ policy: OVNLogicalRouterPolicy) async throws(OVNManagerError)
    func deletePolicy(uuid: String) async throws(OVNManagerError)

    // Gateway Chassis Operations
    func getGatewayChassis() async throws(OVNManagerError) -> [OVNGatewayChassis]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createGatewayChassis(_:onRouterPort:) so the binding is attached to its router port.")
    func createGatewayChassis(_ chassis: OVNGatewayChassis) async throws(OVNManagerError) -> String
    func createGatewayChassis(_ chassis: OVNGatewayChassis, onRouterPort routerPortName: String) async throws(OVNManagerError) -> String
    func updateGatewayChassis(uuid: String, _ chassis: OVNGatewayChassis) async throws(OVNManagerError)
    func deleteGatewayChassis(uuid: String) async throws(OVNManagerError)

    // HA Chassis Group Operations
    func getHAChassisGroups() async throws(OVNManagerError) -> [OVNHAChassisGroup]
    func getHAChassisGroup(named name: String) async throws(OVNManagerError) -> OVNHAChassisGroup?
    func createHAChassisGroup(_ group: OVNHAChassisGroup) async throws(OVNManagerError) -> String
    func updateHAChassisGroup(uuid: String, _ group: OVNHAChassisGroup) async throws(OVNManagerError)
    func deleteHAChassisGroup(uuid: String) async throws(OVNManagerError)

    // HA Chassis Operations
    func getHAChassis() async throws(OVNManagerError) -> [OVNHAChassis]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createHAChassis(_:inGroup:) so the member is attached to its group.")
    func createHAChassis(_ chassis: OVNHAChassis) async throws(OVNManagerError) -> String
    func createHAChassis(_ chassis: OVNHAChassis, inGroup groupName: String) async throws(OVNManagerError) -> String
    func updateHAChassis(uuid: String, _ chassis: OVNHAChassis) async throws(OVNManagerError)
    func deleteHAChassis(uuid: String) async throws(OVNManagerError)

    // ACL Operations
    func getACLs() async throws(OVNManagerError) -> [OVNACL]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createACL(_:onSwitch:) or createACL(_:onPortGroup:) so the ACL is attached.")
    func createACL(_ acl: OVNACL) async throws(OVNManagerError) -> String
    func createACL(_ acl: OVNACL, onSwitch switchName: String) async throws(OVNManagerError) -> String
    func createACL(_ acl: OVNACL, onPortGroup portGroupName: String) async throws(OVNManagerError) -> String
    func updateACL(uuid: String, _ acl: OVNACL) async throws(OVNManagerError)
    func deleteACL(uuid: String) async throws(OVNManagerError)

    // Port Group Operations
    func getPortGroups() async throws(OVNManagerError) -> [OVNPortGroup]
    func getPortGroup(named name: String) async throws(OVNManagerError) -> OVNPortGroup?
    func createPortGroup(_ portGroup: OVNPortGroup) async throws(OVNManagerError) -> String
    func updatePortGroup(uuid: String, _ portGroup: OVNPortGroup) async throws(OVNManagerError)
    func addPorts(_ portUUIDs: [String], toPortGroup name: String) async throws(OVNManagerError)
    func removePorts(_ portUUIDs: [String], fromPortGroup name: String) async throws(OVNManagerError)
    func deletePortGroup(uuid: String) async throws(OVNManagerError)
    func deletePortGroup(named name: String) async throws(OVNManagerError)

    // Address Set Operations
    func getAddressSets() async throws(OVNManagerError) -> [OVNAddressSet]
    func getAddressSet(named name: String) async throws(OVNManagerError) -> OVNAddressSet?
    func createAddressSet(_ addressSet: OVNAddressSet) async throws(OVNManagerError) -> String
    func updateAddressSet(uuid: String, _ addressSet: OVNAddressSet) async throws(OVNManagerError)
    func addAddresses(_ addresses: [String], toAddressSet name: String) async throws(OVNManagerError)
    func removeAddresses(_ addresses: [String], fromAddressSet name: String) async throws(OVNManagerError)
    func deleteAddressSet(uuid: String) async throws(OVNManagerError)
    func deleteAddressSet(named name: String) async throws(OVNManagerError)

    // Load Balancer Operations
    func getLoadBalancers() async throws(OVNManagerError) -> [OVNLoadBalancer]
    func getLoadBalancer(named name: String) async throws(OVNManagerError) -> OVNLoadBalancer?
    func createLoadBalancer(_ loadBalancer: OVNLoadBalancer) async throws(OVNManagerError) -> String
    func updateLoadBalancer(uuid: String, _ loadBalancer: OVNLoadBalancer) async throws(OVNManagerError)
    func deleteLoadBalancer(uuid: String) async throws(OVNManagerError)
    func deleteLoadBalancer(named name: String) async throws(OVNManagerError)
    func attachLoadBalancer(uuid: String, toSwitch switchName: String) async throws(OVNManagerError)
    func attachLoadBalancer(uuid: String, toRouter routerName: String) async throws(OVNManagerError)
    func detachLoadBalancer(uuid: String, fromSwitch switchName: String) async throws(OVNManagerError)
    func detachLoadBalancer(uuid: String, fromRouter routerName: String) async throws(OVNManagerError)

    // NAT Operations
    func getNATRules() async throws(OVNManagerError) -> [OVNNAT]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNATRule(_:onRouter:) so the rule is attached to its router.")
    func createNATRule(_ nat: OVNNAT) async throws(OVNManagerError) -> String
    func createNATRule(_ nat: OVNNAT, onRouter routerName: String) async throws(OVNManagerError) -> String
    func updateNATRule(uuid: String, _ nat: OVNNAT) async throws(OVNManagerError)
    func deleteNATRule(uuid: String) async throws(OVNManagerError)
    
    // QoS Operations (Northbound QoS, not the Open_vSwitch table)
    func getQoSRules() async throws(OVNManagerError) -> [OVNQoS]
    func createQoSRule(_ qos: OVNQoS, onSwitch switchName: String) async throws(OVNManagerError) -> String
    func updateQoSRule(uuid: String, _ qos: OVNQoS) async throws(OVNManagerError)
    func deleteQoSRule(uuid: String) async throws(OVNManagerError)

    // BFD Operations
    func getBFDSessions() async throws(OVNManagerError) -> [OVNBFD]
    func createBFDSession(_ bfd: OVNBFD) async throws(OVNManagerError) -> String
    func updateBFDSession(uuid: String, _ bfd: OVNBFD) async throws(OVNManagerError)
    func deleteBFDSession(uuid: String) async throws(OVNManagerError)

    // DNS Operations
    func getDNS() async throws(OVNManagerError) -> [OVNDNS]
    func createDNS(_ dns: OVNDNS) async throws(OVNManagerError) -> String
    func updateDNS(uuid: String, _ dns: OVNDNS) async throws(OVNManagerError)
    func deleteDNS(uuid: String) async throws(OVNManagerError)
    func attachDNS(uuid: String, toSwitch switchName: String) async throws(OVNManagerError)
    func detachDNS(uuid: String, fromSwitch switchName: String) async throws(OVNManagerError)

    // Meter Operations
    func getMeters() async throws(OVNManagerError) -> [OVNMeter]
    func getMeter(named name: String) async throws(OVNManagerError) -> OVNMeter?
    func createMeter(_ meter: OVNMeter, withBands bands: [OVNMeterBand]) async throws(OVNManagerError) -> String
    func createMeter(_ meter: OVNMeter, withBand band: OVNMeterBand) async throws(OVNManagerError) -> String
    func updateMeter(uuid: String, _ meter: OVNMeter) async throws(OVNManagerError)
    func deleteMeter(uuid: String) async throws(OVNManagerError)
    func deleteMeter(named name: String) async throws(OVNManagerError)

    // Meter Band Operations
    func getMeterBands() async throws(OVNManagerError) -> [OVNMeterBand]
    func createMeterBand(_ band: OVNMeterBand, onMeter meterName: String) async throws(OVNManagerError) -> String
    func updateMeterBand(uuid: String, _ band: OVNMeterBand) async throws(OVNManagerError)
    func deleteMeterBand(uuid: String) async throws(OVNManagerError)

    // DHCP Operations
    func getDHCPOptions() async throws(OVNManagerError) -> [OVNDHCPOptions]
    func createDHCPOptions(_ dhcp: OVNDHCPOptions) async throws(OVNManagerError) -> String
    func updateDHCPOptions(uuid: String, _ dhcp: OVNDHCPOptions) async throws(OVNManagerError)
    func deleteDHCPOptions(uuid: String) async throws(OVNManagerError)
    
    // Monitoring
    func startMonitoring(tables: [String]) async throws(OVNManagerError) -> String
    func stopMonitoring(monitorId: String) async throws(OVNManagerError)
    /// Streams row changes from this manager's monitors.
    ///
    /// The failure type is `any Error` rather than `OVNManagerError` — every
    /// `AsyncThrowingStream` initializer is constrained to
    /// `Failure == any Error`, so a typed-failure stream cannot be built. Only
    /// `OVNManagerError` is ever thrown, so match on it in the `catch`.
    nonisolated func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error>
    
    // Southbound Operations
    func getChassis() async throws(OVNManagerError) -> [OVNChassis]
    func getChassisPrivate() async throws(OVNManagerError) -> [OVNChassisPrivate]
    func getPortBindings() async throws(OVNManagerError) -> [OVNPortBinding]
    func getLogicalFlows() async throws(OVNManagerError) -> [OVNLogicalFlow]
    func getAdvertisedRoutes() async throws(OVNManagerError) -> [OVNAdvertisedRoute]
    func getLearnedRoutes() async throws(OVNManagerError) -> [OVNLearnedRoute]
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
    public static let logicalRouterPolicy = "Logical_Router_Policy"
    public static let gatewayChassis = "Gateway_Chassis"
    public static let haChassis = "HA_Chassis"
    public static let haChassisGroup = "HA_Chassis_Group"
    public static let acl = "ACL"
    public static let portGroup = "Port_Group"
    public static let addressSet = "Address_Set"
    public static let loadBalancer = "Load_Balancer"
    public static let nat = "NAT"
    public static let dhcpOptions = "DHCP_Options"
    /// The Northbound `QoS` table (`OVNQoS`), not the identically named
    /// Open_vSwitch one (`OVSQoS`).
    public static let qos = "QoS"
    public static let bfd = "BFD"
    public static let dns = "DNS"
    public static let meter = "Meter"
    public static let meterBand = "Meter_Band"

    // Southbound tables
    public static let chassis = "Chassis"
    public static let chassisPrivate = "Chassis_Private"
    public static let portBinding = "Port_Binding"
    public static let logicalFlow = "Logical_Flow"
    public static let advertisedRoute = "Advertised_Route"
    public static let learnedRoute = "Learned_Route"
    public static let encap = "Encap"
}

// MARK: - Helper Extensions

public extension OVNManaging {
    /// Connects using the endpoint the manager was constructed with. The
    /// database (northbound/southbound) is fixed at construction time, so
    /// there is no socket path to pass here.
    func connectToNorthbound() async throws(OVNManagerError) {
        try await connect()
    }

    func connectToSouthbound() async throws(OVNManagerError) {
        try await connect()
    }
}
