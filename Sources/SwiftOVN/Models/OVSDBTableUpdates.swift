/// One monitor notification's worth of row changes, parsed.
///
/// Delivered as a batch rather than row by row because that is the unit the
/// server sends and the unit `lastTransactionId` describes: the rows in one
/// notification were committed by one OVSDB transaction, and the transaction id
/// is only a valid resume point once *all* of them have been processed.
public struct OVSDBTableUpdates: Sendable {
    /// The ID of the monitor these changes belong to.
    public let monitorId: String
    /// Which monitor method delivered them, and so which fields of the
    /// `updates` carry information (see `OVSDBUpdate`).
    public let method: OVSDBMonitorMethod
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
        lastTransactionId: String? = nil,
        updates: [OVSDBUpdate]
    ) {
        self.monitorId = monitorId
        self.method = method
        self.lastTransactionId = lastTransactionId
        self.updates = updates
    }
}
