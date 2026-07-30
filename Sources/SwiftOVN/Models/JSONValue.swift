#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        // String is tried first because it is by far the most common OVSDB
        // atom — names, addresses, every external_ids key and value, and both
        // halves of every ["uuid", ...] pair — and each `decode` attempt ahead
        // of the matching one builds and discards a `DecodingError`. A monitor
        // snapshot of thousands of rows made hundreds of thousands of them.
        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let integerValue = try? container.decode(Int64.self) {
            // OVSDB integer columns are int64, but this type carries numbers as
            // `Double`. Decoding straight to `Double` rounded anything past 53
            // bits — a byte counter of 9007199254740993 arrived as
            // ...992 with no error at all. Refuse it instead, which is what
            // `JSONValueScalar.number` already does on the way out.
            guard let double = Double(exactly: integerValue) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: """
                        \(integerValue) needs more than 53 bits of precision and has no exact \
                        JSON number representation
                        """
                )
            }
            self = .number(double)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONValue.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid JSON value")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            // OVSDB integer columns and map keys must serialize as JSON
            // integers; "1.0" is rejected where an integer is expected.
            if let integer = Int64(exactly: value) {
                try container.encode(integer)
            } else {
                try container.encode(value)
            }
        case .boolean(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}