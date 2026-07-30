/// A row in the OVN Southbound `Datapath_Binding` table: one logical datapath,
/// which in practice is either a logical switch or a logical router pipeline.
///
/// This is the table the rest of the Southbound database hangs off.
/// `OVNPortBinding.datapath`, `OVNLogicalFlow.logical_datapath`,
/// `OVNAdvertisedRoute.datapath`, `OVNLearnedRoute.datapath`,
/// `OVNMACBinding.datapath` and the multicast tables are all UUID references
/// into it, so without these rows there is no way to answer which logical
/// switch or router a flow or binding belongs to. `datapathType` and `nb_uuid`
/// name the Northbound row directly; on a database predating those columns the
/// same answer is in `external_ids` under `logical-switch`/`logical-router`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNDatapathBinding: Codable, Sendable {
    public let uuid: String?
    /// The tunnel key the logical datapath is bound to — the only genuinely
    /// physical information a datapath has, since a pipeline has no location.
    /// `OVNFDB.dp_key` is a key in this space rather than a UUID reference.
    public let tunnel_key: Int
    /// `"logical-switch"` or `"logical-router"`: which kind of Northbound row
    /// this datapath was translated from. Unset on a Southbound database
    /// predating the column, where `external_ids` carries the same answer.
    public let datapathType: String?
    /// UUID of the corresponding Northbound `Logical_Switch` or
    /// `Logical_Router` row. Not a reference — it points into the *other*
    /// database, so ovsdb-server cannot type it as one. Unset on a database
    /// predating the column.
    public let nb_uuid: String?
    /// Unused by OVN: the schema keeps the column for backwards compatibility
    /// only. Load balancers reach a datapath through
    /// `OVNSBLoadBalancer.datapaths` and the datapath-group columns instead.
    public let load_balancers: [String]?
    /// Carries `logical-switch` or `logical-router` (the Northbound row's
    /// UUID), the `name`/`name2` ovn-northd copies from that row, and
    /// `interconn-ts` for a transit switch.
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case tunnel_key, nb_uuid, load_balancers, external_ids
        case datapathType = "type"
    }
}
