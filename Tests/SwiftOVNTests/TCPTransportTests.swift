import Foundation
import Testing
import NIO
import NIOPosix
import Logging
@testable import SwiftOVN

/// End-to-end tests for the TCP transport: a minimal in-process JSON-RPC server
/// accepts a real TCP connection from the client, answers requests and pushes
/// monitor notifications, exercising the same pipeline used against a remote
/// ovsdb-server (`tcp:<host>:6641/6642`).
///
/// A `final class` rather than a `struct` so the per-test event loop group can
/// be torn down in `deinit`, the way `tearDown` used to.
@Suite("TCP transport")
final class TCPTransportTests {

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

    private func startServer() async throws -> Channel {
        return try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(JSONRPCStubServerHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    @Test("A JSON-RPC client talks to a server over TCP")
    func jsonRPCClientOverTCP() async throws {
        // No explicit server cleanup: deinit's group shutdown closes it.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await client.connect()
        #expect(client.isConnected)

        let echoed = try await client.echo()
        #expect(echoed == ["echo"])

        let databases = try await client.listDatabases()
        #expect(databases == ["OVN_Northbound", "OVN_Southbound"])

        try await client.disconnect()
        #expect(!client.isConnected)
    }

    @Test("An OVSDB connection handshakes over TCP")
    func ovsdbConnectionOverTCP() async throws {
        // OVSDBConnection.connect() performs the initial echo handshake, so a
        // successful connect proves the full request/response path over TCP.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let connection = OVSDBConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await connection.connect()
        let isConnected = await connection.isConnected
        #expect(isConnected)
        try await connection.disconnect()
    }

    @Test("Monitor updates arrive over the socket")
    func monitorUpdatesArriveOverTheSocket() async throws {
        // The stub answers `monitor` and then pushes an `update` notification the
        // way ovsdb-server does, so this covers the whole inbound path over a
        // real socket: framing, the routing scan, and the notification hub.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await client.connect()

        // Subscribing before the request is what makes the update unmissable.
        let updates = client.monitorUpdates()
        _ = try await client.monitor(database: "OVN_Northbound", monitorId: "mon-1", requests: [:])

        var iterator = updates.makeAsyncIterator()
        let received = try #require(try await iterator.next())
        #expect(received.0 == "mon-1")
        let tables = try #require(
            received.1.objectValue,
            "Expected a Logical_Switch table update, got \(received.1)"
        )
        let rows = try #require(tables["Logical_Switch"]?.objectValue)
        #expect(rows.count == 1)

        try await client.disconnect()
    }

    @Test("A large response split across many reads is reassembled")
    func largeResponseSplitAcrossManyReadsIsReassembled() async throws {
        // A reply far larger than one socket read: the framer has to accumulate
        // it across reads and the decoder has to see exactly one frame.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await client.connect()

        let schema = try await client.getSchema(database: "OVN_Southbound")
        let blob = try #require(
            schema.objectValue?["blob"]?.stringValue,
            "Expected the large schema stub, got \(schema)"
        )
        #expect(blob.count == JSONRPCStubServerHandler.largeBlobLength)

        try await client.disconnect()
    }

    @Test("Reconnecting after a disconnect works")
    func reconnectAfterDisconnect() async throws {
        // connect() has to be usable again after a disconnect: the session, the
        // read loop and the notification hub are all re-established.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await client.connect()
        let echoed = try await client.echo()
        #expect(echoed == ["echo"])
        try await client.disconnect()
        #expect(!client.isConnected)

        try await client.connect()
        #expect(client.isConnected)
        let echoedAgain = try await client.echo()
        #expect(echoedAgain == ["echo"])

        // A stream taken out after the reconnect must be live, not a leftover
        // finished one from the closed session.
        let updates = client.monitorUpdates()
        _ = try await client.monitor(database: "OVN_Northbound", monitorId: "mon-2", requests: [:])
        var iterator = updates.makeAsyncIterator()
        let update = try #require(try await iterator.next())
        #expect(update.0 == "mon-2")

        try await client.disconnect()
    }

