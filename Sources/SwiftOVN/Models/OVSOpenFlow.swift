#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVSOpenFlow: Codable, Sendable {
    public let uuid: String?
    public let bridge: String
    public let version: [String]
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case bridge, version
    }
}