/// A row in the OVN Southbound `Load_Balancer` table: the load balancer as
/// ovn-northd published it to the hypervisors.
///
/// `OVNSB`-prefixed because `Load_Balancer` names a table in both databases with
/// different columns — see `OVNLoadBalancer` for the Northbound row a client
/// writes. The difference that matters is what the row is attached to: a
/// Northbound load balancer is referenced *from* `Logical_Switch.load_balancer`
/// and `Logical_Router.load_balancer`, whereas here the row itself names the
/// datapaths it applies to. Health checking has no Southbound counterpart on
/// this row either; its results are in `OVNServiceMonitor`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBLoadBalancer: Codable, Sendable {
    public let uuid: String?
    /// The Northbound load balancer's name, carried over for human
    /// consumption; it has no functional meaning here.
    public let name: String
    /// VIP (optionally `address:port`) to a comma-separated list of backends,
    /// copied from the Northbound row.
    public let vips: [String: String]?
    /// `"tcp"`, `"udp"` or `"sctp"`. Unset means tcp when the VIPs carry port
    /// numbers.
    public let protocolType: String?
    /// UUID references to the `OVNDatapathBinding` rows the load balancer
    /// applies to, where northd listed them individually.
    public let datapaths: [String]?
    /// Deprecated: the pre-split single datapath group. Current ovn-northd
    /// writes `ls_datapath_group`/`lr_datapath_group` instead, so this reads as
    /// nil against a current deployment.
    public let datapath_group: String?
    /// UUID reference to the `OVNLogicalDPGroup` of logical switch datapaths
    /// this load balancer applies to. The group form is how northd avoids
    /// listing every datapath on a load balancer attached widely.
    public let ls_datapath_group: String?
    /// UUID reference to the `OVNLogicalDPGroup` of logical router datapaths
    /// this load balancer applies to.
    public let lr_datapath_group: String?
    /// Carries `hairpin_snat_ip`, the source address northd picked for
    /// hairpinned traffic, among others.
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, vips, datapaths, datapath_group
        case ls_datapath_group, lr_datapath_group, options, external_ids
        case protocolType = "protocol"
    }
}
