import Foundation

public struct JSONRPCResponse<T: Codable>: Codable {
    public let result: T?
    public let error: JSONRPCError?
    public let id: JSONRPCIdentifier?
}

// Sendable only when the payload is, instead of asserting it unconditionally
// with `@unchecked`.
extension JSONRPCResponse: Sendable where T: Sendable {}