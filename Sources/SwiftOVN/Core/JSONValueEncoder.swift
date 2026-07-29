import Foundation

/// Encodes `Encodable` values straight into a `JSONValue` tree.
///
/// This is the inverse of `OVSDBRowDecoder`, and exists for the same reason:
/// Foundation's `Codable` plumbing cannot carry OVSDB's wire types without
/// losing information. The obvious route out —
/// `JSONEncoder` → `Data` → `JSONSerialization` → `[String: Any]` — collapses
/// JSON booleans and integers into a single `NSNumber` representation, and on
/// Linux Foundation `(0 as NSNumber) as? Bool` succeeds and returns `false`.
/// Telling the two apart then requires sniffing the underlying
/// CoreFoundation / Objective-C type; getting that wrong serialized an OVSDB
/// `wait` op's `timeout: 0` as `"timeout": false`, which ovsdb-server rejects
/// ("Type mismatch for member 'timeout'"), breaking every insert that attaches
/// a row to a parent (logical switch ports, bridges, ...).
///
/// Encoding directly keeps booleans and numbers distinct by construction, and
/// drops two full serialization passes from every write.
///
/// The output uses plain JSON shapes (objects, arrays, scalars);
/// `OVSDBRowEncoder` layers the RFC 7047 tagged forms on top of it.
enum JSONValueEncoder {
    /// Encodes the value, matching `JSONEncoder`'s conventions: `nil`
    /// optionals encoded with `encodeIfPresent` are omitted, dictionaries
    /// become objects (integer keys stringified), and non-finite or
    /// non-representable numbers are rejected rather than silently mangled.
    static func encode<T: Encodable>(_ value: T) throws -> JSONValue {
        let root = JSONValueNode()
        try value.encode(to: JSONValueTreeEncoder(node: root, codingPath: []))
        return root.json
    }
}

/// Index into an unkeyed container, for coding paths in diagnostics.
struct JSONIndexKey: CodingKey {
    let intValue: Int?
    var stringValue: String { "Index \(intValue ?? 0)" }

    init(intValue: Int) { self.intValue = intValue }
    init?(stringValue: String) { return nil }
}

// MARK: - Tree under construction

/// One slot in the tree being built. `Encoder` containers are value types that
/// all have to write into the same tree, so each holds a reference to the node
/// it fills in.
private final class JSONValueNode {
    private enum Kind { case scalar, object, array }

    private var kind: Kind = .scalar
    private var scalar: JSONValue = .null
    private var entries: [String: JSONValueNode] = [:]
    private var items: [JSONValueNode] = []

    /// Number of elements appended so far, for `UnkeyedEncodingContainer.count`.
    var count: Int { items.count }

    func set(_ value: JSONValue) {
        kind = .scalar
        scalar = value
    }

    /// Makes this node an object, so a container that encodes nothing still
    /// produces `{}`.
    func beginObject() {
        if case .object = kind { return }
        kind = .object
    }

    /// Makes this node an array, so a container that encodes nothing still
    /// produces `[]`.
    func beginArray() {
        if case .array = kind { return }
        kind = .array
    }

    /// The child node for `key`, created on first use.
    func child(forKey key: String) -> JSONValueNode {
        beginObject()
        if let existing = entries[key] { return existing }
        let child = JSONValueNode()
        entries[key] = child
        return child
    }

    /// A new child appended to this node's array.
    func appendChild() -> JSONValueNode {
        beginArray()
        let child = JSONValueNode()
        items.append(child)
        return child
    }

    var json: JSONValue {
        switch kind {
        case .scalar:
            return scalar
        case .object:
            return .object(entries.mapValues { $0.json })
        case .array:
            return .array(items.map { $0.json })
        }
    }
}

// MARK: - Scalar conversion

