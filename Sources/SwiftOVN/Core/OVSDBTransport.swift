import Foundation
import NIO

/// A bidirectional JSON-RPC transport to an OVSDB server.
///
/// `OVSDBSocketConnection` implements this over Unix domain sockets, TCP and
/// TLS; the protocol exists so `JSONRPCClient` can also run over a custom or
/// mock transport.
public protocol OVSDBTransport: Sendable {
    func connect() -> EventLoopFuture<Void>
    func disconnect() -> EventLoopFuture<Void>
    func send<T: Codable>(_ message: T) -> EventLoopFuture<Void>
    func receive<T: Codable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount) -> EventLoopFuture<T>
    /// See `OVSDBSocketConnection.notifications()`: the returned stream must
    /// buffer from creation time and finish when the connection closes.
    func notifications() -> AsyncStream<JSONRPCNotification>
    var isConnectionActive: Bool { get }
}

public extension OVSDBTransport {
    func receive<T: Codable>(as type: T.Type, requestId: JSONRPCIdentifier) -> EventLoopFuture<T> {
        return receive(as: type, requestId: requestId, timeout: .seconds(30))
    }
}
