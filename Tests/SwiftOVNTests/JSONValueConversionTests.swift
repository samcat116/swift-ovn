import Foundation
import Testing
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
@Suite("JSONValue encoding")
struct JSONValueConversionTests {

    private struct Sample: Encodable {
        let zero: Int
        let one: Int
        let big: Int
        let flagTrue: Bool
        let flagFalse: Bool
    }

    @Test("Integers 0 and 1 stay numbers")
    func integersZeroAndOneStayNumbers() throws {
        let json = try JSONValueEncoder.encode(
            Sample(zero: 0, one: 1, big: 42, flagTrue: true, flagFalse: false)
        )
        let object = try #require(json.objectValue, "expected object, got \(json)")

        #expect(object["zero"] == .number(0), "integer 0 must not become boolean false")
        #expect(object["one"] == .number(1), "integer 1 must not become boolean true")
        #expect(object["big"] == .number(42))
        #expect(object["flagTrue"] == .boolean(true))
        #expect(object["flagFalse"] == .boolean(false))
    }

    /// The headline regression: a `wait` op with `timeout: 0` must serialize
    /// `timeout` as the integer `0`, not the boolean `false`.
    @Test("A wait op's timeout serializes as an integer")
    func waitOperationTimeoutSerializesAsInteger() throws {
        let waitOp = OVSDBOperation.wait(
            "Logical_Switch",
            where: [OVSDBCondition(column: "name", function: "==", value: .string("default"))],
            columns: ["name"],
            rows: [["name": .string("default")]],
            until: "==",
            timeout: 0
        )
        let json = try JSONValueEncoder.encode(waitOp)
        let object = try #require(json.objectValue, "expected object, got \(json)")

        #expect(object["timeout"] == .number(0), "wait op timeout must be integer 0, not boolean false")
        #expect(object["until"] == .string("=="))
        #expect(object["op"] == .string("wait"))
    }

