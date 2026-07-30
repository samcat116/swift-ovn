import Logging
import Synchronization

/// Fans server-initiated notifications out to any number of subscribers.
///
/// Each subscriber gets its own stream, so a `notifications()` call is valid
/// before `connect()` and before the request that triggers the notifications.
/// That guarantee is why the subscriber table lives behind a `Mutex` rather than
/// in `OVSDBConnectionCore`: actor isolation would force `subscribe()` to be
/// `async`, and a caller could then no longer be sure its subscription was in
/// place before it issued a `monitor`. `Mutex` keeps `Sendable` compiler-checked
/// (unlike the `NSLock` + `@unchecked Sendable` this replaces) and the lock is
/// only ever held for a dictionary walk.
final class JSONRPCNotificationHub: Sendable {
    /// How many notifications may queue up for one subscriber before its stream
    /// is terminated.
    private let bufferSize: Int
    private let logger: Logger
    private let state: Mutex<State>

    private struct State {
        var subscribers: [Int: AsyncThrowingStream<JSONRPCNotification, Error>.Continuation] = [:]
        var nextSubscriberID = 0
        /// Set when the connection ends, so a subscription taken out afterwards
        /// is handed back already finished instead of hanging forever.
        var isClosed = false
    }

    init(bufferSize: Int, logger: Logger) {
        self.bufferSize = bufferSize
        self.logger = logger
        self.state = Mutex(State())
    }

    /// Returns a stream that buffers up to `bufferSize` notifications.
    ///
    /// The buffer is bounded on purpose: `Logical_Flow` monitor updates on an
    /// OVN Southbound database are large and frequent, so an unbounded buffer
    /// turns a briefly stalled consumer into process-wide memory exhaustion. A
    /// consumer that falls further behind than the buffer has its stream
    /// terminated with `OVNManagerError.notificationsDropped` rather than
    /// silently losing an update — a lost `update` would leave its view of the
    /// database permanently wrong, so it has to know to re-subscribe and
    /// re-issue its monitor.
    func subscribe() -> AsyncThrowingStream<JSONRPCNotification, Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(
            of: JSONRPCNotification.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )

        let isClosed = state.withLock { state -> Bool in
            guard !state.isClosed else { return true }
            let id = state.nextSubscriberID
            state.nextSubscriberID += 1
            state.subscribers[id] = continuation
            return false
        }

        if isClosed {
            continuation.finish()
        }
        return stream
    }

    func publish(_ notification: JSONRPCNotification) {
        state.withLock { state in
            // Iterating the dictionary copy leaves mutation of `subscribers`
            // inside the loop safe.
            for (id, continuation) in state.subscribers {
                switch continuation.yield(notification) {
                case .enqueued:
                    continue
                case .dropped:
                    logger.error(
                        """
                        A notifications() consumer fell more than \(bufferSize) notifications \
                        behind; terminating its stream
                        """
                    )
                    state.subscribers.removeValue(forKey: id)
                    continuation.finish(throwing: OVNManagerError.notificationsDropped(bufferSize: bufferSize))
                case .terminated:
                    // The consumer dropped its stream. Pruning here rather than
                    // from `onTermination` keeps the callback from re-entering
                    // this non-recursive lock.
                    state.subscribers.removeValue(forKey: id)
                @unknown default:
                    continue
                }
            }
        }
    }

    /// Ends every subscription and refuses new ones until `reopen()`.
    ///
    /// `error` is nil for a deliberate disconnect, in which case the streams
    /// finish normally; a connection failure is passed through so consumers see
    /// why their monitor stopped.
    func close(throwing error: Error?) {
        let continuations = state.withLock { state -> [AsyncThrowingStream<JSONRPCNotification, Error>.Continuation] in
            state.isClosed = true
            let continuations = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return continuations
        }
        for continuation in continuations {
            continuation.finish(throwing: error)
        }
    }

    /// Accepts subscriptions again, for a connection that has been
    /// re-established. Subscribers from before the drop are not restored — they
    /// were finished, and have to subscribe again.
    func reopen() {
        state.withLock { $0.isClosed = false }
    }
}
