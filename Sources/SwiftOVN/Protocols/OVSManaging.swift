#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO

// MARK: - OVS Management Protocol

/// A column-keyed bag of statistics/status values (e.g. `status`,
/// `other_config`, `statistics`). Each value keeps its OVSDB wire shape as a
/// `JSONValue`, so the type is `Sendable` and consistent with the rest of the
/// typed API.
public typealias StatisticsDictionary = [String: JSONValue]

/// Manages an Open vSwitch instance's `Open_vSwitch` database over OVSDB.
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
///
/// ## No flow operations
///
/// This protocol covers the `Open_vSwitch` *database* only. Installing,
/// dumping and deleting OpenFlow rules is OpenFlow, a separate protocol spoken
/// to `ovs-vswitchd` on its own channel and not reachable over the database
/// socket. Earlier versions declared `getFlows`/`addFlow`/`deleteFlow`/
/// `deleteAllFlows`/`modifyFlow` plus an `OVSFlowBuilder`; none of them could
/// do anything, and `getFlows` returning `[]` was indistinguishable from a
/// bridge with no flows. They are gone rather than left throwing, so the
/// absence is a compile error instead of a runtime surprise. Use `ovs-ofctl`,
/// or an OpenFlow client, for flows; `Bridge.protocols` and the `Controller`
/// table — both modelled here — are how you configure *which* OpenFlow
/// versions and controllers a bridge uses.
public protocol OVSManaging: Sendable {
    // Connection Management
    func connect() async throws(OVNManagerError)
    func disconnect() async throws(OVNManagerError)
    var isConnected: Bool { get async }
    
    // Database Operations
    func listDatabases() async throws(OVNManagerError) -> [String]
    func getDatabaseSchema(database: String) async throws(OVNManagerError) -> JSONValue
    
    // Bridge Operations
    func getBridges() async throws(OVNManagerError) -> [OVSBridge]
    func getBridge(named name: String) async throws(OVNManagerError) -> OVSBridge?
    func createBridge(_ bridge: OVSBridge) async throws(OVNManagerError) -> String
    func updateBridge(uuid: String, _ bridge: OVSBridge) async throws(OVNManagerError)
    func deleteBridge(uuid: String) async throws(OVNManagerError)
    func deleteBridge(named name: String) async throws(OVNManagerError)
    
    // Port Operations
    func getPorts() async throws(OVNManagerError) -> [OVSPort]
    func getPort(named name: String) async throws(OVNManagerError) -> OVSPort?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createPort(_:withInterface:onBridge:) so the port is attached to its bridge.")
    func createPort(_ port: OVSPort) async throws(OVNManagerError) -> String
    func createPort(_ port: OVSPort, withInterface interface: OVSInterface, onBridge bridgeName: String) async throws(OVNManagerError) -> String
    func updatePort(uuid: String, _ port: OVSPort) async throws(OVNManagerError)
    func deletePort(uuid: String) async throws(OVNManagerError)
    func deletePort(named name: String) async throws(OVNManagerError)

    // Interface Operations
    func getInterfaces() async throws(OVNManagerError) -> [OVSInterface]
    func getInterface(named name: String) async throws(OVNManagerError) -> OVSInterface?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createInterface(_:onPort:) to add an interface to an existing port, or createPort(_:withInterface:onBridge:) to create a port with its first interface.")
    func createInterface(_ interface: OVSInterface) async throws(OVNManagerError) -> String
    func createInterface(_ interface: OVSInterface, onPort portName: String) async throws(OVNManagerError) -> String
    func updateInterface(uuid: String, _ interface: OVSInterface) async throws(OVNManagerError)
    func deleteInterface(uuid: String) async throws(OVNManagerError)
    func deleteInterface(named name: String) async throws(OVNManagerError)

    // Controller Operations
    func getControllers() async throws(OVNManagerError) -> [OVSController]
    func getController(target: String) async throws(OVNManagerError) -> OVSController?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createController(_:onBridge:) so the controller is attached to its bridge.")
    func createController(_ controller: OVSController) async throws(OVNManagerError) -> String
    func createController(_ controller: OVSController, onBridge bridgeName: String) async throws(OVNManagerError) -> String
    func updateController(uuid: String, _ controller: OVSController) async throws(OVNManagerError)
    func deleteController(uuid: String) async throws(OVNManagerError)
    func deleteController(target: String) async throws(OVNManagerError)
    
    // There are deliberately no flow operations here — see the note above the
    // protocol.

    // Mirror Operations
    func getMirrors() async throws(OVNManagerError) -> [OVSMirror]
    func getMirror(named name: String) async throws(OVNManagerError) -> OVSMirror?
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createMirror(_:onBridge:) so the mirror is attached to its bridge.")
    func createMirror(_ mirror: OVSMirror) async throws(OVNManagerError) -> String
    func createMirror(_ mirror: OVSMirror, onBridge bridgeName: String) async throws(OVNManagerError) -> String
    func updateMirror(uuid: String, _ mirror: OVSMirror) async throws(OVNManagerError)
    func deleteMirror(uuid: String) async throws(OVNManagerError)
    func deleteMirror(named name: String) async throws(OVNManagerError)

