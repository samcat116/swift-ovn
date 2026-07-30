import Foundation
import Testing
import NIO
import NIOPosix
@testable import SwiftOVN

/// Manager-level tests for the two Southbound writes. Both are defined by their
/// wire form rather than their return value — `deleteChassis(named:)` has to
/// clear three tables in *one* transaction, and the port-binding setters have to
/// guard a weak reference — and none of that is observable from the result, so
/// each test asserts on what actually reached the server.
///
/// A `final class` rather than a `struct` so the per-test event loop group can be
/// torn down in `deinit`.
@Suite("Southbound writes")
final class SouthboundWriteTests {

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

    private let chassisUUID = "0d53b52f-7f4c-4c8f-9b1e-1a2b3c4d5e6f"

    /// Brings up a stub answering the first transaction with `results[0]`, the
    /// second with `results[1]` and so on, plus a Southbound manager connected to
    /// it. The returned future yields the raw bytes of each transaction once
    /// `results.count` of them have arrived.
    private func connectedManager(
        answering results: [[Any]],
        database: String = OVNDatabase.southbound
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
            database: database,
            eventLoopGroup: group
        )
        try await manager.connect()
        return (manager, recorded.futureResult)
    }

    /// Unpacks one recorded `transact` request into its operations. Carried as
    /// raw bytes because a parsed `[String: Any]` is not `Sendable` and so cannot
    /// cross an `EventLoopPromise`.
    private func operations(of request: [UInt8]) throws -> [[String: Any]] {
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(request)) as? [String: Any]
        )
        #expect(json["method"] as? String == "transact")

        // params is [database, op, op, ...] — RFC 7047 §4.1.3.
        let params = try #require(json["params"] as? [Any])
        #expect(params.first as? String == OVNDatabase.southbound)
        return params.dropFirst().compactMap { $0 as? [String: Any] }
    }

    /// The `[column, function, value]` conditions of one operation.
    private func conditions(of operation: [String: Any]) throws -> [[Any]] {
        return try #require(operation["where"] as? [[Any]], "Expected a where clause")
    }

    private func expectSingleCondition(
        _ operation: [String: Any],
        column: String,
        equals value: String
    ) throws {
        let clause = try conditions(of: operation)
        #expect(clause.count == 1, "Expected one condition, got \(clause)")
        let condition = try #require(clause.first)
        #expect(condition.count == 3)
        #expect(condition[0] as? String == column)
        #expect(condition[1] as? String == "==")
        #expect(condition[2] as? String == value)
    }

    // MARK: deleteChassis

    /// The shape that matters: three deletes, one transaction. Split across
    /// transactions, a failure between them would leave a half-evicted chassis —
    /// most damagingly a `Chassis_Private` row with no `Chassis`, which pins
    /// `NB_Global.hv_cfg` at the dead hypervisor's last value and stalls
    /// `waitForHypervisors` for good.
    @Test("Evicting a chassis clears Encap, Chassis_Private and Chassis in one transaction")
    func deleteChassisClearsThreeTablesInOneTransaction() async throws {
        let (manager, recorded) = try await connectedManager(
            answering: [[["count": 1], ["count": 1], ["count": 1]]]
        )

        try await manager.deleteChassis(named: "hv-1")

        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "Eviction must be atomic, not one transaction per table")

        let operations = try self.operations(of: try #require(transactions.first))
        #expect(operations.count == 3, "Expected three deletes, got \(operations)")
        #expect(operations.allSatisfy { $0["op"] as? String == "delete" })

        // Encap is matched by its owner's name, the only back-pointer it has;
        // Chassis_Private and Chassis by their own indexed `name`.
        #expect(operations[0]["table"] as? String == "Encap")
        try expectSingleCondition(operations[0], column: "chassis_name", equals: "hv-1")

        #expect(operations[1]["table"] as? String == "Chassis_Private")
        try expectSingleCondition(operations[1], column: "name", equals: "hv-1")

        #expect(operations[2]["table"] as? String == "Chassis")
        try expectSingleCondition(operations[2], column: "name", equals: "hv-1")

        try await manager.disconnect()
    }

    /// A delete matching no row reports count 0 rather than failing, so the
    /// manager is what has to turn that into an error.
    @Test("Evicting a chassis that does not exist fails")
    func deleteMissingChassisFails() async throws {
        let (manager, _) = try await connectedManager(
            answering: [[["count": 0], ["count": 0], ["count": 0]]]
        )

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.deleteChassis(named: "hv-1")
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }

    /// Only the `Chassis` delete decides whether the chassis was there. A
    /// chassis with no encaps and no `Chassis_Private` row is unusual but legal —
    /// ovn-controller writes those itself, so a chassis it has not finished
    /// registering has neither — and zero counts on them must not read as
    /// "not found".
    @Test("Evicting a chassis with no encaps and no private row still succeeds")
    func deleteChassisWithoutEncapsOrPrivateRowSucceeds() async throws {
        let (manager, _) = try await connectedManager(
            answering: [[["count": 0], ["count": 0], ["count": 1]]]
        )

        try await manager.deleteChassis(named: "hv-1")

        try await manager.disconnect()
    }

    /// Rejected locally, before anything is sent: `Chassis` does not exist in the
    /// Northbound database at all. No server, so a request that escaped the guard
    /// would fail as `connectionFailed` and be visible as such.
    @Test("A Southbound write against the northbound database is refused")
    func southboundWriteAgainstNorthboundIsRefused() async throws {
        let manager = OVNManager(
            socketPath: "/nonexistent/swift-ovn-southbound-writes.sock",
            database: OVNDatabase.northbound
        )

        let deleteError = await #expect(throws: OVNManagerError.self) {
            try await manager.deleteChassis(named: "hv-1")
        }
        #expect(deleteError?.errorCase == .operationFailed)

        let bindError = await #expect(throws: OVNManagerError.self) {
            try await manager.setPortBindingChassis(logicalPort: "lsp-vm", chassisNamed: nil)
        }
        #expect(bindError?.errorCase == .operationFailed)
    }

    // MARK: Port_Binding chassis columns

    /// Clearing a binding needs no chassis lookup and nothing to guard, so it is
    /// one update carrying the empty set — RFC 7047's spelling of an unset
    /// optional column.
    @Test("Clearing a chassis column sends one update with the empty set",
          arguments: [ChassisColumnWrite.chassis, .requestedChassis])
    func clearingAChassisColumnSendsOneUpdate(write: ChassisColumnWrite) async throws {
        let (manager, recorded) = try await connectedManager(answering: [[["count": 1]]])

        try await write.apply(manager, "lsp-vm", nil)

        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "A nil chassis needs no lookup")

        let operations = try self.operations(of: try #require(transactions.first))
        #expect(operations.count == 1, "Expected a lone update, got \(operations)")
        let operation = try #require(operations.first)
        #expect(operation["op"] as? String == "update")
        #expect(operation["table"] as? String == "Port_Binding")
        try expectSingleCondition(operation, column: "logical_port", equals: "lsp-vm")

        let row = try #require(operation["row"] as? [String: Any])
        #expect(row.count == 1, "Only the one column may be written, got \(row)")
        let value = try #require(row[write.column] as? [Any], "Expected a [\"set\", []] value")
        #expect(value.count == 2)
        #expect(value[0] as? String == "set")
        #expect((value[1] as? [Any])?.isEmpty == true)

        try await manager.disconnect()
    }

    /// Naming a chassis costs a lookup — the column holds a UUID, callers know
    /// names — and the resolved UUID then has to be guarded. Both columns are
    /// *weak* references, so without the `wait` a chassis deleted in the gap
    /// would have its UUID silently dropped and the update would report success
    /// on a port it had actually left unbound.
    @Test("Setting a chassis column resolves the name and guards the reference",
          arguments: [ChassisColumnWrite.chassis, .requestedChassis])
    func settingAChassisColumnResolvesAndGuards(write: ChassisColumnWrite) async throws {
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [["_uuid": ["uuid", chassisUUID]]]]],
            [["count": 1], ["count": 1]],
        ])

        try await write.apply(manager, "lsp-vm", "hv-1")

        let transactions = try await recorded.get()
        #expect(transactions.count == 2)

        // The lookup: `_uuid` only, since that is all the caller needs of it.
        let lookup = try self.operations(of: transactions[0])
        #expect(lookup.count == 1)
        #expect(lookup[0]["op"] as? String == "select")
        #expect(lookup[0]["table"] as? String == "Chassis")
        #expect(lookup[0]["columns"] as? [String] == ["_uuid"])
        try expectSingleCondition(lookup[0], column: "name", equals: "hv-1")

        let operations = try self.operations(of: transactions[1])
        #expect(operations.count == 2, "Expected a wait guard and an update, got \(operations)")

        // `wait` until a Chassis row with that UUID is still there — `until !=`
        // against an empty `rows`, which aborts the transaction if it has gone.
        #expect(operations[0]["op"] as? String == "wait")
        #expect(operations[0]["table"] as? String == "Chassis")
        #expect(operations[0]["until"] as? String == "!=")
        #expect(operations[0]["timeout"] as? Int == 0)
        #expect((operations[0]["rows"] as? [Any])?.isEmpty == true)
        let guardCondition = try #require(try conditions(of: operations[0]).first)
        #expect(guardCondition[0] as? String == "_uuid")
        #expect((guardCondition[2] as? [Any])?.last as? String == chassisUUID)

        #expect(operations[1]["op"] as? String == "update")
        #expect(operations[1]["table"] as? String == "Port_Binding")
        try expectSingleCondition(operations[1], column: "logical_port", equals: "lsp-vm")
        let row = try #require(operations[1]["row"] as? [String: Any])
        #expect(row.count == 1)
        // A ["uuid", ...] atom, not a bare string: this column is a reference.
        let value = try #require(row[write.column] as? [Any])
        #expect(value.count == 2)
        #expect(value[0] as? String == "uuid")
        #expect(value[1] as? String == chassisUUID)

        try await manager.disconnect()
    }

    /// An unknown chassis name is caught by the lookup, so the update is never
    /// sent — an update with no value to write would otherwise clear the column
    /// and unbind the port.
    @Test("Setting a chassis column to an unknown chassis sends no update",
          arguments: [ChassisColumnWrite.chassis, .requestedChassis])
    func settingAnUnknownChassisSendsNoUpdate(write: ChassisColumnWrite) async throws {
        // Two scripted answers, but only the first should ever be consumed.
        let (manager, recorded) = try await connectedManager(answering: [
            [["rows": [Any]()]],
            [["count": 1], ["count": 1]],
        ])

        let error = await #expect(throws: OVNManagerError.self) {
            try await write.apply(manager, "lsp-vm", "hv-missing")
        }
        #expect(error?.errorCase == .operationFailed)

        // Closing the connection completes the recording promise with whatever
        // arrived, which must be the lookup and nothing else.
        try await manager.disconnect()
        let transactions = try await recorded.get()
        #expect(transactions.count == 1, "The update must not be sent, got \(transactions.count) transactions")
        #expect(try self.operations(of: transactions[0])[0]["op"] as? String == "select")
    }

    /// An update matching no row reports count 0, which is how a logical port
    /// with no Port_Binding — a port ovn-northd has not translated yet — comes
    /// back.
    @Test("Setting a chassis column on a missing port binding fails")
    func settingAChassisColumnOnMissingPortBindingFails() async throws {
        let (manager, _) = try await connectedManager(answering: [[["count": 0]]])

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.setPortBindingRequestedChassis(logicalPort: "lsp-vm", chassisNamed: nil)
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }
}

