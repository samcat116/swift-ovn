/// Which of the three OVSDB monitor methods a monitor was established with.
///
/// `monitor` is RFC 7047 §4.1.5. `monitor_cond` and `monitor_cond_since` are
/// ovsdb-server extensions (ovsdb-server(7)) that every production OVN client
/// — ovn-controller, ovn-northd, libovsdb — prefers, for two reasons:
///
/// - `monitor_cond` takes a `where` condition per table and filters rows
///   server-side, so a client interested in one datapath is not sent every
///   `Logical_Flow` row in the deployment.
/// - `monitor_cond_since` additionally takes a transaction id and replies with
///   only what changed since it, so a reconnect does not re-download the whole
///   database.
///
/// The three also differ in how row changes reach the client: `monitor` sends
/// `update`, `monitor_cond` sends `update2` and `monitor_cond_since` sends
/// `update3` (see `usesRowUpdate2` and `OVSDBUpdate`).
public enum OVSDBMonitorMethod: Sendable, Hashable, CaseIterable, CustomStringConvertible {
    case monitor
    case monitorCond
    case monitorCondSince

    /// The `last-txn-id` to send to `monitor_cond_since` when there is nothing
    /// to resume from: the all-zero UUID, which no transaction can match, so
    /// the server answers `found: false` with a complete snapshot.
    public static let initialTransactionId = "00000000-0000-0000-0000-000000000000"

    /// The JSON-RPC method name.
    public var rpcMethod: String {
        switch self {
        case .monitor:
            return "monitor"
        case .monitorCond:
            return "monitor_cond"
        case .monitorCondSince:
            return "monitor_cond_since"
        }
    }

    /// The notification method the server reports row changes with for a
    /// monitor established this way.
    public var notificationMethod: String {
        switch self {
        case .monitor:
            return "update"
        case .monitorCond:
            return "update2"
        case .monitorCondSince:
            return "update3"
        }
    }

    /// The method whose monitors send `notificationMethod`, or nil if that is
    /// not a monitor notification at all (`locked`, `stolen`, …).
    public init?(notificationMethod: String) {
        switch notificationMethod {
        case "update":
            self = .monitor
        case "update2":
            self = .monitorCond
        case "update3":
            self = .monitorCondSince
        default:
            return nil
        }
    }

    /// Whether row changes arrive in ovsdb-server(7) `<row-update2>` form —
    /// one of `initial`, `insert`, `modify` or `delete` — rather than RFC 7047's
    /// `old`/`new` pair. True for both conditional methods.
    public var usesRowUpdate2: Bool {
        return self != .monitor
    }

    /// The next method to try when the server rejects this one as unknown,
    /// from most to least capable. Nil once plain `monitor` is reached: RFC 7047
    /// requires it, so there is nothing further to fall back to.
    var fallback: OVSDBMonitorMethod? {
        switch self {
        case .monitorCondSince:
            return .monitorCond
        case .monitorCond:
            return .monitor
        case .monitor:
            return nil
        }
    }

    public var description: String {
        return rpcMethod
    }
}
