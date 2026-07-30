/// A row in the OVN Southbound `HA_Chassis_Group` table: an active/backup set of
/// chassis for gateway failover.
///
/// `OVNSB`-prefixed because `HA_Chassis_Group` names a table in both databases —
/// see `OVNHAChassisGroup` for the Northbound row a client writes. The
/// Southbound row adds `ref_chassis`, which is what makes it worth reading: it
/// records the chassis that need tunnels to the group's members, so a chassis
/// listed there is one whose traffic depends on this group even though it is not
/// a candidate for it. `OVNPortBinding.ha_chassis_group` references these rows.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBHAChassisGroup: Codable, Sendable {
    public let uuid: String?
    /// The group's name.
    public let name: String
    /// UUID references to the group's `OVNSBHAChassis` members. A strong
    /// reference set, so a member exists only while listed here.
    public let ha_chassis: [String]?
    /// UUID references to the `OVNChassis` rows that need tunnels to this
    /// group's members — the chassis hosting ports whose traffic is redirected
    /// through it. Weak references.
    public let ref_chassis: [String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ha_chassis, ref_chassis, external_ids
    }
}
