import Foundation

// MARK: - JSON-RPC Core Models

public struct JSONRPCRequest: Codable {
    public let jsonrpc: String
    public let method: String
    public let params: JSONRPCParams?
    public let id: JSONRPCIdentifier?
    
    public init(method: String, params: JSONRPCParams? = nil, id: JSONRPCIdentifier? = nil) {
        self.jsonrpc = "2.0"
        self.method = method
        self.params = params
        self.id = id
    }
}

public struct JSONRPCResponse<T: Codable>: Codable {
    public let jsonrpc: String
    public let result: T?
    public let error: JSONRPCError?
    public let id: JSONRPCIdentifier?
}

public struct JSONRPCError: Codable, Error {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

public enum JSONRPCIdentifier: Codable, Hashable {
    case string(String)
    case number(Int)
    case null
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
        } else if let intValue = try? container.decode(Int.self) {
            self = .number(intValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCIdentifier.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Invalid JSON-RPC identifier")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }
}

// MARK: - JSON Value Handling

public enum JSONValue: Codable, Hashable {
    case string(String)
    case number(Double)
    case boolean(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let boolValue = try? container.decode(Bool.self) {
            self = .boolean(boolValue)
        } else if let doubleValue = try? container.decode(Double.self) {
            self = .number(doubleValue)
        } else if let stringValue = try? container.decode(String.self) {
            self = .string(stringValue)
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
            try container.encode(value)
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

// MARK: - JSON-RPC Parameters

public enum JSONRPCParams: Codable {
    case array([JSONValue])
    case object([String: JSONValue])
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if let arrayValue = try? container.decode([JSONValue].self) {
            self = .array(arrayValue)
        } else if let objectValue = try? container.decode([String: JSONValue].self) {
            self = .object(objectValue)
        } else {
            throw DecodingError.typeMismatch(
                JSONRPCParams.self,
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Parameters must be array or object")
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .array(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        }
    }
}

// MARK: - OVSDB Specific Models

public struct OVSDBTransactionRequest: Codable {
    public let database: String
    public let operations: [OVSDBOperation]
    
    public init(database: String, operations: [OVSDBOperation]) {
        self.database = database
        self.operations = operations
    }
}

public struct OVSDBOperation: Codable {
    public let op: String
    public let table: String
    public let whereConditions: [OVSDBCondition]?
    public let columns: [String]?
    public let rows: [OVSDBRow]?
    public let row: OVSDBRow?
    public let mutations: [OVSDBMutation]?
    
    private enum CodingKeys: String, CodingKey {
        case op, table, columns, rows, row, mutations
        case whereConditions = "where"
    }
    
    public init(op: String, table: String, whereConditions: [OVSDBCondition]? = nil, columns: [String]? = nil, rows: [OVSDBRow]? = nil, row: OVSDBRow? = nil, mutations: [OVSDBMutation]? = nil) {
        self.op = op
        self.table = table
        self.whereConditions = whereConditions
        self.columns = columns
        self.rows = rows
        self.row = row
        self.mutations = mutations
    }
}

public struct OVSDBCondition: Codable {
    public let column: String
    public let function: String
    public let value: JSONValue
    
    public init(column: String, function: String, value: JSONValue) {
        self.column = column
        self.function = function
        self.value = value
    }
}

public struct OVSDBMutation: Codable {
    public let column: String
    public let mutator: String
    public let value: JSONValue
    
    public init(column: String, mutator: String, value: JSONValue) {
        self.column = column
        self.mutator = mutator
        self.value = value
    }
}

public typealias OVSDBRow = [String: JSONValue]

public struct OVSDBMonitorRequest: Codable {
    public let columns: [String]?
    public let select: OVSDBMonitorSelect?
    
    public init(columns: [String]? = nil, select: OVSDBMonitorSelect? = nil) {
        self.columns = columns
        self.select = select
    }
}

public struct OVSDBMonitorSelect: Codable {
    public let initial: Bool?
    public let insert: Bool?
    public let delete: Bool?
    public let modify: Bool?
    
    public init(initial: Bool? = true, insert: Bool? = true, delete: Bool? = true, modify: Bool? = true) {
        self.initial = initial
        self.insert = insert
        self.delete = delete
        self.modify = modify
    }
}

public struct OVSDBUpdate: Codable {
    public let old: OVSDBRow?
    public let new: OVSDBRow?
    
    public init(old: OVSDBRow? = nil, new: OVSDBRow? = nil) {
        self.old = old
        self.new = new
    }
}

// MARK: - Error Types

public enum OVNManagerError: Error {
    case connectionFailed(String)
    case invalidResponse(String)
    case timeoutError
    case encodingError(Error)
    case decodingError(Error)
    case rpcError(JSONRPCError)
    case invalidSocket(String)
    case operationFailed(String)
}