/// A row in the OVN Southbound `IP_Multicast` table: the multicast snooping
/// configuration for one datapath, and the field values ovn-controller puts in
/// the IGMP/MLD queries it originates.
///
/// One row per datapath (the schema indexes `datapath`). ovn-northd writes it
/// from the Northbound `Logical_Switch.other_config` multicast keys;
/// ovn-controller reads it and, when `seq_no` changes, flushes every group it
/// has learned into `OVNIGMPGroup`.
///
/// Every configuration column is optional in the schema, and an unset column
/// means "use the default" rather than "off" — the defaults are noted per
/// property.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNIPMulticast: Codable, Sendable {
    public let uuid: String?
    /// UUID reference to the `OVNDatapathBinding` these options apply to.
    public let datapath: String
    /// Whether multicast snooping is on. Default when unset: disabled.
    public let enabled: Bool?
    /// Whether this datapath sends multicast queries. Default when unset:
    /// enabled, but only where `enabled` is also true.
    public let querier: Bool?
    /// Source Ethernet address for originated queries.
    public let eth_src: String?
    /// Source IPv4 address for originated queries.
    public let ip4_src: String?
    /// Source IPv6 address for originated queries.
    public let ip6_src: String?
    /// Cap on learned multicast groups per datapath. Default when unset: 2048.
    public let table_size: Int?
    /// Seconds a learned group survives without traffic. Default when unset:
    /// 300.
    public let idle_timeout: Int?
    /// Seconds between originated queries. Default when unset: half
    /// `idle_timeout`.
    public let query_interval: Int?
    /// Seconds to advertise as the query's max-response field. Default when
    /// unset: 1.
    public let query_max_resp: Int?
    /// Flush generation: ovn-controller drops every group learned for this
    /// datapath when it sees this change.
    public let seq_no: Int

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case datapath, enabled, querier, eth_src, ip4_src, ip6_src
        case table_size, idle_timeout, query_interval, query_max_resp, seq_no
    }
}
