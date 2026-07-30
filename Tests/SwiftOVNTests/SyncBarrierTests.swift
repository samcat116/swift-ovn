import Foundation
import Testing
import NIO
import NIOPosix
import Logging
import Synchronization
@testable import SwiftOVN

/// The `nb_cfg`/`sb_cfg`/`hv_cfg` barrier, driven end to end against an
/// in-process stub that answers `transact` and `monitor` the way ovsdb-server
/// does. The interesting behaviour is not in any single request but in how they
/// are sequenced — increment, monitor, then wait for a counter to catch up —
/// so it is exercised over a real socket rather than asserted piecewise.
///
/// A `final class` rather than a `struct` so the per-test event loop group can
/// be torn down in `deinit`, and never with `syncShutdownGracefully()` — see the
/// note on `MessageRoutingTests.deinit`.
@Suite("OVN sync barrier")
final class SyncBarrierTests {

    private let group: MultiThreadedEventLoopGroup

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        group.shutdownGracefully { _ in }
    }

    /// Starts a stub and returns a manager connected to it, plus the stub
    /// itself so a test can see what the manager asked for.
    private func makeManager(
        startingNBCfg: Int,
        monitorInitial: Int,
        pushedValues: [Int] = []
    ) async throws -> (OVNManager, NBGlobalStubServerHandler) {
        let handler = NBGlobalStubServerHandler(
            startingNBCfg: startingNBCfg,
            monitorInitial: monitorInitial,
            pushedValues: pushedValues
        )
        // No explicit server cleanup: deinit's group shutdown closes it.
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(handler)
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
        return (manager, handler)
    }

    @Test("Incrementing nb_cfg returns the value the counter reached")
    func incrementNBCfgReturnsTheNewValue() async throws {
        let (manager, handler) = try await makeManager(startingNBCfg: 41, monitorInitial: 0)

        #expect(try await manager.incrementNBCfg() == 42)
        #expect(try await manager.incrementNBCfg() == 43)
        // The value has to come from the select the increment carries with it,
        // not from a mutate result (which only reports a row count).
        #expect(handler.selectedColumns.withLock { $0 } == ["nb_cfg", "nb_cfg"])

        try await manager.disconnect()
    }

    /// The race the monitor's initial update exists to cover: northd may have
    /// already passed the target by the time the monitor is up, and then no
    /// further update is coming.
    @Test("A counter already past the target returns without waiting for an update")
    func counterAlreadyPastTheTargetReturnsImmediately() async throws {
        let (manager, handler) = try await makeManager(startingNBCfg: 4, monitorInitial: 7)

        let reached = try await manager.waitForNorthd(timeout: .seconds(5))

        // 7 >= the target of 5, so the initial update settles it.
        #expect(reached == 7)
        #expect(handler.monitoredColumns.withLock { $0 } == ["sb_cfg"])

        try await manager.disconnect()
    }

    @Test("waitForNorthd returns once sb_cfg catches up")
    func waitForNorthdReturnsOnceSBCfgCatchesUp() async throws {
        // The monitor's initial value is behind the target, so the wait can only
        // finish on the pushed update. The intermediate value must not satisfy
        // it: 1 < the target of 2.
        let (manager, handler) = try await makeManager(
            startingNBCfg: 1,
            monitorInitial: 0,
            pushedValues: [1, 2]
        )

        let reached = try await manager.waitForNorthd(timeout: .seconds(5))

        #expect(reached == 2)
        #expect(handler.monitoredColumns.withLock { $0 } == ["sb_cfg"])

        try await manager.disconnect()
    }

    @Test("waitForHypervisors waits on hv_cfg")
    func waitForHypervisorsWaitsOnHVCfg() async throws {
        let (manager, handler) = try await makeManager(
            startingNBCfg: 9,
            monitorInitial: 9,
            pushedValues: [10]
        )

        let reached = try await manager.waitForHypervisors(timeout: .seconds(5))

        #expect(reached == 10)
        // The whole point of the hv variant: a barrier that waits on sb_cfg
        // would return before the hypervisors had the flows.
        #expect(handler.monitoredColumns.withLock { $0 } == ["hv_cfg"])

        try await manager.disconnect()
    }

    /// A chassis that is down never advances `hv_cfg`, so no update ever
    /// arrives — the wait has to end on its own rather than hang the caller.
    @Test("A counter that never catches up times out")
    func counterThatNeverCatchesUpTimesOut() async throws {
        let (manager, _) = try await makeManager(startingNBCfg: 0, monitorInitial: 0)

        let error = await #expect(throws: OVNManagerError.self) {
            try await manager.waitForHypervisors(timeout: .milliseconds(200))
        }
        #expect(error?.errorCase == .timeoutError)

        // The connection survives an expired wait: the monitor is cancelled and
        // nothing else is left pending.
        #expect(try await manager.incrementNBCfg() == 2)

        try await manager.disconnect()
    }

    /// `NB_Global` exists only in the northbound database, and the barrier is
    /// meaningless without it. Rejected before anything is sent, so no
    /// connection is needed.
    @Test("The barrier operations reject a southbound manager")
    func barrierOperationsRejectASouthboundManager() async throws {
        let manager = OVNManager(
            endpoint: .tcp(host: "127.0.0.1", port: 1),
            database: OVNDatabase.southbound,
            eventLoopGroup: group
        )

        for operation in ["getNBGlobal", "incrementNBCfg", "waitForNorthd", "options"] {
            let error = await #expect(throws: OVNManagerError.self) {
                switch operation {
                case "getNBGlobal": _ = try await manager.getNBGlobal()
                case "incrementNBCfg": _ = try await manager.incrementNBCfg()
                case "waitForNorthd": _ = try await manager.waitForNorthd(timeout: .seconds(1))
                default: try await manager.updateNBGlobalOptions(["mac_prefix": "0a:5c:1f"])
                }
            }
            #expect(error?.errorCase == .operationFailed, "\(operation) must be refused")
        }
    }

    @Test("Reading SB_Global requires the southbound database")
    func readingSBGlobalRequiresTheSouthboundDatabase() async throws {
        let manager = OVNManager(
            endpoint: .tcp(host: "127.0.0.1", port: 1),
            database: OVNDatabase.northbound,
            eventLoopGroup: group
        )

        let error = await #expect(throws: OVNManagerError.self) {
            _ = try await manager.getSBGlobal()
        }
        #expect(error?.errorCase == .operationFailed)
    }
}

