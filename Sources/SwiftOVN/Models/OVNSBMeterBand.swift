/// A row in the OVN Southbound `Meter_Band` table: the rate and burst an
/// `OVNSBMeter` enforces, and what happens above it.
///
/// `OVNSB`-prefixed because `Meter_Band` names a table in both databases — see
/// `OVNMeterBand` for the Northbound row. The columns are identical apart from
/// `external_ids`, which the Southbound table does not have.
///
/// Not a root table: a band exists only while an `OVNSBMeter.bands` set
/// references it.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBMeterBand: Codable, Sendable {
    public let uuid: String?
    /// What happens to traffic over the rate; `"drop"` is the only value the
    /// schema's enum allows.
    public let action: String
    /// The rate limit, in the unit of the meter this band belongs to.
    public let rate: Int
    /// Burst allowed above `rate`, in the meter's unit.
    public let burst_size: Int

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case action, rate, burst_size
    }
}
