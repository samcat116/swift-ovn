import Foundation

/// A row in the OVN Northbound `Gateway_Chassis` table. These rows are
/// referenced from `Logical_Router_Port.gateway_chassis` and pin a
/// distributed gateway port to a prioritized list of chassis, giving
/// north-south egress a failover order across hypervisors.
public struct OVNGatewayChassis: Codable, Sendable {
    public let uuid: String?
    /// Unique name for this gateway-chassis binding.
    public let name: String
    /// Name of the Southbound `Chassis` this binding places the gateway on.
    /// This is the chassis *name* string, not a UUID reference.
    public let chassis_name: String
    /// Priority of this chassis (0–32767); the highest-priority available
    /// chassis is selected as the active gateway.
    public let priority: Int
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, chassis_name, priority, options, external_ids
    }

    public init(name: String, chassis_name: String, priority: Int, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.chassis_name = chassis_name
        self.priority = priority
        self.options = options
        self.external_ids = external_ids
    }
}
