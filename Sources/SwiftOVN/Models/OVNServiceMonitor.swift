/// A row in the OVN Southbound `Service_Monitor` table: one health probe that
/// ovn-controller runs against a single load balancer backend. ovn-northd
/// creates a row per backend of every health-checked VIP (see
/// `OVNLoadBalancerHealthCheck`), and the chassis hosting the backend writes
/// `status` back — which makes this table the only place to observe whether a
/// backend is actually considered up.
///
/// Read-only: these rows belong to ovn-northd and ovn-controller, so there is
/// no create/update path on `OVNManager` and no public initializer.
///
/// Only the columns that have been in the table since it was introduced are
/// non-optional. `chassis_name` arrived in the 24.03 schema, and
/// `monitorType`, `mac`, `logical_input_port`, `ic_learned` and `remote` are
/// newer still — a Southbound database older than the running library simply
/// does not send them, and decoding must not fail over that.
public struct OVNServiceMonitor: Codable, Sendable {
    public let uuid: String?
    /// What the probe is monitoring: `"load-balancer"`, `"network-function"`
    /// or `"logical-switch-port"`. Absent on schemas predating the column, in
    /// which case the row is a load balancer backend.
    public let monitorType: String?
    /// IP of the backend being probed.
    public let ip: String
    /// MAC of the backend being probed.
    public let mac: String?
    /// `"tcp"`, `"udp"` or `"icmp"`. Unset means the probe has no L4 protocol.
    public let protocolType: String?
    /// Port of the backend being probed.
    public let port: Int
    /// Logical port the probe is injected on, when that differs from the
    /// backend's own port.
    public let logical_input_port: String?
    /// Name of the `Logical_Switch_Port` the backend is behind. ovn-controller
    /// only runs the probe on the chassis where this port is bound.
    public let logical_port: String
    /// Source MAC the probes are sent with, from the owning load balancer's
    /// `ip_port_mappings`.
    public let src_mac: String
    /// Source IP the probes are sent from, from the owning load balancer's
    /// `ip_port_mappings`.
    public let src_ip: String
    /// Chassis running the probe, when it is pinned to one.
    public let chassis_name: String?
    /// The result: `"online"`, `"offline"` or `"error"`. Unset until the
    /// chassis has reported a first outcome — a backend with no status is not
    /// yet known to be up.
    public let status: String?
    /// Whether this row was learned from another availability zone over OVN
    /// interconnect rather than created locally.
    public let ic_learned: Bool?
    /// Whether the monitored backend lives in a remote availability zone.
    public let remote: Bool?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case ip, mac, port, logical_input_port, logical_port, src_mac, src_ip
        case chassis_name, status, ic_learned, remote, options, external_ids
        case monitorType = "type"
        case protocolType = "protocol"
    }
}
