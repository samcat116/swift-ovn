import Foundation

/// Decodes `Codable` models from OVSDB wire-format rows (RFC 7047).
///
/// ovsdb-server does not send plain JSON for column values; it uses tagged
/// forms that a synthesized `Decodable` implementation cannot digest via
/// `JSONDecoder`:
///
/// - `["uuid", "<uuid-string>"]` — a UUID atom.
/// - `["set", [atom...]]` — a set. A set with *exactly one* element is sent
///   as the bare atom itself, and an unset optional scalar column arrives as
///   the empty set `["set", []]`.
/// - `["map", [[key, value]...]]` — a map; keys may be integers
///   (e.g. `QoS.queues`, `Bridge.flow_tables`).
///
/// This decoder adapts those forms to whatever type the model requests:
/// UUID atoms collapse to their string value, a bare atom decodes into a
/// single-element array when an array is requested, an empty set reads as
/// `nil` for any optional, a single-element set collapses to its atom when a
/// scalar is requested, and map keys are stringified so maps decode into
/// `[String: T]` (or `[Int: T]` for integer-keyed maps).
enum OVSDBRowDecoder {
    static func decode<T: Decodable>(_ type: T.Type, from row: OVSDBRow) throws -> T {
        return try T(from: OVSDBValueDecoder(value: .object(row), codingPath: []))
    }

    /// Converts a wire value to a plain Swift object for untyped consumers
    /// (e.g. `[String: Any]` statistics APIs): UUID atoms become strings,
    /// maps become dictionaries (integer keys stringified), sets become
    /// arrays, and scalars pass through.
    static func plainObject(from value: JSONValue) -> Any {
        if let uuid = OVSDBWire.uuidString(value) {
            return uuid
        }
        if let items = OVSDBWire.setItems(value) {
            return items.map { plainObject(from: $0) }
        }
        if let pairs = OVSDBWire.mapPairs(value) {
            var result: [String: Any] = [:]
            for pair in pairs {
                if case .array(let keyValue) = pair, keyValue.count == 2,
                   let key = OVSDBWire.keyString(keyValue[0]) {
                    result[key] = plainObject(from: keyValue[1])
                }
            }
            return result
        }
        switch value {
        case .null:
            return NSNull()
        case .boolean(let bool):
            return bool
        case .number(let number):
            return number
        case .string(let string):
            return string
        case .array(let array):
            return array.map { plainObject(from: $0) }
        case .object(let object):
            return object.mapValues { plainObject(from: $0) }
        }
    }
}

// MARK: - Wire-form helpers

private enum OVSDBWire {
    /// The set's elements, if the value is a tagged `["set", [...]]`.
    static func setItems(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let array) = value,
           array.count == 2,
           case .string("set") = array[0],
           case .array(let items) = array[1] {
            return items
        }
        return nil
    }

    /// The UUID string, if the value is a `["uuid", "..."]` atom.
    static func uuidString(_ value: JSONValue) -> String? {
        if case .array(let array) = value,
           array.count == 2,
           case .string("uuid") = array[0],
           case .string(let uuid) = array[1] {
            return uuid
        }
        return nil
    }

    /// The map's pairs, if the value is a tagged `["map", [[k, v]...]]`.
    static func mapPairs(_ value: JSONValue) -> [JSONValue]? {
        if case .array(let array) = value,
           array.count == 2,
           case .string("map") = array[0],
           case .array(let pairs) = array[1] {
            return pairs
        }
        return nil
    }

    /// Whether the value represents "no value": JSON null or the empty set,
    /// which is how ovsdb-server transmits an unset optional column.
    static func isUnset(_ value: JSONValue) -> Bool {
        if case .null = value { return true }
        if let items = setItems(value) { return items.isEmpty }
        return false
    }

    /// Collapses the value to a scalar atom where possible: UUID atoms become
    /// their string, and a single-element set becomes its sole element.
    static func scalar(_ value: JSONValue) -> JSONValue {
        if let uuid = uuidString(value) { return .string(uuid) }
        if let items = setItems(value), items.count == 1 { return scalar(items[0]) }
        return value
    }

    /// The value's elements for decoding into an array. A bare atom is a
    /// single-element set on the wire, so it yields a one-element list.
    static func elements(of value: JSONValue, codingPath: [CodingKey]) throws -> [JSONValue] {
        switch value {
        case .null:
            throw DecodingError.valueNotFound(
                [JSONValue].self,
                DecodingError.Context(codingPath: codingPath, debugDescription: "Cannot decode an array from null")
            )
        case .array(let array):
            if let items = setItems(value) { return items }
            if uuidString(value) != nil { return [value] }
            if mapPairs(value) != nil {
                throw DecodingError.typeMismatch(
                    [JSONValue].self,
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Expected a set, got an OVSDB map")
                )
            }
            // A plain, untagged JSON array (not a wire form ovsdb-server
            // produces for rows, but tolerated for symmetry).
            return array
        default:
            return [value]
        }
    }

    /// Converts a wire map key to its string form so maps can be decoded via
    /// a keyed container (`[String: T]`, or `[Int: T]` for integer keys).
    static func keyString(_ key: JSONValue) -> String? {
        switch scalar(key) {
        case .string(let string):
            return string
        case .number(let number):
            if let integer = Int64(exactly: number) { return String(integer) }
            return String(number)
        case .boolean(let bool):
            return String(bool)
        default:
            return nil
        }
    }
}

