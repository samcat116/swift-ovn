/// A row in the OVN Southbound `ACL_ID` table: an identifier ovn-northd has to
/// share with every ovn-controller.
///
/// The row's own `_uuid` is the whole point — it matches the Northbound `ACL`
/// row it was created for, so `id` can be a small integer that fits in a
/// dataplane register while still naming an ACL. Only `allow-established` ACLs
/// need one, since those are the ones whose established-traffic decision has to
/// be carried in the packet.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNACLID: Codable, Sendable {
    /// Matches the `_uuid` of the Northbound `OVNACL` row this identifier was
    /// allocated for.
    public let uuid: String?
    /// The small integer identifier standing in for that ACL.
    public let id: Int

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case id
    }
}
