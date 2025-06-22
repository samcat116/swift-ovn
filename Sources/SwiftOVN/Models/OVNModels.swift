import Foundation

// MARK: - OVN Northbound Database Models

public struct OVNLogicalSwitch: Codable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let acls: [String]?
    public let qosRules: [String]?
    public let dnsRecords: [String]?
    public let loadBalancer: [String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name
        case ports
        case acls
        case qosRules = "qos_rules"
        case dnsRecords = "dns_records"
        case loadBalancer = "load_balancer"
        case other_config
        case external_ids
    }
    
    public init(name: String, ports: [String]? = nil, acls: [String]? = nil, qosRules: [String]? = nil, dnsRecords: [String]? = nil, loadBalancer: [String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.acls = acls
        self.qosRules = qosRules
        self.dnsRecords = dnsRecords
        self.loadBalancer = loadBalancer
        self.other_config = other_config
        self.external_ids = external_ids
    }
}

public struct OVNLogicalSwitchPort: Codable {
    public let uuid: String?
    public let name: String
    public let portType: String?
    public let options: [String: String]?
    public let addresses: [String]?
    public let port_security: [String]?
    public let dhcpv4_options: String?
    public let dhcpv6_options: String?
    public let tag: Int?
    public let tag_request: Int?
    public let up: Bool?
    public let enabled: Bool?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, options, addresses
        case port_security, dhcpv4_options, dhcpv6_options
        case tag, tag_request, up, enabled, external_ids
        case portType = "type"
    }
    
    public init(name: String, portType: String? = nil, options: [String: String]? = nil, addresses: [String]? = nil, port_security: [String]? = nil, dhcpv4_options: String? = nil, dhcpv6_options: String? = nil, tag: Int? = nil, tag_request: Int? = nil, up: Bool? = nil, enabled: Bool? = true, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.portType = portType
        self.options = options
        self.addresses = addresses
        self.port_security = port_security
        self.dhcpv4_options = dhcpv4_options
        self.dhcpv6_options = dhcpv6_options
        self.tag = tag
        self.tag_request = tag_request
        self.up = up
        self.enabled = enabled
        self.external_ids = external_ids
    }
}

public struct OVNLogicalRouter: Codable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let static_routes: [String]?
    public let policies: [String]?
    public let nat: [String]?
    public let load_balancer: [String]?
    public let enabled: Bool?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports, static_routes, policies, nat, load_balancer, enabled, options, external_ids
    }
    
    public init(name: String, ports: [String]? = nil, static_routes: [String]? = nil, policies: [String]? = nil, nat: [String]? = nil, load_balancer: [String]? = nil, enabled: Bool? = true, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.ports = ports
        self.static_routes = static_routes
        self.policies = policies
        self.nat = nat
        self.load_balancer = load_balancer
        self.enabled = enabled
        self.options = options
        self.external_ids = external_ids
    }
}

public struct OVNLogicalRouterPort: Codable {
    public let uuid: String?
    public let name: String
    public let mac: String
    public let networks: [String]
    public let peer: String?
    public let enabled: Bool?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, mac, networks, peer, enabled, gateway_chassis, ha_chassis_group, options, external_ids
    }
    
    public init(name: String, mac: String, networks: [String], peer: String? = nil, enabled: Bool? = true, gateway_chassis: [String]? = nil, ha_chassis_group: String? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.mac = mac
        self.networks = networks
        self.peer = peer
        self.enabled = enabled
        self.gateway_chassis = gateway_chassis
        self.ha_chassis_group = ha_chassis_group
        self.options = options
        self.external_ids = external_ids
    }
}

public struct OVNACL: Codable {
    public let uuid: String?
    public let priority: Int
    public let direction: String
    public let match: String
    public let action: String
    public let log: Bool?
    public let severity: String?
    public let meter: String?
    public let name: String?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case priority, direction, match, action, log, severity, meter, name, external_ids
    }
    
    public init(priority: Int, direction: String, match: String, action: String, log: Bool? = nil, severity: String? = nil, meter: String? = nil, name: String? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.priority = priority
        self.direction = direction
        self.match = match
        self.action = action
        self.log = log
        self.severity = severity
        self.meter = meter
        self.name = name
        self.external_ids = external_ids
    }
}

