@testable import SwiftOVN

extension OVNManagerError {

    /// Which case an error is, with its payload discarded.
    ///
    /// `OVNManagerError` is not `Equatable` — `encodingError`/`decodingError`
    /// carry an arbitrary `any Error` — so `#expect(throws: someCase)` cannot
    /// pin down *which* failure surfaced. Comparing discriminators can, and
    /// reports the case that actually arrived when the expectation fails.
    ///
    /// Deliberately exhaustive with no `default`, and reachable only on a
    /// concrete `OVNManagerError`: `TypedThrowsTests` leans on both properties.
    /// Adding a case to `OVNManagerError`, or widening a signature back to
    /// `any Error`, stops this compiling.
    enum Case: String, Sendable {
        case connectionFailed
        case invalidResponse
        case timeoutError
        case encodingError
        case decodingError
        case rpcError
        case invalidSocket
        case operationFailed
        case notificationsDropped
    }

    var errorCase: Case {
        switch self {
        case .connectionFailed: .connectionFailed
        case .invalidResponse: .invalidResponse
        case .timeoutError: .timeoutError
        case .encodingError: .encodingError
        case .decodingError: .decodingError
        case .rpcError: .rpcError
        case .invalidSocket: .invalidSocket
        case .operationFailed: .operationFailed
        case .notificationsDropped: .notificationsDropped
        }
    }
}
