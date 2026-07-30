#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

// MARK: - Codable Extensions for OVSDB Types

// Like the Dictionary overloads below, these build the RFC 7047 *set* wire
// format rather than a plain JSON array, so they can be used directly to
// construct row column values. A plain array is not a legal column value:
// ovsdb-server parses a 2-element array as a tagged atom, so ["a", "b"] is
// rejected outright and ["uuid", x] would be misread as a UUID reference.
extension Array where Element == String {
    func toJSONValue() -> JSONValue {
        return .set(self)
    }
}

extension Array where Element == Int {
    func toJSONValue() -> JSONValue {
        return .set(self)
    }
}

// These build the RFC 7047 map wire format (`["map", [[k, v], ...]]`) rather
// than a plain JSON object, so they can be used directly to construct row
// column values. Use `JSONValue.map(_:)` for the underlying encoding.
extension Dictionary where Key == String, Value == String {
    func toJSONValue() -> JSONValue {
        return .map(self)
    }
}

extension Dictionary where Key == String, Value == Int {
    func toJSONValue() -> JSONValue {
        return .map(self)
    }
}

extension Dictionary where Key == Int, Value == String {
    func toJSONValue() -> JSONValue {
        return .map(self)
    }
}

// MARK: - JSON Value Extraction Helpers

extension JSONValue {
    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }
    
    var numberValue: Double? {
        if case .number(let value) = self {
            return value
        }
        return nil
    }
    
    /// The value as an `Int`, or nil if it is not a number or not an exact
    /// integer.
    ///
    /// `Int(exactly:)`, not `Int(_:)`: the trapping conversion took the whole
    /// process down on a value a server is free to send (`1e300` is valid
    /// JSON), and silently truncated 1.9 to 1 — from a property whose `Int?`
    /// result advertises that it reports failure instead.
    var intValue: Int? {
        if case .number(let value) = self {
            return Int(exactly: value)
        }
        return nil
    }
    
    var boolValue: Bool? {
        if case .boolean(let value) = self {
            return value
        }
        return nil
    }
    
    var arrayValue: [JSONValue]? {
        if case .array(let value) = self {
            return value
        }
        return nil
    }
    
    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }
    
    var isNull: Bool {
        if case .null = self {
            return true
        }
        return false
    }
    
    func asStringArray() -> [String]? {
        guard let array = arrayValue else { return nil }
        return array.compactMap { $0.stringValue }
    }
    
    func asIntArray() -> [Int]? {
        guard let array = arrayValue else { return nil }
        return array.compactMap { $0.intValue }
    }
    
    // These return an empty dictionary for an object with no usable entries,
    // and nil only when the value is not an object at all. Collapsing empty to
    // nil made a legitimately empty column indistinguishable from a type
    // mismatch.
    func asStringDictionary() -> [String: String]? {
        guard let object = objectValue else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let stringValue = value.stringValue {
                result[key] = stringValue
            }
        }
        return result
    }

    func asIntDictionary() -> [String: Int]? {
        guard let object = objectValue else { return nil }
        var result: [String: Int] = [:]
        for (key, value) in object {
            if let intValue = value.intValue {
                result[key] = intValue
            }
        }
        return result
    }
}

// MARK: - UUID Handling

extension JSONValue {
    static func uuid(_ uuidString: String) -> JSONValue {
        return .array([.string("uuid"), .string(uuidString)])
    }
    
    var uuidValue: String? {
        if case .array(let array) = self,
           array.count == 2,
           case .string("uuid") = array[0],
           case .string(let uuid) = array[1] {
            return uuid
        }
        return nil
    }
}

// MARK: - OVSDB Set Handling

extension JSONValue {
    /// The RFC 7047 set wire form for already-converted elements.
    ///
    /// Overloaded per element type rather than generic over `Equatable`. The
    /// generic version converted with a chain of `as?` casts and dropped
    /// anything that missed — which included *every* integer type other than
    /// `Int`, so `JSONValue.set([Int64(5)])` produced `["set", []]`: a write
    /// that tells ovsdb-server to clear the column rather than set it. An
    /// element type with no wire form is now a compile error instead.
    ///
    /// An empty array literal has to name its element type
    /// (`JSONValue.set([] as [String])`); every empty set has the same wire
    /// form regardless.
    static func set(_ values: [JSONValue]) -> JSONValue {
        if values.count == 1 {
            // RFC 7047: a single-element set is sent as the bare scalar.
            return values[0]
        }
        return .array([.string("set"), .array(values)])
    }

    static func set(_ values: [String]) -> JSONValue {
        return set(values.map { JSONValue.string($0) })
    }

    static func set(_ values: [Bool]) -> JSONValue {
        return set(values.map { JSONValue.boolean($0) })
    }

    /// - Note: `JSONValue` carries numbers as `Double`, so an element past 53
    ///   bits cannot be represented exactly. Build such a set from
    ///   `JSONValue.exactNumber(_:)` elements, which reports the failure.
    static func set(_ values: [Int]) -> JSONValue {
        return set(values.map { JSONValue.number(Double($0)) })
    }

    static func set(_ values: [Double]) -> JSONValue {
        return set(values.map { JSONValue.number($0) })
    }

