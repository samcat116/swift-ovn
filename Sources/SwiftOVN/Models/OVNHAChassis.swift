import Foundation

/// A row in the OVN Northbound `HA_Chassis` table. These rows are referenced
/// from `HA_Chassis_Group.ha_chassis` and give one chassis a priority within
/// an HA group used for gateway active/backup failover.
public struct OVNHAChassis: Codable, Sendable {
    public let uuid: String?
    /// Name of the Southbound `Chassis` this HA member refers to. This is the
    /// chassis *name* string, not a UUID reference.
    public let chassis_name: String
    /// Priority of this chassis within its group (0–32767); the
    /// highest-priority available chassis becomes active.
    public let priority: Int
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case chassis_name, priority, external_ids
    }

    public init(chassis_name: String, priority: Int, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.chassis_name = chassis_name
        self.priority = priority
        self.external_ids = external_ids
    }
}
