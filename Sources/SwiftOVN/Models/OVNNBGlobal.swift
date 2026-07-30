#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The one row of the OVN Northbound `NB_Global` table (`maxRows: 1`): the
/// database's global configuration, and the sequence numbers that say how far a
/// write has travelled towards the dataplane.
///
/// `nb_cfg` is bumped by a client (`incrementNBCfg()`) once its writes are
/// committed. ovn-northd copies that value into `sb_cfg` when it has translated
/// the northbound contents into southbound logical flows, and into `hv_cfg`
/// once every chassis has caught up with those flows. So `sb_cfg >= n` means
/// northd has processed everything committed before `nb_cfg` reached `n`, and
/// `hv_cfg >= n` means every hypervisor has. That is the barrier
/// `ovn-nbctl --wait=sb` and `--wait=hv` are built on, and what
/// `waitForNorthd(timeout:)` / `waitForHypervisors(timeout:)` implement.
///
/// The `*_timestamp` columns are the wall-clock milliseconds at which each
/// counter last changed, which is what makes the round-trip latency measurable.
/// They are optional here because they were added to the schema later than the
/// counters themselves (NB schema 5.20), so an older ovsdb-server omits them.
public struct OVNNBGlobal: Codable, Sendable {
    public let uuid: String?
    /// The deployment's name, as set by `ovn-nbctl set NB_Global . name=...`.
    /// Empty unless something set it.
    public let name: String
    /// The client-side sequence number. Monotonically increasing; only clients
    /// write it, and only ever by incrementing.
    public let nb_cfg: Int
    /// Milliseconds since the epoch at which `nb_cfg` last changed.
    public let nb_cfg_timestamp: Int?
    /// How far ovn-northd has got: the `nb_cfg` value whose northbound contents
    /// it has finished translating into the southbound database.
    public let sb_cfg: Int
    /// Milliseconds since the epoch at which `sb_cfg` last changed.
    public let sb_cfg_timestamp: Int?
    /// How far the hypervisors have got: the smallest `nb_cfg` any chassis has
    /// acknowledged, so it never runs ahead of `sb_cfg`. A chassis that is down
    /// holds this back — that is why `ovn-nbctl --wait=hv` can hang on an
    /// otherwise healthy deployment.
    public let hv_cfg: Int
    /// Milliseconds since the epoch at which `hv_cfg` last changed.
    public let hv_cfg_timestamp: Int?
    /// UUID references to the `Connection` rows describing the remote endpoints
    /// ovsdb-server listens on or connects to.
    public let connections: [String]?
    /// UUID reference to the `SSL` row holding this database's TLS material.
    public let ssl: String?
    /// Whether tunnel traffic between chassis is IPsec-encrypted.
    public let ipsec: Bool
    /// Global ovn-northd options (`mac_prefix`, `northd_probe_interval`,
    /// `svc_monitor_mac`, …). Change entries with
    /// `updateNBGlobalOptions(_:)` rather than writing the column wholesale:
    /// ovn-northd stores generated state here that a full replacement would
    /// destroy.
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, nb_cfg, nb_cfg_timestamp, sb_cfg, sb_cfg_timestamp
        case hv_cfg, hv_cfg_timestamp, connections, ssl, ipsec, options, external_ids
    }
}
