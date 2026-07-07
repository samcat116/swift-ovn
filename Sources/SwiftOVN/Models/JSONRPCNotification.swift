import Foundation

/// A JSON-RPC notification received from the server (a message carrying a
/// `method` with a null or absent `id`, so no response is expected).
///
/// OVSDB servers use notifications for monitor updates (`update`, `update2`)
/// and lock state changes (`locked`, `stolen`).
public struct JSONRPCNotification: Sendable {
    public let method: String
    public let params: JSONValue?

    public init(method: String, params: JSONValue? = nil) {
        self.method = method
        self.params = params
    }
}
