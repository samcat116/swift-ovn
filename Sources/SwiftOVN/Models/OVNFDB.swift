/// A row in the OVN Southbound `FDB` table: one MAC address a logical switch
/// learned from traffic rather than from configuration.
///
/// ovn-controller learns into this table for a VIF whose Northbound
/// `Logical_Switch_Port` has port security disabled and `unknown` in its
/// addresses — traffic from any source MAC is allowed there, so the switch has
/// to learn where each MAC actually is in order to deliver unicast back to it.
/// A localnet port with `localnet_learn_fdb` enabled learns the same way.
///
/// Unusually for the Southbound database, this table identifies the datapath
/// and port by tunnel key rather than by UUID reference: match `dp_key` against
/// `OVNDatapathBinding.tunnel_key` and `port_key` against
/// `OVNPortBinding.tunnel_key`.
///
/// Read-only: ovn-controller owns these rows, so there is no create/update path
/// on `OVNManager` and no public initializer.
public struct OVNFDB: Codable, Sendable {
    public let uuid: String?
    /// The learned MAC address.
    public let mac: String
    /// Tunnel key of the datapath the MAC was learned on — an
    /// `OVNDatapathBinding.tunnel_key`, not a UUID.
    public let dp_key: Int
    /// Tunnel key of the port binding the MAC was learned on — an
    /// `OVNPortBinding.tunnel_key`, not a UUID.
    public let port_key: Int
    /// Milliseconds since the epoch when the entry was added or last refreshed;
    /// this is what ages an entry out. Rows written before the column existed
    /// report 0, and a Southbound database older than the column omits it
    /// entirely — hence optional.
    public let timestamp: Int?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case mac, dp_key, port_key, timestamp
    }
}
