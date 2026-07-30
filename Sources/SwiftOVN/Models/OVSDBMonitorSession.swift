/// The outcome of starting a monitor: which method the server accepted, what
/// it sent back, and the transaction id to resume from later.
public struct OVSDBMonitorSession: Sendable {
    /// The monitor's ID, to pass to `stopMonitoring` /
    /// `updateMonitorConditions` and to filter the update stream by.
    public let monitorId: String
    /// The method the server accepted. Lower than requested when the server is
    /// too old for `monitor_cond_since` or `monitor_cond` (see
    /// `OVSDBConnection.startConditionalMonitoring`).
    public let method: OVSDBMonitorMethod
    /// Whether the server resumed from the requested transaction id — the
    /// `found` member of a `monitor_cond_since` reply.
    ///
    /// True: `initialUpdates` holds *only what changed since* that transaction,
    /// which is the point of the method — a reconnect costs one delta instead
    /// of a full copy of the database.
    ///
    /// False: `initialUpdates` is a complete snapshot of the monitored rows, so
    /// any row state carried across the reconnect must be discarded rather than
    /// merged. Always false for `monitor_cond` and `monitor`, neither of which
    /// can resume.
    public let resumed: Bool
    /// The transaction id the reply reported, to pass as `since` on a later
    /// reconnect. Nil unless `method` is `.monitorCondSince`; afterwards each
    /// `update3` carries a newer one (see `OVSDBTableUpdates`).
    public let lastTransactionId: String?
    /// The rows the reply carried: a snapshot of the monitored rows, or the
    /// delta since `since` when `resumed` is true.
    public let initialUpdates: [OVSDBUpdate]

    public init(
        monitorId: String,
        method: OVSDBMonitorMethod,
        resumed: Bool = false,
        lastTransactionId: String? = nil,
        initialUpdates: [OVSDBUpdate] = []
    ) {
        self.monitorId = monitorId
        self.method = method
        self.resumed = resumed
        self.lastTransactionId = lastTransactionId
        self.initialUpdates = initialUpdates
    }
}
