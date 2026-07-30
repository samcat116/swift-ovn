import XCTest
import NIOCore
@testable import SwiftOVN

/// Tests for the routing scan that replaced the throwaway `JSONSerialization`
/// pass over every inbound message.
///
/// The scanner has to agree with a real JSON parser about where the top-level
/// `method` and `id` are, whatever surrounds them — otherwise a response is
/// matched to the wrong request, or a notification is mistaken for a
/// server-to-client request and answered.
final class JSONRPCFrameEnvelopeTests: XCTestCase {

    private func scan(_ json: String) -> JSONRPCFrameEnvelope? {
        return JSONRPCFrameScanner.scanEnvelope(ByteBuffer(string: json))
    }

    // MARK: - Well-formed frames

    func testResponseWithNumericId() throws {
        let envelope = try XCTUnwrap(scan(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#))
        XCTAssertNil(envelope.method)
        XCTAssertEqual(envelope.identifier, .value(.number(7)))
    }

    func testResponseWithStringId() throws {
        let envelope = try XCTUnwrap(scan(#"{"id":"req-3","result":{},"error":null}"#))
        XCTAssertEqual(envelope.identifier, .value(.string("req-3")))
    }

    func testNegativeId() throws {
        let envelope = try XCTUnwrap(scan(#"{"id":-12,"result":{}}"#))
        XCTAssertEqual(envelope.identifier, .value(.number(-12)))
    }

    func testNotificationWithNullId() throws {
        let envelope = try XCTUnwrap(scan(#"{"method":"update","params":["mon1",{}],"id":null}"#))
        XCTAssertEqual(envelope.method, "update")
        XCTAssertEqual(envelope.identifier, .absent)
    }

    func testNotificationWithNoIdMember() throws {
        let envelope = try XCTUnwrap(scan(#"{"method":"update","params":[]}"#))
        XCTAssertEqual(envelope.method, "update")
        XCTAssertEqual(envelope.identifier, .absent)
    }

    func testServerRequest() throws {
        let envelope = try XCTUnwrap(scan(#"{"method":"echo","params":["ping"],"id":42}"#))
        XCTAssertEqual(envelope.method, "echo")
        XCTAssertEqual(envelope.identifier, .value(.number(42)))
    }

    func testMemberOrderDoesNotMatter() throws {
        let idFirst = try XCTUnwrap(scan(#"{"id":null,"params":[],"method":"update"}"#))
        XCTAssertEqual(idFirst.method, "update")
        XCTAssertEqual(idFirst.identifier, .absent)
    }

    func testWhitespaceBetweenMembers() throws {
        let envelope = try XCTUnwrap(scan("{\n  \"method\" : \"echo\" ,\n  \"id\" : 5\n}"))
        XCTAssertEqual(envelope.method, "echo")
        XCTAssertEqual(envelope.identifier, .value(.number(5)))
    }

    func testEmptyObject() throws {
        let envelope = try XCTUnwrap(scan("{}"))
        XCTAssertNil(envelope.method)
        XCTAssertEqual(envelope.identifier, .absent)
    }

    // MARK: - Skipping payloads

    func testIdAfterANestedPayload() throws {
        // The common shape for a monitor update: the id sits behind the payload,
        // so every kind of nested value has to be skipped to reach it.
        let json = #"""
        {"method":"update","params":["mon1",{"Logical_Flow":{"aa":{"new":{"match":"ip4.dst == 10.0.0.1","actions":["a","b"],"n":1,"ok":true,"nothing":null}}}}],"id":null}
        """#
        let envelope = try XCTUnwrap(scan(json))
        XCTAssertEqual(envelope.method, "update")
        XCTAssertEqual(envelope.identifier, .absent)
    }

    func testBracesAndKeywordsInsideStringsAreSkipped() throws {
        // A payload string containing `}`, `"id":`, or an escaped quote must not
        // be mistaken for structure or for a top-level member.
        let json = #"{"result":{"details":"unexpected } char, \"id\":99, {nested"},"id":4}"#
        let envelope = try XCTUnwrap(scan(json))
        XCTAssertNil(envelope.method)
        XCTAssertEqual(envelope.identifier, .value(.number(4)))
    }

    func testNestedIdMemberIsNotMistakenForTheTopLevelOne() throws {
        let json = #"{"result":{"rows":[{"id":123}]},"id":8}"#
        let envelope = try XCTUnwrap(scan(json))
        XCTAssertEqual(envelope.identifier, .value(.number(8)))
    }

    func testNestedMethodMemberIsIgnored() throws {
        let json = #"{"result":{"method":"not-ours"},"id":9}"#
        let envelope = try XCTUnwrap(scan(json))
        XCTAssertNil(envelope.method)
        XCTAssertEqual(envelope.identifier, .value(.number(9)))
    }

    func testEscapedBackslashBeforeAClosingQuote() throws {
        // The string ends at the quote after `\\`, not at the escaped one.
        let json = #"{"result":"trailing backslash \\","id":10}"#
        XCTAssertEqual(scan(json)?.identifier, .value(.number(10)))
    }

    // MARK: - Ids this library cannot correlate

    func testFractionalIdIsUnsupported() throws {
        XCTAssertEqual(scan(#"{"id":1.5,"result":{}}"#)?.identifier, .unsupported)
    }

    func testBooleanIdIsUnsupported() throws {
        XCTAssertEqual(scan(#"{"id":true,"result":{}}"#)?.identifier, .unsupported)
    }

    func testObjectIdIsUnsupported() throws {
        let envelope = try XCTUnwrap(scan(#"{"id":{"a":1},"result":{},"method":"x"}"#))
        XCTAssertEqual(envelope.identifier, .unsupported)
        XCTAssertEqual(envelope.method, "x")
    }

    func testOutOfRangeIdIsUnsupported() throws {
        XCTAssertEqual(scan(#"{"id":99999999999999999999,"result":{}}"#)?.identifier, .unsupported)
    }

    func testStringIdWithEscapesIsUnsupported() throws {
        // Escapes are not expanded, so the scanned text cannot be compared with
        // the ids this library generates; refusing to correlate beats matching
        // the wrong pending request.
        XCTAssertEqual(scan(#"{"id":"a\"b","result":{}}"#)?.identifier, .unsupported)
    }

    func testNonStringMethodIsNotAMethod() throws {
        let envelope = try XCTUnwrap(scan(#"{"method":5,"id":11}"#))
        XCTAssertNil(envelope.method)
        XCTAssertEqual(envelope.identifier, .value(.number(11)))
    }

    // MARK: - Malformed input

    func testNonObjectFrameIsRejected() {
        XCTAssertNil(scan(#"[1,2,3]"#))
        XCTAssertNil(scan(#""just a string""#))
        XCTAssertNil(scan(""))
    }

    func testTruncatedFrameIsRejected() {
        XCTAssertNil(scan(#"{"id":1,"result":"#))
        XCTAssertNil(scan(#"{"method":"upda"#))
    }

    func testMissingColonIsRejected() {
        XCTAssertNil(scan(#"{"id" 1}"#))
    }

    func testLeadingWhitespaceIsAllowed() throws {
        XCTAssertEqual(scan("\n\t {\"id\":2}")?.identifier, .value(.number(2)))
    }

    // MARK: - Agreement with a real parser

    func testScannerAgreesWithJSONSerializationOnRealisticFrames() throws {
        let frames = [
            #"{"id":1,"result":["OVN_Northbound","OVN_Southbound"],"error":null}"#,
            #"{"method":"update","params":["mon-1",{"Logical_Switch":{"uuid":{"new":{"name":"ls0"}}}}],"id":null}"#,
            #"{"method":"echo","params":["ping"],"id":"probe-1"}"#,
            #"{"id":"tx-9","result":[{"count":1}],"error":null}"#,
            #"{"error":{"code":-32000,"message":"syntax error, }"},"id":12}"#,
        ]

        for frame in frames {
            let envelope = try XCTUnwrap(scan(frame), frame)
            let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any], frame)

            XCTAssertEqual(envelope.method, parsed["method"] as? String, frame)

            let expected: JSONRPCFrameEnvelope.Identifier
            switch parsed["id"] {
            case let value as Int:
                expected = .value(.number(value))
            case let value as String:
                expected = .value(.string(value))
            default:
                expected = .absent
            }
            XCTAssertEqual(envelope.identifier, expected, frame)
        }
    }
}
