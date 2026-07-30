/// A change in ownership of an OVSDB lock, delivered as a server-to-client
/// notification (RFC 7047 §4.1.9, §4.1.10).
///
/// Both halves matter to an active/standby client: `locked` is the standby
/// being promoted after the previous owner went away, and `stolen` is this
/// client being demoted while it may still believe it is the writer. See
/// `JSONRPCClient.lockUpdates()`.
public struct OVSDBLockNotification: Sendable, Hashable {

    public enum Kind: String, Sendable, CaseIterable {
        /// A lock this client had requested and been queued for is now held by
        /// it.
        case locked
        /// Another client stole a lock this client held; it is no longer the
        /// owner. Any transaction it commits from here on must not assume it
        /// is (see `OVSDBOperation.assert(lock:)`).
        case stolen
    }

    public let kind: Kind
    public let lockID: String

    public init(kind: Kind, lockID: String) {
        self.kind = kind
        self.lockID = lockID
    }
}

extension OVSDBLockNotification {
    /// Parses a `locked` or `stolen` notification, whose params are the
    /// one-element array `[<lock-id>]`.
    ///
    /// Returns nil for any other notification method, so a caller can filter a
    /// mixed notification stream with it.
    init?(_ notification: JSONRPCNotification) {
        guard let kind = Kind(rawValue: notification.method),
              case .array(let params)? = notification.params,
              case .string(let lockID)? = params.first else {
            return nil
        }
        self.init(kind: kind, lockID: lockID)
    }
}
