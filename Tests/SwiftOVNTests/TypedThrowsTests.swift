import XCTest
@testable import SwiftOVN

/// Locks in the typed-throws contract: `OVNManaging`, `OVSManaging` and the
/// layers beneath them throw `OVNManagerError` and nothing else, so callers can
/// handle every failure exhaustively.
///
/// These are as much compile-time checks as runtime ones — `describe` has no
/// `default` case and takes a concrete `OVNManagerError`, so widening any of
/// those signatures back to `any Error` stops this file compiling.
final class TypedThrowsTests: XCTestCase {

    /// Exhaustive over `OVNManagerError`, which only type-checks at a `catch`
    /// site while the thrown type is concrete there.
    private func describe(_ error: OVNManagerError) -> String {
        switch error {
        case .connectionFailed: return "connectionFailed"
        case .invalidResponse: return "invalidResponse"
        case .timeoutError: return "timeoutError"
        case .encodingError: return "encodingError"
        case .decodingError: return "decodingError"
        case .rpcError: return "rpcError"
        case .invalidSocket: return "invalidSocket"
        case .operationFailed: return "operationFailed"
        case .notificationsDropped: return "notificationsDropped"
        }
    }

    /// Connecting to a socket that isn't there fails through every layer —
    /// manager, `OVSDBConnection`, `JSONRPCClient`, transport — and arrives as
    /// an `OVNManagerError` with no cast at the call site. Exercised through the
    /// protocol rather than the concrete class so the requirement's own thrown
    /// type is covered.
    func testOVNConnectFailureIsTypedThroughTheProtocol() async {
        let manager: some OVNManaging = OVNManager(socketPath: "/nonexistent/swift-ovn-typed-throws.sock")

        do {
            try await manager.connect()
            XCTFail("Expected connecting to a missing socket to fail")
        } catch {
            XCTAssertEqual(describe(error), "connectionFailed")
        }
    }

    func testOVSConnectFailureIsTypedThroughTheProtocol() async {
        let manager: some OVSManaging = OVSManager(socketPath: "/nonexistent/swift-ovn-typed-throws.sock")

        do {
            try await manager.connect()
            XCTFail("Expected connecting to a missing socket to fail")
        } catch {
            XCTAssertEqual(describe(error), "connectionFailed")
        }
    }

    func testEndpointParsingThrowsTyped() {
        do {
            _ = try OVSDBEndpoint(parsing: "udp:host:6641")
            XCTFail("Expected an unsupported scheme to be rejected")
        } catch {
            XCTAssertEqual(describe(error), "connectionFailed")
        }
    }

    /// `JSONValueEncoder` is a general `Encoder` and throws `EncodingError`;
    /// `makeRow` is the boundary that has to turn that into a case callers can
    /// match, so a non-finite `Double` must not surface as a raw
    /// `EncodingError`.
    func testRowEncodingWrapsForeignEncodingErrors() {
        struct Broken: Codable { let value: Double }

        do {
            _ = try OVSDBRowEncoder.makeRow(from: Broken(value: .infinity), hints: .ovn)
            XCTFail("Expected a non-finite Double to be refused")
        } catch {
            guard case .encodingError(let underlying) = error else {
                return XCTFail("Expected encodingError, got \(describe(error))")
            }
            XCTAssertTrue(underlying is EncodingError, "Expected the EncodingError to be preserved, got \(underlying)")
        }
    }

    /// The boundary helper must not double-wrap: the layers below re-throw
    /// their own `OVNManagerError`s constantly, and burying, say, a `timeoutError`
    /// inside a `decodingError` would defeat the point of the typed contract.
    func testWrappingPassesManagerErrorsThroughUnchanged() {
        let wrapped = OVNManagerError.wrapping(OVNManagerError.timeoutError) { .decodingError($0) }
        XCTAssertEqual(describe(wrapped), "timeoutError")
    }

    func testWrappingConvertsForeignErrors() {
        struct Foreign: Error {}

        let wrapped = OVNManagerError.wrapping(Foreign()) { .decodingError($0) }
        guard case .decodingError(let underlying) = wrapped else {
            return XCTFail("Expected decodingError, got \(describe(wrapped))")
        }
        XCTAssertTrue(underlying is Foreign, "Expected the original error to be preserved, got \(underlying)")
    }
}
