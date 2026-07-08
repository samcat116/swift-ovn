import XCTest
import NIO
import NIOPosix
import Logging
@testable import SwiftOVN

/// End-to-end tests for the TCP transport: a minimal in-process JSON-RPC
/// server accepts a real TCP connection from the client and answers `echo`
/// and `list_dbs`, exercising the same pipeline used against a remote
/// ovsdb-server (`tcp:<host>:6641/6642`).
final class TCPTransportTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
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

    func testJSONRPCClientOverTCP() async throws {
        let server = try await startServer()
        defer { try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await client.connect()
        XCTAssertTrue(client.isConnected)

        let echoed = try await client.echo()
        XCTAssertEqual(echoed, ["echo"])

        let databases = try await client.listDatabases()
        XCTAssertEqual(databases, ["OVN_Northbound", "OVN_Southbound"])

        try await client.disconnect()
        XCTAssertFalse(client.isConnected)
    }

    func testOVSDBConnectionOverTCP() async throws {
        // OVSDBConnection.connect() performs the initial echo handshake, so a
        // successful connect proves the full request/response path over TCP.
        let server = try await startServer()
        defer { try? server.close().wait() }
        let port = try XCTUnwrap(server.localAddress?.port)

        let connection = OVSDBConnection(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        try await connection.connect()
        let isConnected = await connection.isConnected
        XCTAssertTrue(isConnected)
        try await connection.disconnect()
    }

    func testConnectFailsWhenNothingIsListening() async throws {
        // Bind and immediately close to obtain a port with no listener.
        let server = try await startServer()
        let port = try XCTUnwrap(server.localAddress?.port)
        try await server.close()

        let client = JSONRPCClient(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            eventLoopGroup: group
        )
        do {
            try await client.connect()
            XCTFail("Expected connection to fail")
        } catch {
            guard case OVNManagerError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
    }
}

/// Answers `echo` and `list_dbs` requests the way ovsdb-server would.
/// Assumes each inbound read contains exactly one JSON-RPC object, which
/// holds for the sequential requests these tests issue.
private final class JSONRPCStubServerHandler: ChannelInboundHandler, @unchecked Sendable {
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
