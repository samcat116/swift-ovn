import Foundation

public enum OVNManagerError: Error, Sendable {
    case connectionFailed(String)
    case invalidResponse(String)
    case timeoutError
    case encodingError(Error)
    case decodingError(Error)
    case rpcError(JSONRPCError)
    case invalidSocket(String)
    case operationFailed(String)
    /// A `notifications()` consumer fell more than `bufferSize` notifications
    /// behind, so its stream was terminated instead of buffering without bound.
    /// Whatever the consumer had built from those updates is now incomplete: it
    /// has to subscribe again and re-issue its monitor to resynchronize.
    case notificationsDropped(bufferSize: Int)
}

// Without an explicit `errorDescription`, bridging to `NSError` discards the
// associated messages: `localizedDescription` becomes the useless
// "The operation could not be completed. (SwiftOVN.OVNManagerError error 6.)".
// That hid the real ovsdb rejection (e.g. `operationFailed`'s transaction
// message) behind an opaque case index. Surface the payload instead.
extension OVNManagerError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let message):
            return "OVN connection failed: \(message)"
        case .invalidResponse(let message):
            return "Invalid OVSDB response: \(message)"
        case .timeoutError:
            return "OVSDB operation timed out"
        case .encodingError(let error):
            return "OVSDB request encoding failed: \(error)"
        case .decodingError(let error):
            return "OVSDB response decoding failed: \(error)"
        case .rpcError(let error):
            return "OVSDB JSON-RPC error: \(error)"
        case .invalidSocket(let path):
            return "Invalid OVSDB socket: \(path)"
        case .operationFailed(let message):
            return message
        case .notificationsDropped(let bufferSize):
            return "OVSDB notification consumer fell more than \(bufferSize) notifications behind; re-subscribe and re-issue the monitor"
        }
    }
}