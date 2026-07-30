#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row in the OVN Northbound `Meter_Band` table: the rate and burst a
/// `OVNMeter` enforces, and what happens to the traffic above it.
///
/// `Meter_Band` is not a root table — its rows are referenced from
/// `Meter.bands` — so a band must be inserted attached to a meter or it is
/// garbage-collected when the transaction commits. `action`, `rate` and
/// `burst_size` are all required scalars; only `external_ids` may be omitted.
public struct OVNMeterBand: Codable, Sendable {
    public let uuid: String?
    /// What to do with traffic exceeding the rate. `"drop"` is the only value
    /// the schema's enum allows today, hence the default.
    public let action: String
    /// The rate limit, in the unit of the meter this band belongs to
    /// (`OVNMeter.unit`). 1...4294967295.
    public let rate: Int
    /// Maximum burst allowed above the rate, in kilobits or packets to match
    /// the meter's unit. 0...4294967295; `ovn-nbctl meter-add` leaves it 0 when
    /// no burst is given.
    public let burst_size: Int
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case action, rate, burst_size, external_ids
    }

    public init(action: String = "drop", rate: Int, burst_size: Int = 0, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.action = action
        self.rate = rate
        self.burst_size = burst_size
        self.external_ids = external_ids
    }
}
