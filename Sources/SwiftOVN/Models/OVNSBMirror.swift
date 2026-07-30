/// A row in the OVN Southbound `Mirror` table: one port-mirroring rule
/// ovn-controller realizes in OVS.
///
/// `OVNSB`-prefixed because `Mirror` names a table in both databases; the
/// Southbound row is the Northbound one minus `mirror_rules`, since the
/// per-rule filtering that column expresses has already been flattened into
/// these rows. `OVNPortBinding.mirror_rules` references them, which is how a
/// caller finds which ports a mirror is attached to.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBMirror: Codable, Sendable {
    public let uuid: String?
    /// The mirror's name.
    public let name: String
    /// Which direction is mirrored: `"from-lport"`, `"to-lport"` or `"both"`.
    public let filter: String
    /// Where mirrored traffic goes: a tunnel destination IP for `"gre"` and
    /// `"erspan"`, an OVS interface name for `"local"`, or a logical port name
    /// for `"lport"`.
    public let sink: String
    /// The tunnel or attachment type: `"gre"`, `"erspan"`, `"local"` or
    /// `"lport"`.
    public let mirrorType: String
    /// The tunnel's identifier: the GRE key for `"gre"`, the ERSPAN index for
    /// `"erspan"`. Unused by the port-based types, and absent on a Southbound
    /// database predating the column.
    public let index: Int?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case name, filter, sink, index, external_ids
        case mirrorType = "type"
    }
}
