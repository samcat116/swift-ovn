import XCTest
@testable import SwiftOVN

final class OVSDBEndpointTests: XCTestCase {

    // MARK: - Parsing

    func testParsesUnixEndpoint() throws {
        let endpoint = try OVSDBEndpoint(parsing: "unix:/var/run/ovn/ovnnb_db.sock")
        XCTAssertEqual(endpoint, .unix(path: "/var/run/ovn/ovnnb_db.sock"))
    }

    func testParsesTCPEndpoint() throws {
        let endpoint = try OVSDBEndpoint(parsing: "tcp:central.example.com:6641")
        XCTAssertEqual(endpoint, .tcp(host: "central.example.com", port: 6641))
    }

    func testParsesTCPEndpointWithIPv4Host() throws {
        let endpoint = try OVSDBEndpoint(parsing: "tcp:192.0.2.10:6642")
        XCTAssertEqual(endpoint, .tcp(host: "192.0.2.10", port: 6642))
    }

    func testParsesBracketedIPv6Host() throws {
        let endpoint = try OVSDBEndpoint(parsing: "tcp:[2001:db8::1]:6641")
        XCTAssertEqual(endpoint, .tcp(host: "2001:db8::1", port: 6641))
    }

    func testParsesSSLEndpointWithDefaultTLSConfiguration() throws {
        let endpoint = try OVSDBEndpoint(parsing: "ssl:central.example.com:6642")
        XCTAssertEqual(endpoint, .ssl(host: "central.example.com", port: 6642, tls: OVSDBTLSConfiguration()))
    }

    func testRejectsUnknownScheme() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "udp:host:6641"))
    }

    func testRejectsMissingScheme() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "/var/run/ovn/ovnnb_db.sock"))
    }

    func testRejectsMissingPort() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp:hostonly"))
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp:[2001:db8::1]"))
    }

    func testRejectsInvalidPort() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp:host:notaport"))
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp:host:0"))
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp:host:70000"))
    }

    func testRejectsEmptyHost() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "tcp::6641"))
    }

    func testRejectsEmptyUnixPath() {
        XCTAssertThrowsError(try OVSDBEndpoint(parsing: "unix:"))
    }

    // MARK: - Description round trip

    func testDescriptionRoundTrips() throws {
        let strings = [
            "unix:/var/run/ovn/ovnnb_db.sock",
            "tcp:central.example.com:6641",
            "tcp:[2001:db8::1]:6641",
            "ssl:central.example.com:6642"
        ]
        for string in strings {
            let endpoint = try OVSDBEndpoint(parsing: string)
            XCTAssertEqual(endpoint.description, string)
            XCTAssertEqual(try OVSDBEndpoint(parsing: endpoint.description), endpoint)
        }
    }

    // MARK: - Defaults

    func testDefaultPorts() {
        XCTAssertEqual(OVSDBEndpoint.defaultNorthboundPort, 6641)
        XCTAssertEqual(OVSDBEndpoint.defaultSouthboundPort, 6642)
    }

    func testSSLConvenienceUsesDefaultTLSConfiguration() {
        XCTAssertEqual(
            OVSDBEndpoint.ssl(host: "h", port: 6642),
            .ssl(host: "h", port: 6642, tls: OVSDBTLSConfiguration())
        )
    }
}
