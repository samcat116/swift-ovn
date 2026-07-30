#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row in the OVN Northbound `Address_Set` table. An address set is a named
/// collection of addresses that an ACL match string references as
/// `$name` instead of inlining every member, which is how match strings stay
/// manageable as membership grows (mirroring `ovn-nbctl create Address_Set`).
/// `Address_Set` is a root table, so a set persists until it is explicitly
/// deleted.
///
/// The Southbound database has its own `Address_Set` table, populated by
/// ovn-northd from these rows; this model describes the Northbound one that
/// callers write.
public struct OVNAddressSet: Codable, Sendable {
    public let uuid: String?
    /// Unique set name, referenced from a match as `$name`. The NB schema
    /// indexes this column. OVN accepts only letters, digits and underscores
    /// here, since anything else could not be parsed back out of a match
    /// string.
    public let name: String
    /// The set's members: IP addresses, CIDR prefixes or MAC addresses,
    /// depending on the field the referencing match compares against. Plain
    /// strings, not references — a member is not tied to any other row.
    public let addresses: [String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, addresses, options, external_ids
    }

    public init(
        name: String,
        addresses: [String]? = nil,
        options: [String: String]? = nil,
        external_ids: [String: String]? = nil
    ) {
        self.uuid = nil
        self.name = name
        self.addresses = addresses
        self.options = options
        self.external_ids = external_ids
    }
}
