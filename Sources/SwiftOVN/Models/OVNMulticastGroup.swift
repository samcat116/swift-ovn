/// A row in the OVN Southbound `Multicast_Group` table: a named group of
/// logical ports within one datapath that a single tunnelled packet fans out
/// to.
///
/// A logical flow can `output` to a group exactly as it would to a single port,
/// by assigning `name` to `outport` — which is how one packet on the wire
/// reaches several VMs on the same hypervisor. Group names and logical port
/// names share a namespace, so ovn-northd prefixes the ones it creates with
/// `_MC_`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNMulticastGroup: Codable, Sendable {
    public let uuid: String?
    /// UUID reference to the `OVNDatapathBinding` the group lives in.
    public let datapath: String
    /// The group's name, unique within `datapath`. This is what a flow assigns
    /// to `outport`.
    public let name: String
    /// The logical egress port key used for this group in tunnel
    /// encapsulations, unique within `datapath`. Its range is deliberately
    /// disjoint from the one `OVNPortBinding.tunnel_key` uses so group and port
    /// keys cannot collide.
    public let tunnel_key: Int
    /// UUID references to the `OVNPortBinding` rows in the group, all of which
    /// belong to `datapath`. A weak reference set, so a port that goes away
    /// drops out of the group; an emptied group sends this as the empty set,
    /// which decodes as nil.
    public let ports: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case datapath, name, tunnel_key, ports
    }
}
