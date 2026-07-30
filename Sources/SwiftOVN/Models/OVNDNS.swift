#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row of the OVN Northbound `DNS` table: the records OVN answers DNS
/// queries with, for the logical switches that reference the row
/// (`Logical_Switch.dns_records`).
///
/// `DNS` is a root table, so the row survives unattached — but it takes effect
/// only once a switch references it, which is what
/// `OVNManager.attachDNS(uuid:toSwitch:)` does.
public struct OVNDNS: Codable, Sendable {
    public let uuid: String?
    /// The records themselves: a domain name (or an `in-addr.arpa` /
    /// `ip6.arpa` name, for reverse lookups) to the address it resolves to.
    /// A row with no records is legal — it simply answers nothing.
    public let records: [String: String]
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case records, options, external_ids
    }

    public init(records: [String: String] = [:], options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.records = records
        self.options = options
        self.external_ids = external_ids
    }
}
