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
/// `OVNManager.attachDNS(uuid:toSwitch:)` does (or
/// `createDNS(_:attachedToSwitch:)`, which does both at once). A switch may
/// reference any number of `DNS` rows: `dns_records` has `max: unlimited`, so
/// several zones — or one zone sharded across rows — can serve one switch.
///
/// **OVN answers UDP only.** `ovn-controller` intercepts UDP/53 in the
/// datapath and spoofs a reply; TCP/53 is not matched at all and passes
/// through to whatever resolver the guest was configured with. A query type
/// other than A, AAAA, ANY or PTR is likewise passed through, as is any name
/// this row has no record for.
public struct OVNDNS: Codable, Sendable {
    public let uuid: String?

    /// The records themselves, keyed by DNS query name.
    ///
    /// A value is one or more IP addresses **separated by a comma or a
    /// space**, so a single key covers both A and AAAA — OVN answers each
    /// query type with the addresses of that family:
    ///
    /// ```swift
    /// ["vm1.ovn.org": "10.0.0.4 aef0::4"]
    /// ```
    ///
    /// PTR is the same map with the key made a reverse name and the value a
    /// domain name — `in-addr.arpa` for IPv4, `ip6.arpa` for IPv6:
    ///
    /// ```swift
    /// ["4.0.0.10.in-addr.arpa": "vm1.ovn.org"]
    /// ```
    ///
    /// **Keys must be lowercase or they never match.** DNS lookups are
    /// case-insensitive, and OVN implements that by lowercasing the query name
    /// off the wire and looking it up verbatim. `ovn-northd` lowercases each
    /// *value* on the way to the Southbound copy but passes each *key*
    /// through unchanged, so a key carrying any uppercase character can never
    /// be the string a lookup searches for. Nothing rejects it: the row is
    /// accepted, and queries for that name fall through as if unconfigured.
    /// This type does not normalize the map — that would silently rewrite a
    /// caller's data — so lowercase the keys before constructing one.
    ///
    /// A row with no records is legal; it simply answers nothing.
    public let records: [String: String]

    /// Row options. One key is defined: `ovn-owned`. Set it to `"true"` to
    /// declare OVN authoritative for these names, which makes it *refuse* a
    /// query whose family this row has no address for rather than let it fall
    /// through — so a guest asking AAAA for an IPv4-only name fails fast
    /// instead of waiting out a resolver timeout.
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
