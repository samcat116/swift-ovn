import Foundation

/// An element of a notification stream: either a notification from the server
/// or a report that some were discarded.
///
/// Notification streams buffer a bounded number of notifications per consumer
/// (see `OVSDBSocketConnection.notificationBufferSize`). A consumer that stops
/// draining its stream would otherwise make the client buffer without limit —
/// on an OVN Southbound `Logical_Flow` monitor that is enough to exhaust
/// memory. Once the buffer is full the oldest notifications are discarded and
/// the consumer is told how many, so a gap is visible instead of silent.
public enum JSONRPCNotificationEvent: Sendable {
    case notification(JSONRPCNotification)

    /// At least `count` notifications were discarded before the next element
    /// of the stream because this consumer fell behind.
    ///
    /// The count is exact once the consumer catches up; a report emitted as the
    /// connection closes can undercount, because fitting it into an already
    /// full buffer costs another element. Treat it as a lower bound.
    ///
    /// Anything derived from the stream is now incomplete. For a monitor that
    /// means the replicated view has a hole no later update will fill: restart
    /// the monitor (`startMonitoring` returns a fresh snapshot) rather than
    /// carrying on.
    case dropped(count: Int)
}
