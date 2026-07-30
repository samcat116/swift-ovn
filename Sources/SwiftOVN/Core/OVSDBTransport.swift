#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO

/// A bidirectional JSON-RPC transport to an OVSDB server.
///
/// `OVSDBSocketConnection` implements this over Unix domain sockets, TCP and
/// TLS; the protocol exists so `JSONRPCClient` can also run over a custom or
/// mock transport.
public protocol OVSDBTransport: Sendable {
    func connect() -> EventLoopFuture<Void>
    func disconnect() -> EventLoopFuture<Void>
    /// `Sendable` is required because the message is handed to the channel's
    /// event loop, and the decoded response is handed back out of it.
    func send<T: Codable & Sendable>(_ message: T) -> EventLoopFuture<Void>
    func receive<T: Codable & Sendable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount) -> EventLoopFuture<T>
    /// See `OVSDBSocketConnection.notifications()`: the returned stream must
    /// buffer from creation time and finish when the connection closes.
    func notifications() -> AsyncStream<JSONRPCNotification>
    /// See `OVSDBSocketConnection.notificationEvents()`: as `notifications()`,
    /// but reporting notifications discarded because the consumer fell behind.
    ///
    /// The default implementation wraps `notifications()` and therefore never
    /// reports a gap; a transport that bounds its buffering should implement
    /// this directly so consumers can tell that their view is incomplete.
    func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent>
    var isConnectionActive: Bool { get }
}

public extension OVSDBTransport {
    func receive<T: Codable & Sendable>(as type: T.Type, requestId: JSONRPCIdentifier) -> EventLoopFuture<T> {
        return receive(as: type, requestId: requestId, timeout: .seconds(30))
    }

    func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent> {
        let notifications = notifications()
        return AsyncStream { continuation in
            let task = Task {
                for await notification in notifications {
                    continuation.yield(.notification(notification))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
