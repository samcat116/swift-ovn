/// What a remote reported about its own copy of a database.
enum OVSDBLeadership: Sendable, Equatable {
    /// This server is the RAFT leader (or the database is not clustered, in
    /// which case `ovsdb-server` reports the single copy as the leader).
    case leader
    /// The database is being served, but by a follower. Writes sent here are
    /// rejected, so a connection that needs the leader must move on.
    case follower
    /// The server has the database but is not currently serving it — mid-join,
    /// or disconnected from the cluster.
    case notConnected
    /// The remote did not say: `_Server` is missing (`ovsdb-server` older than
    /// 2.9), the table did not contain a row for this database, or the columns
    /// were not readable. Treated as usable, because refusing to connect on the
    /// strength of a question we could not ask would be worse than connecting to
    /// a follower.
    case unknown
}

/// The `_Server` database, which is how a client asks an `ovsdb-server` about the
/// databases it serves — including, for a clustered database, whether this
/// particular server is the RAFT leader.
///
/// Only the three columns the reconnect logic acts on are monitored. `schema` in
/// particular is deliberately left out: it carries the entire database schema as
/// a string, which is megabytes for OVN Southbound and would be re-sent on every
/// reconnect for nothing.
enum OVSDBServerStatus {
    static let database = "_Server"
    static let table = "Database"
    static let monitoredColumns = ["name", "connected", "leader"]

    /// The `<monitor-requests>` object for a `monitor` on `_Server`.
    static var monitorRequests: JSONValue {
        return .object([
            table: .object(["columns": .array(monitoredColumns.map { .string($0) })])
        ])
    }

    /// Reads the leadership of `database` out of a `<table-updates>` object —
    /// either a `monitor` reply's initial contents or a later `update`
    /// notification, which have the same shape.
    static func leadership(ofDatabase database: String, in tableUpdates: JSONValue) -> OVSDBLeadership {
        guard let rows = tableUpdates.objectValue?[table]?.objectValue else {
            return .unknown
        }

        for (_, rowUpdate) in rows {
            // Only `new` matters: a row that only has `old` was deleted, which
            // says nothing about the current state.
            guard let row = rowUpdate.objectValue?["new"]?.objectValue,
                  row["name"]?.stringValue == database else {
                continue
            }
            if boolean(row["connected"]) == false {
                return .notConnected
            }
            switch boolean(row["leader"]) {
            case true:
                return .leader
            case false:
                return .follower
            case nil:
                return .unknown
            }
        }
        return .unknown
    }

    /// Reads an OVSDB boolean column, which arrives either as a JSON boolean or,
    /// when the column is optional and set, as the single-element set form
    /// (RFC 7047 §5.1). An empty set — the column is unset — reads as nil.
    private static func boolean(_ value: JSONValue?) -> Bool? {
        guard let value else { return nil }
        if let boolValue = value.boolValue { return boolValue }
        guard let set = value.setValue, set.count == 1 else { return nil }
        return set[0].boolValue
    }
}
