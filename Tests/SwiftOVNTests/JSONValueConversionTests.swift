import Foundation
import XCTest
@testable import SwiftOVN

/// Regression tests for `convertToJSONValue`, the bridge from
/// `JSONSerialization` output back into the `JSONValue` wire tree.
///
/// The bug: an integer `NSNumber` holding 0 or 1 also casts to `Bool` on Linux
/// Foundation, so checking `as? Bool` before `as? NSNumber` turned integer 0/1
/// into `false`/`true`. An OVSDB `wait` op's `timeout: 0` therefore went out as
/// `"timeout": false`, which ovsdb-server rejects ("Type mismatch for member
/// 'timeout'"), breaking every `insertAttached`-based operation (logical switch
/// ports, bridges).
final class JSONValueConversionTests: XCTestCase {

    /// Round-trips a value through the exact path `JSONRPCClient.transact` uses:
    /// `JSONEncoder` → `JSONSerialization.jsonObject` → `convertToJSONValue`.
    private func roundTrip<T: Encodable>(_ value: T) throws -> JSONValue {
        let data = try JSONEncoder().encode(value)
        let object = try JSONSerialization.jsonObject(with: data)
        return try convertToJSONValue(object)
    }

    private struct Sample: Encodable {
        let zero: Int
        let one: Int
        let big: Int
        let flagTrue: Bool
        let flagFalse: Bool
    }

    func testIntegersZeroAndOneStayNumbers() throws {
        let json = try roundTrip(Sample(zero: 0, one: 1, big: 42, flagTrue: true, flagFalse: false))
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
        let json = try roundTrip(waitOp)
        guard case .object(let object) = json else {
            return XCTFail("expected object, got \(json)")
        }
        XCTAssertEqual(object["timeout"], .number(0), "wait op timeout must be integer 0, not boolean false")
        XCTAssertEqual(object["until"], .string("=="))
        XCTAssertEqual(object["op"], .string("wait"))
    }
}
