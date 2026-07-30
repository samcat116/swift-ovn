import Testing
@testable import SwiftOVN

@Suite("OVSDB endpoint")
struct OVSDBEndpointTests {

    // MARK: - Parsing

    @Test("Parses the cleartext endpoint forms", arguments: [
        ("unix:/var/run/ovn/ovnnb_db.sock", OVSDBEndpoint.unix(path: "/var/run/ovn/ovnnb_db.sock")),
        ("tcp:central.example.com:6641", .tcp(host: "central.example.com", port: 6641)),
        ("tcp:192.0.2.10:6642", .tcp(host: "192.0.2.10", port: 6642)),
        // The brackets around an IPv6 literal are delimiters, not part of the host.
        ("tcp:[2001:db8::1]:6641", .tcp(host: "2001:db8::1", port: 6641)),
    ])
    func parses(string: String, expected: OVSDBEndpoint) throws {
        #expect(try OVSDBEndpoint(parsing: string) == expected)
    }

    #if TLS
    @Test("An `ssl:` endpoint parses with the default TLS configuration")
    func parsesSSLEndpoint() throws {
        #expect(
            try OVSDBEndpoint(parsing: "ssl:central.example.com:6642")
                == .ssl(host: "central.example.com", port: 6642, tls: OVSDBTLSConfiguration())
        )
    }
    #else
    /// With the `TLS` trait off, `ssl:` cannot be a compile error here (the
    /// string is only known at runtime), so it must be a clear throw instead.
    @Test("An `ssl:` endpoint is rejected with the TLS trait off")
    func rejectsSSLEndpointWhenTLSTraitDisabled() throws {
        let error = try #require(
            #expect(throws: OVNManagerError.self) {
                try OVSDBEndpoint(parsing: "ssl:central.example.com:6642")
            }
        )
        #expect("\(error)".contains("TLS"), "Error should name the TLS trait, got: \(error)")
    }
    #endif

    @Test("Rejects an unknown scheme")
    func rejectsUnknownScheme() {
        #expect(throws: OVNManagerError.self) { try OVSDBEndpoint(parsing: "udp:host:6641") }
    }

    @Test("Rejects a bare path with no scheme")
    func rejectsMissingScheme() {
        #expect(throws: OVNManagerError.self) {
            try OVSDBEndpoint(parsing: "/var/run/ovn/ovnnb_db.sock")
        }
    }

    @Test("Rejects a host with no port", arguments: ["tcp:hostonly", "tcp:[2001:db8::1]"])
    func rejectsMissingPort(string: String) {
        #expect(throws: OVNManagerError.self) { try OVSDBEndpoint(parsing: string) }
    }

    @Test("Rejects a port that is not a usable number",
          arguments: ["tcp:host:notaport", "tcp:host:0", "tcp:host:70000"])
    func rejectsInvalidPort(string: String) {
        #expect(throws: OVNManagerError.self) { try OVSDBEndpoint(parsing: string) }
    }

    @Test("Rejects an empty host")
    func rejectsEmptyHost() {
        #expect(throws: OVNManagerError.self) { try OVSDBEndpoint(parsing: "tcp::6641") }
    }

    @Test("Rejects an empty unix path")
    func rejectsEmptyUnixPath() {
        #expect(throws: OVNManagerError.self) { try OVSDBEndpoint(parsing: "unix:") }
    }

    // MARK: - Description round trip

    /// Every endpoint form whose `description` has to parse back to itself.
    /// A `static let` rather than a literal in the attribute because the `ssl:`
    /// form only exists when the `TLS` trait is on.
    private static let roundTrippableStrings: [String] = {
        var strings = [
            "unix:/var/run/ovn/ovnnb_db.sock",
            "tcp:central.example.com:6641",
            "tcp:[2001:db8::1]:6641",
        ]
        #if TLS
        strings.append("ssl:central.example.com:6642")
        #endif
        return strings
    }()

    @Test("`description` round trips", arguments: OVSDBEndpointTests.roundTrippableStrings)
    func descriptionRoundTrips(string: String) throws {
        let endpoint = try OVSDBEndpoint(parsing: string)
        #expect(endpoint.description == string)
        #expect(try OVSDBEndpoint(parsing: endpoint.description) == endpoint)
    }

    // MARK: - Defaults

    @Test("The northbound and southbound default ports are the OVN ones")
    func defaultPorts() {
        #expect(OVSDBEndpoint.defaultNorthboundPort == 6641)
        #expect(OVSDBEndpoint.defaultSouthboundPort == 6642)
    }

    #if TLS
    @Test("The `ssl` convenience uses the default TLS configuration")
    func sslConvenienceUsesDefaultTLSConfiguration() {
        #expect(
            OVSDBEndpoint.ssl(host: "h", port: 6642)
                == .ssl(host: "h", port: 6642, tls: OVSDBTLSConfiguration())
        )
    }
    #endif
}
