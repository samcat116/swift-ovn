/// A row in the OVN Southbound `Controller_Event` table: something
/// ovn-controller punted to the control plane because the dataplane could not
/// resolve it.
///
/// The canonical case is `empty_lb_backends` — a packet arrived for a load
/// balancer VIP with no backends left — which is how a CMS learns that a
/// service has no capacity behind it. There is no exactly-once guarantee: the
/// same event may be written more than once, and `seq_num` is the global counter
/// a consumer deduplicates on.
///
/// Read-only: ovn-controller owns these rows, so there is no create path on
/// `OVNManager` and no public initializer.
public struct OVNControllerEvent: Codable, Sendable {
    public let uuid: String?
    /// What happened; `"empty_lb_backends"` is the event OVN generates today.
    public let event_type: String
    /// Event detail. For `empty_lb_backends` the keys are `vip`, `protocol` and
    /// `load_balancer` (the UUID of the Northbound load balancer).
    public let event_info: [String: String]?
    /// UUID reference to the `OVNChassis` that reported the event. A weak
    /// reference, so it reads as nil once that chassis is gone.
    public let chassis: String?
    /// Global event counter, used to spot the duplicate deliveries this table
    /// explicitly permits.
    public let seq_num: Int

    private enum CodingKeys: String, CodingKey {
        case uuid = "_uuid"
        case event_type, event_info, chassis, seq_num
    }
}
