#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct JSONRPCError: Codable, Error, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}