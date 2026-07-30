/// A row in the OVN Southbound `Connection` table: one remote ovsdb-server
/// connects to or listens on for this database, and how that connection is
/// currently doing.
///
/// `OVNSBGlobal.connections` references these rows, so this is what resolves
/// those UUIDs. Two things make it worth reading rather than inferring from
/// configuration: `is_connected` and `status` are live, ephemeral columns
/// ovsdb-server maintains — so an `ssl:`/`tcp:` remote that is *supposed* to be
/// up but is not shows up here — and `role` is what ties a client to an
/// `OVNRBACRole`, which is how a chassis's write access is scoped.
///
/// `OVNSB`-prefixed because `Connection` names a table in both databases; the
/// Southbound row adds `read_only` and `role`, both of which exist because
/// hypervisors connect here and Northbound clients do not.
///
/// Read-only: ovsdb-server's own connection configuration is out of scope for
/// this library, so there is no create/update path on `OVNManager` and no public
/// initializer.
public struct OVNSBConnection: Codable, Sendable {
    public let uuid: String?
    /// The connection method: `tcp:`/`ssl:` to connect out, `ptcp:`/`pssl:` to
    /// listen. Port 6640 is the default in every form.
    public let target: String
    /// Maximum reconnect backoff in milliseconds; nil means ovsdb-server's
    /// default.
    public let max_backoff: Int?
    /// Inactivity probe interval in milliseconds; nil means the default, 0
    /// disables probing.
    public let inactivity_probe: Int?
    /// Whether clients on this connection may only read.
    public let read_only: Bool
    /// The RBAC role clients on this connection are restricted to, matching
    /// `OVNRBACRole.name`. An empty string means no RBAC restriction.
    public let role: String
    /// Live: whether the connection is up right now. Ephemeral — ovsdb-server
    /// never persists it, so it reflects this moment only.
    public let is_connected: Bool?
    /// Live connection detail: `state`, `sec_since_connect`,
    /// `sec_since_disconnect`, `last_error`, `n_connections` and so on.
    /// Ephemeral, like `is_connected`.
    public let status: [String: String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case target, max_backoff, inactivity_probe, read_only, role
        case is_connected, status, other_config, external_ids
    }
}
