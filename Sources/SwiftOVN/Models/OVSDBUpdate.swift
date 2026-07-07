import Foundation

/// A single row change from an OVSDB monitor.
///
/// Per RFC 7047 §4.1.6, `old`/`new` describe the kind of change:
/// - insert (or initial row): `old` is nil, `new` has the row
/// - delete: `old` has the row, `new` is nil
/// - modify: `old` has the prior values of changed columns, `new` the row
public struct OVSDBUpdate: Codable, Sendable {
    /// The table the row belongs to.
    public let table: String
    /// The UUID of the changed row.
    public let uuid: String
    public let old: OVSDBRow?
    public let new: OVSDBRow?

    public init(table: String, uuid: String, old: OVSDBRow? = nil, new: OVSDBRow? = nil) {
        self.table = table
        self.uuid = uuid
        self.old = old
        self.new = new
    }
}
