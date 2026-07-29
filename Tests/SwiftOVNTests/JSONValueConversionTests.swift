import Foundation
import XCTest
@testable import SwiftOVN

/// Tests for `JSONValueEncoder`, the direct `Encodable` → `JSONValue` path used
/// by `JSONRPCClient.transact`/`monitor` and `OVSDBRowEncoder`.
///
/// The bug this path retires: the encoder used to round-trip through
/// `JSONSerialization`, where a JSON boolean and an integer 0/1 are both
/// `NSNumber` — and on Linux Foundation an integer `NSNumber` holding 0 or 1
/// also casts to `Bool`. An OVSDB `wait` op's `timeout: 0` therefore went out
/// as `"timeout": false`, which ovsdb-server rejects ("Type mismatch for member
/// 'timeout'"), breaking every `insertAttached`-based operation (logical switch
/// ports, bridges). Encoding straight to `JSONValue` keeps the two apart by
/// construction, so these are regression tests for a bug class that no longer
/// has a place to hide.
final class JSONValueConversionTests: XCTestCase {

    private struct Sample: Encodable {
        let zero: Int
        let one: Int
        let big: Int
        let flagTrue: Bool
        let flagFalse: Bool
    }

    func testIntegersZeroAndOneStayNumbers() throws {
        let json = try JSONValueEncoder.encode(
            Sample(zero: 0, one: 1, big: 42, flagTrue: true, flagFalse: false)
        )
        guard case .object(let object) = json else {
            return XCTFail("expected object, got \(json)")
        }
        XCTAssertEqual(object["zero"], .number(0), "integer 0 must not become boolean false")
        XCTAssertEqual(object["one"], .number(1), "integer 1 must not become boolean true")
        XCTAssertEqual(object["big"], .number(42))
        XCTAssertEqual(object["flagTrue"], .boolean(true))
        XCTAssertEqual(object["flagFalse"], .boolean(false))
    }

