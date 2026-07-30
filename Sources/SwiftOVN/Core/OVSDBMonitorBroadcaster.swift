#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Logging
import Synchronization

/// Fans one `OVSDBConnection`'s monitor pipeline out to the streams it handed
/// out — `monitorTableUpdates()` and, through it, `monitorUpdates()`.
///
/// It exists so that everything a monitor stream can be told arrives by *one*
/// path. `JSONRPCNotificationHub` already fans the transport's notifications
/// out, and those streams used to subscribe to it directly — but then a monitor
/// re-established after a reconnect had nowhere to put its reply: the reply is
/// the answer to a request, delivered to `OVSDBConnection`, while the live
/// updates that follow it come from the hub, and nothing orders the two. With a
/// single task draining the hub into this broadcaster, the connection can slot
/// that reply in ahead of the updates buffered behind it.
///
/// The subscriber table sits behind a `Mutex` for the same reason as the hub's:
/// `subscribe()` has to be synchronous, so a caller can be sure its stream is in
/// place before it issues the request that starts producing updates.
final class OVSDBMonitorBroadcaster: Sendable {
    /// What a subscriber can be told. Everything else — filtering by monitor id,
    /// turning a gap into a thrown error — is the stream's business.
    enum Event: Sendable {
        /// One notification's worth of row changes, or the reply of a monitor
        /// re-established after a reconnect (see `OVSDBTableUpdates.Origin`).
        case updates(OVSDBTableUpdates)
        /// Batches were discarded because this subscriber fell behind, so its
        /// view of the rows has a hole.
        case dropped(count: Int)
        /// The named monitor could not be re-established after a reconnect and
        /// has been forgotten, so nothing more will arrive for it. Sent instead
        /// of leaving a consumer waiting on a monitor that no longer exists.
        case interrupted(monitorId: String, reason: String)
    }

    private struct Subscriber {
        let continuation: AsyncStream<Event>.Continuation
        /// Events discarded because this subscriber's buffer was full, waiting
        /// for a slot to be reported in.
        var pendingDrops: Int = 0
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        /// Set by `finishAll()`. Without it a `subscribe()` after the pipeline
        /// has closed would hand back a stream nothing ever finishes, hanging
        /// the consumer's `for await` forever. Cleared by `reopen()`.
        var isClosed = false
    }

    private let bufferSize: Int
    private let logger: Logger
    private let state = Mutex(State())
    /// Serializes a whole `publish` against a whole `finishAll`.
    ///
    /// Both walk the subscriber table outside the `state` lock — they have to,
    /// because `yield`/`finish` can run `onTermination`, which takes it. Without
    /// this, `finishAll` could snapshot a lagging subscriber's `pendingDrops`
    /// while `publish` was between discarding a batch and recording it, then
    /// finish that subscriber's stream cleanly: the consumer would be told its
    /// view was complete when a batch had just been thrown away.
    ///
    /// Held across `yield`, which is safe: `yield` enqueues and resumes, it does
    /// not run consumer code, and `onTermination` takes only `state`.
    private let delivery = Mutex(())

    init(bufferSize: Int = OVSDBSocketConnection.notificationBufferSize, logger: Logger? = nil) {
        // A zero-length buffer would report the value just handed to `yield` as
        // the discarded one, which breaks the drop accounting below.
        self.bufferSize = max(1, bufferSize)
        self.logger = logger ?? Logger(label: "ovn-manager.monitor-pipeline")
    }

    func subscribe() -> AsyncStream<Event> {
        let id = UUID()
        // `.bufferingOldest`, unlike the hub's `.bufferingNewest`: the consumer
        // sees an unbroken run of batches followed by the report of the gap,
        // rather than a run with a silent hole in the middle of it.
        let (stream, continuation) = AsyncStream.makeStream(
            of: Event.self,
            bufferingPolicy: .bufferingOldest(bufferSize)
        )

        let isClosed = state.withLock { state -> Bool in
            guard !state.isClosed else { return true }
            state.subscribers[id] = Subscriber(continuation: continuation)
            return false
        }

        if isClosed {
            continuation.finish()
            return stream
        }

        // Set outside the lock: the callback takes the same non-recursive lock,
        // and `finish()` invokes it synchronously.
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        return stream
    }

    /// Publishes to every subscriber. Called from the connection's single
    /// pipeline task, so calls are serialized and the per-subscriber drop counts
    /// below stay consistent.
    func publish(_ event: Event) {
        delivery.withLock { _ in deliver(event) }
    }

    private func deliver(_ event: Event) {
        // Snapshot under the lock, then yield outside it: `yield` can finish a
        // stream, whose `onTermination` reaches back into this lock.
        let entries = state.withLock { Array($0.subscribers) }

        for (id, subscriber) in entries {
            var pending = subscriber.pendingDrops

            if pending > 0 {
                switch subscriber.continuation.yield(.dropped(count: pending)) {
                case .terminated:
                    continue
                case .enqueued:
                    pending = 0
                case .dropped:
                    // Still no room. The report waits for one; nothing is lost
                    // by delaying it, because the count only grows.
                    break
                @unknown default:
                    break
                }
            }

            if pending == 0 {
                switch subscriber.continuation.yield(event) {
                case .terminated:
                    continue
                case .dropped:
                    pending = 1
                    // Logged once per overflow episode rather than once per
                    // discarded batch, which under a sustained overflow would
                    // itself flood.
                    logger.warning("Monitor pipeline buffer full (\(bufferSize)); a consumer is not keeping up and row updates are being discarded")
                default:
                    break
                }
            } else {
                pending += 1
            }

            if pending != subscriber.pendingDrops {
                setPendingDrops(id, to: pending)
            }
        }
    }

    /// Finishes every subscription and refuses later ones, so a stream taken out
    /// after the connection is gone comes back finished instead of hanging.
    func finishAll() {
        delivery.withLock { _ in finishAllLocked() }
    }

    private func finishAllLocked() {
        let entries = state.withLock { state -> [Subscriber] in
            state.isClosed = true
            let entries = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return entries
        }

        for subscriber in entries {
            // Last chance to tell a lagging consumer that its view was
            // incomplete; after the finish below nothing more can be delivered.
            if subscriber.pendingDrops > 0 {
                subscriber.continuation.yield(.dropped(count: subscriber.pendingDrops))
            }
            subscriber.continuation.finish()
        }
    }

    /// Clears the closed flag so a later `connect()` can publish again. The
    /// broadcaster is created once per connection but each connect starts a
    /// fresh pipeline, so without this every subscription after the first
    /// disconnect would come back already finished.
    func reopen() {
        state.withLock { $0.isClosed = false }
    }

    private func setPendingDrops(_ id: UUID, to count: Int) {
        state.withLock { state in
            if var subscriber = state.subscribers[id] {
                subscriber.pendingDrops = max(0, count)
                state.subscribers[id] = subscriber
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
