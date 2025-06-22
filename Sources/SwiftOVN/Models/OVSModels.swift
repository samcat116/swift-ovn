import Foundation

// MARK: - Open vSwitch Database Models

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
}

public struct OVSPort: Codable {
    public let uuid: String?
    public let name: String
    public let interfaces: [String]
    public let trunks: [Int]?
    public let tag: Int?
    public let vlan_mode: String?
    public let qos: String?
    public let mac: String?
    public let bond_mode: String?
    public let lacp: String?
    public let bond_updelay: Int?
    public let bond_downdelay: Int?
    public let bond_fake_iface: Bool?
    public let fake_bridge: Bool?
    public let status: [String: String]?
    public let statistics: [String: Int]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, interfaces, trunks, tag, vlan_mode, qos, mac, bond_mode, lacp, bond_updelay, bond_downdelay, bond_fake_iface, fake_bridge, status, statistics, other_config, external_ids
    }
    
    public init(name: String, interfaces: [String], trunks: [Int]? = nil, tag: Int? = nil, vlan_mode: String? = nil, qos: String? = nil, mac: String? = nil, bond_mode: String? = nil, lacp: String? = nil, bond_updelay: Int? = nil, bond_downdelay: Int? = nil, bond_fake_iface: Bool? = nil, fake_bridge: Bool? = nil, status: [String: String]? = nil, statistics: [String: Int]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.interfaces = interfaces
        self.trunks = trunks
        self.tag = tag
        self.vlan_mode = vlan_mode
        self.qos = qos
        self.mac = mac
        self.bond_mode = bond_mode
        self.lacp = lacp
        self.bond_updelay = bond_updelay
        self.bond_downdelay = bond_downdelay
        self.bond_fake_iface = bond_fake_iface
        self.fake_bridge = fake_bridge
        self.status = status
        self.statistics = statistics
        self.other_config = other_config
        self.external_ids = external_ids
    }
}

public struct OVSInterface: Codable {
    public let uuid: String?
    public let name: String
    public let interfaceType: String?
    public let options: [String: String]?
    public let ingress_policing_rate: Int?
    public let ingress_policing_burst: Int?
    public let mac_in_use: String?
    public let mac: String?
    public let ifindex: Int?
    public let external_ids: [String: String]?
    public let other_config: [String: String]?
    public let statistics: [String: Int]?
    public let status: [String: String]?
    public let admin_state: String?
    public let link_state: String?
    public let link_resets: Int?
    public let link_speed: Int?
    public let duplex: String?
    public let mtu: Int?
    public let error: String?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, options, ingress_policing_rate, ingress_policing_burst, mac_in_use, mac, ifindex, external_ids, other_config, statistics, status, admin_state, link_state, link_resets, link_speed, duplex, mtu, error
        case interfaceType = "type"
    }
    
    public init(name: String, interfaceType: String? = nil, options: [String: String]? = nil, ingress_policing_rate: Int? = nil, ingress_policing_burst: Int? = nil, mac_in_use: String? = nil, mac: String? = nil, ifindex: Int? = nil, external_ids: [String: String]? = nil, other_config: [String: String]? = nil, statistics: [String: Int]? = nil, status: [String: String]? = nil, admin_state: String? = nil, link_state: String? = nil, link_resets: Int? = nil, link_speed: Int? = nil, duplex: String? = nil, mtu: Int? = nil, error: String? = nil) {
        self.uuid = nil
        self.name = name
        self.interfaceType = interfaceType
        self.options = options
        self.ingress_policing_rate = ingress_policing_rate
        self.ingress_policing_burst = ingress_policing_burst
        self.mac_in_use = mac_in_use
        self.mac = mac
        self.ifindex = ifindex
        self.external_ids = external_ids
        self.other_config = other_config
        self.statistics = statistics
        self.status = status
        self.admin_state = admin_state
        self.link_state = link_state
        self.link_resets = link_resets
        self.link_speed = link_speed
        self.duplex = duplex
        self.mtu = mtu
        self.error = error
    }
}