private enum JSONValueScalar {
    /// `JSONValue` carries numbers as `Double`, so an integer outside the
    /// 53-bit exactly-representable range is rejected rather than rounded to a
    /// different value on the wire. `OVSDBRowDecoder` refuses the same values
    /// on the way in.
    static func number<T: BinaryInteger>(_ value: T, codingPath: [CodingKey]) throws -> JSONValue {
        guard let double = Double(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) is not exactly representable as a JSON number"
            ))
        }
        return .number(double)
    }

    /// Infinity and NaN have no JSON spelling; `JSONEncoder` throws for them
    /// too by default.
    static func number<T: BinaryFloatingPoint>(_ value: T, codingPath: [CodingKey]) throws -> JSONValue {
        guard value.isFinite else {
            throw EncodingError.invalidValue(value, EncodingError.Context(
                codingPath: codingPath,
                debugDescription: "\(value) is not representable in JSON"
            ))
        }
        return .number(Double(value))
    }
}

// MARK: - Encoder

private struct JSONValueTreeEncoder: Encoder {
    let node: JSONValueNode
    let codingPath: [CodingKey]
    var userInfo: [CodingUserInfoKey: Any] { [:] }

    func container<Key: CodingKey>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> {
        node.beginObject()
        return KeyedEncodingContainer(JSONValueKeyedContainer<Key>(node: node, codingPath: codingPath))
    }

    func unkeyedContainer() -> UnkeyedEncodingContainer {
        node.beginArray()
        return JSONValueUnkeyedContainer(node: node, codingPath: codingPath)
    }

    func singleValueContainer() -> SingleValueEncodingContainer {
        return JSONValueSingleValueContainer(node: node, codingPath: codingPath)
    }
}

// MARK: - Keyed container

private struct JSONValueKeyedContainer<Key: CodingKey>: KeyedEncodingContainerProtocol {
    let node: JSONValueNode
    let codingPath: [CodingKey]

    func encodeNil(forKey key: Key) throws { slot(for: key).set(.null) }
    func encode(_ value: Bool, forKey key: Key) throws { slot(for: key).set(.boolean(value)) }
    func encode(_ value: String, forKey key: Key) throws { slot(for: key).set(.string(value)) }

    func encode(_ value: Double, forKey key: Key) throws { try encodeFloat(value, forKey: key) }
    func encode(_ value: Float, forKey key: Key) throws { try encodeFloat(value, forKey: key) }

    func encode(_ value: Int, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: Int8, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: Int16, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: Int32, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: Int64, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: UInt, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: UInt8, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: UInt16, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: UInt32, forKey key: Key) throws { try encodeInteger(value, forKey: key) }
    func encode(_ value: UInt64, forKey key: Key) throws { try encodeInteger(value, forKey: key) }

    func encode<T: Encodable>(_ value: T, forKey key: Key) throws {
        try value.encode(to: JSONValueTreeEncoder(node: slot(for: key), codingPath: path(for: key)))
    }

    func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type,
        forKey key: Key
    ) -> KeyedEncodingContainer<NestedKey> {
        let child = slot(for: key)
        child.beginObject()
        return KeyedEncodingContainer(JSONValueKeyedContainer<NestedKey>(node: child, codingPath: path(for: key)))
    }

    func nestedUnkeyedContainer(forKey key: Key) -> UnkeyedEncodingContainer {
        let child = slot(for: key)
        child.beginArray()
        return JSONValueUnkeyedContainer(node: child, codingPath: path(for: key))
    }

    func superEncoder() -> Encoder {
        return JSONValueTreeEncoder(node: node.child(forKey: "super"), codingPath: codingPath)
    }

    func superEncoder(forKey key: Key) -> Encoder {
        return JSONValueTreeEncoder(node: slot(for: key), codingPath: path(for: key))
    }

    private func slot(for key: Key) -> JSONValueNode {
        return node.child(forKey: key.stringValue)
    }

    private func path(for key: Key) -> [CodingKey] {
        return codingPath + [key]
    }

    private func encodeInteger<T: BinaryInteger>(_ value: T, forKey key: Key) throws {
        slot(for: key).set(try JSONValueScalar.number(value, codingPath: path(for: key)))
    }

    private func encodeFloat<T: BinaryFloatingPoint>(_ value: T, forKey key: Key) throws {
        slot(for: key).set(try JSONValueScalar.number(value, codingPath: path(for: key)))
    }
}

