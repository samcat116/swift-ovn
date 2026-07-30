import Testing
@testable import SwiftOVN

/// Locks in the typed-throws contract: `OVNManaging`, `OVSManaging` and the
/// layers beneath them throw `OVNManagerError` and nothing else, so callers can
/// handle every failure exhaustively.
///
/// These are as much compile-time checks as runtime ones — `errorCase` is
/// exhaustive over `OVNManagerError` with no `default` and exists only on the
/// concrete type, so widening any of those signatures back to `any Error` stops
/// this file compiling.
@Suite("Typed throws")
struct TypedThrowsTests {

    /// Connecting to a socket that isn't there fails through every layer —
    /// manager, `OVSDBConnection`, `JSONRPCClient`, transport — and arrives as
    /// an `OVNManagerError` with no cast at the call site. Exercised through the
    /// protocol rather than the concrete class so the requirement's own thrown
    /// type is covered.
    @Test("An OVN connect failure is typed through the protocol")
    func ovnConnectFailureIsTypedThroughTheProtocol() async {
        let manager: some OVNManaging = OVNManager(socketPath: "/nonexistent/swift-ovn-typed-throws.sock")

        do {
            try await manager.connect()
            Issue.record("Expected connecting to a missing socket to fail")
        } catch {
            #expect(error.errorCase == .connectionFailed)
        }
    }

    @Test("An OVS connect failure is typed through the protocol")
    func ovsConnectFailureIsTypedThroughTheProtocol() async {
        let manager: some OVSManaging = OVSManager(socketPath: "/nonexistent/swift-ovn-typed-throws.sock")

        do {
            try await manager.connect()
            Issue.record("Expected connecting to a missing socket to fail")
        } catch {
            #expect(error.errorCase == .connectionFailed)
        }
    }

    @Test("Endpoint parsing throws a typed error")
    func endpointParsingThrowsTyped() {
        do {
            _ = try OVSDBEndpoint(parsing: "udp:host:6641")
            Issue.record("Expected an unsupported scheme to be rejected")
        } catch {
            #expect(error.errorCase == .connectionFailed)
        }
    }

    /// `JSONValueEncoder` is a general `Encoder` and throws `EncodingError`;
    /// `makeRow` is the boundary that has to turn that into a case callers can
    /// match, so a non-finite `Double` must not surface as a raw
    /// `EncodingError`.
    @Test("Row encoding wraps foreign encoding errors")
    func rowEncodingWrapsForeignEncodingErrors() throws {
        struct Broken: Codable { let value: Double }

        let error = try #require(
            #expect(throws: OVNManagerError.self) {
                try OVSDBRowEncoder.makeRow(from: Broken(value: .infinity), hints: .ovn)
            }
        )

        guard case .encodingError(let underlying) = error else {
            Issue.record("Expected encodingError, got \(error.errorCase)")
            return
        }
        #expect(underlying is EncodingError, "Expected the EncodingError to be preserved, got \(underlying)")
    }

    /// The boundary helper must not double-wrap: the layers below re-throw
    /// their own `OVNManagerError`s constantly, and burying, say, a `timeoutError`
    /// inside a `decodingError` would defeat the point of the typed contract.
    @Test("Wrapping passes manager errors through unchanged")
    func wrappingPassesManagerErrorsThroughUnchanged() {
        let wrapped = OVNManagerError.wrapping(OVNManagerError.timeoutError) { .decodingError($0) }
        #expect(wrapped.errorCase == .timeoutError)
    }

    @Test("Wrapping converts foreign errors")
    func wrappingConvertsForeignErrors() {
        struct Foreign: Error {}

        let wrapped = OVNManagerError.wrapping(Foreign()) { .decodingError($0) }
        guard case .decodingError(let underlying) = wrapped else {
            Issue.record("Expected decodingError, got \(wrapped.errorCase)")
            return
        }
        #expect(underlying is Foreign, "Expected the original error to be preserved, got \(underlying)")
    }
}
