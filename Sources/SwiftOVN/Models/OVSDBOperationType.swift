/// The `op` member of an OVSDB transaction operation (RFC 7047 §5.2).
///
/// The set is closed — ovsdb-server rejects a transaction containing any other
/// `op` — so the only values a `String` here could add are typos the compiler
/// cannot catch.
public enum OVSDBOperationType: String, Codable, Sendable, CaseIterable {
    case insert
    case select
    case update
    case mutate
    case delete
    case wait
    case commit
    case abort
    case comment
    case assert
}
