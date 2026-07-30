/// A row in the OVN Southbound `IGMP_Group` table: one multicast group a
/// chassis learned by snooping IGMP or MLD.
///
/// Where `OVNMulticastGroup` holds the groups ovn-northd computes from
/// configuration, this holds what was actually observed on the wire, indexed by
/// address, datapath and chassis — so the same group appears once per chassis
/// that has listeners for it. `OVNIPMulticast` carries the snooping
/// configuration these rows are learned under.
///
/// Read-only: ovn-controller owns these rows, so there is no create/update path
/// on `OVNManager` and no public initializer.
public struct OVNIGMPGroup: Codable, Sendable {
    public let uuid: String?
    /// The group's destination IP address.
    public let address: String
    /// Group protocol version: `"IGMPv1"`, `"IGMPv2"`, `"IGMPv3"`, `"MLDv1"` or
    /// `"MLDv2"`.
    public let protocolType: String
    /// UUID reference to the `OVNDatapathBinding` the group belongs to. A weak
    /// reference, and optional: a group whose datapath has gone reads as nil
    /// here rather than blocking the datapath's deletion.
    public let datapath: String?
    /// UUID reference to the `OVNChassis` that learned the group, weak and
    /// optional for the same reason as `datapath`.
    public let chassis: String?
    /// UUID references to the `OVNPortBinding` rows multicast traffic for this
    /// group is delivered to.
    public let ports: [String]?
    /// Name of the chassis that inserted the row, recorded for RBAC only —
    /// `chassis` is the reference to follow. Absent on a Southbound database
    /// predating the column.
    public let chassis_name: String?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case address, datapath, chassis, ports, chassis_name
        case protocolType = "protocol"
    }
}
