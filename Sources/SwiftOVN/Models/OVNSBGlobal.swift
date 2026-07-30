#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The one row of the OVN Southbound `SB_Global` table (`maxRows: 1`): the
/// southbound counterpart of `OVNNBGlobal`, holding the same connection, TLS
/// and IPsec configuration plus the sequence number the hypervisors read.
///
/// The `nb_cfg` here is not the northbound one a client increments — ovn-northd
/// copies `NB_Global.nb_cfg` into it once it has translated that generation of
/// northbound configuration into logical flows, and ovn-controller on each
/// chassis copies it onwards into its own `Chassis_Private.nb_cfg` once it has
/// installed them. Reading it says how far the southbound side of the barrier
/// has got; `NB_Global.sb_cfg` is where northd reports the same thing back to
/// northbound clients, which is what `waitForNorthd(timeout:)` waits on.
///
/// There is no `name` column: this row carries one sequence number, with its
/// timestamp, rather than the three the northbound row reconciles.
public struct OVNSBGlobal: Codable, Sendable {
    public let uuid: String?
    /// The generation of northbound configuration ovn-northd has published to
    /// this database.
    public let nb_cfg: Int
    /// Milliseconds since the epoch at which ovn-northd last wrote `nb_cfg`,
    /// set atomically with it. A hypervisor measures end-to-end propagation
    /// latency by comparing this against when it finished programming its own
    /// datapath. Absent on a Southbound database predating the column.
    public let nb_cfg_timestamp: Int?
    /// UUID references to the `OVNSBConnection` rows describing the remote
    /// endpoints ovsdb-server listens on or connects to; resolve them with
    /// `getConnections()`.
    public let connections: [String]?
    /// UUID reference to the `OVNSBSSL` row holding this database's TLS
    /// material; resolve it with `getSSL()`.
    public let ssl: String?
    /// Whether tunnel traffic between chassis is IPsec-encrypted.
    public let ipsec: Bool
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case nb_cfg, nb_cfg_timestamp, connections, ssl, ipsec, options, external_ids
    }
}