// MARK: - Decoder

private struct OVSDBValueDecoder: Decoder {
    let value: JSONValue
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let entries: [String: JSONValue]
        switch value {
        case .object(let dictionary):
            entries = dictionary
        default:
            if let pairs = OVSDBWire.mapPairs(value) {
                var result: [String: JSONValue] = [:]
                for pair in pairs {
                    guard case .array(let keyValue) = pair, keyValue.count == 2,
                          let key = OVSDBWire.keyString(keyValue[0]) else {
                        throw DecodingError.dataCorrupted(DecodingError.Context(
                            codingPath: codingPath,
                            debugDescription: "Malformed OVSDB map pair: \(pair)"
                        ))
                    }
                    result[key] = keyValue[1]
                }
                entries = result
            } else if OVSDBWire.isUnset(value) {
                entries = [:]
            } else {
                throw DecodingError.typeMismatch(
                    [String: JSONValue].self,
                    DecodingError.Context(codingPath: codingPath, debugDescription: "Expected an object or OVSDB map, got \(value)")
                )
            }
        }
        return KeyedDecodingContainer(OVSDBKeyedContainer<Key>(entries: entries, codingPath: codingPath))
    }

    func unkeyedContainer() throws -> UnkeyedDecodingContainer {
        return OVSDBUnkeyedContainer(
            elements: try OVSDBWire.elements(of: value, codingPath: codingPath),
            codingPath: codingPath
        )
    }

    func singleValueContainer() throws -> SingleValueDecodingContainer { self }
}

// MARK: - Single-value container

extension OVSDBValueDecoder: SingleValueDecodingContainer {
    func decodeNil() -> Bool {
        return OVSDBWire.isUnset(value)
    }

    func decode(_ type: Bool.Type) throws -> Bool {
        guard case .boolean(let bool) = OVSDBWire.scalar(value) else { throw mismatch(type) }
        return bool
    }

    func decode(_ type: String.Type) throws -> String {
        guard case .string(let string) = OVSDBWire.scalar(value) else { throw mismatch(type) }
        return string
    }

    func decode(_ type: Double.Type) throws -> Double {
        guard case .number(let number) = OVSDBWire.scalar(value) else { throw mismatch(type) }
        return number
    }

    func decode(_ type: Float.Type) throws -> Float { Float(try decode(Double.self)) }

