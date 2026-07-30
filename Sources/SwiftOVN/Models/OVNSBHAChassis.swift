/// A row in the OVN Southbound `HA_Chassis` table: one chassis's priority
/// within an `OVNSBHAChassisGroup`.
///
/// `OVNSB`-prefixed because `HA_Chassis` names a table in both databases — see
/// `OVNHAChassis` for the Northbound row a client writes. As with
/// `OVNSBGatewayChassis`, the Northbound column is the plain string
/// `chassis_name` while this one is a weak reference into `OVNChassis`. There is
/// no `name` column and no index: a row is identified only by the group that
/// references it.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBHAChassis: Codable, Sendable {
    public let uuid: String?
    /// UUID reference to the `OVNChassis` this member names, weak and so nil
    /// once that chassis is gone.
    public let chassis: String?
    /// Priority within the group (0–32767); the highest-priority reachable
    /// member is active.
    public let priority: Int
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case chassis, priority, external_ids
    }
}
