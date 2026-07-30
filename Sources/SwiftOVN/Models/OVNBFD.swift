#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row of the OVN Northbound `BFD` table: a Bidirectional Forwarding
/// Detection session from a logical router port to a next hop, so a route can
/// be withdrawn when the peer stops answering.
///
/// `BFD` is a root table, so a session row stands on its own — but it monitors
/// nothing until a `Logical_Router_Static_Route.bfd` or a
/// `Logical_Router_Policy.bfd_sessions` entry references it.
///
/// The schema indexes `(logical_port, dst_ip)`, so ovsdb-server rejects a
/// second session for a pair that already has one.
public struct OVNBFD: Codable, Sendable {
    public let uuid: String?
    /// Name of the `Logical_Router_Port` the session runs from. A plain
    /// port-name string, not a UUID reference.
    public let logical_port: String
    /// The peer address the session probes.
    public let dst_ip: String
    /// Minimum transmit interval, in milliseconds. Unset leaves the interval to
    /// ovn-controller's default.
    public let min_tx: Int?
    /// Minimum receive interval, in milliseconds.
    public let min_rx: Int?
    /// Detection multiplier: consecutive missed packets before the session is
    /// declared down.
    public let detect_mult: Int?
    public let options: [String: String]?
    /// Session state: `"admin_down"`, `"down"`, `"init"` or `"up"`.
    ///
    /// Read-only in practice — ovn-northd owns this column and rewrites
    /// whatever a client puts there. It is therefore decoded but has no
    /// initializer parameter: a session you construct never carries one, so
    /// `createBFDSession` and `updateBFDSession` send no `status` for it.
    public let status: String?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, dst_ip, min_tx, min_rx, detect_mult, options, status, external_ids
    }

    public init(logical_port: String, dst_ip: String, min_tx: Int? = nil, min_rx: Int? = nil, detect_mult: Int? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.logical_port = logical_port
        self.dst_ip = dst_ip
        self.min_tx = min_tx
        self.min_rx = min_rx
        self.detect_mult = detect_mult
        self.options = options
        self.status = nil
        self.external_ids = external_ids
    }
}