    var setValue: [JSONValue]? {
        // A bare scalar is a single-element set (RFC 7047).
        switch self {
        case .string, .number, .boolean:
            return [self]
        case .array(let array):
            // The `["set", [...]]` wire form.
            if array.count == 2,
               case .string("set") = array[0],
               case .array(let values) = array[1] {
                return values
            }
            return nil
        default:
            return nil
        }
    }
    
    var setStringValues: [String]? {
        return setValue?.compactMap { $0.stringValue }
    }
    
    var setIntValues: [Int]? {
        return setValue?.compactMap { $0.intValue }
    }
}

// MARK: - OVSDB Map Handling

extension JSONValue {
    /// The RFC 7047 map wire form for already-converted pairs.
    ///
    /// Overloaded per key/value type for the same reason as `set(_:)`: the
    /// generic version `continue`d past any pair it could not cast, so an
    /// unsupported key or value type silently vanished from the column.
    static func map(_ pairs: [(JSONValue, JSONValue)]) -> JSONValue {
        return .array([.string("map"), .array(pairs.map { .array([$0.0, $0.1]) })])
    }

    static func map(_ dictionary: [String: String]) -> JSONValue {
        return map(dictionary.map { (.string($0.key), .string($0.value)) })
    }

    static func map(_ dictionary: [String: Int]) -> JSONValue {
        return map(dictionary.map { (.string($0.key), .number(Double($0.value))) })
    }

    static func map(_ dictionary: [String: Double]) -> JSONValue {
        return map(dictionary.map { (.string($0.key), .number($0.value)) })
    }

    static func map(_ dictionary: [Int: String]) -> JSONValue {
        return map(dictionary.map { (.number(Double($0.key)), .string($0.value)) })
    }
    
    var mapValue: [(JSONValue, JSONValue)]? {
        if case .array(let array) = self,
           array.count == 2,
           case .string("map") = array[0],
           case .array(let pairs) = array[1] {
            
            return pairs.compactMap { pair in
                if case .array(let pairArray) = pair,
                   pairArray.count == 2 {
                    return (pairArray[0], pairArray[1])
                }
                return nil
            }
        }
        
        return nil
    }
    
    var mapStringValues: [String: String]? {
        guard let pairs = mapValue else { return nil }
        
        var result: [String: String] = [:]
        for (key, value) in pairs {
            if let keyString = key.stringValue,
               let valueString = value.stringValue {
                result[keyString] = valueString
            }
        }

        return result
    }
    
    var mapIntValues: [String: Int]? {
        guard let pairs = mapValue else { return nil }
        
        var result: [String: Int] = [:]
        for (key, value) in pairs {
            if let keyString = key.stringValue,
               let valueInt = value.intValue {
                result[keyString] = valueInt
            }
        }

        return result
    }
}

// MARK: - Convenience Initializers

extension JSONValue {
    /// `.number` for an integer JSON can carry exactly, or nil past 53 bits,
    /// where this type's `Double` payload would round it to a different value
    /// on the wire.
    static func exactNumber(_ value: some BinaryInteger) -> JSONValue? {
        guard let double = Double(exactly: value) else { return nil }
        return .number(double)
    }

    /// `exactNumber(_:)`, or a thrown error rather than a rounded value.
    ///
    /// The request builders below go through this because they are the last
    /// place that still holds the caller's exact integer: once it is a
    /// `.number(Double)` the damage is done and nothing downstream can tell a
    /// rounded value from an intended one. A condition built on a rounded key
    /// matches the wrong row, or none, and reports no error.
    static func requiringExactNumber(_ value: some BinaryInteger) throws(OVNManagerError) -> JSONValue {
        guard let number = exactNumber(value) else {
            throw OVNManagerError.encodingError(
                EncodingError.invalidValue(value, EncodingError.Context(
                    codingPath: [],
                    debugDescription: """
                        \(value) needs more than 53 bits of precision and has no exact JSON \
                        number representation
                        """
                ))
            )
        }
        return number
    }
}

extension OVSDBCondition {
    static func equal(column: String, to value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .string(value))
    }

    static func equal(column: String, to value: Int) throws(OVNManagerError) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: try .requiringExactNumber(value))
    }

    static func equal(column: String, to value: Bool) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .boolean(value))
    }
    
    static func notEqual(column: String, to value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "!=", value: .string(value))
    }
    
    static func includes(column: String, value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "includes", value: .string(value))
    }
    
    static func excludes(column: String, value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "excludes", value: .string(value))
    }
}

extension OVSDBMutation {
    static func insert(column: String, value: String) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "insert", value: .string(value))
    }
    
    static func delete(column: String, value: String) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "delete", value: .string(value))
    }
    
    static func add(column: String, value: Int) throws(OVNManagerError) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "+=", value: try .requiringExactNumber(value))
    }

    static func subtract(column: String, value: Int) throws(OVNManagerError) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "-=", value: try .requiringExactNumber(value))
    }

    static func multiply(column: String, value: Int) throws(OVNManagerError) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "*=", value: try .requiringExactNumber(value))
    }

    static func divide(column: String, value: Int) throws(OVNManagerError) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "/=", value: try .requiringExactNumber(value))
    }

    static func modulo(column: String, value: Int) throws(OVNManagerError) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "%=", value: try .requiringExactNumber(value))
    }
}