    /// `OVSDBCondition` and `OVSDBMutation` hand-encode into unkeyed
    /// containers, and rows are dictionaries of `JSONValue` that encode through
    /// single-value containers — the whole operation tree must survive.
    @Test("A wait op's nested containers survive encoding")
    func waitOperationEncodesNestedContainers() throws {
        let waitOp = OVSDBOperation.wait(
            "Logical_Switch",
            where: [OVSDBCondition(column: "name", function: "==", value: .string("ls-1"))],
            columns: ["name", "ports"],
            rows: [["name": .string("ls-1"), "tag": .number(7), "up": .boolean(false)]],
            until: "==",
            timeout: 0
        )
        let json = try JSONValueEncoder.encode(waitOp)
        let object = try #require(json.objectValue, "expected object, got \(json)")

        #expect(object["table"] == .string("Logical_Switch"))
        #expect(object["columns"] == .array([.string("name"), .string("ports")]))
        // Conditions serialize as [column, function, value] triples.
        #expect(object["where"] == .array([.array([.string("name"), .string("=="), .string("ls-1")])]))
        #expect(
            object["rows"]
                == .array([.object(["name": .string("ls-1"), "tag": .number(7), "up": .boolean(false)])])
        )
    }

    @Test("A mutation encodes as a triple")
    func mutationEncodesAsTriple() throws {
        let json = try JSONValueEncoder.encode(OVSDBMutation.add(column: "priority", value: 0))

        #expect(json == .array([.string("priority"), .string("+="), .number(0)]))
    }

    /// Unset optionals are omitted rather than sent as JSON null, matching what
    /// `JSONEncoder` produced before: ovsdb-server rejects unknown/null members
    /// in an operation object.
    @Test("Unset optionals are omitted")
    func unsetOptionalsAreOmitted() throws {
        let selectOp = OVSDBOperation(op: .select, table: "Logical_Switch")
        let json = try JSONValueEncoder.encode(selectOp)
        let object = try #require(json.objectValue, "expected object, got \(json)")

        #expect(object.keys.sorted() == ["op", "table"])
    }

    /// Monitor requests nest a struct of optional booleans inside a dictionary;
    /// the booleans must stay booleans.
    @Test("Monitor requests encode nested select flags")
    func monitorRequestsEncodeNestedSelectFlags() throws {
        let requests = [
            "Logical_Switch": OVSDBMonitorRequest(
                columns: ["name"],
                select: OVSDBMonitorSelect(initial: true, insert: true, delete: false, modify: nil)
            ),
        ]

        let json = try JSONValueEncoder.encode(requests)

        #expect(json == .object([
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
    @Test("An integer-keyed dictionary encodes string keys")
    func integerKeyedDictionaryEncodesStringKeys() throws {
        let json = try JSONValueEncoder.encode([0: "a", 12: "b"])

        #expect(json == .object(["0": .string("a"), "12": .string("b")]))
    }

    @Test("Empty collections keep their shape")
    func emptyCollectionsKeepTheirShape() throws {
        #expect(try JSONValueEncoder.encode([String]()) == .array([]))
        #expect(try JSONValueEncoder.encode([String: String]()) == .object([:]))
    }

    @Test("A non-finite Double throws")
    func nonFiniteDoubleThrows() {
        struct Broken: Encodable { let value: Double }

        let error = #expect(throws: (any Error).self) {
            try JSONValueEncoder.encode(Broken(value: .infinity))
        }
        #expect(error is EncodingError, "expected EncodingError, got \(error as Any)")
    }

    /// `JSONValue` carries numbers as `Double`, so an integer that cannot be
    /// represented exactly is refused rather than silently rounded to a
    /// different value on the wire.
    @Test("An integer beyond Double's precision throws")
    func integerBeyondDoublePrecisionThrows() throws {
        struct Counter: Encodable { let value: Int64 }

        let error = #expect(throws: (any Error).self) {
            try JSONValueEncoder.encode(Counter(value: (1 << 53) + 1))
        }
        #expect(error is EncodingError, "expected EncodingError, got \(error as Any)")

        // The boundary itself is exactly representable and must still encode.
        #expect(
            try JSONValueEncoder.encode(Counter(value: 1 << 53))
                == .object(["value": .number(9_007_199_254_740_992)])
        )
    }

    /// The encoder feeds `JSONEncoder` on the way to the socket, so integral
    /// values must still reach the wire without a fractional part.
    @Test("Integral values reach the wire without a fraction")
    func encodedOperationSerializesIntegersWithoutFraction() throws {
        let waitOp = OVSDBOperation(op: .wait, table: "Logical_Switch", until: "==", timeout: 0)
        let json = try JSONValueEncoder.encode(waitOp)
        let data = try JSONEncoder().encode(json)
        let text = String(decoding: data, as: UTF8.self)

        #expect(text.contains("\"timeout\":0"), "expected integral timeout in \(text)")
    }

    /// Regression: the decode side rounded silently while the encode side
    /// refused, so an int64 column wider than 53 bits — an interface byte
    /// counter, say — arrived as a different number with no error anywhere.
    @Test("An integer too wide for a JSON number is refused on the way in")
    func decodingAnOverwideIntegerThrows() throws {
        let data = Data("{\"rx_bytes\":9007199254740993}".utf8)

        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([String: JSONValue].self, from: data)
        }

        // The boundary itself still decodes, and exactly.
        let atBoundary = try JSONDecoder().decode(
            [String: JSONValue].self,
            from: Data("{\"rx_bytes\":9007199254740992}".utf8)
        )
        #expect(atBoundary["rx_bytes"] == .number(9_007_199_254_740_992))
    }

    /// Regression: `intValue` used the trapping `Int(_: Double)`, so a value a
    /// server is free to send took the process down instead of returning nil —
    /// from a property whose `Int?` result promises the opposite — and quietly
    /// truncated fractions the rest of the time.
    @Test("intValue reports failure instead of trapping or truncating", arguments: [
        (JSONValue.number(1e300), nil as Int?),
        (JSONValue.number(-1e300), nil),
        (JSONValue.number(1.9), nil),
        (JSONValue.string("7"), nil),
        (JSONValue.number(42), 42),
        (JSONValue.number(-42), -42),
    ])
    func intValueIsExact(value: JSONValue, expected: Int?) {
        #expect(value.intValue == expected)
    }

    /// Regression: a one-element set of an unsupported element type encoded as
    /// the *empty* set, which tells ovsdb-server to clear the column rather than
    /// set it. The overloads make that a compile error; this pins the wire forms
    /// they produce.
    @Test("Set wire forms are exact for every supported element type")
    func setWireForms() {
        #expect(JSONValue.set([] as [String]) == .array([.string("set"), .array([])]))
        #expect(JSONValue.set(["only"]) == .string("only"))
        #expect(JSONValue.set([true, false]) == .array([
            .string("set"), .array([.boolean(true), .boolean(false)])
        ]))
        #expect(JSONValue.set([1, 2]) == .array([
            .string("set"), .array([.number(1), .number(2)])
        ]))
    }

    /// Regression: the Int-taking builders converted with a bare `Double(_:)`,
    /// so a condition on a value past 53 bits went out rounded and matched the
    /// wrong row, or none, without an error.
    @Test("The integer request builders refuse a value they cannot represent")
    func integerBuildersRefuseInexactValues() {
        #expect(throws: OVNManagerError.self) {
            _ = try OVSDBCondition.equal(column: "tunnel_key", to: (1 << 53) + 1)
        }
        #expect(throws: OVNManagerError.self) {
            _ = try OVSDBMutation.add(column: "priority", value: (1 << 53) + 1)
        }
        #expect(throws: Never.self) {
            _ = try OVSDBCondition.equal(column: "tunnel_key", to: 1 << 53)
        }
    }
}
