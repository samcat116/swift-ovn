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

    /// The code used for errors that carry none: OVSDB speaks JSON-RPC 1.0,
    /// where the `error` member is an arbitrary value with no code in it.
    public static let noCode = 0

    /// Decodes the shapes an OVSDB server actually sends, as well as JSON-RPC
    /// 2.0's.
    ///
    /// RFC 7047 is JSON-RPC 1.0, whose `error` member is any value — and
    /// ovsdb-server uses that latitude. It answers an unimplemented method with
    /// the bare string `"unknown method"`, and reports most other failures as
    /// `{"error": "<name>", "details": "<explanation>"}`. Neither has a `code`
    /// or a `message`, so decoding this type by synthesis failed on every real
    /// error reply: the whole `JSONRPCResponse` failed to decode and the caller
    /// got an opaque `decodingError` instead of the server's reason — including
    /// the "unknown method" that monitor-method negotiation depends on
    /// recognizing.
    public init(from decoder: Decoder) throws {
        let value = try JSONValue(from: decoder)

        switch value {
        case .string(let message):
            // ovsdb-server's `unknown method`, and JSON-RPC 1.0 errors generally.
            self.init(code: Self.noCode, message: message)
        case .object(let members):
            if case .number(let code)? = members["code"],
               case .string(let message)? = members["message"] {
                // JSON-RPC 2.0.
                self.init(code: Int(code), message: message, data: members["data"])
            } else if case .string(let name)? = members["error"] {
                // ovsdb-server's error object: the name is the stable part, the
                // details are prose. Both are worth surfacing, and the whole
                // object stays in `data`.
                var message = name
                if case .string(let details)? = members["details"] {
                    message += ": \(details)"
                }
                self.init(code: Self.noCode, message: message, data: value)
            } else {
                self.init(code: Self.noCode, message: "\(value)", data: value)
            }
        default:
            self.init(code: Self.noCode, message: "\(value)", data: value)
        }
    }

    /// Whether the server rejected the request because it does not implement the
    /// method at all, rather than because the request was wrong.
    ///
    /// ovsdb-server answers a method it has never heard of with the JSON-RPC 1.0
    /// error string `unknown method`; a JSON-RPC 2.0 peer would use -32601. This
    /// is what tells a client that an ovsdb-server is too old for
    /// `monitor_cond_since` or `monitor_cond` and that it should fall back.
    public var isUnknownMethod: Bool {
        return code == -32601 || message.lowercased().contains("unknown method")
    }
}
