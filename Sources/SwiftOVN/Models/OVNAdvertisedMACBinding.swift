/// A row in the OVN Southbound `Advertised_MAC_Binding` table: one IP/MAC pair
/// a logical switch announces to the outside fabric when EVPN is enabled on its
/// datapath.
///
/// The outbound counterpart of `OVNMACBinding` — that table records what OVN
/// learned, this one what OVN publishes. It pairs with `OVNAdvertisedRoute` in
/// the same way: routes and MAC bindings are the two things the dynamic-routing
/// integration exports.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNAdvertisedMACBinding: Codable, Sendable {
    public let uuid: String?
    /// UUID reference to the `OVNDatapathBinding` of the logical switch this
    /// binding belongs to.
    public let datapath: String
    /// UUID reference to the `OVNPortBinding` this binding belongs to. Unlike
    /// `OVNMACBinding.logical_port`, which is a port name, this really is a
    /// reference.
    public let logical_port: String
    /// The announced IP address.
    public let ip: String
    /// The announced Ethernet address.
    public let mac: String
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case datapath, logical_port, ip, mac, external_ids
    }
}
