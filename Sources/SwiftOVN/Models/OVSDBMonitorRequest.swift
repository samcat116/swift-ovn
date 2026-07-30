#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// What to monitor in one table: RFC 7047 §4.1.5 `<monitor-request>`, plus the
/// `where` conditions ovsdb-server's `monitor_cond` / `monitor_cond_since` add.
public struct OVSDBMonitorRequest: Codable, Sendable {
    public let columns: [String]?
    public let select: OVSDBMonitorSelect?
    /// Conditions the server evaluates before sending a row, so an uninterested
    /// client is never sent it — the reason `monitor_cond` exists. An empty list
    /// or nil matches every row.
    ///
    /// Only `monitor_cond` and `monitor_cond_since` accept these; plain
    /// `monitor` rejects the member outright, which is why
    /// `OVSDBConnection.startConditionalMonitoring` refuses to fall back to
    /// `monitor` while any request carries one rather than quietly monitor
    /// everything.
    public let whereConditions: [OVSDBCondition]?

    private enum CodingKeys: String, CodingKey {
        case columns, select
        case whereConditions = "where"
    }

    public init(
        columns: [String]? = nil,
        select: OVSDBMonitorSelect? = nil,
        whereConditions: [OVSDBCondition]? = nil
    ) {
        self.columns = columns
        self.select = select
        self.whereConditions = whereConditions
    }

    /// The same request with its conditions removed, for the plain `monitor`
    /// method: ovsdb-server parses a `<monitor-request>` strictly and fails the
    /// whole request on an unexpected member, so even `"where": []` cannot be
    /// sent to it.
    func droppingConditions() -> OVSDBMonitorRequest {
        return OVSDBMonitorRequest(columns: columns, select: select)
    }

    /// The same request with different conditions, for recording what a
    /// `monitor_cond_change` left the monitor running with.
    func withConditions(_ conditions: [OVSDBCondition]) -> OVSDBMonitorRequest {
        return OVSDBMonitorRequest(columns: columns, select: select, whereConditions: conditions)
    }
}
