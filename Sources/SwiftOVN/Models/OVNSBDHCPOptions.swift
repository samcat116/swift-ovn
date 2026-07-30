/// A row in the OVN Southbound `DHCP_Options` table: one DHCPv4 option that
/// native OVN DHCP knows how to emit.
///
/// `OVNSB`-prefixed because `DHCP_Options` names a table in both databases, but
/// the two are unrelated beyond the name: `OVNDHCPOptions` is a *configuration*
/// row (a CIDR and the option values to serve on it), while this is a
/// *dictionary* row — ovn-northd populates one per supported option and
/// ovn-controller looks up the code and type for each option named in a
/// `put_dhcp_opts` action. Reading this table is how a caller finds out which
/// option names a given OVN version accepts.
///
/// The DHCPv6 dictionary is the separate `OVNSBDHCPv6Options`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBDHCPOptions: Codable, Sendable {
    public let uuid: String?
    /// The option's name, as written in a `put_dhcp_opts` action.
    public let name: String
    /// The DHCPv4 option code carried on the wire.
    public let code: Int
    /// The option's value type — `"bool"`, `"uint8"`, `"uint16"`, `"uint32"`,
    /// `"ipv4"`, `"static_routes"`, `"str"`, `"host_id"` or `"domains"` — which
    /// is what tells ovn-controller how to encode the configured value.
    public let optionType: String

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, code
        case optionType = "type"
    }
}
