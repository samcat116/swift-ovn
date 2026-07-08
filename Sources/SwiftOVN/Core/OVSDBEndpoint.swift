import Foundation

/// Where an OVSDB server is listening.
///
/// OVSDB servers accept connections over a local Unix domain socket or over
/// TCP, optionally protected by TLS (`ssl:` in OVN/OVS tooling). A remote
/// endpoint is what allows several hypervisors to share one central
/// northbound/southbound database.
public enum OVSDBEndpoint: Sendable, Equatable {
    /// A local Unix domain socket, e.g. `/var/run/ovn/ovnnb_db.sock`.
    case unix(path: String)
    /// A cleartext TCP connection, e.g. `tcp:central.example.com:6641`.
    case tcp(host: String, port: Int)
    /// A TLS-protected TCP connection, e.g. `ssl:central.example.com:6641`.
    case ssl(host: String, port: Int, tls: OVSDBTLSConfiguration)

    /// Default OVN northbound database port.
    public static let defaultNorthboundPort = 6641
    /// Default OVN southbound database port.
    public static let defaultSouthboundPort = 6642

    /// A TLS endpoint using the default TLS configuration (system trust
    /// roots, server certificate verification on, no client certificate).
    public static func ssl(host: String, port: Int) -> OVSDBEndpoint {
        return .ssl(host: host, port: port, tls: OVSDBTLSConfiguration())
    }

    /// Parses an OVN/OVS-style connection string:
    ///
    /// - `unix:/var/run/ovn/ovnnb_db.sock`
    /// - `tcp:192.0.2.1:6641` or `tcp:[2001:db8::1]:6641`
    /// - `ssl:central.example.com:6642`
    ///
    /// TLS options (CA, client certificate) cannot be expressed in the string
    /// form; parse the endpoint and re-create it with `.ssl(host:port:tls:)`
    /// when they are needed.
    public init(parsing string: String) throws {
        guard let colonIndex = string.firstIndex(of: ":") else {
            throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(string)': expected unix:, tcp: or ssl: prefix")
        }

        let scheme = String(string[..<colonIndex])
        let remainder = String(string[string.index(after: colonIndex)...])

        switch scheme {
        case "unix":
            guard !remainder.isEmpty else {
                throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(string)': missing socket path")
            }
            self = .unix(path: remainder)
        case "tcp", "ssl":
            let (host, port) = try Self.parseHostPort(remainder, in: string)
            if scheme == "tcp" {
                self = .tcp(host: host, port: port)
            } else {
                self = .ssl(host: host, port: port, tls: OVSDBTLSConfiguration())
            }
        default:
            throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(string)': unsupported scheme '\(scheme)'")
        }
    }

    private static func parseHostPort(_ remainder: String, in original: String) throws -> (host: String, port: Int) {
        let host: String
        let portString: String

        if remainder.hasPrefix("[") {
            // Bracketed IPv6 literal: [2001:db8::1]:6641
            guard let closingBracket = remainder.firstIndex(of: "]") else {
                throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(original)': unterminated IPv6 address")
            }
            host = String(remainder[remainder.index(after: remainder.startIndex)..<closingBracket])
            let afterBracket = remainder[remainder.index(after: closingBracket)...]
            guard afterBracket.hasPrefix(":") else {
                throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(original)': missing port")
            }
            portString = String(afterBracket.dropFirst())
        } else {
            guard let portColon = remainder.lastIndex(of: ":") else {
                throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(original)': missing port")
            }
            host = String(remainder[..<portColon])
            portString = String(remainder[remainder.index(after: portColon)...])
        }

        guard !host.isEmpty else {
            throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(original)': missing host")
        }
        guard let port = Int(portString), (1...65535).contains(port) else {
            throw OVNManagerError.connectionFailed("Invalid OVSDB endpoint '\(original)': invalid port '\(portString)'")
        }
        return (host, port)
    }
}

extension OVSDBEndpoint: CustomStringConvertible {
    public var description: String {
        switch self {
        case .unix(let path):
            return "unix:\(path)"
        case .tcp(let host, let port):
            return "tcp:\(Self.formatHost(host)):\(port)"
        case .ssl(let host, let port, _):
            return "ssl:\(Self.formatHost(host)):\(port)"
        }
    }

    private static func formatHost(_ host: String) -> String {
        // Bracket IPv6 literals so host and port remain unambiguous.
        return host.contains(":") ? "[\(host)]" : host
    }
}

/// TLS settings for an `ssl:` OVSDB endpoint.
///
/// OVN deployments typically run a private PKI (`ovn-pki`), so the CA that
/// signed the server certificate must be supplied explicitly, and the server
/// usually requires a client certificate signed by the same CA. All paths
/// point to PEM files, matching the files `ovn-pki` produces.
public struct OVSDBTLSConfiguration: Sendable, Equatable {
    /// PEM file with the CA certificate(s) used to verify the server
    /// (ovsdb-server's `--ca-cert`). When nil, the system trust roots are used.
    public var caCertificatePath: String?
    /// PEM file with the client certificate chain presented to the server
    /// (the ovs/ovn `--certificate` counterpart).
    public var clientCertificatePath: String?
    /// PEM file with the private key for the client certificate
    /// (the ovs/ovn `--private-key` counterpart).
    public var clientPrivateKeyPath: String?
    /// Whether the server certificate is verified against the trust roots.
    /// Disable only for lab setups whose certificates are not verifiable.
    public var verifiesServerCertificate: Bool
    /// Hostname used for SNI and certificate hostname verification. Defaults
    /// to the endpoint host; set explicitly when connecting by IP address to
    /// a certificate issued for a DNS name.
    public var serverHostname: String?

    public init(
        caCertificatePath: String? = nil,
        clientCertificatePath: String? = nil,
        clientPrivateKeyPath: String? = nil,
        verifiesServerCertificate: Bool = true,
        serverHostname: String? = nil
    ) {
        self.caCertificatePath = caCertificatePath
        self.clientCertificatePath = clientCertificatePath
        self.clientPrivateKeyPath = clientPrivateKeyPath
        self.verifiesServerCertificate = verifiesServerCertificate
        self.serverHostname = serverHostname
    }
}
