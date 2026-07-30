#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// Builds the operations for column-level writes whose correct wire form is not
/// obvious from RFC 7047: incrementing a counter and reading back what it
/// became, and changing individual entries of a map column without
/// read-modify-writing the whole map.
///
/// These are the shapes `NB_Global` needs — a singleton row whose `nb_cfg`
/// counter is the sync barrier and whose `options` map holds state other
/// writers own — but nothing here is specific to that table.
public enum OVSDBColumnTransactions {
    /// `mutate`(column += 1) followed by `select`(column), so the transaction
    /// returns the value the counter reached.
    ///
    /// A transaction's operations execute in order against its own uncommitted
    /// state (RFC 7047 §4.1.3), so the select sees the incremented value; a
    /// select in a *separate* transaction could not, because another client's
    /// increment may land in between. This is what `ovsdb_idl_txn_increment`
    /// does, and it is the only way to learn the value your own increment
    /// produced.
    ///
    /// The mutate result is operation 0 (its `count` says whether a row
    /// matched) and the select result operation 1. An empty `conditions`
    /// matches every row of the table — which for a `maxRows: 1` table like
    /// `NB_Global` is the singleton row.
    public static func increment(
        column: String,
        in table: String,
        where conditions: [OVSDBCondition] = []
    ) -> [OVSDBOperation] {
        [
            .mutate(
                table,
                where: conditions,
                mutations: [OVSDBMutation(column: column, mutator: "+=", value: .number(1))]
            ),
            .select(from: table, where: conditions, columns: [column])
        ]
    }

    /// Mutations that set `entries` in a map column, leaving every other key
    /// untouched — `ovs-vsctl set ... column:key=value` semantics.
    ///
    /// Two mutations, in order, because neither alone is an upsert: an
    /// `insert` of a map ignores keys the column already has (RFC 7047 §5.1,
    /// "insert ... key-value pairs ... that do not already exist"), so an
    /// existing key would keep its old value. Deleting the keys first — a
    /// `delete` whose value is a *set of keys* rather than a map, which removes
    /// those keys whatever they map to — makes the following insert land every
    /// pair. Both mutations belong to a single mutate operation, so a reader
    /// never observes the column with the keys missing.
    public static func upsertMapEntries(_ entries: [String: String], column: String) -> [OVSDBMutation] {
        [
            removeMapEntries(keys: Array(entries.keys), column: column),
            OVSDBMutation(column: column, mutator: "insert", value: .map(entries))
        ]
    }

    /// A mutation removing `keys` from a map column whatever they map to. The
    /// value is a set of keys: a `delete` given a map instead would only remove
    /// pairs that match on both key *and* value.
    public static func removeMapEntries(keys: [String], column: String) -> OVSDBMutation {
        OVSDBMutation(
            column: column,
            mutator: "delete",
            // Always the tagged set form, never the bare-atom spelling a
            // one-element set is also allowed: ovsdb-server accepts both, and
            // the tagged form keeps the single-key case from looking like a
            // string-valued delete.
            value: .array([.string("set"), .array(keys.map { .string($0) })])
        )
    }
}