public struct OVSController: Codable {
    public let uuid: String?
    public let target: String
    public let max_backoff: Int?
    public let inactivity_probe: Int?
    public let connection_mode: String?
    public let enable_async_messages: Bool?
    public let controller_rate_limit: Int?
    public let controller_burst_limit: Int?
    public let local_ip: String?
    public let local_netmask: String?
    public let local_gateway: String?
    public let status: [String: String]?
    public let role: String?
    public let external_ids: [String: String]?
    public let other_config: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case target, max_backoff, inactivity_probe, connection_mode, enable_async_messages, controller_rate_limit, controller_burst_limit, local_ip, local_netmask, local_gateway, status, role, external_ids, other_config
    }
    
    public init(target: String, max_backoff: Int? = nil, inactivity_probe: Int? = nil, connection_mode: String? = nil, enable_async_messages: Bool? = nil, controller_rate_limit: Int? = nil, controller_burst_limit: Int? = nil, local_ip: String? = nil, local_netmask: String? = nil, local_gateway: String? = nil, status: [String: String]? = nil, role: String? = nil, external_ids: [String: String]? = nil, other_config: [String: String]? = nil) {
        self.uuid = nil
        self.target = target
        self.max_backoff = max_backoff
        self.inactivity_probe = inactivity_probe
        self.connection_mode = connection_mode
        self.enable_async_messages = enable_async_messages
        self.controller_rate_limit = controller_rate_limit
        self.controller_burst_limit = controller_burst_limit
        self.local_ip = local_ip
        self.local_netmask = local_netmask
        self.local_gateway = local_gateway
        self.status = status
        self.role = role
        self.external_ids = external_ids
        self.other_config = other_config
    }
}

public struct OVSOpenFlow: Codable {
    public let uuid: String?
    public let bridge: String
    public let version: [String]
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case bridge, version
    }
}

public struct OVSFlow: Codable {
    public let table: Int?
    public let priority: Int?
    public let match: String?
    public let actions: String?
    public let idle_timeout: Int?
    public let hard_timeout: Int?
    public let cookie: String?
    public let packet_count: Int?
    public let byte_count: Int?
    public let duration: String?
    
    public init(table: Int? = nil, priority: Int? = nil, match: String? = nil, actions: String? = nil, idle_timeout: Int? = nil, hard_timeout: Int? = nil, cookie: String? = nil, packet_count: Int? = nil, byte_count: Int? = nil, duration: String? = nil) {
        self.table = table
        self.priority = priority
        self.match = match
        self.actions = actions
        self.idle_timeout = idle_timeout
        self.hard_timeout = hard_timeout
        self.cookie = cookie
        self.packet_count = packet_count
        self.byte_count = byte_count
        self.duration = duration
    }
}

public struct OVSMirror: Codable {
    public let uuid: String?
    public let name: String
    public let select_all: Bool?
    public let select_src_port: [String]?
    public let select_dst_port: [String]?
    public let select_vlan: [Int]?
    public let output_port: String?
    public let output_vlan: Int?
    public let snaplen: Int?
    public let external_ids: [String: String]?
    public let statistics: [String: Int]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, select_all, select_src_port, select_dst_port, select_vlan, output_port, output_vlan, snaplen, external_ids, statistics
    }
    
    public init(name: String, select_all: Bool? = nil, select_src_port: [String]? = nil, select_dst_port: [String]? = nil, select_vlan: [Int]? = nil, output_port: String? = nil, output_vlan: Int? = nil, snaplen: Int? = nil, external_ids: [String: String]? = nil, statistics: [String: Int]? = nil) {
        self.uuid = nil
        self.name = name
        self.select_all = select_all
        self.select_src_port = select_src_port
        self.select_dst_port = select_dst_port
        self.select_vlan = select_vlan
        self.output_port = output_port
        self.output_vlan = output_vlan
        self.snaplen = snaplen
        self.external_ids = external_ids
        self.statistics = statistics
    }
}

public struct OVSNetFlow: Codable {
    public let uuid: String?
    public let targets: [String]
    public let engine_type: Int?
    public let engine_id: Int?
    public let add_id_to_interface: Bool?
    public let active_timeout: Int?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case targets, engine_type, engine_id, add_id_to_interface, active_timeout, external_ids
    }
    
    public init(targets: [String], engine_type: Int? = nil, engine_id: Int? = nil, add_id_to_interface: Bool? = nil, active_timeout: Int? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.targets = targets
        self.engine_type = engine_type
        self.engine_id = engine_id
        self.add_id_to_interface = add_id_to_interface
        self.active_timeout = active_timeout
        self.external_ids = external_ids
    }
}

public struct OVSQoS: Codable {
    public let uuid: String?
    public let qosType: String
    public let queues: [Int: String]?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case queues, other_config, external_ids
        case qosType = "type"
    }
    
    public init(qosType: String, queues: [Int: String]? = nil, other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.qosType = qosType
        self.queues = queues
        self.other_config = other_config
        self.external_ids = external_ids
    }
}

public struct OVSQueue: Codable {
    public let uuid: String?
    public let other_config: [String: String]?
    public let external_ids: [String: String]?
    
    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case other_config, external_ids
    }
    
    public init(other_config: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.other_config = other_config
        self.external_ids = external_ids
    }
}