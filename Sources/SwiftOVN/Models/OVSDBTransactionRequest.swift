#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVSDBTransactionRequest: Codable, Sendable {
    public let database: String
    public let operations: [OVSDBOperation]
    
    public init(database: String, operations: [OVSDBOperation]) {
        self.database = database
        self.operations = operations
    }
}