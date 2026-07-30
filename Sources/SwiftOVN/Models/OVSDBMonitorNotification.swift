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

extension OVSDBMonitorNotification {
    /// Parses an `update`, `update2` or `update3` notification.
    ///
    /// Returns nil for a notification that is not one of those three, and for
    /// one that is but whose params are not the shape ovsdb-server(7) gives it,
    /// so a caller can filter a mixed notification stream with it.
    public init?(_ notification: JSONRPCNotification) {
        guard let method = OVSDBMonitorMethod(notificationMethod: notification.method),
              case .array(let params)? = notification.params,
              case .string(let monitorId)? = params.first else {
            return nil
        }

        switch method {
        case .monitor, .monitorCond:
            // [<monitor-id>, <table-updates>]
            guard params.count >= 2 else { return nil }
            self.init(monitorId: monitorId, method: method, tableUpdates: params[1])
        case .monitorCondSince:
            // [<monitor-id>, <last-txn-id>, <table-updates2>]
            guard params.count >= 3, case .string(let transactionId) = params[1] else {
                return nil
            }
            self.init(
                monitorId: monitorId,
                method: method,
                lastTransactionId: transactionId,
                tableUpdates: params[2]
            )
        }
    }
}
