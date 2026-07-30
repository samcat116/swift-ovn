import Foundation
import Testing
import NIO
import NIOPosix
import Logging
@testable import SwiftOVN

/// End-to-end tests for the TCP transport: a minimal in-process JSON-RPC
/// server accepts a real TCP connection from the client and answers `echo`
/// and `list_dbs`, exercising the same pipeline used against a remote
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
        try? group.syncShutdownGracefully()
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

    @Test("Notifications subscribed after a disconnect are already finished")
    func notificationsSubscribedAfterDisconnectAreFinished() async throws {
        let server = try await startServer()
        let port = try #require(server.localAddress?.port)

        let connection = OVSDBSocketConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await connection.connect().get()
        try await connection.disconnect().get()

        // Subscribing once the connection is gone used to hand back a stream
        // nothing would ever finish, hanging the consumer.
        let stream = connection.notifications()
        let finished = await withTaskGroup(of: Bool.self) { taskGroup in
            taskGroup.addTask {
                for await _ in stream {}
                return true
            }
            taskGroup.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await taskGroup.next() ?? false
            taskGroup.cancelAll()
            return first
        }
        #expect(finished, "A stream created after disconnect must already be finished")

        // Reconnecting revives the hub, so later subscribers are live again.
        try await connection.connect().get()
        #expect(connection.isConnectionActive)
        try await connection.disconnect().get()
    }

    /// `send` writes the encoder's bytes straight into the channel's buffer
    /// instead of decoding them to a `String` and concatenating a newline, so
    /// this pins what actually reaches the wire: the encoded request, then the
    /// trailing newline.
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
        try await connection.connect().get()
        try await connection.send(
            JSONRPCRequest(method: "list_dbs", params: nil, id: .number(1))
        ).get()

        let bytes = try await recorded.futureResult.get()
        #expect(bytes.last == UInt8(ascii: "\n"))

        let request = try #require(
            JSONSerialization.jsonObject(with: Data(bytes.dropLast())) as? [String: Any]
        )
        #expect(request["method"] as? String == "list_dbs")
        #expect(request["id"] as? Int == 1)

        try await connection.disconnect().get()
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

/// Answers `echo` and `list_dbs` requests the way ovsdb-server would.
/// Assumes each inbound read contains exactly one JSON-RPC object, which
/// holds for the sequential requests these tests issue. Shared with
/// `TLSTransportTests`.
final class JSONRPCStubServerHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

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
        default:
            result = [String: Any]()
        }

        let reply: [String: Any] = [
            "id": request["id"] ?? NSNull(),
            "result": result,
            "error": NSNull()
        ]
        guard let replyData = try? JSONSerialization.data(withJSONObject: reply) else {
            return
        }
        var out = context.channel.allocator.buffer(capacity: replyData.count)
        out.writeBytes(replyData)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}
