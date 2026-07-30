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
/// There is no `name` column, and no `*_timestamp` columns: this row carries
/// one sequence number rather than the three the northbound row reconciles.
public struct OVNSBGlobal: Codable, Sendable {
    public let uuid: String?
    /// The generation of northbound configuration ovn-northd has published to
    /// this database.
    public let nb_cfg: Int
    /// UUID references to the `Connection` rows describing the remote endpoints
    /// ovsdb-server listens on or connects to.
    public let connections: [String]?
    /// UUID reference to the `SSL` row holding this database's TLS material.
    public let ssl: String?
    /// Whether tunnel traffic between chassis is IPsec-encrypted.
    public let ipsec: Bool
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case nb_cfg, connections, ssl, ipsec, options, external_ids
    }
}
