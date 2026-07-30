/// A row in the OVN Northbound `Load_Balancer_Group` table: a named set of
/// load balancers that switches and routers reference as a unit
/// (`Logical_Switch.load_balancer_group`, `Logical_Router.load_balancer_group`,
/// mirroring `ovn-nbctl lb-group-add`). Adding a load balancer to the group
/// applies it to every switch and router referencing the group, which is how a
/// deployment avoids fanning one load balancer out across thousands of
/// individual `load_balancer` columns.
///
/// This is a root table, so a group persists until it is explicitly deleted.
/// The switch and router columns pointing at it are *strong* references,
/// though, so the group cannot be deleted while one still names it — see
/// `OVNManager.deleteLoadBalancerGroup(uuid:)`, which detaches in the same
/// transaction.
public struct OVNLoadBalancerGroup: Codable, Sendable {
    public let uuid: String?
    /// Unique group name. The NB schema indexes this column.
    public let name: String
    /// UUIDs of the `Load_Balancer` rows in the group. This is a *weak*
    /// reference set: a member whose load balancer row is deleted is dropped
    /// from the group automatically, and ovsdb-server silently drops a member
    /// UUID that names no row rather than failing the write — so `OVNManager`
    /// guards every write of this column with a `wait` op.
    ///
    /// The schema gives this column no `external_ids` companion; the table has
    /// exactly these two columns.
    public let load_balancer: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, load_balancer
    }

    public init(name: String, load_balancer: [String]? = nil) {
        self.uuid = nil
        self.name = name
        self.load_balancer = load_balancer
    }
}
