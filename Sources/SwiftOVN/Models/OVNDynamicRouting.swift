import Foundation

public enum OVNDynamicRoutingRedistribute: String, CaseIterable, Sendable {
    case connected
    case connectedAsHost = "connected-as-host"
    case staticRoutes = "static"
    case nat
    case loadBalancer = "lb"
    case hubSpoke = "hub-spoke"
}

public enum OVNRoutingProtocol: String, CaseIterable, Sendable {
    case bgp = "BGP"
    case bfd = "BFD"
}

public extension OVNLogicalRouter {
    var dynamicRoutingEnabled: Bool {
        options?[OVNDynamicRoutingOption.dynamicRouting] == "true"
    }

    var dynamicRoutingRedistribute: Set<OVNDynamicRoutingRedistribute> {
        OVNDynamicRoutingOption.redistributeValues(from: options?[OVNDynamicRoutingOption.redistribute])
    }

    func withDynamicRouting(
        enabled: Bool = true,
        redistribute: Set<OVNDynamicRoutingRedistribute>? = nil,
        vrfID: UInt32? = nil,
        vrfName: String? = nil,
        noLearning: Bool? = nil,
        ipv4PrefixNexthop: String? = nil,
        ipv6PrefixNexthop: String? = nil
    ) -> OVNLogicalRouter {
        var updatedOptions = options ?? [:]
        updatedOptions[OVNDynamicRoutingOption.dynamicRouting] = String(enabled)

        if let redistribute {
            updatedOptions[OVNDynamicRoutingOption.redistribute] = OVNDynamicRoutingOption.redistributeString(redistribute)
        }
        if let vrfID {
            updatedOptions[OVNDynamicRoutingOption.vrfID] = String(vrfID)
        }
        if let vrfName {
            updatedOptions[OVNDynamicRoutingOption.vrfName] = vrfName
        }
        if let noLearning {
            updatedOptions[OVNDynamicRoutingOption.noLearning] = String(noLearning)
        }
        if let ipv4PrefixNexthop {
            updatedOptions[OVNDynamicRoutingOption.ipv4PrefixNexthop] = ipv4PrefixNexthop
        }
        if let ipv6PrefixNexthop {
            updatedOptions[OVNDynamicRoutingOption.ipv6PrefixNexthop] = ipv6PrefixNexthop
        }

        return copy(options: updatedOptions)
    }

    func withoutDynamicRouting() -> OVNLogicalRouter {
        var updatedOptions = options ?? [:]
        for key in OVNDynamicRoutingOption.logicalRouterKeys {
            updatedOptions.removeValue(forKey: key)
        }
        return copy(options: updatedOptions.isEmpty ? nil : updatedOptions)
    }

    private func copy(options: [String: String]?) -> OVNLogicalRouter {
        OVNLogicalRouter(
            uuid: uuid,
            name: name,
            ports: ports,
            static_routes: static_routes,
            policies: policies,
            nat: nat,
            load_balancer: load_balancer,
            enabled: enabled,
            options: options,
            external_ids: external_ids
        )
    }
}

public extension OVNLogicalRouterPort {
    var dynamicRoutingRedistribute: Set<OVNDynamicRoutingRedistribute> {
        OVNDynamicRoutingOption.redistributeValues(from: options?[OVNDynamicRoutingOption.redistribute])
    }

    var routingProtocols: Set<OVNRoutingProtocol> {
        OVNDynamicRoutingOption.routingProtocolValues(from: options?[OVNDynamicRoutingOption.routingProtocols])
    }

    func withDynamicRouting(
        redistribute: Set<OVNDynamicRoutingRedistribute>? = nil,
        maintainVRF: Bool? = nil,
        noLearning: Bool? = nil,
        portName: String? = nil,
        routingProtocols: Set<OVNRoutingProtocol>? = nil,
        routingProtocolRedirect: String? = nil
    ) -> OVNLogicalRouterPort {
        var updatedOptions = options ?? [:]

        if let redistribute {
            updatedOptions[OVNDynamicRoutingOption.redistribute] = OVNDynamicRoutingOption.redistributeString(redistribute)
        }
        if let maintainVRF {
            updatedOptions[OVNDynamicRoutingOption.maintainVRF] = String(maintainVRF)
        }
        if let noLearning {
            updatedOptions[OVNDynamicRoutingOption.noLearning] = String(noLearning)
        }
        if let portName {
            updatedOptions[OVNDynamicRoutingOption.portName] = portName
        }
        if let routingProtocols {
            updatedOptions[OVNDynamicRoutingOption.routingProtocols] = OVNDynamicRoutingOption.routingProtocolString(routingProtocols)
        }
        if let routingProtocolRedirect {
            updatedOptions[OVNDynamicRoutingOption.routingProtocolRedirect] = routingProtocolRedirect
        }

        return copy(options: updatedOptions)
    }

    func withoutDynamicRoutingOverrides() -> OVNLogicalRouterPort {
        var updatedOptions = options ?? [:]
        for key in OVNDynamicRoutingOption.logicalRouterPortKeys {
            updatedOptions.removeValue(forKey: key)
        }
        return copy(options: updatedOptions.isEmpty ? nil : updatedOptions)
    }

    private func copy(options: [String: String]?) -> OVNLogicalRouterPort {
        OVNLogicalRouterPort(
            uuid: uuid,
            name: name,
            mac: mac,
            networks: networks,
            peer: peer,
            enabled: enabled,
            gateway_chassis: gateway_chassis,
            ha_chassis_group: ha_chassis_group,
            options: options,
            external_ids: external_ids
        )
    }
}

private enum OVNDynamicRoutingOption {
    static let dynamicRouting = "dynamic-routing"
    static let redistribute = "dynamic-routing-redistribute"
    static let noLearning = "dynamic-routing-no-learning"
    static let vrfID = "dynamic-routing-vrf-id"
    static let vrfName = "dynamic-routing-vrf-name"
    static let ipv4PrefixNexthop = "dynamic-routing-v4-prefix-nexthop"
    static let ipv6PrefixNexthop = "dynamic-routing-v6-prefix-nexthop"
    static let maintainVRF = "dynamic-routing-maintain-vrf"
    static let portName = "dynamic-routing-port-name"
    static let routingProtocols = "routing-protocols"
    static let routingProtocolRedirect = "routing-protocol-redirect"

    static let logicalRouterKeys: Set<String> = [
        dynamicRouting,
        redistribute,
        noLearning,
        vrfID,
        vrfName,
        ipv4PrefixNexthop,
        ipv6PrefixNexthop,
    ]

    static let logicalRouterPortKeys: Set<String> = [
        redistribute,
        noLearning,
        maintainVRF,
        portName,
        routingProtocols,
        routingProtocolRedirect,
    ]

    static func redistributeString(_ values: Set<OVNDynamicRoutingRedistribute>) -> String {
        values.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func redistributeValues(from value: String?) -> Set<OVNDynamicRoutingRedistribute> {
        guard let value else { return [] }
        return Set(value.split(separator: ",").compactMap { OVNDynamicRoutingRedistribute(rawValue: String($0)) })
    }

    static func routingProtocolString(_ values: Set<OVNRoutingProtocol>) -> String {
        values.map(\.rawValue).sorted().joined(separator: ",")
    }

    static func routingProtocolValues(from value: String?) -> Set<OVNRoutingProtocol> {
        guard let value else { return [] }
        return Set(value.split(separator: ",").compactMap { OVNRoutingProtocol(rawValue: String($0)) })
    }
}