public struct OVNLoadBalancer: Codable {
    public let uuid: String?
    public let name: String
    public let vips: [String: String]
    public let protocolType: String?
    public let health_check: [String]?
    public let ip_port_mappings: [String: String]?
    public let selection_fields: [String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, vips, health_check, ip_port_mappings, selection_fields, options, external_ids
        case protocolType = "protocol"
    }
    
    public init(name: String, vips: [String: String], protocolType: String? = nil, health_check: [String]? = nil, ip_port_mappings: [String: String]? = nil, selection_fields: [String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.vips = vips
        self.protocolType = protocolType
        self.health_check = health_check
        self.ip_port_mappings = ip_port_mappings
        self.selection_fields = selection_fields
        self.options = options
        self.external_ids = external_ids
    }
}

public struct OVNNAT: Codable {
    public let uuid: String?
    public let natType: String
    public let external_ip: String
    public let external_mac: String?
    public let external_port_range: String?
    public let logical_ip: String
    public let logical_port: String?
    public let allowed_ext_ips: String?
    public let exempted_ext_ips: String?
    public let options: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case external_ip, external_mac, external_port_range, logical_ip, logical_port, allowed_ext_ips, exempted_ext_ips, options, external_ids
        case natType = "type"
    }
    
    public init(natType: String, external_ip: String, logical_ip: String, external_mac: String? = nil, external_port_range: String? = nil, logical_port: String? = nil, allowed_ext_ips: String? = nil, exempted_ext_ips: String? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.natType = natType
        self.external_ip = external_ip
        self.external_mac = external_mac
        self.external_port_range = external_port_range
        self.logical_ip = logical_ip
        self.logical_port = logical_port
        self.allowed_ext_ips = allowed_ext_ips
        self.exempted_ext_ips = exempted_ext_ips
        self.options = options
        self.external_ids = external_ids
    }
}

public struct OVNDHCPOptions: Codable {
    public let uuid: String?
    public let cidr: String
    public let options: [String: String]
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case cidr, options, external_ids
    }
    
    public init(cidr: String, options: [String: String], external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.cidr = cidr
        self.options = options
        self.external_ids = external_ids
    }
}

// MARK: - OVN Southbound Database Models

public struct OVNChassisPrivate: Codable {
    public let uuid: String?
    public let name: String
    public let chassis: String?
    public let nb_cfg: Int?
    public let nb_cfg_timestamp: Int?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, chassis, nb_cfg, nb_cfg_timestamp, external_ids
    }
}

public struct OVNChassis: Codable {
    public let uuid: String?
    public let name: String
    public let hostname: String
    public let encaps: [String]
    public let vtep_logical_switches: [String]?
    public let nb_cfg: Int?
    public let transport_zones: [String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, hostname, encaps, vtep_logical_switches, nb_cfg, transport_zones, other_config, external_ids
    }
}

public struct OVNEncap: Codable {
    public let uuid: String?
    public let encapType: String
    public let ip: String
    public let options: [String: String]?
    public let chassis_name: String?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case ip, options, chassis_name
        case encapType = "type"
    }
}

public struct OVNPortBinding: Codable {
    public let uuid: String?
    public let logical_port: String
    public let bindingType: String
    public let mac: [String]?
    public let chassis: String?
    public let datapath: String?
    public let tunnel_key: Int?
    public let parent_port: String?
    public let tag: Int?
    public let gateway_chassis: [String]?
    public let ha_chassis_group: String?
    public let up: Bool?
    public let external_ids: [String: String]?
    public let options: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, mac, chassis, datapath, tunnel_key, parent_port, tag, gateway_chassis, ha_chassis_group, up, external_ids, options
        case bindingType = "type"
    }
}

public struct OVNLogicalFlow: Codable {
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
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_datapath, logical_dp_group, pipeline, table_id, priority, match, actions, tags, controller_meter, external_ids
    }
}