#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

public struct OVNLogicalRouter: Codable, Sendable {
    public let uuid: String?
    public let name: String
    public let ports: [String]?
    public let static_routes: [String]?
    public let policies: [String]?
    public let nat: [String]?
    public let load_balancer: [String]?
    /// UUIDs of the `OVNLoadBalancerGroup` rows applied to this router. Unlike
    /// `load_balancer`, which is a weak reference set, these are *strong*
    /// references: a group cannot be deleted while a router still names it.
    public let load_balancer_group: [String]?
    /// `Copp` (control-plane protection) reference. That table is not modeled
    /// yet, so this stays a UUID string.
    public let copp: String?
    public let enabled: Bool?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, ports, static_routes, policies, nat, load_balancer, enabled, options, external_ids
        case load_balancer_group, copp
    }

    public init(name: String, ports: [String]? = nil, static_routes: [String]? = nil, policies: [String]? = nil, nat: [String]? = nil, load_balancer: [String]? = nil, enabled: Bool? = true, options: [String: String]? = nil, external_ids: [String: String]? = nil, load_balancer_group: [String]? = nil, copp: String? = nil) {
        self.init(
            uuid: nil,
            name: name,
            ports: ports,
            static_routes: static_routes,
            policies: policies,
            nat: nat,
            load_balancer: load_balancer,
            enabled: enabled,
            options: options,
            external_ids: external_ids,
            load_balancer_group: load_balancer_group,
            copp: copp
        )
    }

    init(uuid: String?, name: String, ports: [String]? = nil, static_routes: [String]? = nil, policies: [String]? = nil, nat: [String]? = nil, load_balancer: [String]? = nil, enabled: Bool? = true, options: [String: String]? = nil, external_ids: [String: String]? = nil, load_balancer_group: [String]? = nil, copp: String? = nil) {
        self.uuid = uuid
        self.name = name
        self.ports = ports
        self.static_routes = static_routes
        self.policies = policies
        self.nat = nat
        self.load_balancer = load_balancer
        self.load_balancer_group = load_balancer_group
        self.copp = copp
        self.enabled = enabled
        self.options = options
        self.external_ids = external_ids
    }
}
