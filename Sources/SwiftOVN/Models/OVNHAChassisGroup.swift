import Foundation

/// A row in the OVN Northbound `HA_Chassis_Group` table. Referenced (weakly)
/// from `Logical_Router_Port.ha_chassis_group` and `Logical_Switch_Port`, it
/// groups `HA_Chassis` members that back a gateway with active/backup
/// failover. This is a root table, so a group persists even when no port
/// references it.
public struct OVNHAChassisGroup: Codable, Sendable {
    public let uuid: String?
    /// Unique name for this HA chassis group.
    public let name: String
    /// UUID references to the `HA_Chassis` rows that make up this group.
    public let ha_chassis: [String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ha_chassis, external_ids
    }

    public init(name: String, ha_chassis: [String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ha_chassis = ha_chassis
        self.external_ids = external_ids
    }
}
