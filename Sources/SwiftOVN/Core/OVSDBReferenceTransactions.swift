import Foundation

/// A parent table/column pair whose reference set may contain a child row's
/// UUID (e.g. `Logical_Switch.ports`, `Bridge.mirrors`).
public struct OVSDBParentReference: Sendable {
    public let table: String
    public let column: String

    public init(table: String, column: String) {
        self.table = table
        self.column = column
    }
}

/// Builds the multi-operation transactions that keep child rows and their
/// parents' reference sets consistent. Per RFC 7047, a row in a non-root
/// table that nothing references is garbage-collected when the transaction
/// commits — so an insert must add the new row to its parent's reference
/// column atomically, or the returned UUID refers to nothing. Conversely, a
/// strongly-referenced row cannot be deleted while a parent still references
/// it (ovsdb-server rejects the transaction), so the parent set must be
/// mutated in the same transaction as the row delete.
public enum OVSDBReferenceTransactions {
    /// Operations for creating a child row attached to its parent:
    /// `wait`(parent exists) → `insert`(child, with `uuid-name`) →
    /// `mutate`(parent column += `named-uuid`). The wait aborts the whole
    /// transaction if the parent vanished after the caller's existence
    /// check, so the insert can never commit as an orphan.
    ///
    /// Pass a nil `parentCondition` for a singleton root parent (the
    /// `Open_vSwitch` table), which skips the wait and mutates every row of
    /// the parent table — i.e. the one root row.
    public static func insertAttached(
        row: OVSDBRow,
        into table: String,
        uuidName: String,
        parentTable: String,
        parentColumn: String,
        parentCondition: OVSDBCondition?
    ) -> [OVSDBOperation] {
        var operations: [OVSDBOperation] = []

        if let condition = parentCondition {
            operations.append(OVSDBOperation(
                op: "wait",
                table: parentTable,
                whereConditions: [condition],
                columns: [condition.column],
                rows: [[condition.column: condition.value]],
                until: "==",
                timeout: 0
            ))
        }

        operations.append(OVSDBOperation(
            op: "insert",
            table: table,
            row: row,
            uuidName: uuidName
        ))

        operations.append(OVSDBOperation(
            op: "mutate",
            table: parentTable,
            whereConditions: parentCondition.map { [$0] } ?? [],
            mutations: [OVSDBMutation(
                column: parentColumn,
                mutator: "insert",
                value: .array([.string("named-uuid"), .string(uuidName)])
            )]
        ))

        return operations
    }

    /// Operations for deleting a child row: one `mutate` per parent reference
    /// removing the UUID from the parent's column (matching zero parents is
    /// fine — the row may be an orphan or attached elsewhere), then the row
    /// `delete` itself, all in one transaction so no dangling reference is
    /// ever visible.
    public static func deleteDetaching(
        uuid: String,
        from table: String,
        parentReferences: [OVSDBParentReference]
    ) -> [OVSDBOperation] {
        let uuidAtom = JSONValue.array([.string("uuid"), .string(uuid)])

        var operations = parentReferences.map { parent in
            OVSDBOperation(
                op: "mutate",
                table: parent.table,
                whereConditions: [OVSDBCondition(column: parent.column, function: "includes", value: uuidAtom)],
                mutations: [OVSDBMutation(column: parent.column, mutator: "delete", value: uuidAtom)]
            )
        }

        operations.append(OVSDBOperation(
            op: "delete",
            table: table,
            whereConditions: [OVSDBCondition(column: "_uuid", function: "==", value: uuidAtom)]
        ))

        return operations
    }
}
