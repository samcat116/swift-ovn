#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row in the OVN Northbound `Meter` table: a named rate limiter
/// (`ovn-nbctl meter-add`). `OVNACL.meter` and `OVNLogicalFlow.controller_meter`
/// name one of these rows to rate-limit the packets an ACL logs or sends to the
/// controller; the `Copp` table references them by UUID for control-plane
/// protection.
///
/// `Meter` is a root table, so a row persists on its own — but `bands` has a
/// schema minimum of one, so a meter cannot exist without at least one
/// `OVNMeterBand`. That is why the only create is
/// `createMeter(_:withBands:)`/`createMeter(_:withBand:)`, which inserts the
/// meter and its bands in one transaction.
public struct OVNMeter: Codable, Sendable {
    public let uuid: String?
    /// Unique meter name — the schema indexes this column, so ovsdb-server
    /// rejects a duplicate. This is the name `OVNACL.meter` holds.
    public let name: String
    /// `"kbps"` (kilobits per second) or `"pktps"` (packets per second); the
    /// schema's enum allows nothing else.
    public let unit: String
    /// UUID references to this meter's `OVNMeterBand` rows. A strong reference
    /// set with a schema minimum of one: an empty `bands` is a constraint
    /// violation, and a band that nothing references is garbage-collected at
    /// commit.
    ///
    /// Optional here because a `select` of a narrowed column list omits it;
    /// every meter row ovsdb-server sends has at least one band. The create
    /// operations ignore whatever is set here and write the bands they insert.
    public let bands: [String]?
    /// When true the rate limit is applied per attachment point rather than
    /// shared across everything referencing the meter.
    public let fair: Bool?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, unit, bands, fair, external_ids
    }

    public init(name: String, unit: String, bands: [String]? = nil, fair: Bool? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.name = name
        self.unit = unit
        self.bands = bands
        self.fair = fair
        self.external_ids = external_ids
    }
}
