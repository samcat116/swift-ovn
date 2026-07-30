import Foundation
import Testing
import NIOCore
@testable import SwiftOVN

/// One frame and the envelope the scanner has to find in it.
struct EnvelopeCase: Sendable, CustomTestStringConvertible {
    let json: String
    let method: String?
    let identifier: JSONRPCFrameEnvelope.Identifier

    /// The frame itself is the most useful label a failure can carry.
    var testDescription: String { json }

    init(_ json: String, method: String? = nil, identifier: JSONRPCFrameEnvelope.Identifier) {
        self.json = json
        self.method = method
        self.identifier = identifier
    }
}

/// Tests for the routing scan that replaced the throwaway `JSONSerialization`
/// pass over every inbound message.
///
/// The scanner has to agree with a real JSON parser about where the top-level
/// `method` and `id` are, whatever surrounds them — otherwise a response is
/// matched to the wrong request, or a notification is mistaken for a
/// server-to-client request and answered.
@Suite("JSON-RPC frame envelope scanning")
struct JSONRPCFrameEnvelopeTests {

    private func scan(_ json: String) -> JSONRPCFrameEnvelope? {
        return JSONRPCFrameScanner.scanEnvelope(ByteBuffer(string: json))
    }

    /// Scans `testCase.json` and checks both envelope members.
    private func check(_ testCase: EnvelopeCase) throws {
        let envelope = try #require(scan(testCase.json))
        #expect(envelope.method == testCase.method)
        #expect(envelope.identifier == testCase.identifier)
    }

    // MARK: - Well-formed frames

    static let wellFormedCases: [EnvelopeCase] = [
        EnvelopeCase(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#,
                     identifier: .value(.number(7))),
        EnvelopeCase(#"{"id":"req-3","result":{},"error":null}"#,
                     identifier: .value(.string("req-3"))),
        EnvelopeCase(#"{"id":-12,"result":{}}"#, identifier: .value(.number(-12))),
        EnvelopeCase(#"{"method":"update","params":["mon1",{}],"id":null}"#,
                     method: "update", identifier: .absent),
        EnvelopeCase(#"{"method":"update","params":[]}"#, method: "update", identifier: .absent),
        EnvelopeCase(#"{"method":"echo","params":["ping"],"id":42}"#,
                     method: "echo", identifier: .value(.number(42))),
        // Member order carries no meaning in JSON, so the scan cannot rely on it.
        EnvelopeCase(#"{"id":null,"params":[],"method":"update"}"#,
                     method: "update", identifier: .absent),
        EnvelopeCase("{\n  \"method\" : \"echo\" ,\n  \"id\" : 5\n}",
                     method: "echo", identifier: .value(.number(5))),
        EnvelopeCase("{}", identifier: .absent),
        // Leading whitespace before the object is allowed.
        EnvelopeCase("\n\t {\"id\":2}", identifier: .value(.number(2))),
    ]

    @Test("Scans a well-formed frame", arguments: JSONRPCFrameEnvelopeTests.wellFormedCases)
    func scansWellFormedFrame(testCase: EnvelopeCase) throws {
        try check(testCase)
    }

    // MARK: - Skipping payloads

    static let payloadSkippingCases: [EnvelopeCase] = [
        // The common shape for a monitor update: the id sits behind the payload,
        // so every kind of nested value has to be skipped to reach it.
        EnvelopeCase(
            #"{"method":"update","params":["mon1",{"Logical_Flow":{"aa":{"new":{"match":"ip4.dst == 10.0.0.1","actions":["a","b"],"n":1,"ok":true,"nothing":null}}}}],"id":null}"#,
            method: "update", identifier: .absent),
        // A payload string containing `}`, `"id":`, or an escaped quote must not
        // be mistaken for structure or for a top-level member.
        EnvelopeCase(#"{"result":{"details":"unexpected } char, \"id\":99, {nested"},"id":4}"#,
                     identifier: .value(.number(4))),
        // A nested `id` is not the top-level one.
        EnvelopeCase(#"{"result":{"rows":[{"id":123}]},"id":8}"#, identifier: .value(.number(8))),
        // Nor is a nested `method`.
        EnvelopeCase(#"{"result":{"method":"not-ours"},"id":9}"#, identifier: .value(.number(9))),
        // The string ends at the quote after `\\`, not at the escaped one.
        EnvelopeCase(#"{"result":"trailing backslash \\","id":10}"#,
                     identifier: .value(.number(10))),
    ]

    @Test("Skips a payload to reach the envelope members",
          arguments: JSONRPCFrameEnvelopeTests.payloadSkippingCases)
    func skipsPayload(testCase: EnvelopeCase) throws {
        try check(testCase)
    }

    // MARK: - Ids this library cannot correlate

    static let uncorrelatableCases: [EnvelopeCase] = [
        EnvelopeCase(#"{"id":1.5,"result":{}}"#, identifier: .unsupported),
        EnvelopeCase(#"{"id":true,"result":{}}"#, identifier: .unsupported),
        EnvelopeCase(#"{"id":{"a":1},"result":{},"method":"x"}"#,
                     method: "x", identifier: .unsupported),
        EnvelopeCase(#"{"id":99999999999999999999,"result":{}}"#, identifier: .unsupported),
        // Escapes are not expanded, so the scanned text cannot be compared with
        // the ids this library generates; refusing to correlate beats matching
        // the wrong pending request.
        EnvelopeCase(#"{"id":"a\"b","result":{}}"#, identifier: .unsupported),
    ]

    @Test("Refuses an id it cannot correlate",
          arguments: JSONRPCFrameEnvelopeTests.uncorrelatableCases)
    func refusesUncorrelatableId(testCase: EnvelopeCase) throws {
        try check(testCase)
    }

    @Test("A non-string method is not a method")
    func nonStringMethodIsNotAMethod() throws {
        try check(EnvelopeCase(#"{"method":5,"id":11}"#, identifier: .value(.number(11))))
    }

    // MARK: - Malformed input

    @Test("Rejects a malformed frame", arguments: [
        // Not a JSON object at all.
        #"[1,2,3]"#,
        #""just a string""#,
        "",
        // Truncated mid-value and mid-string.
        #"{"id":1,"result":"#,
        #"{"method":"upda"#,
        // A member with no colon after its name.
        #"{"id" 1}"#,
    ])
    func rejectsMalformedFrame(json: String) {
        #expect(scan(json) == nil)
    }

    // MARK: - Agreement with a real parser

    @Test("The scanner agrees with JSONSerialization on a realistic frame", arguments: [
        #"{"id":1,"result":["OVN_Northbound","OVN_Southbound"],"error":null}"#,
        #"{"method":"update","params":["mon-1",{"Logical_Switch":{"uuid":{"new":{"name":"ls0"}}}}],"id":null}"#,
        #"{"method":"echo","params":["ping"],"id":"probe-1"}"#,
        #"{"id":"tx-9","result":[{"count":1}],"error":null}"#,
        #"{"error":{"code":-32000,"message":"syntax error, }"},"id":12}"#,
    ])
    func scannerAgreesWithJSONSerialization(frame: String) throws {
        let envelope = try #require(scan(frame))
        let parsed = try #require(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any])

        #expect(envelope.method == parsed["method"] as? String)

        let expected: JSONRPCFrameEnvelope.Identifier
        switch parsed["id"] {
        case let value as Int:
            expected = .value(.number(value))
        case let value as String:
            expected = .value(.string(value))
        default:
            expected = .absent
        }
        #expect(envelope.identifier == expected)
    }
}
