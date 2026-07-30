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
    /// See `OVSDBSocketConnection.connectionState`: where the transport is in
    /// its lifecycle, which with automatic reconnection says more than
    /// `isConnectionActive` can.
    ///
    /// The default implementation derives what it can from
    /// `isConnectionActive`, so a transport that does not reconnect (or does not
    /// track remotes) needs no extra code.
    var connectionState: OVSDBConnectionState { get }
    /// See `OVSDBSocketConnection.connectionStates()`: the transitions of
    /// `connectionState`, starting with the current value.
    ///
    /// The default implementation reports the current state and finishes, which
    /// is all a transport without a lifecycle of its own has to say.
    func connectionStates() -> AsyncStream<OVSDBConnectionState>
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

    var connectionState: OVSDBConnectionState {
        // No remote to name and no reconnect cycle to report on: a transport
        // that wants either implements this itself.
        return isConnectionActive ? .connected(endpoint: nil) : .closed(reason: nil)
    }

    func connectionStates() -> AsyncStream<OVSDBConnectionState> {
        let state = connectionState
        return AsyncStream { continuation in
            continuation.yield(state)
            continuation.finish()
        }
    }
}
