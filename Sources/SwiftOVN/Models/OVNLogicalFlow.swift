#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNLogicalFlow: Codable, Sendable {
    public let uuid: String?
    public let logical_datapath: String?
    public let logical_dp_group: String?
    public let pipeline: String
    public let table_id: Int
    public let priority: Int
    public let match: String
    public let actions: String
    public let tags: [String: String]?
    public let controller_meter: String?
    /// Human-readable explanation of what the flow is for, when northd emits
    /// one.
    public let flow_desc: String?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_datapath, logical_dp_group, pipeline, table_id, priority, match, actions, tags, controller_meter, external_ids
        case flow_desc
    }
}