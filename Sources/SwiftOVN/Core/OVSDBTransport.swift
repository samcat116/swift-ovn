import Foundation
import NIO

/// A bidirectional JSON-RPC transport to an OVSDB server.
///
/// `OVSDBSocketConnection` implements this over Unix domain sockets, TCP and
/// TLS; the protocol exists so `JSONRPCClient` can also run over a custom or
/// mock transport.
public protocol OVSDBTransport: Sendable {
    func connect() async throws
    func disconnect() async throws
    /// Sends a message that expects no reply (a JSON-RPC notification).
    ///
    /// `Sendable` is required because the message is handed to the channel's
    /// write side, and the decoded response is handed back out of it.
    func send<T: Codable & Sendable>(_ message: T) async throws
    /// Sends `request` and waits for the response carrying `id`.
    ///
    /// Sending and awaiting are one operation because the two cannot be
    /// separated safely: the response may already be on the wire before `send`
    /// returns, so an implementation must register interest in `id` *before* the
    /// request is written.
    func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response
    /// See `OVSDBSocketConnection.notifications()`: the returned stream must
    /// buffer from creation time, finish when the connection closes, and be
    /// already finished if the connection has closed.
    ///
    /// Deliberately synchronous, so a caller can be sure its subscription is in
    /// place before it issues the request that triggers the notifications.
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
    func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type
    ) async throws -> Response {
        return try await sendRequest(request, id: id, responseType: responseType, timeout: .seconds(30))
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
