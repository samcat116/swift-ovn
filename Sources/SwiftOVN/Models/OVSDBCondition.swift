import Foundation

public struct OVSDBCondition: Codable {
    public let column: String
    public let function: String
    public let value: JSONValue
    
    public init(column: String, function: String, value: JSONValue) {
        self.column = column
        self.function = function
        self.value = value
    }
    
    // OVSDB conditions must be encoded as arrays: [column, function, value]
    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(column)
        try container.encode(function)
        try container.encode(value)
    }
    
    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        column = try container.decode(String.self)
        function = try container.decode(String.self)
        value = try container.decode(JSONValue.self)
    }
}