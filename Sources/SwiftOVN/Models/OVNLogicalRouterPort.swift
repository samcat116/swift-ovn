#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNLogicalRouterPort: Codable, Sendable {
    public let uuid: String?
    public let name: String
    public let mac: String
    public let networks: [String]
    public let peer: String?
    public let enabled: Bool?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    public let ipv6_ra_configs: [String: String]?
    /// IPv6 prefixes this port obtained by prefix delegation (RFC 3633).
    public let ipv6_prefix: [String]?
    /// `DHCP_Relay` reference. That table is not modeled yet, so this stays a
    /// UUID string.
    public let dhcp_relay: String?
    /// Written by ovn-northd. For a distributed gateway port, the
    /// `hosting-chassis` key names the chassis currently hosting the port —
    /// the only place gateway HA placement is observable.
    public let status: [String: String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, mac, networks, peer, enabled, gateway_chassis, ha_chassis_group, ipv6_ra_configs, options, external_ids
        case ipv6_prefix, dhcp_relay, status
    }

    public init(name: String, mac: String, networks: [String], peer: String? = nil, enabled: Bool? = true, gateway_chassis: [String]? = nil, ha_chassis_group: String? = nil, ipv6_ra_configs: [String: String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil, ipv6_prefix: [String]? = nil, dhcp_relay: String? = nil, status: [String: String]? = nil) {
        self.init(
            uuid: nil,
            name: name,
            mac: mac,
            networks: networks,
            peer: peer,
            enabled: enabled,
            gateway_chassis: gateway_chassis,
            ha_chassis_group: ha_chassis_group,
            ipv6_ra_configs: ipv6_ra_configs,
            options: options,
            external_ids: external_ids,
            ipv6_prefix: ipv6_prefix,
            dhcp_relay: dhcp_relay,
            status: status
        )
    }

    init(uuid: String?, name: String, mac: String, networks: [String], peer: String? = nil, enabled: Bool? = true, gateway_chassis: [String]? = nil, ha_chassis_group: String? = nil, ipv6_ra_configs: [String: String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil, ipv6_prefix: [String]? = nil, dhcp_relay: String? = nil, status: [String: String]? = nil) {
        self.uuid = uuid
        self.name = name
        self.mac = mac
        self.networks = networks
        self.peer = peer
        self.enabled = enabled
        self.gateway_chassis = gateway_chassis
        self.ha_chassis_group = ha_chassis_group
        self.ipv6_ra_configs = ipv6_ra_configs
        self.ipv6_prefix = ipv6_prefix
        self.dhcp_relay = dhcp_relay
        self.status = status
        self.options = options
        self.external_ids = external_ids
    }
}
