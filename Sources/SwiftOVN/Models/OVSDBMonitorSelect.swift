#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVSDBMonitorSelect: Codable, Sendable {
    public let initial: Bool?
    public let insert: Bool?
    public let delete: Bool?
    public let modify: Bool?
    
    public init(initial: Bool? = true, insert: Bool? = true, delete: Bool? = true, modify: Bool? = true) {
        self.initial = initial
        self.insert = insert
        self.delete = delete
        self.modify = modify
    }
}