/// One monitor notification — `update`, `update2` or `update3` — with its row
/// payload left unparsed.
///
/// `JSONRPCClient.monitorNotifications()` yields these; `OVSDBConnection` parses
/// `tableUpdates` into `OVSDBTableUpdates`.
public struct OVSDBMonitorNotification: Sendable {
    /// The ID of the monitor the notification belongs to, as passed to
    /// `monitor` / `monitor_cond` / `monitor_cond_since`.
    public let monitorId: String
    /// Which method's notification this is, and therefore which form
    /// `tableUpdates` takes.
    public let method: OVSDBMonitorMethod
    /// The transaction id this notification's changes leave the database at,
    /// from an `update3`. Nil for `update` and `update2`, which carry none.
    public let lastTransactionId: String?
    /// The notification's `<table-updates>` (for `update`) or
    /// `<table-updates2>` (for `update2`/`update3`) payload.
    public let tableUpdates: JSONValue

    public init(
        monitorId: String,
        method: OVSDBMonitorMethod,
        lastTransactionId: String? = nil,
        tableUpdates: JSONValue
    ) {
        self.monitorId = monitorId
        self.method = method
        self.lastTransactionId = lastTransactionId
        self.tableUpdates = tableUpdates
    }
}
