/// A row in the OVN Northbound `Load_Balancer_Health_Check` table. These rows
/// are referenced from `Load_Balancer.health_check` and turn a VIP into a
/// health-checked one (`ovn-nbctl lb-add-health-check`): ovn-controller probes
/// each backend of the VIP and stops steering traffic at the ones that fail.
///
/// `Load_Balancer_Health_Check` is not a root table, so a row that no load
/// balancer references is garbage-collected when the transaction commits —
/// hence there is no unattached create on `OVNManager`.
///
/// A health check only takes effect once the load balancer also carries an
/// `ip_port_mappings` entry per backend, naming the logical port and source IP
/// the probes are sent from. The observed result of the probing lands in the
/// Southbound `Service_Monitor` table (`OVNServiceMonitor`), not here.
public struct OVNLoadBalancerHealthCheck: Codable, Sendable {
    public let uuid: String?
    /// The VIP this check covers, in the same `IP:port` spelling as the key of
    /// the owning load balancer's `vips` map. A check whose `vip` matches no
    /// key of that map is inert.
    public let vip: String
    /// Probe tuning. The keys ovn-northd reads are `interval` (seconds between
    /// probes), `timeout` (seconds to wait for a reply), `success_count`
    /// (successes before a backend is considered online) and `failure_count`.
    /// Values are strings even though they carry numbers.
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case vip, options, external_ids
    }

    public init(vip: String, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.vip = vip
        self.options = options
        self.external_ids = external_ids
    }
}
