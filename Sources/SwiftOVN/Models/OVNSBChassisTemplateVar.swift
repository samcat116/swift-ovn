/// A row in the OVN Southbound `Chassis_Template_Var` table: the template
/// variable values that apply on one chassis.
///
/// Template variables let a single logical flow carry a per-chassis value — a
/// flow written against `^var` resolves it from this row on whichever chassis
/// evaluates it, which is how one flow serves chassis with different addresses.
/// ovn-northd populates these from the Northbound `Chassis_Template_Var` table.
///
/// `OVNSB`-prefixed because `Chassis_Template_Var` names a table in both
/// databases; the Southbound row is the same minus `external_ids`.
///
/// Read-only: ovn-northd owns these rows, so there is no create/update path on
/// `OVNManager` and no public initializer.
public struct OVNSBChassisTemplateVar: Codable, Sendable {
    public let uuid: String?
    /// Name of the chassis these values apply to — a chassis *name*, not a
    /// reference into `OVNChassis`. The schema indexes it, so there is at most
    /// one row per chassis.
    public let chassis: String
    /// Variable name to the value it takes on `chassis`.
    public let variables: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case chassis, variables
    }
}
