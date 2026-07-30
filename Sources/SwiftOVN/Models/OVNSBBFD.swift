/// A row in the OVN Southbound `BFD` table: one live BFD session ovn-controller
/// is running, and the state it is in.
///
/// `OVNSB`-prefixed because `BFD` names a table in both databases — see
/// `OVNBFD` for the Northbound row a client writes. The tables look alike but
/// serve opposite directions: Northbound is the request, with every timing
/// column optional and `status` reporting back, while here the timings are
/// required (they are the negotiated values) and the row carries the wire
/// details a session actually needs — `src_port`, `disc` and the chassis running
/// it. This is the table to read for whether a BFD-monitored next hop is up.
///
/// Read-only: ovn-controller owns these rows, so there is no create/update path
/// on `OVNManager` and no public initializer.
public struct OVNSBBFD: Codable, Sendable {
    public let uuid: String?
    /// Name of the logical port the session runs on.
    public let logical_port: String
    /// The BFD peer's IP address.
    public let dst_ip: String
    /// UDP source port of the session's control packets, in 49152–65535 as
    /// RFC 5881 requires.
    public let src_port: Int
    /// The session's nonzero local discriminator, which demultiplexes several
    /// sessions between the same pair of systems.
    public let disc: Int
    /// Minimum interval in milliseconds this system wants to transmit control
    /// packets at, before jitter. Zero is reserved.
    public let min_tx: Int
    /// Minimum interval in milliseconds between received control packets this
    /// system can support. Zero asks the peer not to send periodic packets at
    /// all.
    public let min_rx: Int
    /// Detection multiplier: the negotiated transmit interval times this is the
    /// detection time.
    public let detect_mult: Int
    /// The session's state: `"admin_down"`, `"down"`, `"init"` or `"up"`.
    public let status: String
    /// Name of the chassis where `logical_port` is bound — a chassis *name*, not
    /// a reference. Absent on a Southbound database predating the column.
    public let chassis_name: String?
    /// Reserved for future use by the schema; nothing reads it today.
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, dst_ip, src_port, disc
        case min_tx, min_rx, detect_mult, status, chassis_name, options, external_ids
    }
}