    func decode(_ type: Int.Type) throws -> Int { try integer(type) }
    func decode(_ type: Int8.Type) throws -> Int8 { try integer(type) }
    func decode(_ type: Int16.Type) throws -> Int16 { try integer(type) }
    func decode(_ type: Int32.Type) throws -> Int32 { try integer(type) }
    func decode(_ type: Int64.Type) throws -> Int64 { try integer(type) }
    func decode(_ type: UInt.Type) throws -> UInt { try integer(type) }
    func decode(_ type: UInt8.Type) throws -> UInt8 { try integer(type) }
    func decode(_ type: UInt16.Type) throws -> UInt16 { try integer(type) }
    func decode(_ type: UInt32.Type) throws -> UInt32 { try integer(type) }
    func decode(_ type: UInt64.Type) throws -> UInt64 { try integer(type) }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        return try T(from: self)
    }

    private func integer<T: FixedWidthInteger>(_ type: T.Type) throws -> T {
        let number = try decode(Double.self)
        guard let integer = T(exactly: number) else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "Number \(number) is not representable as \(type)"
            ))
        }
        return integer
    }

    private func mismatch<T>(_ type: T.Type) -> DecodingError {
        return DecodingError.typeMismatch(
            type,
            DecodingError.Context(codingPath: codingPath, debugDescription: "Expected \(type), got \(value)")
        )
    }
}

// MARK: - Keyed container

private struct OVSDBKeyedContainer<Key: CodingKey>: KeyedDecodingContainerProtocol {
    let entries: [String: JSONValue]
    let codingPath: [CodingKey]

    var allKeys: [Key] { entries.keys.compactMap { Key(stringValue: $0) } }

    func contains(_ key: Key) -> Bool { entries[key.stringValue] != nil }

    func decodeNil(forKey key: Key) throws -> Bool {
        return OVSDBWire.isUnset(try rawValue(forKey: key))
    }

    func decode(_ type: Bool.Type, forKey key: Key) throws -> Bool { try decoder(forKey: key).decode(type) }
    func decode(_ type: String.Type, forKey key: Key) throws -> String { try decoder(forKey: key).decode(type) }
    func decode(_ type: Double.Type, forKey key: Key) throws -> Double { try decoder(forKey: key).decode(type) }
    func decode(_ type: Float.Type, forKey key: Key) throws -> Float { try decoder(forKey: key).decode(type) }
    func decode(_ type: Int.Type, forKey key: Key) throws -> Int { try decoder(forKey: key).decode(type) }
    func decode(_ type: Int8.Type, forKey key: Key) throws -> Int8 { try decoder(forKey: key).decode(type) }
    func decode(_ type: Int16.Type, forKey key: Key) throws -> Int16 { try decoder(forKey: key).decode(type) }
    func decode(_ type: Int32.Type, forKey key: Key) throws -> Int32 { try decoder(forKey: key).decode(type) }
    func decode(_ type: Int64.Type, forKey key: Key) throws -> Int64 { try decoder(forKey: key).decode(type) }
    func decode(_ type: UInt.Type, forKey key: Key) throws -> UInt { try decoder(forKey: key).decode(type) }
    func decode(_ type: UInt8.Type, forKey key: Key) throws -> UInt8 { try decoder(forKey: key).decode(type) }
    func decode(_ type: UInt16.Type, forKey key: Key) throws -> UInt16 { try decoder(forKey: key).decode(type) }
    func decode(_ type: UInt32.Type, forKey key: Key) throws -> UInt32 { try decoder(forKey: key).decode(type) }
    func decode(_ type: UInt64.Type, forKey key: Key) throws -> UInt64 { try decoder(forKey: key).decode(type) }

    func decode<T: Decodable>(_ type: T.Type, forKey key: Key) throws -> T {
        return try T(from: decoder(forKey: key))
    }

