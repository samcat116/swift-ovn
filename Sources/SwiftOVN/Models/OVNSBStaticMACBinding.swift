/// A row in the OVN Southbound `Static_MAC_Binding` table: an IP-to-MAC binding
/// configured on a logical router port rather than discovered.
///
/// ovn-northd populates these from the Northbound `Static_MAC_Binding` table.
/// With `override_dynamic_mac` set, the entry also suppresses whatever ARP or
/// neighbour discovery would otherwise learn for the same address — which makes
/// this the table to read when a router insists on a MAC that no
/// `OVNMACBinding` row explains.
///
/// `OVNSB`-prefixed because `Static_MAC_Binding` is also a Northbound table
/// name; the Southbound row differs by carrying `datapath`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBStaticMACBinding: Codable, Sendable {
    public let uuid: String?
    /// Name of the logical router port the binding applies to. A port *name*,
    /// not a UUID reference.
    public let logical_port: String
    /// The bound IP address.
    public let ip: String
    /// The Ethernet address `ip` is bound to.
    public let mac: String
    /// Whether this entry wins over a dynamically learned `OVNMACBinding` for
    /// the same address.
    public let override_dynamic_mac: Bool
    /// UUID reference to the `OVNDatapathBinding` of the router `logical_port`
    /// belongs to.
    public let datapath: String

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, ip, mac, override_dynamic_mac, datapath
    }
}
