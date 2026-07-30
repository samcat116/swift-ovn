/// A row in the OVN Southbound `DNS` table: the records the `dns_lookup` action
/// answers from, scoped to a set of datapaths.
///
/// `OVNSB`-prefixed because `DNS` names a table in both databases — see
/// `OVNDNS` for the Northbound row a client writes. The difference is the
/// direction of attachment: Northbound, a `DNS` row is referenced from
/// `Logical_Switch.dns_records`; here the row names the datapaths it applies to
/// itself, which is why `datapaths` has a schema minimum of one.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBDNS: Codable, Sendable {
    public let uuid: String?
    /// Query name to a space- or comma-separated list of addresses. Names are
    /// stored lowercased so lookups can be case-insensitive.
    public let records: [String: String]?
    /// UUID references to the `OVNDatapathBinding` rows these records answer
    /// for. The schema requires at least one; optional here only because a
    /// narrowed column select would omit it.
    public let datapaths: [String]?
    /// Carries `ovn-owned`, which marks the domains as OVN's — a query for one
    /// is then answered locally or rejected rather than forwarded.
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case records, datapaths, options, external_ids
    }
}