// MARK: - Unkeyed container

private struct JSONValueUnkeyedContainer: UnkeyedEncodingContainer {
    let node: JSONValueNode
    let codingPath: [CodingKey]

    var count: Int { node.count }

    mutating func encodeNil() throws { node.appendChild().set(.null) }
    mutating func encode(_ value: Bool) throws { node.appendChild().set(.boolean(value)) }
    mutating func encode(_ value: String) throws { node.appendChild().set(.string(value)) }

    mutating func encode(_ value: Double) throws { try encodeFloat(value) }
    mutating func encode(_ value: Float) throws { try encodeFloat(value) }

    mutating func encode(_ value: Int) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int8) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int16) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int32) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int64) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt8) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt16) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt32) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt64) throws { try encodeInteger(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        let path = nextPath()
        try value.encode(to: JSONValueTreeEncoder(node: node.appendChild(), codingPath: path))
    }

    mutating func nestedContainer<NestedKey: CodingKey>(
        keyedBy keyType: NestedKey.Type
    ) -> KeyedEncodingContainer<NestedKey> {
        let path = nextPath()
        let child = node.appendChild()
        child.beginObject()
        return KeyedEncodingContainer(JSONValueKeyedContainer<NestedKey>(node: child, codingPath: path))
    }

    mutating func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let path = nextPath()
        let child = node.appendChild()
        child.beginArray()
        return JSONValueUnkeyedContainer(node: child, codingPath: path)
    }

    mutating func superEncoder() -> Encoder {
        let path = nextPath()
        return JSONValueTreeEncoder(node: node.appendChild(), codingPath: path)
    }

    /// The coding path of the element about to be appended.
    private func nextPath() -> [CodingKey] {
        return codingPath + [JSONIndexKey(intValue: count)]
    }

    private mutating func encodeInteger<T: BinaryInteger>(_ value: T) throws {
        let value = try JSONValueScalar.number(value, codingPath: nextPath())
        node.appendChild().set(value)
    }

    private mutating func encodeFloat<T: BinaryFloatingPoint>(_ value: T) throws {
        let value = try JSONValueScalar.number(value, codingPath: nextPath())
        node.appendChild().set(value)
    }
}

// MARK: - Single-value container

private struct JSONValueSingleValueContainer: SingleValueEncodingContainer {
    let node: JSONValueNode
    let codingPath: [CodingKey]

    mutating func encodeNil() throws { node.set(.null) }
    mutating func encode(_ value: Bool) throws { node.set(.boolean(value)) }
    mutating func encode(_ value: String) throws { node.set(.string(value)) }

    mutating func encode(_ value: Double) throws { try encodeFloat(value) }
    mutating func encode(_ value: Float) throws { try encodeFloat(value) }

    mutating func encode(_ value: Int) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int8) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int16) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int32) throws { try encodeInteger(value) }
    mutating func encode(_ value: Int64) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt8) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt16) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt32) throws { try encodeInteger(value) }
    mutating func encode(_ value: UInt64) throws { try encodeInteger(value) }

    mutating func encode<T: Encodable>(_ value: T) throws {
        try value.encode(to: JSONValueTreeEncoder(node: node, codingPath: codingPath))
    }

    private func encodeInteger<T: BinaryInteger>(_ value: T) throws {
        node.set(try JSONValueScalar.number(value, codingPath: codingPath))
    }

    private func encodeFloat<T: BinaryFloatingPoint>(_ value: T) throws {
        node.set(try JSONValueScalar.number(value, codingPath: codingPath))
    }
}
