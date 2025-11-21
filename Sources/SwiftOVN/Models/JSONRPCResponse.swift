import Foundation

public struct JSONRPCResponse<T: Codable>: Codable, @unchecked Sendable {
    public let result: T?
    public let error: JSONRPCError?
    public let id: JSONRPCIdentifier?
}