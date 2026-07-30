/// A row in the OVN Southbound `Port_Group` table: the members of a Northbound
/// port group, by name.
///
/// `OVNSB`-prefixed because `Port_Group` names a table in both databases — see
/// `OVNPortGroup` for the Northbound row a client writes. The two differ in
/// what `ports` holds: Northbound it is a weak reference set into
/// `Logical_Switch_Port`, here it is plain logical-port name strings, since a
/// Southbound flow matches on names. The group's ACLs do not appear here at all;
/// they have already been compiled into `OVNLogicalFlow` rows.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBPortGroup: Codable, Sendable {
    public let uuid: String?
    /// The group's name.
    public let name: String
    /// Names of the logical switch ports in the group — strings, not
    /// references.
    public let ports: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports
    }
}
