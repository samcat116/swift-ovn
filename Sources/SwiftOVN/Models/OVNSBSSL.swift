/// The one row of the OVN Southbound `SSL` table (`maxRows: 1`): the TLS
/// material ovsdb-server uses for this database's `ssl:`/`pssl:` remotes.
///
/// `OVNSBGlobal.ssl` references it, so this is what resolves that UUID. The
/// columns are paths on the ovsdb-server host, not the material itself, so
/// reading this tells a caller where the server expects its key and certificate
/// to be — not their contents.
///
/// `OVNSB`-prefixed because `SSL` names a table in both databases. Unusually the
/// two schemas are identical here, so nothing about this model is Southbound
/// specific; only `getSSL()`, which reads the Southbound one, is.
///
/// Read-only: ovsdb-server's own TLS configuration is out of scope for this
/// library, so there is no create/update path on `OVNManager` and no public
/// initializer. This is unrelated to `OVSDBTLSConfiguration`, which is the
/// client-side material *this* process presents when connecting.
public struct OVNSBSSL: Codable, Sendable {
    public let uuid: String?
    /// Path on the ovsdb-server host to its private key.
    public let private_key: String
    /// Path on the ovsdb-server host to its certificate.
    public let certificate: String
    /// Path on the ovsdb-server host to the CA certificate peers are verified
    /// against.
    public let ca_cert: String
    /// Whether ovsdb-server may accept the peer's CA certificate on first
    /// connection and write it to `ca_cert` — convenient to bootstrap, and no
    /// protection against a man in the middle while it happens.
    public let bootstrap_ca_cert: Bool
    /// Space-separated TLS versions to allow. Absent on a database predating the
    /// column; empty means ovsdb-server's default.
    public let ssl_protocols: String?
    /// OpenSSL cipher list for TLS 1.2 and below. Absent on a database predating
    /// the column.
    public let ssl_ciphers: String?
    /// OpenSSL ciphersuite list for TLS 1.3. Absent on a database predating the
    /// column.
    public let ssl_ciphersuites: String?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case private_key, certificate, ca_cert, bootstrap_ca_cert
        case ssl_protocols, ssl_ciphers, ssl_ciphersuites, external_ids
    }
}
