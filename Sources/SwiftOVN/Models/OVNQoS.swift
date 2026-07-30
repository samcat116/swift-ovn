#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row of the OVN Northbound `QoS` table: rate limiting and DSCP/mark
/// tagging applied to the traffic of a logical switch (`Logical_Switch.qos_rules`).
///
/// Distinct from `OVSQoS`, which models the Open_vSwitch `QoS` table — a
/// queueing discipline attached to a physical port. The two tables share only
/// their name.
///
/// `action` and `bandwidth` are `map<string,integer>`, not the
/// `map<string,string>` the rest of the models use: the schema restricts
/// `action` keys to `dscp`/`mark` and `bandwidth` keys to `rate`/`burst`, both
/// with integer values.
public struct OVNQoS: Codable, Sendable {
    public let uuid: String?
    public let priority: Int
    public let direction: String
    public let match: String
    public let action: [String: Int]?
    public let bandwidth: [String: Int]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case priority, direction, match, action, bandwidth, external_ids
    }

    public init(priority: Int, direction: String, match: String, action: [String: Int]? = nil, bandwidth: [String: Int]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.priority = priority
        self.direction = direction
        self.match = match
        self.action = action
        self.bandwidth = bandwidth
        self.external_ids = external_ids
    }
}
