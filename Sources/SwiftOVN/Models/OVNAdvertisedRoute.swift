import Foundation

public struct OVNAdvertisedRoute: Codable, Sendable {
    public let uuid: String?
    public let datapath: String
    public let logical_port: String
    public let ip_prefix: String
    public let tracked_port: String?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case datapath, logical_port, ip_prefix, tracked_port, external_ids
    }
}
