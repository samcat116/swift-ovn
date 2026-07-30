/// A row in the OVN Southbound `Address_Set` table: a named set of addresses
/// that a Southbound logical flow's match references as `$name`.
///
/// `OVNSB`-prefixed because `Address_Set` names a table in both databases — see
/// `OVNAddressSet` for the Northbound row a client writes. ovn-northd syncs
/// these from that table *and* generates one per Northbound `Port_Group`
/// (holding the group members' addresses), so a Southbound set with no
/// Northbound namesake is normal rather than stale.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBAddressSet: Codable, Sendable {
    public let uuid: String?
    /// The set's name, as it appears in a logical flow's match after `$`.
    public let name: String
    /// The set's members: plain address strings, not references.
    public let addresses: [String]?
    public let options: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, addresses, options
    }
}
