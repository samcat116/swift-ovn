#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNLogicalSwitch: Codable, Sendable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let acls: [String]?
    public let qosRules: [String]?
    public let dnsRecords: [String]?
    public let loadBalancer: [String]?
    /// UUIDs of the `Load_Balancer_Group` rows applied to this switch. Unlike
    /// `loadBalancer`, which is a weak reference set, these are *strong*
    /// references: a group cannot be deleted while a switch still names it.
    public let loadBalancerGroup: [String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name
        case ports
        case acls
        case qosRules = "qos_rules"
        case dnsRecords = "dns_records"
        case loadBalancer = "load_balancer"
        case loadBalancerGroup = "load_balancer_group"
        case other_config
        case external_ids
    }

    public init(name: String, ports: [String]? = nil, acls: [String]? = nil, qosRules: [String]? = nil, dnsRecords: [String]? = nil, loadBalancer: [String]? = nil, loadBalancerGroup: [String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.acls = acls
        self.qosRules = qosRules
        self.dnsRecords = dnsRecords
        self.loadBalancer = loadBalancer
        self.loadBalancerGroup = loadBalancerGroup
        self.other_config = other_config
        self.external_ids = external_ids
    }
}