/// One monitor notification's worth of row changes, parsed.
///
/// Delivered as a batch rather than row by row because that is the unit the
/// server sends and the unit `lastTransactionId` describes: the rows in one
/// notification were committed by one OVSDB transaction, and the transaction id
/// is only a valid resume point once *all* of them have been processed.
public struct OVSDBTableUpdates: Sendable {
    /// Where a batch came from, and so what a consumer replicating rows has to
    /// do with it.
    ///
    /// Only a reconnect makes this interesting. `OVSDBConnection` re-establishes
    /// its monitors on the new session and delivers what they reply with on the
    /// same stream as the live updates, so a batch has to say whether it
    /// *continues* the consumer's view of the rows or *replaces* it.
    public enum Origin: Sendable, Hashable {
        /// A change notification from a running monitor: apply it to what you
        /// have.
        case live
        /// The reply of a monitor re-established after a reconnect, which the
        /// server resumed from the transaction id this connection had last
        /// delivered (`monitor_cond_since` answering `found: true`). These are
        /// the changes made while the connection was down: apply them to what
        /// you have and the view is whole again.
        case resumed
        /// The reply of a monitor re-established after a reconnect that could
        /// *not* be resumed — a `monitor_cond` or plain `monitor` monitor, or a
        /// `monitor_cond_since` one whose transaction the server does not have
        /// (it was compacted away, or this is a different member of the
        /// cluster).
        ///
        /// A complete snapshot of the monitored rows, so a consumer replicating
        /// them must **discard what it had** rather than merge: rows deleted
        /// while the connection was down are simply absent here, and nothing
        /// will ever report their deletion.
        case snapshot
    }

    /// The ID of the monitor these changes belong to.
    public let monitorId: String
    /// Which monitor method delivered them, and so which fields of the
    /// `updates` carry information (see `OVSDBUpdate`).
    public let method: OVSDBMonitorMethod
    /// Whether this batch continues the consumer's view of the rows or replaces
    /// it. `.live` for everything a running monitor reports.
    public let origin: Origin
    /// The transaction id to resume a `monitor_cond_since` monitor from once
    /// every update in this batch has been processed. Nil unless `method` is
    /// `.monitorCondSince`.
    public let lastTransactionId: String?
    /// The row changes, in no particular order — the rows of one transaction
    /// are independent of each other.
    public let updates: [OVSDBUpdate]

    public init(
        monitorId: String,
        method: OVSDBMonitorMethod,
        origin: Origin = .live,
        lastTransactionId: String? = nil,
        updates: [OVSDBUpdate]
    ) {
        self.monitorId = monitorId
        self.method = method
        self.origin = origin
        self.lastTransactionId = lastTransactionId
        self.updates = updates
    }
}