/// Answers the requests a barrier makes: `echo` for the handshake, the
/// increment `transact` (mutate + select, replying with the counter's new
/// value), and `monitor` — whose reply carries the initial row, followed by an
/// `update` notification per configured value, exactly as ovsdb-server pushes
/// them as northd and the hypervisors catch up.
///
/// Assumes each inbound read holds one JSON-RPC object, which holds for the
/// sequential requests these tests issue.
final class NBGlobalStubServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private static let rowUUID = "8c5d9b1e-4f3a-4d2b-9e7c-0a1b2c3d4e5f"

    private let monitorInitial: Int
    private let pushedValues: [Int]
    /// Only ever touched from the channel's event loop.
    private var nbCfg: Int

    /// The columns the manager monitored, and the columns its transactions
    /// selected, in order. Read from the test's task, hence the lock.
    let monitoredColumns = Mutex<[String]>([])
    let selectedColumns = Mutex<[String]>([])

    init(startingNBCfg: Int, monitorInitial: Int, pushedValues: [Int]) {
        self.nbCfg = startingNBCfg
        self.monitorInitial = monitorInitial
        self.pushedValues = pushedValues
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes),
              let request = (try? JSONSerialization.jsonObject(with: Data(bytes))) as? [String: Any],
              let method = request["method"] as? String else {
            return
        }
        let params = request["params"] as? [Any]

        let result: Any
        switch method {
        case "echo":
            result = request["params"] ?? [Any]()
        case "transact":
            result = transactResult(params: params)
        case "monitor":
            result = monitorResult(params: params)
        default:
            result = [String: Any]()
        }

        write(["id": request["id"] ?? NSNull(), "result": result, "error": NSNull()], context: context)

        if method == "monitor", let monitorId = params?.dropFirst().first {
            for value in pushedValues {
                write(update(monitorId: monitorId, column: lastMonitoredColumn, value: value), context: context)
            }
        }
    }

    /// The increment's `[mutate, select]`: one row matched, and the select
    /// carries the value the counter reached — the select happens after the
    /// mutate inside the same transaction, so it sees the new value.
    private func transactResult(params: [Any]?) -> Any {
        let operations = params?.dropFirst().compactMap { $0 as? [String: Any] } ?? []

        var results: [Any] = []
        for operation in operations {
            switch operation["op"] as? String {
            case "mutate":
                if let mutation = (operation["mutations"] as? [[Any]])?.first,
                   mutation.first as? String == "nb_cfg" {
                    nbCfg += 1
                }
                results.append(["count": 1])
            case "select":
                let columns = operation["columns"] as? [String] ?? []
                selectedColumns.withLock { $0.append(contentsOf: columns) }
                results.append(["rows": [["nb_cfg": nbCfg]]])
            default:
                results.append([String: Any]())
            }
        }
        return results
    }

    /// The monitor reply: the requested table's current rows, in the same
    /// `{"new": {...}}` shape an insert update uses (RFC 7047 §4.1.5).
    private func monitorResult(params: [Any]?) -> Any {
        let requests = params?.dropFirst(2).first as? [String: Any]
        let columns = (requests?["NB_Global"] as? [String: Any])?["columns"] as? [String] ?? []
        monitoredColumns.withLock { $0.append(contentsOf: columns) }

        return ["NB_Global": [Self.rowUUID: ["new": [lastMonitoredColumn: monitorInitial]]]]
    }

    private var lastMonitoredColumn: String {
        monitoredColumns.withLock { $0.last } ?? "sb_cfg"
    }

    private func update(monitorId: Any, column: String, value: Int) -> [String: Any] {
        return [
            "id": NSNull(),
            "method": "update",
            "params": [monitorId, ["NB_Global": [Self.rowUUID: ["new": [column: value]]]]]
        ]
    }

    private func write(_ message: [String: Any], context: ChannelHandlerContext) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return
        }
        var out = context.channel.allocator.buffer(capacity: data.count)
        out.writeBytes(data)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}
