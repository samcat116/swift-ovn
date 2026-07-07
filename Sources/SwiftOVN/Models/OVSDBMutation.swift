import Foundation

public struct OVSDBMutation: Codable, Sendable {
    public let column: String
    public let mutator: String
    public let value: JSONValue
    
    public init(column: String, mutator: String, value: JSONValue) {
        self.column = column
        self.mutator = mutator
        self.value = value
    }

    // OVSDB mutations must be encoded as arrays: [column, mutator, value]
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(column)
        try container.encode(mutator)
        try container.encode(value)
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        column = try container.decode(String.self)
        mutator = try container.decode(String.self)
        value = try container.decode(JSONValue.self)
    }
}