/// One of the two `Port_Binding` chassis columns: the manager method to call and
/// the column it must write. Both take the same path through
/// `setPortBindingChassisColumn`, so every wire-form assertion applies to both.
struct ChassisColumnWrite: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let column: String
    let apply: @Sendable (OVNManager, String, String?) async throws -> Void

    static let chassis = ChassisColumnWrite(
        testDescription: "setPortBindingChassis",
        column: "chassis",
        apply: { try await $0.setPortBindingChassis(logicalPort: $1, chassisNamed: $2) }
    )

    static let requestedChassis = ChassisColumnWrite(
        testDescription: "setPortBindingRequestedChassis",
        column: "requested_chassis",
        apply: { try await $0.setPortBindingRequestedChassis(logicalPort: $1, chassisNamed: $2) }
    )
}

/// Answers the `echo` handshake, then each `transact` with the next entry of
/// `results` — an already-formed JSON-RPC `result` array, so a test can script a
/// `select`'s rows and a later transaction's counts independently. Reusing the
/// last entry once they run out would hide an unexpected extra transaction, so a
/// transaction past the end is answered with an empty result instead.
///
/// Hands every recorded `transact` request back verbatim, once `results.count` of
/// them have arrived or the connection closes — verbatim because a parsed
/// `[String: Any]` is not `Sendable` and so cannot cross the promise.
///
/// Assumes each inbound read contains exactly one JSON-RPC object, which holds
/// for the sequential requests these tests issue.
final class OVSDBScriptedTransactHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let results: [[Any]]
    private let transactions: EventLoopPromise<[[UInt8]]>
    private var recorded: [[UInt8]] = []
    private var hasCompleted = false

    init(results: [[Any]], transactions: EventLoopPromise<[[UInt8]]>) {
        self.results = results
        self.transactions = transactions
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              let request = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
              let method = request["method"] as? String else {
            return
        }

        let result: Any
        switch method {
        case "echo":
            result = request["params"] ?? [Any]()
        case "transact":
            let index = recorded.count
            recorded.append(bytes)
            result = index < results.count ? results[index] : [Any]()
            if recorded.count >= results.count { complete(with: recorded) }
        default:
            result = [String: Any]()
        }

        let reply: [String: Any] = [
            "id": request["id"] ?? NSNull(),
            "result": result,
            "error": NSNull()
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: reply) else { return }
        var out = context.channel.allocator.buffer(capacity: data.count)
        out.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A test expecting *fewer* transactions than it scripted asserts on what
        // arrived by the time it disconnected, so completing here is the normal
        // path rather than a failure case.
        complete(with: recorded)
        context.fireChannelInactive()
    }

    private func complete(with transactions: [[UInt8]]) {
        guard !hasCompleted else { return }
        hasCompleted = true
        self.transactions.succeed(transactions)
    }
}
