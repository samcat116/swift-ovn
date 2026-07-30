#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Logging
import Synchronization

/// Fans server-initiated notifications out to any number of subscribers.
///
/// Each subscriber gets its own `AsyncStream` buffering up to `bufferSize`
/// notifications, so notifications arriving while the consumer is between
/// iterations are still delivered. The buffer is bounded on purpose: an
/// unbounded one lets a single stalled consumer grow the process without limit
/// (Southbound `Logical_Flow` updates are both large and frequent). When it
/// overflows the oldest notifications are discarded and the subscriber is sent
/// a `.dropped(count:)` event so the gap is visible rather than silent.
///
/// Outlives the connection's channel so subscriptions can be created before the
/// connection is established, and survives a reconnect (see `reopen()`).
///
/// The subscriber table sits behind a `Mutex` rather than in
/// `OVSDBConnectionCore`, the actor that owns the rest of the transport's state,
/// because `subscribe()` has to be synchronous: actor isolation would make it
/// `async`, and a caller could then no longer be sure its subscription was in
/// place before it issued a `monitor`. `Mutex` keeps `Sendable`
/// compiler-checked, unlike the `NSLock` plus `@unchecked Sendable` it replaces.
final class JSONRPCNotificationHub: Sendable {
    private struct Subscriber {
        let continuation: AsyncStream<JSONRPCNotificationEvent>.Continuation
        /// Notifications discarded since this subscriber was last told about
        /// a gap. Reported with the next event that reaches its buffer.
        var pendingDrops: Int = 0
    }

    private struct State {
        var subscribers: [UUID: Subscriber] = [:]
        /// Set by `finishAll()` when the connection drops. Without it a
        /// `subscribe()` after the connection is gone would hand back a stream
        /// whose continuation nothing ever finishes, hanging the consumer's
        /// `for await` forever. Cleared by `reopen()` on the next connect.
        var isClosed = false
    }

    private let bufferSize: Int
    private let logger: Logger
    private let state = Mutex(State())

    init(bufferSize: Int = OVSDBSocketConnection.notificationBufferSize, logger: Logger? = nil) {
        // A zero-length buffer would make `yield` report the value it was just
        // handed as the dropped one, which breaks the drop accounting below.
        self.bufferSize = max(1, bufferSize)
        self.logger = logger ?? Logger(label: "ovn-manager.notifications")
    }

    func subscribe() -> AsyncStream<JSONRPCNotificationEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: JSONRPCNotificationEvent.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )

        let isClosed = state.withLock { state -> Bool in
            guard !state.isClosed else { return true }
            state.subscribers[id] = Subscriber(continuation: continuation)
            return false
        }

        if isClosed {
            // Nothing will ever publish on this hub again; finish immediately
            // rather than leave the consumer waiting on a dead stream.
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

    /// Publishes to every subscriber. Called from the transport's single read
    /// loop, so calls are serialized with respect to each other and the
    /// per-subscriber drop counts below stay consistent.
    func publish(_ notification: JSONRPCNotification) {
        publish(event: .notification(notification))
    }

    /// Tells every subscriber that the connection was re-established and their
    /// monitors were restarted (see `JSONRPCNotificationEvent.reconnected`).
    ///
    /// Published by the supervisor between sessions, when no monitor exists on
    /// the new session yet — so nothing from it can reach a subscriber ahead of
    /// this event.
    func publishReconnected() {
        publish(event: .reconnected)
    }

    private func publish(event: JSONRPCNotificationEvent) {
        // Snapshot under the lock, then yield outside it: `yield` can finish a
        // stream, whose `onTermination` reaches back into this lock.
        let entries = state.withLock { Array($0.subscribers) }

        for (id, subscriber) in entries {
            var delta = 0

            if subscriber.pendingDrops > 0 {
                // `.bufferingNewest` always accepts the value and evicts the
                // oldest instead, so the report itself is guaranteed a slot;
                // whatever it displaced is folded back into the count.
                let result = subscriber.continuation.yield(.dropped(count: subscriber.pendingDrops))
                if case .terminated = result { continue }
                delta -= subscriber.pendingDrops
                if case .dropped(let evicted) = result {
                    delta += Self.notificationCount(of: evicted)
                }
            }

            if case .dropped(let evicted) = subscriber.continuation.yield(event) {
                delta += Self.notificationCount(of: evicted)
            }

            if delta > 0 && subscriber.pendingDrops == 0 {
                // Log once per overflow episode rather than once per discarded
                // notification, which under a sustained overflow would itself
                // flood.
                logger.warning("Notification buffer full (\(bufferSize)); a subscriber is not keeping up and notifications are being discarded")
            }
            adjustPendingDrops(id, by: delta)
        }
    }

    func finishAll() {
        let entries = state.withLock { state -> [Subscriber] in
            state.isClosed = true
            let entries = Array(state.subscribers.values)
            state.subscribers.removeAll()
            return entries
        }

        for subscriber in entries {
            // Last chance to tell a lagging consumer about the gap; after the
            // finish below nothing more can be delivered.
            if subscriber.pendingDrops > 0 {
                subscriber.continuation.yield(.dropped(count: subscriber.pendingDrops))
            }
            subscriber.continuation.finish()
        }
    }

    /// Clears the closed flag so a reconnect can publish again. The hub is
    /// created once per connection object but each connect builds a fresh
    /// channel, so without this every subscription after the first disconnect
    /// would come back already finished.
    func reopen() {
        state.withLock { $0.isClosed = false }
    }

    /// How many server notifications an evicted stream element represents.
    private static func notificationCount(of event: JSONRPCNotificationEvent) -> Int {
        switch event {
        case .notification:
            return 1
        case .dropped(let count):
            return count
        case .reconnected:
            // Not a notification, so evicting it loses no update — but it does
            // lose the news that the monitors restarted. Counting it as one drop
            // keeps the consumer from being told nothing at all: a drop report
            // already means "re-read, your view has a hole", which is the action
            // a missed reconnect calls for too.
            return 1
        }
    }

    private func adjustPendingDrops(_ id: UUID, by delta: Int) {
        guard delta != 0 else { return }
        state.withLock { state in
            if var subscriber = state.subscribers[id] {
                subscriber.pendingDrops = max(0, subscriber.pendingDrops + delta)
                state.subscribers[id] = subscriber
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
    }
}