    @Test("Concurrent connects share one attempt")
    func concurrentConnectsShareOneAttempt() async throws {
        // Each concurrent connect() used to bootstrap its own channel and leak
        // all but the last; they now share one in-flight attempt.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let connection = OVSDBSocketConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try await connection.connect() }
            }
            try await group.waitForAll()
        }
        #expect(connection.isConnectionActive)

        let client = JSONRPCClient(transport: connection)
        let echoed = try await client.echo()
        #expect(echoed == ["echo"])

        await connection.disconnect()
        #expect(!connection.isConnectionActive)
    }

    @Test("Notifications subscribed after a disconnect are already finished")
    func notificationsSubscribedAfterDisconnectAreFinished() async throws {
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let connection = OVSDBSocketConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await connection.connect()
        await connection.disconnect()

        // Subscribing once the connection is gone used to hand back a stream
        // nothing would ever finish, hanging the consumer.
        let stream = connection.notifications()
        let finished = await withTaskGroup(of: Bool.self) { taskGroup in
            taskGroup.addTask {
                for await _ in stream {}
                return true
            }
            taskGroup.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false
            }
            let first = await taskGroup.next() ?? false
            taskGroup.cancelAll()
            return first
        }
        #expect(finished, "A stream created after disconnect must already be finished")

        // Reconnecting revives the hub, so later subscribers are live again.
        try await connection.connect()
        #expect(connection.isConnectionActive)
        await connection.disconnect()
    }

    /// `send` writes the encoder's bytes straight into a `ByteBuffer` instead of
    /// decoding them to a `String` and concatenating a newline, so this pins what
    /// actually reaches the wire: the encoded request, then the trailing newline.
    @Test("send writes the encoded request followed by a newline")
    func sendWritesTheEncodedRequestFollowedByANewline() async throws {
        let recorded = group.next().makePromise(of: [UInt8].self)
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawRequestRecordingHandler(recorded: recorded))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(server.localAddress?.port)

        let connection = OVSDBSocketConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await connection.connect()
        try await connection.send(
            JSONRPCRequest(method: "list_dbs", params: nil, id: .number(1))
        )

        let bytes = try await recorded.futureResult.get()
        #expect(bytes.last == UInt8(ascii: "\n"))

        let request = try #require(
            JSONSerialization.jsonObject(with: Data(bytes.dropLast())) as? [String: Any]
        )
        #expect(request["method"] as? String == "list_dbs")
        #expect(request["id"] as? Int == 1)

        await connection.disconnect()
    }

    @Test("Connecting fails when nothing is listening")
    func connectFailsWhenNothingIsListening() async throws {
        // Bind and immediately close to obtain a port with no listener.
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)
        try await server.close()

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        let error = await #expect(throws: OVNManagerError.self) {
            try await client.connect()
        }
        #expect(error?.errorCase == .connectionFailed)
    }
}

/// Records the raw bytes of one client request verbatim, so a test can assert
/// on the exact wire form rather than on whatever a JSON parser tolerates.
final class RawRequestRecordingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let recorded: EventLoopPromise<[UInt8]>
    private var accumulated: [UInt8] = []
    private var isRecorded = false

    init(recorded: EventLoopPromise<[UInt8]>) {
        self.recorded = recorded
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard !isRecorded, let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return
        }
        // One write is not guaranteed to arrive as one read, so accumulate
        // until the request's terminating newline shows up.
        accumulated.append(contentsOf: bytes)
        guard accumulated.last == UInt8(ascii: "\n") else { return }
        isRecorded = true
        recorded.succeed(accumulated)
    }
}

/// Answers `echo`, `list_dbs`, `get_schema` and `monitor` requests the way
/// ovsdb-server would, including the `update` notification a monitor triggers.
/// Assumes each inbound read contains exactly one JSON-RPC object, which
/// holds for the sequential requests these tests issue. Shared with
/// `TLSTransportTests`.
final class JSONRPCStubServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// Big enough that the reply cannot arrive in a single socket read.
    static let largeBlobLength = 512 * 1024

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
        case "list_dbs":
            result = ["OVN_Northbound", "OVN_Southbound"]
        case "get_schema":
            result = ["blob": String(repeating: "a", count: Self.largeBlobLength)]
        default:
            result = [String: Any]()
        }

        let reply: [String: Any] = [
            "id": request["id"] ?? NSNull(),
            "result": result,
            "error": NSNull()
        ]
        write(reply, context: context)

        // RFC 7047 §4.1.5: the monitor reply is followed by `update`
        // notifications as rows change. One is enough to prove the path.
        if method == "monitor", let monitorId = (request["params"] as? [Any])?.dropFirst().first {
            let update: [String: Any] = [
                "id": NSNull(),
                "method": "update",
                "params": [
                    monitorId,
                    ["Logical_Switch": ["3f2e-uuid": ["new": ["name": "ls0"]]]]
                ]
            ]
            write(update, context: context)
        }
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
