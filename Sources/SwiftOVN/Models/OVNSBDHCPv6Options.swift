/// A row in the OVN Southbound `DHCPv6_Options` table: one DHCPv6 option that
/// native OVN DHCPv6 knows how to emit.
///
/// The IPv6 twin of `OVNSBDHCPOptions`, with the same columns and the same
/// purpose — a dictionary ovn-controller consults for the code and type of each
/// option named in a `put_dhcpv6_opts` action. It carries the `OVNSB` prefix for
/// symmetry with that type rather than because the name collides; only
/// `DHCP_Options` exists in both databases.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBDHCPv6Options: Codable, Sendable {
    public let uuid: String?
    /// The option's name, as written in a `put_dhcpv6_opts` action.
    public let name: String
    /// The DHCPv6 option code carried on the wire.
    public let code: Int
    /// The option's value type — `"ipv6"`, `"str"`, `"mac"` or `"domain"`.
    public let optionType: String

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, code
        case optionType = "type"
    }
}