    /// The headline regression: a `wait` op with `timeout: 0` must serialize
    /// `timeout` as the integer `0`, not the boolean `false`.
    func testWaitOperationTimeoutSerializesAsInteger() throws {
        let waitOp = OVSDBOperation(
            op: "wait",
            table: "Logical_Switch",
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("default"))],
            columns: ["name"],
            rows: [["name": .string("default")]],
            until: "==",
            timeout: 0
        )
        let json = try JSONValueEncoder.encode(waitOp)
        guard case .object(let object) = json else {
            return XCTFail("expected object, got \(json)")
        }
        XCTAssertEqual(object["timeout"], .number(0), "wait op timeout must be integer 0, not boolean false")
        XCTAssertEqual(object["until"], .string("=="))
        XCTAssertEqual(object["op"], .string("wait"))
    }

    /// `OVSDBCondition` and `OVSDBMutation` hand-encode into unkeyed
    /// containers, and rows are dictionaries of `JSONValue` that encode through
    /// single-value containers — the whole operation tree must survive.
    func testWaitOperationEncodesNestedContainers() throws {
        let waitOp = OVSDBOperation(
            op: "wait",
            table: "Logical_Switch",
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("ls-1"))],
            columns: ["name", "ports"],
            rows: [["name": .string("ls-1"), "tag": .number(7), "up": .boolean(false)]],
            until: "==",
            timeout: 0
        )
        let json = try JSONValueEncoder.encode(waitOp)
        guard case .object(let object) = json else {
            return XCTFail("expected object, got \(json)")
        }

        XCTAssertEqual(object["table"], .string("Logical_Switch"))
        XCTAssertEqual(object["columns"], .array([.string("name"), .string("ports")]))
        // Conditions serialize as [column, function, value] triples.
        XCTAssertEqual(
            object["where"],
            .array([.array([.string("name"), .string("=="), .string("ls-1")])])
        )
        XCTAssertEqual(
            object["rows"],
            .array([.object(["name": .string("ls-1"), "tag": .number(7), "up": .boolean(false)])])
        )
    }

    func testMutationEncodesAsTriple() throws {
        let json = try JSONValueEncoder.encode(OVSDBMutation.add(column: "priority", value: 0))

        XCTAssertEqual(json, .array([.string("priority"), .string("+="), .number(0)]))
    }

    /// Unset optionals are omitted rather than sent as JSON null, matching what
    /// `JSONEncoder` produced before: ovsdb-server rejects unknown/null members
    /// in an operation object.
    func testUnsetOptionalsAreOmitted() throws {
        let selectOp = OVSDBOperation(op: "select", table: "Logical_Switch")
        let json = try JSONValueEncoder.encode(selectOp)
        guard case .object(let object) = json else {
            return XCTFail("expected object, got \(json)")
        }

        XCTAssertEqual(object.keys.sorted(), ["op", "table"])
    }

    /// Monitor requests nest a struct of optional booleans inside a dictionary;
    /// the booleans must stay booleans.
    func testMonitorRequestsEncodeNestedSelectFlags() throws {
        let requests = [
            "Logical_Switch": OVSDBMonitorRequest(
                columns: ["name"],
                select: OVSDBMonitorSelect(initial: true, insert: true, delete: false, modify: nil)
            ),
        ]

        let json = try JSONValueEncoder.encode(requests)

        XCTAssertEqual(json, .object([
            "Logical_Switch": .object([
                "columns": .array([.string("name")]),
                "select": .object([
                    "initial": .boolean(true),
                    "insert": .boolean(true),
                    "delete": .boolean(false),
                ]),
            ]),
        ]))
    }

    /// Dictionaries with integer keys encode as objects with stringified keys,
    /// which is what `OVSDBRowEncoder`'s integer-keyed map columns read back.
    func testIntegerKeyedDictionaryEncodesStringKeys() throws {
        let json = try JSONValueEncoder.encode([0: "a", 12: "b"])

        XCTAssertEqual(json, .object(["0": .string("a"), "12": .string("b")]))
    }

    func testEmptyCollectionsKeepTheirShape() throws {
        XCTAssertEqual(try JSONValueEncoder.encode([String]()), .array([]))
        XCTAssertEqual(try JSONValueEncoder.encode([String: String]()), .object([:]))
    }

    func testNonFiniteDoubleThrows() throws {
        struct Broken: Encodable { let value: Double }

        XCTAssertThrowsError(try JSONValueEncoder.encode(Broken(value: .infinity))) { error in
            XCTAssertTrue(error is EncodingError, "expected EncodingError, got \(error)")
        }
    }

    /// `JSONValue` carries numbers as `Double`, so an integer that cannot be
    /// represented exactly is refused rather than silently rounded to a
    /// different value on the wire.
    func testIntegerBeyondDoublePrecisionThrows() throws {
        struct Counter: Encodable { let value: Int64 }

        XCTAssertThrowsError(try JSONValueEncoder.encode(Counter(value: (1 << 53) + 1))) { error in
            XCTAssertTrue(error is EncodingError, "expected EncodingError, got \(error)")
        }
        // The boundary itself is exactly representable and must still encode.
        XCTAssertEqual(
            try JSONValueEncoder.encode(Counter(value: 1 << 53)),
            .object(["value": .number(9_007_199_254_740_992)])
        )
    }

    /// The encoder feeds `JSONEncoder` on the way to the socket, so integral
    /// values must still reach the wire without a fractional part.
    func testEncodedOperationSerializesIntegersWithoutFraction() throws {
        let waitOp = OVSDBOperation(op: "wait", table: "Logical_Switch", until: "==", timeout: 0)
        let json = try JSONValueEncoder.encode(waitOp)
        let data = try JSONEncoder().encode(json)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(text.contains("\"timeout\":0"), "expected integral timeout in \(text)")
    }
}
