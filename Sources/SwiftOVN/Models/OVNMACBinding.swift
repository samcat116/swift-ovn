/// A row in the OVN Southbound `MAC_Binding` table: one IP-to-MAC binding a
/// logical router discovered through ARP (IPv4) or neighbour discovery (IPv6).
///
/// The table expresses a function — `(logical_port, ip) → mac` — and exists
/// mainly for addresses on physical networks, since a virtual machine's binding
/// is usually static in `Port_Binding`. ovn-controller inserts a row when a
/// router's `put_arp` action resolves an address, and every other hypervisor
/// then forwards straight to the bound MAC. Reading it is how a stale or
/// unexpected neighbour entry on a router port is found.
///
/// The statically configured counterpart is `OVNSBStaticMACBinding`.
///
/// Read-only: ovn-controller owns these rows, so there is no create/update path
/// on `OVNManager` and no public initializer.
public struct OVNMACBinding: Codable, Sendable {
    public let uuid: String?
    /// Name of the logical router port the binding was discovered on. A port
    /// *name*, not a UUID reference.
    public let logical_port: String
    /// The bound IP address.
    public let ip: String
    /// The Ethernet address `ip` is bound to.
    public let mac: String
    /// Milliseconds since the epoch when the binding was added or last
    /// refreshed. Rows written before the column existed report 0, and a
    /// Southbound database older than the column omits it entirely — hence
    /// optional.
    public let timestamp: Int?
    /// UUID reference to the `OVNDatapathBinding` of the router `logical_port`
    /// belongs to.
    public let datapath: String

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case logical_port, ip, mac, timestamp, datapath
    }
}
