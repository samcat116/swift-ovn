#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A row in the OVN Northbound `Logical_Router_Policy` table. These rows are
/// referenced from `Logical_Router.policies` and implement policy-based
/// routing (`ovn-nbctl lr-policy-add`): a packet is matched against the
/// router's policies before its static routes, and the highest-priority match
/// decides what happens to it.
public struct OVNLogicalRouterPolicy: Codable, Sendable {
    public let uuid: String?
    /// Evaluation order, 0...32767. Higher priorities are evaluated first.
    public let priority: Int
    /// Logical-flow match expression, e.g. `"ip4.src == 10.0.0.0/24"`.
    public let match: String
    /// `"allow"`, `"drop"`, `"reroute"` or `"jump"`. `"reroute"` needs
    /// `nexthop` or `nexthops`; `"jump"` needs `jump_chain`.
    public let action: String
    /// Next hop for a `"reroute"` action.
    public let nexthop: String?
    /// Next hops for an ECMP `"reroute"`. A plain string set, not references.
    public let nexthops: [String]?
    /// UUID reference to the `Logical_Router_Port` the packet is sent out of —
    /// unlike `OVNLogicalRouterStaticRoute.output_port`, which is a plain
    /// port-name string. The two columns share a name and do not share a wire
    /// form, which is why row encoding for this table is table-scoped (see
    /// `OVSDBRowEncoder.ColumnHints.ovn(table:)`).
    ///
    /// This is a *weak* reference: ovsdb-server silently drops a UUID whose
    /// port row no longer exists rather than failing the write, so
    /// `OVNManager` guards it with a `wait` op on create and update.
    public let output_port: String?
    /// Policy chain this row belongs to; nil (or the empty string) is the
    /// router's main chain.
    public let chain: String?
    /// Chain a `"jump"` action transfers evaluation to.
    public let jump_chain: String?
    /// UUID references to the `OVNBFD` sessions monitoring the next hops. Also
    /// a weak reference set, and guarded the same way on create and update.
    public let bfd_sessions: [String]?
    public let options: [String: String]?
    public let external_ids: [String: String]?

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case priority, match, action, nexthop, nexthops, output_port, chain, jump_chain, bfd_sessions, options, external_ids
    }

    public init(priority: Int, match: String, action: String, nexthop: String? = nil, nexthops: [String]? = nil, output_port: String? = nil, chain: String? = nil, jump_chain: String? = nil, bfd_sessions: [String]? = nil, options: [String: String]? = nil, external_ids: [String: String]? = nil) {
        self.uuid = nil
        self.priority = priority
        self.match = match
        self.action = action
        self.nexthop = nexthop
        self.nexthops = nexthops
        self.output_port = output_port
        self.chain = chain
        self.jump_chain = jump_chain
        self.bfd_sessions = bfd_sessions
        self.options = options
        self.external_ids = external_ids
    }
}
