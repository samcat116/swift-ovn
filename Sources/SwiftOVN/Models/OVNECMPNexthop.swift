/// A row in the OVN Southbound `ECMP_Nexthop` table: one next hop currently
/// active for an ECMP route created with `--ecmp-symmetric-reply`.
///
/// Symmetric-reply ECMP commits its choice of next hop to the connection
/// tracker so that reply traffic takes the same path. ovn-northd records the
/// live next hops here and ovn-controller uses the table to tell which
/// conntrack entries are still wanted and flush the ones that are not — so a
/// row disappearing is what triggers cleanup.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNECMPNexthop: Codable, Sendable {
    public let uuid: String?
    /// The next-hop IP address: either a connected router port's address or an
    /// external device's.
    public let nexthop: String
    /// UUID reference to the `OVNPortBinding` used to reach `nexthop`.
    public let port: String
    /// UUID reference to the `OVNDatapathBinding` `port` runs on.
    public let datapath: String
    /// The next hop's Ethernet address.
    public let mac: String
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case nexthop, port, datapath, mac, external_ids
    }
}