    func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type, forKey key: Key) throws -> KeyedDecodingContainer<NestedKey> {
        return try decoder(forKey: key).container(keyedBy: type)
    }

    func nestedUnkeyedContainer(forKey key: Key) throws -> UnkeyedDecodingContainer {
        return try decoder(forKey: key).unkeyedContainer()
    }

    func superDecoder() throws -> Decoder {
        return OVSDBValueDecoder(value: .object(entries), codingPath: codingPath)
    }

    func superDecoder(forKey key: Key) throws -> Decoder {
        return try decoder(forKey: key)
    }

    private func rawValue(forKey key: Key) throws -> JSONValue {
        guard let value = entries[key.stringValue] else {
            throw DecodingError.keyNotFound(key, DecodingError.Context(
                codingPath: codingPath,
                debugDescription: "No value for key '\(key.stringValue)'"
            ))
        }
        return value
    }

    private func decoder(forKey key: Key) throws -> OVSDBValueDecoder {
        var path = codingPath
        path.append(key)
        return OVSDBValueDecoder(value: try rawValue(forKey: key), codingPath: path)
    }
}

// MARK: - Unkeyed container

private struct OVSDBUnkeyedContainer: UnkeyedDecodingContainer {
    let elements: [JSONValue]
    let codingPath: [CodingKey]
    var currentIndex: Int = 0

    var count: Int? { elements.count }
    var isAtEnd: Bool { currentIndex >= elements.count }

    mutating func decodeNil() throws -> Bool {
        guard !isAtEnd else { throw endError(Never.self) }
        if case .null = elements[currentIndex] {
            currentIndex += 1
            return true
        }
        return false
    }

    mutating func decode(_ type: Bool.Type) throws -> Bool { try nextDecoder().decode(type) }
    mutating func decode(_ type: String.Type) throws -> String { try nextDecoder().decode(type) }
    mutating func decode(_ type: Double.Type) throws -> Double { try nextDecoder().decode(type) }
    mutating func decode(_ type: Float.Type) throws -> Float { try nextDecoder().decode(type) }
    mutating func decode(_ type: Int.Type) throws -> Int { try nextDecoder().decode(type) }
    mutating func decode(_ type: Int8.Type) throws -> Int8 { try nextDecoder().decode(type) }
    mutating func decode(_ type: Int16.Type) throws -> Int16 { try nextDecoder().decode(type) }
    mutating func decode(_ type: Int32.Type) throws -> Int32 { try nextDecoder().decode(type) }
    mutating func decode(_ type: Int64.Type) throws -> Int64 { try nextDecoder().decode(type) }
    mutating func decode(_ type: UInt.Type) throws -> UInt { try nextDecoder().decode(type) }
    mutating func decode(_ type: UInt8.Type) throws -> UInt8 { try nextDecoder().decode(type) }
    mutating func decode(_ type: UInt16.Type) throws -> UInt16 { try nextDecoder().decode(type) }
    mutating func decode(_ type: UInt32.Type) throws -> UInt32 { try nextDecoder().decode(type) }
    mutating func decode(_ type: UInt64.Type) throws -> UInt64 { try nextDecoder().decode(type) }

    mutating func decode<T: Decodable>(_ type: T.Type) throws -> T {
        return try T(from: nextDecoder())
    }

    mutating func nestedContainer<NestedKey: CodingKey>(keyedBy type: NestedKey.Type) throws -> KeyedDecodingContainer<NestedKey> {
        return try nextDecoder().container(keyedBy: type)
    }

    mutating func nestedUnkeyedContainer() throws -> UnkeyedDecodingContainer {
        return try nextDecoder().unkeyedContainer()
    }

    mutating func superDecoder() throws -> Decoder {
        return try nextDecoder()
    }

    private mutating func nextDecoder() throws -> OVSDBValueDecoder {
        guard !isAtEnd else { throw endError(JSONValue.self) }
        var path = codingPath
        path.append(OVSDBIndexKey(intValue: currentIndex))
        let decoder = OVSDBValueDecoder(value: elements[currentIndex], codingPath: path)
        currentIndex += 1
        return decoder
    }

    private func endError<T>(_ type: T.Type) -> DecodingError {
        var path = codingPath
        path.append(OVSDBIndexKey(intValue: currentIndex))
        return DecodingError.valueNotFound(type, DecodingError.Context(
            codingPath: path,
            debugDescription: "Unkeyed container is at end"
        ))
    }
}

private struct OVSDBIndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }

    init(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { return nil }
}
