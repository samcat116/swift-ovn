#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNACL: Codable, Sendable {
    public let uuid: String?
    public let priority: Int
    public let direction: String
    public let match: String
    public let action: String
    public let log: Bool?
    public let severity: String?
    public let meter: String?
    public let name: String?
    /// The hierarchical tier (0-3) this ACL is evaluated in. Tier 0 is
    /// evaluated first; each next tier only runs when no verdict was reached.
    public let tier: Int?
    /// A 32-bit identifier copied to the connection-tracker entry of allowed
    /// connections, so a leaked conntrack entry can be traced back to its ACL.
    public let label: Int?
    /// `Network_Function_Group` reference. That table is not modeled yet, so
    /// this stays a UUID string.
    public let network_function_group: String?
    /// `Sample` references for new and established connections. That table is
    /// not modeled yet, so these stay UUID strings.
    public let sample_new: String?
    public let sample_est: String?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case priority, direction, match, action, log, severity, meter, name, external_ids
        case tier, label, network_function_group, sample_new, sample_est, options
    }

    public init(priority: Int, direction: String, match: String, action: String, log: Bool? = nil, severity: String? = nil, meter: String? = nil, name: String? = nil, external_ids: [String: String]? = nil, tier: Int? = nil, label: Int? = nil, network_function_group: String? = nil, sample_new: String? = nil, sample_est: String? = nil, options: [String: String]? = nil) {
        self.uuid = nil
        self.priority = priority
        self.direction = direction
        self.match = match
        self.action = action
        self.log = log
        self.severity = severity
        self.meter = meter
        self.name = name
        self.tier = tier
        self.label = label
        self.network_function_group = network_function_group
        self.sample_new = sample_new
        self.sample_est = sample_est
        self.options = options
        self.external_ids = external_ids
    }
}