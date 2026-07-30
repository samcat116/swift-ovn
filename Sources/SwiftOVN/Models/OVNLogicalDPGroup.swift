/// A row in the OVN Southbound `Logical_DP_Group` table: a set of logical
/// datapaths that one `OVNLogicalFlow` applies to.
///
/// ovn-northd leans on datapath groups heavily — where the same flow would
/// otherwise be emitted once per datapath, it emits one flow whose
/// `logical_dp_group` names the group. So a large fraction of Southbound flows
/// have `logical_datapath` unset and only `logical_dp_group` set, and reading a
/// flow's scope means resolving the group through this table.
///
/// Not a root table: a group exists only while some `Logical_Flow` references
/// it, and is garbage-collected when the last reference goes.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNLogicalDPGroup: Codable, Sendable {
    public let uuid: String?
    /// UUID references to the `OVNDatapathBinding` rows in the group. A weak
    /// reference set: a datapath that goes away drops out of the group rather
    /// than blocking its deletion.
    ///
    /// Optional because a group whose members have all been removed sends this
    /// as the empty set, which decodes as nil.
    public let datapaths: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case datapaths
    }
}
