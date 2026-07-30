/// A row in the OVN Southbound `RBAC_Permission` table: what one role may do to
/// one table.
///
/// Referenced from `OVNRBACRole.permissions`. The mechanism is authorization by
/// self-identification: `authorization` names the columns whose value must equal
/// the client's own ID for the row to be considered that client's, and
/// `insert_delete` and `update` then say what it may do to such a row. That is
/// how a chassis is allowed to write its own `Chassis_Private` row and no one
/// else's.
///
/// Read-only: ovsdb-server's own RBAC configuration is out of scope for this
/// library, so there is no create/update path on `OVNManager` and no public
/// initializer.
public struct OVNRBACPermission: Codable, Sendable {
    public let uuid: String?
    /// Name of the table these permissions apply to.
    public let table: String
    /// Columns, or `column:key` pairs, compared against the client's ID; one
    /// match authorizes. The empty string is special and authorizes every
    /// client, so an `authorization` containing it is an unrestricted table
    /// rather than an unreachable one.
    public let authorization: [String]?
    /// Whether the role may insert rows, and delete the rows it is authorized
    /// for.
    public let insert_delete: Bool
    /// Columns, or `column:key` pairs, an authorized client may modify.
    public let update: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case table, authorization, insert_delete, update
    }
}
