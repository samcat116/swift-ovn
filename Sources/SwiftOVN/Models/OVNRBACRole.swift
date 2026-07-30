/// A row in the OVN Southbound `RBAC_Role` table: a named set of per-table
/// permissions that ovsdb-server applies to a client connection.
///
/// A connection's `OVNSBConnection.role` names one of these. The role is what
/// stops a compromised hypervisor from writing rows that belong to another —
/// `ovn-controller` connects with the `ovn-controller` role, which permits it to
/// write only rows it can prove are its own. Reading this table is how a caller
/// confirms which restrictions a deployment's ovsdb-server is actually
/// enforcing.
///
/// Read-only: ovsdb-server's own RBAC configuration is out of scope for this
/// library, so there is no create/update path on `OVNManager` and no public
/// initializer.
public struct OVNRBACRole: Codable, Sendable {
    public let uuid: String?
    /// The role's name, as `OVNSBConnection.role` spells it.
    public let name: String
    /// Table name to the UUID of the `OVNRBACPermission` row governing it. A
    /// map with weak reference values, so a table with no entry is one this role
    /// may not write at all.
    public let permissions: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, permissions
    }
}
