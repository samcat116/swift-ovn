#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A single row change from an OVSDB monitor.
///
/// An RFC 7047 §4.1.6 `update` notification describes a change as an `old`/`new`
/// pair:
/// - insert (or initial row): `old` is nil, `new` has the row
/// - delete: `old` has the row, `new` is nil
/// - modify: `old` has the prior values of changed columns, `new` the row
///
/// The `update2`/`update3` notifications a `monitor_cond` /
/// `monitor_cond_since` monitor sends describe it differently (ovsdb-server(7)
/// `<row-update2>`): each row carries exactly one of `initial`, `insert`,
/// `modify` or `delete`, a `modify` carries *only the columns that changed*,
/// and there is no `old` alongside it — the server assumes the client already
/// has the row.
///
/// So an update parsed from `update2`/`update3` reports what the server
/// actually said: `kind`, and for a modify the changed columns in `diff`, with
/// `old` and `new` left nil rather than filled in with a guess. Synthesizing
/// the pair would take a client-side copy of every monitored row *and* the
/// database schema, because a `modify` expresses set- and map-typed values as
/// OVSDB's XOR-style difference against the old value, and a single-element set
/// is indistinguishable from a scalar on the wire without knowing the column's
/// type. A consumer that needs whole rows keeps its own cache keyed by `uuid`,
/// seeded from the monitor's `initialUpdates`, and applies `diff` with the
/// column types it knows.
///
/// `kind` is set however the update was parsed, so switching on it works for
/// both notification forms.
public struct OVSDBUpdate: Codable, Sendable {
    /// What happened to the row.
    public enum Kind: String, Codable, Sendable {
        /// A row that already existed when the monitor started, from the
        /// monitor's reply. RFC 7047 `update` cannot distinguish these from
        /// inserts, so they are only reported as `initial` on the reply itself.
        case initial
        /// A row that came into existence, or newly started matching a
        /// conditional monitor's `where`.
        case insert
        /// Columns of an existing row changed.
        case modify
        /// A row was deleted, or stopped matching a conditional monitor's
        /// `where`.
        case delete
    }

    /// The table the row belongs to.
    public let table: String
    /// The UUID of the changed row.
    public let uuid: String
    /// Which kind of change this is.
    public let kind: Kind
    public let old: OVSDBRow?
    public let new: OVSDBRow?
    /// The columns an `update2`/`update3` `modify` reported as changed, and only
    /// those: scalars hold their new value, while set- and map-typed columns
    /// hold OVSDB's difference against the old value (for a set, the elements
    /// added or removed; for a map, the pairs added, removed or re-valued).
    /// Nil for every other kind, and for anything parsed from an `update`.
    public let diff: OVSDBRow?

    /// Creates an update in RFC 7047 `old`/`new` form, deriving `kind` from the
    /// pair.
    public init(table: String, uuid: String, old: OVSDBRow? = nil, new: OVSDBRow? = nil) {
        self.init(table: table, uuid: uuid, kind: Self.kind(old: old, new: new), old: old, new: new)
    }

    public init(
        table: String,
        uuid: String,
        kind: Kind,
        old: OVSDBRow? = nil,
        new: OVSDBRow? = nil,
        diff: OVSDBRow? = nil
    ) {
        self.table = table
        self.uuid = uuid
        self.kind = kind
        self.old = old
        self.new = new
        self.diff = diff
    }

    private enum CodingKeys: String, CodingKey {
        case table, uuid, kind, old, new, diff
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        table = try container.decode(String.self, forKey: .table)
        uuid = try container.decode(String.self, forKey: .uuid)
        old = try container.decodeIfPresent(OVSDBRow.self, forKey: .old)
        new = try container.decodeIfPresent(OVSDBRow.self, forKey: .new)
        diff = try container.decodeIfPresent(OVSDBRow.self, forKey: .diff)
        // `kind` post-dates the type, so an encoded update written without it
        // still decodes: the `old`/`new` pair says which change it was.
        kind = try container.decodeIfPresent(Kind.self, forKey: .kind)
            ?? Self.kind(old: old, new: new)
    }

    /// The change an RFC 7047 `old`/`new` pair describes.
    static func kind(old: OVSDBRow?, new: OVSDBRow?) -> Kind {
        if new == nil {
            // Neither present is not a change ovsdb-server sends; calling it a
            // delete at least keeps `new == nil` and `.delete` consistent.
            return .delete
        }
        return old == nil ? .insert : .modify
    }
}
