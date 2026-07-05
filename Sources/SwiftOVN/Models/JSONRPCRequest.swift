import Foundation

public struct JSONRPCRequest: Codable, Sendable {
    // OVSDB (RFC 7047) speaks JSON-RPC 1.0, which has no "jsonrpc" member.
    // Emitting "jsonrpc":"2.0" makes ovsdb-server silently drop the request
    // (it never replies), so every OVSDB connection times out. The field is
    // therefore intentionally omitted from the wire format.
    public let method: String
    public let params: JSONRPCParams?
    public let id: JSONRPCIdentifier?

    public init(method: String, params: JSONRPCParams? = nil, id: JSONRPCIdentifier? = nil) {
        self.method = method
        self.params = params
        self.id = id
    }
}