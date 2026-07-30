import Foundation
import Testing
import NIO
import NIOPosix
@testable import SwiftOVN

/// One incremental membership change: the manager helper to call and the OVSDB
/// mutator it has to produce.
struct MembershipChange: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let mutator: String
    let apply: @Sendable (OVNManager, [String], String) async throws -> Void

    static let add = MembershipChange(
        testDescription: "addAddresses",
        mutator: "insert",
        apply: { try await $0.addAddresses($1, toAddressSet: $2) }
    )

    static let remove = MembershipChange(
        testDescription: "removeAddresses",
        mutator: "delete",
        apply: { try await $0.removeAddresses($1, fromAddressSet: $2) }
    )
}

/// Manager-level tests for the `Address_Set` membership helpers, driven against
/// a stub that answers `transact` and hands back the operations it was sent.
/// The point of `addAddresses`/`removeAddresses` is the wire form — one
/// `mutate` op, no read of the existing set — and that is invisible in the
/// return value, so it has to be asserted on what reaches the server.
///
/// A `final class` rather than a `struct` so the per-test event loop group can
/// be torn down in `deinit`.
@Suite("Address set membership")
final class AddressSetTests {

    private let group: MultiThreadedEventLoopGroup

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Asynchronously, and never `syncShutdownGracefully()` — see the note
        // on `MessageRoutingTests.deinit`. This also closes the test servers,
        // which is why none of them are closed explicitly.
        group.shutdownGracefully { _ in }
    }

    /// Brings up a stub answering each transaction with the next of `counts`,
    /// and a manager connected to it. The returned future yields the raw bytes
    /// of the *first* `transact` request the manager sends; `operations(of:)`
    /// unpacks them.
    private func connectedManager(
        answeringCounts counts: [Int]
    ) async throws -> (OVNManager, EventLoopFuture<[UInt8]>) {
        let recorded = group.next().makePromise(of: [UInt8].self)
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    OVSDBTransactStubHandler(counts: counts, firstTransaction: recorded)
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

    /// Unpacks a recorded `transact` request into its operations. The request is
    /// carried as raw bytes because a parsed `[String: Any]` is not `Sendable`
    /// and so cannot cross an `EventLoopPromise`.
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

    /// Unwraps a recorded transaction down to its single `[column, mutator,
    /// value]` mutation, checking everything about the shape on the way.
    private func singleMutation(of operations: [[String: Any]]) throws -> [Any] {
        // One op, and in particular no select: an incremental membership change
        // must not read-modify-write the whole `addresses` set.
        #expect(operations.count == 1, "Expected a lone mutate op, got \(operations)")
        let operation = try #require(operations.first)
        #expect(operation["op"] as? String == "mutate")
        #expect(operation["table"] as? String == "Address_Set")

        let condition = try #require(
            (operation["where"] as? [[Any]])?.first,
            "Expected one [column, function, value] condition"
        )
        #expect(condition.count == 3)
        #expect(condition[0] as? String == "name")
        #expect(condition[1] as? String == "==")
        #expect(condition[2] as? String == "web_tier")

        return try #require(
            (operation["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
    }

    @Test("A membership change sends one mutation on the addresses column",
          arguments: [MembershipChange.add, .remove])
    func membershipChangeSendsOneMutation(change: MembershipChange) async throws {
        let (manager, recorded) = try await connectedManager(answeringCounts: [1])

        try await change.apply(manager, ["10.0.0.1", "10.0.1.0/24"], "web_tier")

        let mutation = try singleMutation(of: try operations(of: try await recorded.get()))
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "addresses")
        #expect(mutation[1] as? String == change.mutator)
        // Plain strings in a tagged set, not ["uuid", ...] atoms: `addresses`
        // holds addresses, not references to other rows.
        let value = try #require(mutation[2] as? [Any], "Expected a [\"set\", [...]] value")
        #expect(value.count == 2)
        #expect(value[0] as? String == "set")
        #expect(value[1] as? [String] == ["10.0.0.1", "10.0.1.0/24"])

        try await manager.disconnect()
    }

    @Test("An empty membership change sends nothing at all")
    func emptyMembershipChangeSendsNothing() async throws {
        let (manager, recorded) = try await connectedManager(answeringCounts: [1])

        // Neither of these may reach the server: an empty mutation is a
        // pointless round trip, and ovsdb-server rejects an empty set for the
        // `insert`/`delete` mutators outright.
        try await manager.addAddresses([], toAddressSet: "web_tier")
        try await manager.removeAddresses([], fromAddressSet: "web_tier")

        // So the first transaction the server sees is this one, not either of
        // the calls above.
        try await manager.addAddresses(["10.0.0.1", "10.0.1.0/24"], toAddressSet: "web_tier")

        // The members, not an empty set, are what identifies the transaction as
        // the third call rather than the first.
        let mutation = try singleMutation(of: try operations(of: try await recorded.get()))
        #expect(mutation[1] as? String == "insert")
        #expect((mutation[2] as? [Any])?.last as? [String] == ["10.0.0.1", "10.0.1.0/24"])

        try await manager.disconnect()
    }

    @Test("A membership change on a missing address set fails",
          arguments: [MembershipChange.add, .remove])
    func membershipChangeOnMissingAddressSetFails(change: MembershipChange) async throws {
        // A mutate matching no row reports count 0 rather than failing, so the
        // manager is what has to turn that into an error.
        let (manager, _) = try await connectedManager(answeringCounts: [0])

        let error = await #expect(throws: OVNManagerError.self) {
            try await change.apply(manager, ["10.0.0.1"], "web_tier")
        }
        #expect(error?.errorCase == .operationFailed)

        try await manager.disconnect()
    }
}

/// Answers the `echo` handshake, then each `transact` with one `{"count": n}`
/// result per operation, taking `n` from `counts` in order and reusing the last
/// entry once they run out. Hands the first `transact` request back verbatim so
/// a test can assert on the exact wire form the manager produced — verbatim
/// because a parsed `[String: Any]` is not `Sendable` and so cannot cross the
/// promise.
///
/// Assumes each inbound read contains exactly one JSON-RPC object, which holds
/// for the sequential requests these tests issue.
final class OVSDBTransactStubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let counts: [Int]
    private let firstTransaction: EventLoopPromise<[UInt8]>
    private var transactionIndex = 0
    private var hasRecorded = false

    init(counts: [Int], firstTransaction: EventLoopPromise<[UInt8]>) {
        self.counts = counts
        self.firstTransaction = firstTransaction
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
            if !hasRecorded {
                hasRecorded = true
                firstTransaction.succeed(bytes)
            }
            // params is [database, op, op, ...] — RFC 7047 §4.1.3, so one
            // result object per op after the database name.
            let operationCount = ((request["params"] as? [Any])?.count ?? 1) - 1
            let count = counts[min(transactionIndex, counts.count - 1)]
            transactionIndex += 1
            result = (0..<max(operationCount, 0)).map { _ in ["count": count] }
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
        // A test whose transaction never arrives would otherwise leave the
        // promise uncompleted, hanging on `get()` instead of failing.
        if !hasRecorded {
            hasRecorded = true
            firstTransaction.fail(ChannelError.eof)
        }
        context.fireChannelInactive()
    }
}
