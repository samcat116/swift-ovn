import Foundation
import Testing
import NIO
import NIOPosix
@testable import SwiftOVN

/// Manager-level tests for the Northbound `DNS` table.
///
/// The row shape is covered by `OVSDBRowCodingTests`; what is asserted here is
/// the *wire form* of each operation, which the return value does not show:
/// whether a create attaches in the same transaction, whether a weak reference
/// is guarded, and whether a delete tries to detach first. Each of those is a
/// correctness property invisible from the manager's result.
///
/// A `final class` rather than a `struct` so the per-test event loop group can
/// be torn down in `deinit`.
@Suite("DNS records")
final class DNSTests {

    private let group: MultiThreadedEventLoopGroup

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Asynchronously, and never `syncShutdownGracefully()` — see the note on
        // `MessageRoutingTests.deinit`. This also closes the test servers, which
        // is why none of them are closed explicitly.
        group.shutdownGracefully { _ in }
    }

    private let dnsUUID = "1f7c9a02-3d4e-4a5b-8c6d-7e8f9a0b1c2d"
    private let switchUUID = "2a8d0b13-4e5f-4b6c-9d7e-8f9a0b1c2d3e"

    /// Brings up a stub answering the first transaction with `results[0]`, the
    /// second with `results[1]` and so on, plus a Northbound manager connected
    /// to it. The returned future yields the raw bytes of each transaction once
    /// `results.count` of them have arrived.
    private func connectedManager(
        answering results: [[Any]]
    ) async throws -> (OVNManager, EventLoopFuture<[[UInt8]]>) {
        let recorded = group.next().makePromise(of: [[UInt8]].self)
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    OVSDBScriptedTransactHandler(results: results, transactions: recorded)
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(server.localAddress?.port)

        let manager = OVNManager(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            database: OVNDatabase.northbound,
            eventLoopGroup: group
        )
        try await manager.connect()
        return (manager, recorded.futureResult)
    }

    /// Unpacks one recorded `transact` request into its operations. Carried as
    /// raw bytes because a parsed `[String: Any]` is not `Sendable` and so
    /// cannot cross an `EventLoopPromise`.
    private func operations(of request: [UInt8]) throws -> [[String: Any]] {
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(request)) as? [String: Any]
        )
        #expect(json["method"] as? String == "transact")

        // params is [database, op, op, ...] — RFC 7047 §4.1.3.
        let params = try #require(json["params"] as? [Any])
        #expect(params.first as? String == OVNDatabase.northbound)
        return params.dropFirst().compactMap { $0 as? [String: Any] }
    }

    private func expectSingleCondition(
        _ operation: [String: Any],
        column: String,
        equalsString value: String
    ) throws {
        let clause = try #require(operation["where"] as? [[Any]], "Expected a where clause")
        #expect(clause.count == 1, "Expected one condition, got \(clause)")
        let condition = try #require(clause.first)
        #expect(condition.count == 3)
        #expect(condition[0] as? String == column)
        #expect(condition[1] as? String == "==")
        #expect(condition[2] as? String == value)
    }

    private func expectSingleCondition(
        _ operation: [String: Any],
        column: String,
        equalsUUID value: String
    ) throws {
        let clause = try #require(operation["where"] as? [[Any]], "Expected a where clause")
        #expect(clause.count == 1, "Expected one condition, got \(clause)")
        let condition = try #require(clause.first)
        #expect(condition.count == 3)
        #expect(condition[0] as? String == column)
        #expect(condition[1] as? String == "==")
        // A ["uuid", ...] atom rather than a bare string — `_uuid` is a
        // reference-typed column.
        let atom = try #require(condition[2] as? [Any], "Expected a [\"uuid\", ...] atom")
        #expect(atom.count == 2)
        #expect(atom[0] as? String == "uuid")
        #expect(atom[1] as? String == value)
    }

    /// A `["map", [[key, value], ...]]` column unpacked into a dictionary.
    private func mapColumn(_ value: Any?) throws -> [String: String] {
        let tagged = try #require(value as? [Any], "Expected a [\"map\", [...]] value")
        #expect(tagged.count == 2)
        #expect(tagged[0] as? String == "map")
        let pairs = try #require(tagged[1] as? [[Any]], "Expected a list of [key, value] pairs")

        var map: [String: String] = [:]
        for pair in pairs {
            #expect(pair.count == 2)
            let key = try #require(pair[0] as? String)
            let value = try #require(pair[1] as? String)
            map[key] = value
        }
        return map
    }

    /// The one-key-covers-both-families form the schema documents: a single
    /// record name carrying an IPv4 and an IPv6 address, space separated.
    private let records = ["vm1.ovn.org": "10.0.0.4 aef0::4"]

    // MARK: create

    /// A bare create is one insert and nothing else — `DNS` is a root table,
    /// so the row is kept without a referrer and there is nothing to attach it
    /// to yet.
    @Test("Creating a DNS record set sends one insert carrying the records map")
    func createSendsOneInsert() async throws {
        let (manager, recorded) = try await connectedManager(
            answering: [[["uuid": ["uuid", dnsUUID]]]]
        )

        let created = try await manager.createDNS(OVNDNS(records: records))
        #expect(created == dnsUUID)

        let transactions = try await recorded.get()
        #expect(transactions.count == 1)

        let operations = try self.operations(of: try #require(transactions.first))
        #expect(operations.count == 1, "Expected a lone insert, got \(operations)")
        let operation = try #require(operations.first)
        #expect(operation["op"] as? String == "insert")
        #expect(operation["table"] as? String == "DNS")

        let row = try #require(operation["row"] as? [String: Any])
        #expect(try mapColumn(row["records"]) == records)
        // `_uuid` is server-assigned, and the two unset optionals are omitted
        // rather than sent as empty maps.
        #expect(row.count == 1, "Only `records` was set, got \(row)")

        try await manager.disconnect()
    }

    /// The attaching create has to be *one* transaction: wait the switch still
    /// exists, insert, then mutate the new row's `named-uuid` into
    /// `dns_records`. Split in two, a switch deleted in between would leave an
    /// unreferenced row behind — `DNS` being a root table means it is kept, not
    /// collected.
    @Test("Creating a DNS record set on a switch attaches it in the same transaction")
    func createAttachedIsOneTransaction() async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [["_uuid": ["uuid", switchUUID]]]]],
            [[String: Any](), ["uuid": ["uuid", dnsUUID]], ["count": 1]],
        ])

        let created = try await manager.createDNS(OVNDNS(records: records), attachedToSwitch: "ls0")
        #expect(created == dnsUUID)

        let transactions = try await recorded.get()
        #expect(transactions.count == 2, "A lookup, then one atomic insert-and-attach")

        // The lookup, for the error message only.
        let lookup = try self.operations(of: transactions[0])
        #expect(lookup.count == 1)
        #expect(lookup[0]["op"] as? String == "select")
        #expect(lookup[0]["table"] as? String == "Logical_Switch")
        try expectSingleCondition(lookup[0], column: "name", equalsString: "ls0")

        let operations = try self.operations(of: transactions[1])
        #expect(operations.count == 3, "Expected wait/insert/mutate, got \(operations)")

        // The guard that closes the race the lookup cannot: `Logical_Switch.name`
        // is unindexed, so the switch can still go between the two transactions.
        #expect(operations[0]["op"] as? String == "wait")
        #expect(operations[0]["table"] as? String == "Logical_Switch")
        #expect(operations[0]["until"] as? String == "==")
        #expect(operations[0]["timeout"] as? Int == 0)

        #expect(operations[1]["op"] as? String == "insert")
        #expect(operations[1]["table"] as? String == "DNS")
        let uuidName = try #require(operations[1]["uuid-name"] as? String)
        let row = try #require(operations[1]["row"] as? [String: Any])
        #expect(try mapColumn(row["records"]) == records)

        // The mutate refers to the insert by its `named-uuid`, which is what
        // makes the two one operation rather than two.
        #expect(operations[2]["op"] as? String == "mutate")
        #expect(operations[2]["table"] as? String == "Logical_Switch")
        try expectSingleCondition(operations[2], column: "name", equalsString: "ls0")
        let mutation = try #require(
            (operations[2]["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "dns_records")
        #expect(mutation[1] as? String == "insert")
        let reference = try #require(mutation[2] as? [Any])
        #expect(reference.count == 2)
        #expect(reference[0] as? String == "named-uuid")
        #expect(reference[1] as? String == uuidName)

        try await manager.disconnect()
    }

    /// An unknown switch is caught by the lookup, so no row is ever inserted —
    /// otherwise a typo would leave an orphan `DNS` row behind on every call.
    @Test("Creating a DNS record set on a missing switch inserts nothing")
    func createAttachedToMissingSwitchInsertsNothing() async throws {
        // Two scripted answers, but only the first should ever be consumed.
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [Any]()]],
            [[String: Any](), ["uuid": ["uuid", dnsUUID]], ["count": 1]],
        ])

        let error = await #expect(throws: OVNManagerError.self) {
            _ = try await manager.createDNS(OVNDNS(records: records), attachedToSwitch: "ls-missing")
        }
        #expect(error?.errorCase == .operationFailed)

        // Closing completes the recording promise with whatever arrived, which
        // must be the lookup and nothing else.
        try await manager.disconnect()
        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "The insert must not be sent, got \(transactions.count) transactions")
        #expect(try self.operations(of: transactions[0])[0]["op"] as? String == "select")
    }

    // MARK: read

    @Test("Reading a DNS record set selects by UUID and decodes its records")
    func getByUUIDSelectsAndDecodes() async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [[
                "_uuid": ["uuid", dnsUUID],
                "records": ["map", [["vm1.ovn.org", "10.0.0.4 aef0::4"]]],
                "options": ["map", [["ovn-owned", "true"]]],
                "external_ids": ["map", [Any]()],
            ]]]],
        ])

        let dns = try #require(try await manager.getDNS(uuid: dnsUUID))
        #expect(dns.uuid == dnsUUID)
        #expect(dns.records == records)
        #expect(dns.options == ["ovn-owned": "true"])
        #expect(dns.external_ids == [:])

        let operations = try self.operations(of: try #require(try await recorded.get().first))
        #expect(operations.count == 1)
        #expect(operations[0]["op"] as? String == "select")
        #expect(operations[0]["table"] as? String == "DNS")
        try expectSingleCondition(operations[0], column: "_uuid", equalsUUID: dnsUUID)

        try await manager.disconnect()
    }

    /// `DNS` has no name column, so a caller holding a stale UUID is the normal
    /// way to miss. That is a nil, not an error — same as `getMeter(named:)`.
    @Test("Reading a DNS record set that does not exist returns nil")
    func getByUUIDReturnsNilWhenAbsent() async throws {
        let (manager, _) = try await connectedManager(answering: [[["rows": [Any]()]]])

        #expect(try await manager.getDNS(uuid: dnsUUID) == nil)

        try await manager.disconnect()
    }

    @Test("Listing DNS record sets selects the whole table")
    func listSelectsWholeTable() async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [
                ["_uuid": ["uuid", dnsUUID], "records": ["map", [["vm1.ovn.org", "10.0.0.4 aef0::4"]]]],
                ["_uuid": ["uuid", switchUUID], "records": ["map", [Any]()]],
            ]]],
        ])

        let all = try await manager.getDNS()
        #expect(all.count == 2)
        #expect(all[0].records == records)
        // A row with no records decodes to an empty map, not a failure: the
        // column's schema minimum is 0.
        #expect(all[1].records == [:])

        let operations = try self.operations(of: try #require(try await recorded.get().first))
        #expect(operations.count == 1)
        #expect(operations[0]["op"] as? String == "select")
        #expect(operations[0]["table"] as? String == "DNS")
        // Selecting the whole table means matching every row.
        #expect((operations[0]["where"] as? [[Any]])?.isEmpty == true)

        try await manager.disconnect()
    }

    // MARK: update and delete

    @Test("Updating a DNS record set rewrites the records map")
    func updateRewritesRecords() async throws {
        let (manager, recorded) = try await connectedManager(answering: [[["count": 1]]])

        try await manager.updateDNS(uuid: dnsUUID, OVNDNS(records: records))

        let operations = try self.operations(of: try #require(try await recorded.get().first))
        #expect(operations.count == 1)
        #expect(operations[0]["op"] as? String == "update")
        #expect(operations[0]["table"] as? String == "DNS")
        try expectSingleCondition(operations[0], column: "_uuid", equalsUUID: dnsUUID)
        let row = try #require(operations[0]["row"] as? [String: Any])
        #expect(try mapColumn(row["records"]) == records)

        try await manager.disconnect()
    }

    /// `Logical_Switch.dns_records` is a *weak* reference set, so ovsdb-server
    /// drops the UUID from every switch still naming it rather than rejecting
    /// the delete. That is why this is a lone delete with no detaching mutate —
    /// unlike a strongly-referenced row, which would need one.
    @Test("Deleting a DNS record set sends one delete and detaches nothing")
    func deleteSendsOneDeleteWithoutDetaching() async throws {
        let (manager, recorded) = try await connectedManager(answering: [[["count": 1]]])

        try await manager.deleteDNS(uuid: dnsUUID)

        let operations = try self.operations(of: try #require(try await recorded.get().first))
        #expect(operations.count == 1, "Expected a lone delete, got \(operations)")
        #expect(operations[0]["op"] as? String == "delete")
        #expect(operations[0]["table"] as? String == "DNS")
        try expectSingleCondition(operations[0], column: "_uuid", equalsUUID: dnsUUID)

        try await manager.disconnect()
    }

    /// An update or delete matching no row reports count 0 rather than failing,
    /// so the manager is what has to turn that into an error.
    @Test("Updating or deleting a missing DNS record set fails",
          arguments: [MissingRowWrite.update, .delete])
    func writingToAMissingRecordSetFails(write: MissingRowWrite) async throws {
        let (manager, _) = try await connectedManager(answering: [[["count": 0]]])

        let error = await #expect(throws: OVNManagerError.self) {
            try await write.apply(manager, dnsUUID)
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }

    // MARK: attach and detach

    /// Attaching guards the reference with a `wait` in the same transaction:
    /// the column is weak, so ovsdb-server would silently drop a UUID whose row
    /// had gone and report the mutate as having succeeded.
    @Test("Attaching a DNS record set guards the weak reference")
    func attachGuardsTheWeakReference() async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [["_uuid": ["uuid", dnsUUID]]]]],
            [[String: Any](), ["count": 1]],
        ])

        try await manager.attachDNS(uuid: dnsUUID, toSwitch: "ls0")

        let transactions = try await recorded.get()
        #expect(transactions.count == 2)

        let lookup = try self.operations(of: transactions[0])
        #expect(lookup[0]["op"] as? String == "select")
        #expect(lookup[0]["table"] as? String == "DNS")

        let operations = try self.operations(of: transactions[1])
        #expect(operations.count == 2, "Expected a wait guard and a mutate, got \(operations)")

        // `wait` until a DNS row with that UUID is still there — `until !=`
        // against an empty `rows`, which aborts the transaction if it has gone.
        #expect(operations[0]["op"] as? String == "wait")
        #expect(operations[0]["table"] as? String == "DNS")
        #expect(operations[0]["until"] as? String == "!=")
        #expect(operations[0]["timeout"] as? Int == 0)
        #expect((operations[0]["rows"] as? [Any])?.isEmpty == true)

        #expect(operations[1]["op"] as? String == "mutate")
        #expect(operations[1]["table"] as? String == "Logical_Switch")
        try expectSingleCondition(operations[1], column: "name", equalsString: "ls0")
        let mutation = try #require((operations[1]["mutations"] as? [[Any]])?.first)
        #expect(mutation[0] as? String == "dns_records")
        #expect(mutation[1] as? String == "insert")
        let atom = try #require(mutation[2] as? [Any])
        #expect(atom[0] as? String == "uuid")
        #expect(atom[1] as? String == dnsUUID)

        try await manager.disconnect()
    }

    /// Detaching needs no guard and no lookup: removing a UUID from a set is a
    /// no-op if it is not there, so a single mutate is the whole operation. The
    /// `DNS` row itself is left alone.
    @Test("Detaching a DNS record set sends one unguarded mutate")
    func detachSendsOneUnguardedMutate() async throws {
        let (manager, recorded) = try await connectedManager(answering: [[["count": 1]]])

        try await manager.detachDNS(uuid: dnsUUID, fromSwitch: "ls0")

        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "Detaching needs no existence check")

        let operations = try self.operations(of: transactions[0])
        #expect(operations.count == 1, "Expected a lone mutate, got \(operations)")
        #expect(operations[0]["op"] as? String == "mutate")
        #expect(operations[0]["table"] as? String == "Logical_Switch")
        try expectSingleCondition(operations[0], column: "name", equalsString: "ls0")
        let mutation = try #require((operations[0]["mutations"] as? [[Any]])?.first)
        #expect(mutation[0] as? String == "dns_records")
        #expect(mutation[1] as? String == "delete")
        let atom = try #require(mutation[2] as? [Any])
        #expect(atom[0] as? String == "uuid")
        #expect(atom[1] as? String == dnsUUID)

        try await manager.disconnect()
    }

    /// A mutate matching no switch reports count 0, which is how a misspelled
    /// switch name comes back. The record set itself was found, so only the
    /// mutate can report the miss.
    @Test("Attaching to a missing switch fails")
    func attachingToAMissingSwitchFails() async throws {
        let (manager, _) = try await connectedManager(answering: [
            [["rows": [["_uuid": ["uuid", dnsUUID]]]]],
            [[String: Any](), ["count": 0]],
        ])

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.attachDNS(uuid: dnsUUID, toSwitch: "ls-missing")
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }

    /// The same miss on the detach side, which has no lookup in front of it —
    /// the lone mutate's count is the only signal there is.
    @Test("Detaching from a missing switch fails")
    func detachingFromAMissingSwitchFails() async throws {
        let (manager, _) = try await connectedManager(answering: [[["count": 0]]])

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.detachDNS(uuid: dnsUUID, fromSwitch: "ls-missing")
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }

    /// Attaching a record set that has been deleted is caught by the lookup, so
    /// the mutate is never sent — it would otherwise be accepted and silently
    /// drop the reference, leaving the switch resolving nothing.
    @Test("Attaching a DNS record set that does not exist sends no mutate")
    func attachingAMissingRecordSetSendsNoMutate() async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [Any]()]],
            [[String: Any](), ["count": 1]],
        ])

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.attachDNS(uuid: dnsUUID, toSwitch: "ls0")
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "The mutate must not be sent, got \(transactions.count) transactions")
        #expect(try self.operations(of: transactions[0])[0]["op"] as? String == "select")
    }
}

/// A write addressed by UUID, used to check that a count of 0 becomes an error.
/// Both take the same "not found" path, so one test covers them.
struct MissingRowWrite: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let apply: @Sendable (OVNManager, String) async throws -> Void

    static let update = MissingRowWrite(
        testDescription: "updateDNS",
        apply: { try await $0.updateDNS(uuid: $1, OVNDNS(records: ["vm1.ovn.org": "10.0.0.4"])) }
    )

    static let delete = MissingRowWrite(
        testDescription: "deleteDNS",
        apply: { try await $0.deleteDNS(uuid: $1) }
    )
}
