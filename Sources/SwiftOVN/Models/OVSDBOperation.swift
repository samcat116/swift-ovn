#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// One operation of an OVSDB transaction (RFC 7047 §5.2).
///
/// Every operation but `insert`, `select`, `update`, `mutate`, `delete` and
/// `wait` leaves most members nil — the struct is the union of all ten
/// operations' fields, because that is what the wire format is. Prefer the
/// builders (`.select(from:)`, `.commit(durable:)`, …) over the memberwise
/// initializer: they set exactly the members their operation defines, so an
/// operation cannot be assembled with fields the server will reject.
public struct OVSDBOperation: Codable, Sendable, Equatable {
    public let op: OVSDBOperationType
    /// The table the operation applies to, or nil for the four operations that
    /// name none: `commit`, `abort`, `comment` and `assert`.
    public let table: String?
    public let whereConditions: [OVSDBCondition]?
    public let columns: [String]?
    public let rows: [OVSDBRow]?
    public let row: OVSDBRow?
    public let mutations: [OVSDBMutation]?
    public let uuidName: String?
    public let until: String?
    public let timeout: Int?
    /// `commit` only: when true the server does not reply until the
    /// transaction is on stable storage.
    public let durable: Bool?
    /// `assert` only: the lock this connection must own, or the whole
    /// transaction is aborted with a `not owner` error.
    public let lock: String?
    /// `comment` only: the text recorded in the server's transaction log.
    public let comment: String?

    private enum CodingKeys: String, CodingKey {
        case op, table, columns, rows, row, mutations, until, timeout, durable, lock, comment
        case whereConditions = "where"
        case uuidName = "uuid-name"
    }

    public init(
        op: OVSDBOperationType,
        table: String? = nil,
        whereConditions: [OVSDBCondition]? = nil,
        columns: [String]? = nil,
        rows: [OVSDBRow]? = nil,
        row: OVSDBRow? = nil,
        mutations: [OVSDBMutation]? = nil,
        uuidName: String? = nil,
        until: String? = nil,
        timeout: Int? = nil,
        durable: Bool? = nil,
        lock: String? = nil,
        comment: String? = nil
    ) {
        self.op = op
        self.table = table
        self.whereConditions = whereConditions
        self.columns = columns
        self.rows = rows
        self.row = row
        self.mutations = mutations
        self.uuidName = uuidName
        self.until = until
        self.timeout = timeout
        self.durable = durable
        self.lock = lock
        self.comment = comment
    }
}

// MARK: - Builders

public extension OVSDBOperation {

    /// Reads rows matching `conditions`, or every row when it is empty
    /// (RFC 7047 §5.2.2). A nil `columns` selects them all.
    static func select(
        from table: String,
        where conditions: [OVSDBCondition] = [],
        columns: [String]? = nil
    ) -> OVSDBOperation {
        return OVSDBOperation(op: .select, table: table, whereConditions: conditions, columns: columns)
    }

    /// Inserts `row` (RFC 7047 §5.2.1). A `uuidName` makes the new row's UUID
    /// referenceable as `["named-uuid", uuidName]` from later operations in the
    /// same transaction — which is how a row in a non-root table is attached to
    /// its parent before the commit garbage-collects it (see
    /// `OVSDBReferenceTransactions`).
    static func insert(
        into table: String,
        row: OVSDBRow,
        uuidName: String? = nil
    ) -> OVSDBOperation {
        return OVSDBOperation(op: .insert, table: table, row: row, uuidName: uuidName)
    }

    /// Overwrites the columns present in `row` on every matching row
    /// (RFC 7047 §5.2.3).
    static func update(
        _ table: String,
        where conditions: [OVSDBCondition],
        row: OVSDBRow
    ) -> OVSDBOperation {
        return OVSDBOperation(op: .update, table: table, whereConditions: conditions, row: row)
    }

    /// Applies `mutations` in place on every matching row (RFC 7047 §5.2.4) —
    /// the read-modify-write-free way to add to or remove from a set column.
    static func mutate(
        _ table: String,
        where conditions: [OVSDBCondition],
        mutations: [OVSDBMutation]
    ) -> OVSDBOperation {
        return OVSDBOperation(op: .mutate, table: table, whereConditions: conditions, mutations: mutations)
    }

    /// Deletes every matching row (RFC 7047 §5.2.5).
    static func delete(
        from table: String,
        where conditions: [OVSDBCondition]
    ) -> OVSDBOperation {
        return OVSDBOperation(op: .delete, table: table, whereConditions: conditions)
    }

    /// Aborts the transaction unless the matching rows' `columns` compare
    /// `until` ("==" or "!=") to `rows` (RFC 7047 §5.2.6).
    ///
    /// With `timeout: 0` — what a guard against a concurrent writer wants — the
    /// server checks once and aborts immediately on a mismatch instead of
    /// waiting for the condition to come true.
    static func wait(
        _ table: String,
        where conditions: [OVSDBCondition],
        columns: [String]? = nil,
        rows: [OVSDBRow],
        until: String = "==",
        timeout: Int? = nil
    ) -> OVSDBOperation {
        return OVSDBOperation(
            op: .wait,
            table: table,
            whereConditions: conditions,
            columns: columns,
            rows: rows,
            until: until,
            timeout: timeout
        )
    }

    /// Requests that the transaction be committed (RFC 7047 §5.2.7). With
    /// `durable: true` the server withholds its reply until the transaction has
    /// reached stable storage, so a reply means the change survives a crash.
    static func commit(durable: Bool) -> OVSDBOperation {
        return OVSDBOperation(op: .commit, durable: durable)
    }

    /// Aborts the transaction (RFC 7047 §5.2.8): everything before it is
    /// discarded and the operations after it are not executed.
    static let abort = OVSDBOperation(op: .abort)

    /// Records `text` in the server's transaction log (RFC 7047 §5.2.9) — how
    /// `ovs-vsctl` leaves the command line that made a change behind for
    /// `ovsdb-tool show-log`.
    static func comment(_ text: String) -> OVSDBOperation {
        return OVSDBOperation(op: .comment, comment: text)
    }

    /// Aborts the transaction unless this connection owns `lock`
    /// (RFC 7047 §5.2.10).
    ///
    /// This is what makes `lock` usable for active/standby election: ownership
    /// can be stolen at any moment, so a writer that only checked the lock
    /// before building its transaction could still commit after losing it.
    /// Asserting the lock inside the transaction closes that window — the
    /// commit and the ownership check are atomic.
    static func assert(lock: String) -> OVSDBOperation {
        return OVSDBOperation(op: .assert, lock: lock)
    }
}
