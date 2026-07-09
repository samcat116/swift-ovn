import Foundation

// MARK: - Codable Extensions for OVSDB Types

extension Array where Element == String {
    func toJSONValue() -> JSONValue {
        return .array(self.map { .string($0) })
    }
}

extension Array where Element == Int {
    func toJSONValue() -> JSONValue {
        return .array(self.map { .number(Double($0)) })
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
    
    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
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
    
    func asStringDictionary() -> [String: String]? {
        guard let object = objectValue else { return nil }
        var result: [String: String] = [:]
        for (key, value) in object {
            if let stringValue = value.stringValue {
                result[key] = stringValue
            }
        }
        return result.isEmpty ? nil : result
    }
    
    func asIntDictionary() -> [String: Int]? {
        guard let object = objectValue else { return nil }
        var result: [String: Int] = [:]
        for (key, value) in object {
            if let intValue = value.intValue {
                result[key] = intValue
            }
        }
        return result.isEmpty ? nil : result
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
    static func set<T>(_ values: [T]) -> JSONValue where T: Equatable {
        if values.isEmpty {
            return .array([.string("set"), .array([])])
        } else if values.count == 1, let scalar = scalarJSONValue(values[0]) {
            // RFC 7047: a single-element set is sent as the bare scalar.
            return scalar
        }

        // Multiple values as a set.
        let jsonArray = values.compactMap { scalarJSONValue($0) }
        return .array([.string("set"), .array(jsonArray)])
    }

    /// Maps a supported scalar element (String, Bool, Int, Double) to a
    /// `JSONValue`, or `nil` for unsupported types. `Bool` is checked before
    /// the numeric types because it must not be coerced into a number.
    private static func scalarJSONValue<T>(_ value: T) -> JSONValue? {
        if let stringValue = value as? String {
            return .string(stringValue)
        } else if let boolValue = value as? Bool {
            return .boolean(boolValue)
        } else if let intValue = value as? Int {
            return .number(Double(intValue))
        } else if let doubleValue = value as? Double {
            return .number(doubleValue)
        }
        return nil
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
    static func map<K, V>(_ dictionary: [K: V]) -> JSONValue where K: Hashable {
        if dictionary.isEmpty {
            return .array([.string("map"), .array([])])
        }
        
        var pairs: [JSONValue] = []
        for (key, value) in dictionary {
            var keyValue: JSONValue
            var valueValue: JSONValue
            
            if let stringKey = key as? String {
                keyValue = .string(stringKey)
            } else if let intKey = key as? Int {
                keyValue = .number(Double(intKey))
            } else {
                continue
            }
            
            if let stringValue = value as? String {
                valueValue = .string(stringValue)
            } else if let intValue = value as? Int {
                valueValue = .number(Double(intValue))
            } else if let doubleValue = value as? Double {
                valueValue = .number(doubleValue)
            } else {
                continue
            }
            
            pairs.append(.array([keyValue, valueValue]))
        }
        
        return .array([.string("map"), .array(pairs)])
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
        
        return result.isEmpty ? nil : result
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
        
        return result.isEmpty ? nil : result
    }
}

// MARK: - Convenience Initializers

extension OVSDBCondition {
    static func equal(column: String, to value: String) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .string(value))
    }
    
    static func equal(column: String, to value: Int) -> OVSDBCondition {
        return OVSDBCondition(column: column, function: "==", value: .number(Double(value)))
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
    
    static func add(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "+=", value: .number(Double(value)))
    }
    
    static func subtract(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "-=", value: .number(Double(value)))
    }
    
    static func multiply(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "*=", value: .number(Double(value)))
    }
    
    static func divide(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "/=", value: .number(Double(value)))
    }
    
    static func modulo(column: String, value: Int) -> OVSDBMutation {
        return OVSDBMutation(column: column, mutator: "%=", value: .number(Double(value)))
    }
}