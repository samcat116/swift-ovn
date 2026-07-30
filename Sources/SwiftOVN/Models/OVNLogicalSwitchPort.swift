#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNLogicalSwitchPort: Codable, Sendable {
    public let uuid: String?
    public let name: String
    public let portType: String?
    public let options: [String: String]?
    public let addresses: [String]?
    /// The name of this port's parent port, for a container or nested port.
    /// `tag_request` only allocates a VLAN tag when a parent is named — a
    /// `tag_request` on a parentless port is ignored by ovn-northd.
    public let parent_name: String?
    /// Addresses ovn-northd assigned when `addresses` contains `"dynamic"`.
    /// Read-only in practice: northd owns the column, and the allocation is
    /// only observable here.
    public let dynamic_addresses: String?
    public let port_security: [String]?
    /// For a port pairing two logical switches, the *name* of the other port
    /// of the pair (not a reference). Empty for a port attached to a router.
    public let peer: String?
    public let dhcpv4_options: String?
    public let dhcpv6_options: String?
    /// `Logical_Switch_Port_Health_Check` references. That table is not
    /// modeled yet, so these stay UUID strings.
    public let health_checks: [String]?
    /// `Mirror` references. That table is not modeled yet, so these stay
    /// UUID strings.
    public let mirror_rules: [String]?
    public let ha_chassis_group: String?
    public let tag: Int?
    public let tag_request: Int?
    public let up: Bool?
    public let enabled: Bool?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, options, addresses
        case parent_name, dynamic_addresses, port_security, peer
        case dhcpv4_options, dhcpv6_options
        case health_checks, mirror_rules, ha_chassis_group
        case tag, tag_request, up, enabled, external_ids
        case portType = "type"
    }

    public init(name: String, portType: String? = nil, options: [String: String]? = nil, addresses: [String]? = nil, port_security: [String]? = nil, dhcpv4_options: String? = nil, dhcpv6_options: String? = nil, tag: Int? = nil, tag_request: Int? = nil, up: Bool? = nil, enabled: Bool? = true, external_ids: [String: String]? = nil, parent_name: String? = nil, dynamic_addresses: String? = nil, peer: String? = nil, health_checks: [String]? = nil, mirror_rules: [String]? = nil, ha_chassis_group: String? = nil) {
        self.uuid = nil
        self.name = name
        self.portType = portType
        self.options = options
        self.addresses = addresses
        self.parent_name = parent_name
        self.dynamic_addresses = dynamic_addresses
        self.port_security = port_security
        self.peer = peer
        self.dhcpv4_options = dhcpv4_options
        self.dhcpv6_options = dhcpv6_options
        self.health_checks = health_checks
        self.mirror_rules = mirror_rules
        self.ha_chassis_group = ha_chassis_group
        self.tag = tag
        self.tag_request = tag_request
        self.up = up
        self.enabled = enabled
        self.external_ids = external_ids
    }
}