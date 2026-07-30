import Foundation

/// The single error type thrown by every throwing operation on `OVNManaging`,
/// `OVSManaging`, `OVSDBConnection` and `JSONRPCClient` — those are declared
/// `throws(OVNManagerError)`, so `catch` binds this type directly and a
/// `switch` over it can be exhaustive without a `default`.
///
/// Layers below that surface throw foreign errors — `DecodingError` from
/// `OVSDBRowDecoder`, `EncodingError` from `JSONValueEncoder`, NIO channel and
/// TLS failures from the transport — which are wrapped into `decodingError`,
/// `encodingError` and `connectionFailed` at the boundary that crosses into the
/// typed API (see `wrapping(_:in:)`).
public enum OVNManagerError: Error, Sendable {
    case connectionFailed(String)
    case invalidResponse(String)
    case timeoutError
    case encodingError(Error)
    case decodingError(Error)
    case rpcError(JSONRPCError)
    case invalidSocket(String)
    case operationFailed(String)
    /// Monitor updates were discarded because the consumer fell behind, so the
    /// stream it was reading no longer describes every change. Restart the
    /// monitor to get a fresh snapshot.
    case notificationsDropped(count: Int)
}

extension OVNManagerError {
    /// Narrows an untyped error caught at the edge of the typed-throws API.
    ///
    /// An error that is already an `OVNManagerError` passes through unchanged —
    /// the layers below re-throw their own failures a lot, and double-wrapping
    /// them would bury the case a caller wants to match. Anything else is a
    /// foreign error (`DecodingError`, `EncodingError`, a NIO channel or TLS
    /// failure) and is handed to `transform` to be given the case that fits the
    /// operation that failed.
    static func wrapping(
        _ error: any Error,
        in transform: (any Error) -> OVNManagerError
    ) -> OVNManagerError {
        error as? OVNManagerError ?? transform(error)
    }
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
        case .notificationsDropped(let count):
            return "Dropped \(count) OVSDB notification(s) because the consumer fell behind; the monitor's view is incomplete and the monitor must be restarted"
        }
    }
}