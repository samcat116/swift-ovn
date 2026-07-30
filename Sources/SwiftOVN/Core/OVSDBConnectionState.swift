#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIOCore
import Synchronization

/// Where a connection is in its lifecycle, including the states that only exist
/// because reconnection does.
///
/// `isConnectionActive` answers one question — is a session up right now — and
/// with automatic reconnection that answer flickers: it goes false for the
/// duration of an election and true again afterwards, and nothing in a boolean
/// says which of those is happening. This is the observable version, so a caller
/// can tell "reconnecting, third attempt, next try in 4s" from "given up".
public enum OVSDBConnectionState: Sendable, Equatable {
    /// No session and none attempted: `connect()` has not been called yet.
    case idle

    /// A connection to `endpoint` is being established. `attempt` counts
    /// consecutive failed passes over the remote list and is 1 for the first
    /// try after a successful session.
    ///
    /// `endpoint` is nil only for a custom `OVSDBTransport` that does not track
    /// remotes (see the default implementations on the protocol).
    case connecting(endpoint: OVSDBEndpoint?, attempt: Int)

    /// A session is up, and — when leader-only mode is on — the remote reported
    /// that it is the leader of the database this connection serves.
    case connected(endpoint: OVSDBEndpoint?)

    /// Every remote failed; the next pass starts in `retryIn`.
    case waiting(retryIn: TimeAmount, attempt: Int)

    /// No session, and no further attempt will be made: `disconnect()` was
    /// called, reconnection is disabled, or `maximumAttempts` was reached.
    /// `reason` says which.
    case closed(reason: String?)

    /// Whether a session is up. Matches `isConnectionActive` at the moment the
    /// state was published.
    public var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    /// The remote this state refers to, when it refers to one.
    public var endpoint: OVSDBEndpoint? {
        switch self {
        case .connecting(let endpoint, _), .connected(let endpoint):
            return endpoint
        case .idle, .waiting, .closed:
            return nil
        }
    }
}

extension OVSDBConnectionState: CustomStringConvertible {
    public var description: String {
        switch self {
        case .idle:
            return "idle"
        case .connecting(let endpoint, let attempt):
            return "connecting to \(endpoint?.description ?? "remote") (attempt \(attempt))"
        case .connected(let endpoint):
            return "connected to \(endpoint?.description ?? "remote")"
        case .waiting(let retryIn, let attempt):
            return "waiting \(retryIn.nanoseconds / 1_000_000)ms before attempt \(attempt + 1)"
        case .closed(let reason):
            return reason.map { "closed: \($0)" } ?? "closed"
        }
    }
}

/// Broadcasts `OVSDBConnectionState` transitions and remembers the latest one.
///
/// Deliberately shaped like `JSONRPCNotificationHub` — a `Mutex` rather than
/// actor state, so `subscribe()` and `current` are synchronous — but with two
/// differences that matter for state rather than data:
///
/// - a new subscriber is handed the current state immediately, so it does not
///   have to wait for the next transition to learn where things stand, and
/// - the per-subscriber buffer keeps the *newest* states. A consumer that falls
///   behind loses intermediate transitions, never the latest one, so it can
///   never be left believing a stale state is current.
final class OVSDBConnectionStateHub: Sendable {
    /// Enough to hold a full connect/backoff cycle for a three-server cluster
    /// without discarding anything for a consumer that is merely between
    /// iterations.
    static let bufferSize = 32

    private struct State {
        var current: OVSDBConnectionState = .idle
        var subscribers: [UUID: AsyncStream<OVSDBConnectionState>.Continuation] = [:]
        var isFinished = false
    }

    private let state = Mutex(State())

    var current: OVSDBConnectionState {
        return state.withLock { $0.current }
    }

    func subscribe() -> AsyncStream<OVSDBConnectionState> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: OVSDBConnectionState.self,
            bufferingPolicy: .bufferingNewest(Self.bufferSize)
        )

        let outcome = state.withLock { state -> (current: OVSDBConnectionState, isFinished: Bool) in
            if !state.isFinished {
                state.subscribers[id] = continuation
            }
            return (state.current, state.isFinished)
        }

        // Outside the lock: `yield`/`finish` can run `onTermination`, which takes
        // the same non-recursive lock.
        continuation.yield(outcome.current)
        if outcome.isFinished {
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.remove(id)
        }
        return stream
    }

    func publish(_ newState: OVSDBConnectionState) {
        let continuations = state.withLock { state -> [AsyncStream<OVSDBConnectionState>.Continuation] in
            guard !state.isFinished, state.current != newState else { return [] }
            state.current = newState
            return Array(state.subscribers.values)
        }
        for continuation in continuations {
            continuation.yield(newState)
        }
    }

    /// Publishes a final state and finishes every stream. Called when the
    /// connection object goes away, so a consumer's `for await` ends instead of
    /// hanging on a hub nothing will ever publish to again.
    func finish(reason: String?) {
        let continuations = state.withLock { state -> [AsyncStream<OVSDBConnectionState>.Continuation] in
            guard !state.isFinished else { return [] }
            state.isFinished = true
            state.current = .closed(reason: reason)
            let continuations = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.yield(.closed(reason: reason))
            continuation.finish()
        }
    }

    private func remove(_ id: UUID) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
