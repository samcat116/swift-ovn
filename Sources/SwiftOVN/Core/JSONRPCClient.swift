import Foundation
import NIO
import Logging

public final class JSONRPCClient {
    private let connection: UnixSocketConnection
    private let logger: Logger
    private var requestId: Int = 0
    private let requestIdLock = NSLock()
    
    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = UnixSocketConnection(
            socketPath: socketPath, 
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.jsonrpc-client")
    }
    
    public func connect() async throws {
        logger.info("JSONRPCClient: Starting connection process...")
        try await connection.connect().get()
        logger.info("JSONRPCClient: Connection established successfully")
    }
    
    public func disconnect() async throws {
        try await connection.disconnect().get()
    }
    
    public var isConnected: Bool {
        return connection.isConnectionActive
    }
    
    private func nextRequestId() -> Int {
        requestIdLock.lock()
        defer { requestIdLock.unlock() }
        requestId += 1
        return requestId
    }
    
    // MARK: - Generic JSON-RPC Methods
    
    public func call<T: Codable>(
        method: String,
        params: JSONRPCParams? = nil,
        responseType: T.Type
    ) async throws -> T {
        let id = JSONRPCIdentifier.number(nextRequestId())
        let request = JSONRPCRequest(method: method, params: params, id: id)
        
        logger.debug("Sending JSON-RPC request: \(method) with ID: \(id)")
        
        logger.debug("Connection active before send: \(connection.isConnectionActive)")
        
        // Set up the response handler before sending to avoid race conditions
        let responseFuture = connection.receive(
            as: JSONRPCResponse<T>.self,
            requestId: id
        )
        
        try await connection.send(request).get()
        logger.debug("Message sent successfully, waiting for response...")
        
        let response: JSONRPCResponse<T> = try await responseFuture.get()
        
        logger.debug("Received response for request ID: \(id)")
        
        if let error = response.error {
            logger.error("JSON-RPC error response: \(error.message)")
            throw OVNManagerError.rpcError(error)
        }
        
        guard let result = response.result else {
            throw OVNManagerError.invalidResponse("No result in response")
        }
        
        return result
    }
    
    public func notify(method: String, params: JSONRPCParams? = nil) async throws {
        let request = JSONRPCRequest(method: method, params: params, id: nil)
        
        logger.debug("Sending JSON-RPC notification: \(method)")
        
        try await connection.send(request).get()
    }
    
    // MARK: - OVSDB Specific Methods
    
    public func echo() async throws -> [String] {
        logger.info("Performing echo test...")
        let params = JSONRPCParams.array([.string("echo")])
        let result = try await call(
            method: "echo",
            params: params,
            responseType: [String].self
        )
        logger.info("Echo test completed successfully")
        return result
    }
    
    public func listDatabases() async throws -> [String] {
        logger.info("Listing databases...")
        let result = try await call(
            method: "list_dbs",
            responseType: [String].self
        )
        logger.info("Found \(result.count) databases: \(result)")
        return result
    }
    
    public func getSchema(database: String) async throws -> JSONValue {
        let params = JSONRPCParams.array([.string(database)])
        return try await call(
            method: "get_schema",
            params: params,
            responseType: JSONValue.self
        )
    }
    
    public func transact(database: String, operations: [OVSDBOperation]) async throws -> [JSONValue] {
        var paramsArray: [JSONValue] = [.string(database)]
        
        for operation in operations {
            let encoder = JSONEncoder()
            let data = try encoder.encode(operation)
            let jsonObject = try JSONSerialization.jsonObject(with: data)
            let jsonValue = try convertToJSONValue(jsonObject)
            paramsArray.append(jsonValue)
        }
        
        let params = JSONRPCParams.array(paramsArray)
        
        return try await call(
            method: "transact",
            params: params,
            responseType: [JSONValue].self
        )
    }
    
    public func monitor(
        database: String,
        monitorId: String,
        requests: [String: OVSDBMonitorRequest]
    ) async throws -> JSONValue {
        let encoder = JSONEncoder()
        let requestsData = try encoder.encode(requests)
        let requestsObject = try JSONSerialization.jsonObject(with: requestsData)
        let requestsValue = try convertToJSONValue(requestsObject)
        
        let params = JSONRPCParams.array([
            .string(database),
            .string(monitorId),
            requestsValue
        ])
        
        return try await call(
            method: "monitor",
            params: params,
            responseType: JSONValue.self
        )
    }
    
    public func cancelMonitor(monitorId: String) async throws {
        let params = JSONRPCParams.array([.string(monitorId)])
        
        try await notify(method: "monitor_cancel", params: params)
    }
    
    // MARK: - Monitoring Stream
    
    public func monitorUpdates() -> AsyncThrowingStream<(String, JSONValue), Error> {
        AsyncThrowingStream { continuation in
            Task {
                while connection.isConnectionActive {
                    do {
                        let response: JSONRPCResponse<JSONValue> = try await connection.receiveAny(
                            as: JSONRPCResponse<JSONValue>.self,
                            timeout: .seconds(60)
                        ).get()
                        
                        if let result = response.result, 
                           case .object(let updateObject) = result,
                           let method = updateObject["method"],
                           case .string(let methodName) = method,
                           methodName == "update" {
                            
                            if let params = updateObject["params"],
                               case .array(let paramsArray) = params,
                               paramsArray.count >= 2,
                               case .string(let monitorId) = paramsArray[0] {
                                continuation.yield((monitorId, paramsArray[1]))
                            }
                        }
                    } catch {
                        if connection.isConnectionActive {
                            continuation.finish(throwing: error)
                        }
                        break
                    }
                }
                continuation.finish()
            }
        }
    }
}

// MARK: - Helper Functions

private func convertToJSONValue(_ object: Any) throws -> JSONValue {
    if object is NSNull {
        return .null
    } else if let bool = object as? Bool {
        return .boolean(bool)
    } else if let number = object as? NSNumber {
        return .number(number.doubleValue)
    } else if let string = object as? String {
        return .string(string)
    } else if let array = object as? [Any] {
        let jsonArray = try array.map { try convertToJSONValue($0) }
        return .array(jsonArray)
    } else if let dict = object as? [String: Any] {
        var jsonObject: [String: JSONValue] = [:]
        for (key, value) in dict {
            jsonObject[key] = try convertToJSONValue(value)
        }
        return .object(jsonObject)
    } else {
        throw OVNManagerError.encodingError(
            NSError(domain: "JSONRPCClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unsupported type for JSON conversion"])
        )
    }
}