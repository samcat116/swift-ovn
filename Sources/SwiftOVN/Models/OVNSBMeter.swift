/// A row in the OVN Southbound `Meter` table: the rate limiter as ovn-northd
/// published it to the hypervisors.
///
/// `OVNSB`-prefixed because `Meter` names a table in both databases — see
/// `OVNMeter` for the Northbound row a client writes. The Southbound row has no
/// `fair` column and no `external_ids`; the per-attachment-point behaviour
/// `fair` selects is expressed instead by northd emitting a separate Southbound
/// meter (with a generated name) per attachment point.
/// `OVNLogicalFlow.controller_meter` names one of these rows.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBMeter: Codable, Sendable {
    public let uuid: String?
    /// The meter's name, as `OVNLogicalFlow.controller_meter` spells it.
    public let name: String
    /// `"kbps"` or `"pktps"`.
    public let unit: String
    /// UUID references to this meter's `OVNSBMeterBand` rows. A strong
    /// reference set with a schema minimum of one; optional here only because a
    /// narrowed column select would omit it.
    public let bands: [String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, unit, bands
    }
}
