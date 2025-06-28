import Foundation

public struct OVSBridge: Codable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let mirrors: [String]?
    public let netflow: String?
    public let sflow: String?
    public let ipfix: String?
    public let controller: [String]?
    public let protocols: [String]?
    public let fail_mode: String?
    public let status: [String: String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    public let flood_vlans: [Int]?
    public let flow_tables: [String: String]?
    public let mcast_snooping_enable: Bool?
    public let rstp_enable: Bool?
    public let rstp_status: [String: String]?
    public let stp_enable: Bool?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports, mirrors, netflow, sflow, ipfix, controller, protocols, fail_mode, status, other_config, external_ids, flood_vlans, flow_tables, mcast_snooping_enable, rstp_enable, rstp_status, stp_enable
    }
    
    public init(name: String, ports: [String]? = nil, mirrors: [String]? = nil, netflow: String? = nil, sflow: String? = nil, ipfix: String? = nil, controller: [String]? = nil, protocols: [String]? = nil, fail_mode: String? = nil, status: [String: String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil, flood_vlans: [Int]? = nil, flow_tables: [String: String]? = nil, mcast_snooping_enable: Bool? = nil, rstp_enable: Bool? = nil, rstp_status: [String: String]? = nil, stp_enable: Bool? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.mirrors = mirrors
        self.netflow = netflow
        self.sflow = sflow
        self.ipfix = ipfix
        self.controller = controller
        self.protocols = protocols
        self.fail_mode = fail_mode
        self.status = status
        self.other_config = other_config
        self.external_ids = external_ids
        self.flood_vlans = flood_vlans
        self.flow_tables = flow_tables
        self.mcast_snooping_enable = mcast_snooping_enable
        self.rstp_enable = rstp_enable
        self.rstp_status = rstp_status
        self.stp_enable = stp_enable
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        
        uuid = try container.decodeIfPresent(String.self, forKey: .uuid)
        name = try container.decode(String.self, forKey: .name)
        fail_mode = try container.decodeIfPresent(String.self, forKey: .fail_mode)
        status = try container.decodeIfPresent([String: String].self, forKey: .status)
        other_config = try container.decodeIfPresent([String: String].self, forKey: .other_config)
        external_ids = try container.decodeIfPresent([String: String].self, forKey: .external_ids)
        flow_tables = try container.decodeIfPresent([String: String].self, forKey: .flow_tables)
        mcast_snooping_enable = try container.decodeIfPresent(Bool.self, forKey: .mcast_snooping_enable)
        rstp_enable = try container.decodeIfPresent(Bool.self, forKey: .rstp_enable)
        rstp_status = try container.decodeIfPresent([String: String].self, forKey: .rstp_status)
        stp_enable = try container.decodeIfPresent(Bool.self, forKey: .stp_enable)
        
        // Handle fields that might be single values or arrays
        ports = try Self.decodeStringArrayOrSingle(from: container, forKey: .ports)
        mirrors = try Self.decodeStringArrayOrSingle(from: container, forKey: .mirrors)
        controller = try Self.decodeStringArrayOrSingle(from: container, forKey: .controller)
        protocols = try Self.decodeStringArrayOrSingle(from: container, forKey: .protocols)
        
        // Handle fields that might be single strings or arrays, but we only need the first value
        netflow = try Self.decodeFirstStringOrNull(from: container, forKey: .netflow)
        sflow = try Self.decodeFirstStringOrNull(from: container, forKey: .sflow)
        ipfix = try Self.decodeFirstStringOrNull(from: container, forKey: .ipfix)
        
        // Handle flood_vlans which might be a single int or array of ints
        if container.contains(.flood_vlans) {
            if let singleValue = try? container.decode(Int.self, forKey: .flood_vlans) {
                flood_vlans = [singleValue]
            } else {
                flood_vlans = try container.decodeIfPresent([Int].self, forKey: .flood_vlans)
            }
        } else {
            flood_vlans = nil
        }
    }
    
    private static func decodeStringArrayOrSingle(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> [String]? {
        if !container.contains(key) {
            return nil
        }
        
        if let singleValue = try? container.decode(String.self, forKey: key) {
            return [singleValue]
        } else if let arrayValue = try? container.decode([String].self, forKey: key) {
            return arrayValue
        } else {
            return nil
        }
    }
    
    private static func decodeFirstStringOrNull(from container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> String? {
        if !container.contains(key) {
            return nil
        }
        
        if let singleValue = try? container.decode(String.self, forKey: key) {
            return singleValue
        } else if let arrayValue = try? container.decode([String].self, forKey: key) {
            return arrayValue.first
        } else {
            return nil
        }
    }
}