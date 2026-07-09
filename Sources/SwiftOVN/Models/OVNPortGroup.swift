import Foundation

/// A row in the OVN Northbound `Port_Group` table. Port groups collect a set
/// of logical switch ports so ACLs can be applied to the group as a whole,
/// which is OVN's scalable pattern for security groups (mirroring
/// `ovn-nbctl pg-add`). `Port_Group` is a root table, so a group persists
/// until it is explicitly deleted.
public struct OVNPortGroup: Codable, Sendable {
    public let uuid: String?
    /// Unique group name. The NB schema indexes this column.
    public let name: String
    /// UUIDs of the `Logical_Switch_Port` rows that belong to the group. This
    /// is a weak reference set: a member whose port row is deleted is dropped
    /// from the group automatically.
    public let ports: [String]?
    /// UUIDs of the `ACL` rows applied to the group.
    public let acls: [String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports, acls, external_ids
    }

    public init(name: String, ports: [String]? = nil, acls: [String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.acls = acls
        self.external_ids = external_ids
    }
}
