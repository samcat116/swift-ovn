import Foundation

/// A row in the OVN Northbound `Logical_Router_Static_Route` table. These rows
/// are referenced from `Logical_Router.static_routes` and program the routes a
/// logical router applies to matching traffic.
public struct OVNLogicalRouterStaticRoute: Codable, Sendable {
    public let uuid: String?
    /// Destination network prefix (CIDR), e.g. `"10.0.0.0/24"` or `"::/0"`.
    public let ip_prefix: String
    /// Next-hop IP, or the name of an `output_port` for a link-local route.
    public let nexthop: String
    /// Name of the logical router port the packet is sent out of. This is a
    /// plain port-name string, not a UUID reference.
    public let output_port: String?
    /// Routing policy: `"dst-ip"` (default) or `"src-ip"`.
    public let policy: String?
    /// UUID reference to a `BFD` session monitoring `nexthop`.
    public let bfd: String?
    /// Named route table this route belongs to (empty string is the main table).
    public let route_table: String?
    /// Packet fields used for ECMP hashing when multiple routes share a prefix
    /// (OVN 25.03+). Plain string set, e.g. `["ip_src", "ip_dst"]`.
    public let selection_fields: [String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case ip_prefix, nexthop, output_port, policy, bfd, route_table, selection_fields, options, external_ids
    }

    public init(ip_prefix: String, nexthop: String, output_port: String? = nil, policy: String? = nil, bfd: String? = nil, route_table: String? = nil, selection_fields: [String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.ip_prefix = ip_prefix
        self.nexthop = nexthop
        self.output_port = output_port
        self.policy = policy
        self.bfd = bfd
        self.route_table = route_table
        self.selection_fields = selection_fields
        self.options = options
        self.external_ids = external_ids
    }
}