    // NetFlow Operations
    func getNetFlows() async throws(OVNManagerError) -> [OVSNetFlow]
    @available(*, deprecated, message: "Creates an orphan row that is garbage-collected at commit, so the returned UUID refers to nothing. Use createNetFlow(_:onBridge:) so the NetFlow config is attached to its bridge.")
    func createNetFlow(_ netflow: OVSNetFlow) async throws(OVNManagerError) -> String
    func createNetFlow(_ netflow: OVSNetFlow, onBridge bridgeName: String) async throws(OVNManagerError) -> String
    func updateNetFlow(uuid: String, _ netflow: OVSNetFlow) async throws(OVNManagerError)
    func deleteNetFlow(uuid: String) async throws(OVNManagerError)
    
    // QoS Operations
    func getQoSPolicies() async throws(OVNManagerError) -> [OVSQoS]
    func createQoSPolicy(_ qos: OVSQoS) async throws(OVNManagerError) -> String
    func updateQoSPolicy(uuid: String, _ qos: OVSQoS) async throws(OVNManagerError)
    func deleteQoSPolicy(uuid: String) async throws(OVNManagerError)
    
    // Queue Operations
    func getQueues() async throws(OVNManagerError) -> [OVSQueue]
    func createQueue(_ queue: OVSQueue) async throws(OVNManagerError) -> String
    func updateQueue(uuid: String, _ queue: OVSQueue) async throws(OVNManagerError)
    func deleteQueue(uuid: String) async throws(OVNManagerError)
    
    // Statistics Operations
    func getBridgeStatistics(bridge: String) async throws(OVNManagerError) -> StatisticsDictionary
    func getPortStatistics(port: String) async throws(OVNManagerError) -> StatisticsDictionary
    func getInterfaceStatistics(interface: String) async throws(OVNManagerError) -> StatisticsDictionary
    
    // Monitoring
    func startMonitoring(tables: [String]) async throws(OVNManagerError) -> String
    /// Starts a monitor that filters rows server-side and, where the server
    /// supports `monitor_cond_since`, resumes from `lastTransactionId` instead of
    /// re-downloading the database.
    func startConditionalMonitoring(
        tables: [String: OVSDBMonitorRequest],
        monitorId: String?,
        since lastTransactionId: String?
    ) async throws(OVNManagerError) -> OVSDBMonitorSession
    /// Replaces a running conditional monitor's `where` conditions in place.
    func updateMonitorConditions(
        monitorId: String,
        conditions: [String: [OVSDBCondition]]
    ) async throws(OVNManagerError)
    /// The transaction id a `monitor_cond_since` monitor can be resumed from.
    func lastTransactionId(forMonitor monitorId: String) async -> String?
    func stopMonitoring(monitorId: String) async throws(OVNManagerError)
    /// Streams row changes from this manager's monitors.
    ///
    /// The failure type is `any Error` rather than `OVNManagerError` — every
    /// `AsyncThrowingStream` initializer is constrained to
    /// `Failure == any Error`, so a typed-failure stream cannot be built. Only
    /// `OVNManagerError` is ever thrown, so match on it in the `catch`.
    nonisolated func monitorUpdates() -> AsyncThrowingStream<OVSDBUpdate, Error>
    /// Streams row changes one notification at a time, carrying the transaction
    /// id a `monitor_cond_since` monitor resumes from. The stream to use with
    /// `startConditionalMonitoring`; the failure type is `any Error` for the
    /// reason above.
    nonisolated func monitorTableUpdates(monitorId: String?) -> AsyncThrowingStream<OVSDBTableUpdates, Error>
}

// MARK: - OVS Database Constants

public enum OVSDatabase {
    public static let openVSwitch = "Open_vSwitch"
}

public enum OVSTable {
    public static let bridge = "Bridge"
    public static let port = "Port"
    public static let interface = "Interface"
    public static let controller = "Controller"
    public static let manager = "Manager"
    public static let mirror = "Mirror"
    public static let netflow = "NetFlow"
    public static let sflow = "sFlow"
    public static let ipfix = "IPFIX"
    public static let qos = "QoS"
    public static let queue = "Queue"
    public static let ssl = "SSL"
    public static let openVSwitch = "Open_vSwitch"
    public static let flowTable = "Flow_Table"
    public static let flowSampleCollectorSet = "Flow_Sample_Collector_Set"
}

// MARK: - Helper Extensions

public extension OVSManaging {
    /// Connects using the endpoint the manager was constructed with.
    func connectToOVS() async throws(OVNManagerError) {
        try await connect()
    }
}