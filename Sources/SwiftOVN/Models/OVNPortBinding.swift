#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNPortBinding: Codable, Sendable {
    public let uuid: String?
    public let logical_port: String
    public let bindingType: String
    public let mac: [String]?
    public let chassis: String?
    public let datapath: String?
    public let tunnel_key: Int?
    public let parent_port: String?
    public let tag: Int?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    /// The `Chassis` this port is destined for, populated by ovn-northd from
    /// `Logical_Switch_Port.options:requested-chassis`. Read together with
    /// `chassis` it is how a binding in flight during live migration reads:
    /// `requested_chassis` is the destination, `chassis` the current holder.
    public let requested_chassis: String?
    /// Further `Chassis` this port is bound to beyond `chassis` — a
    /// multi-chassis binding, as used mid-migration.
    public let additional_chassis: [String]?
    /// The requested counterpart of `additional_chassis`.
    public let requested_additional_chassis: [String]?
    /// `Encap` reference for the tunnel to `chassis`. The `Encap` table is not
    /// modeled yet, so this stays a UUID string.
    public let encap: String?
    /// The `Encap` records for the tunnels to `additional_chassis`, the
    /// multi-chassis counterpart of `encap`.
    public let additional_encap: [String]?
    /// `Mirror` references. That table is not modeled yet, so these stay UUID
    /// strings.
    public let mirror_rules: [String]?
    /// The mirror target port, for an lport-type mirror.
    public let mirror_port: String?
    public let port_security: [String]?
    /// A MAC address followed by the SNAT/DNAT external IPs that gratuitous
    /// ARPs are sent for on this port's behalf.
    public let nat_addresses: [String]?
    /// For a `virtual` port, the parent port whose traffic claimed the virtual
    /// IP — one of the Northbound `options:virtual-parents`, written by
    /// ovn-controller along with `chassis` when it runs `bind_vport`.
    public let virtual_parent: String?
    public let up: Bool?
    public let external_ids: [String: String]?
    public let options: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, mac, chassis, datapath, tunnel_key, parent_port, tag, gateway_chassis, ha_chassis_group, up, external_ids, options
        case requested_chassis, additional_chassis, requested_additional_chassis
        case encap, additional_encap
        case mirror_rules, mirror_port, port_security, nat_addresses, virtual_parent
        case bindingType = "type"
    }
}