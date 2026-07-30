import NIOCore

/// How a connection re-establishes itself after the session it had went away.
///
/// Against a clustered `ovsdb-server` a dropped connection is routine, not
/// exceptional: a leader election closes the sessions to the old leader, and a
/// rolling upgrade closes every session in turn. Reconnection is therefore
/// enabled by default, with the doubling backoff OVS's own `reconnect` library
/// uses (1s, capped at 8s) plus jitter, so a cluster coming back up is not hit
/// by every client in lockstep.
///
/// What reconnection does *not* do is hide the drop:
///
/// - requests in flight when the session ends still fail, because their
///   responses are gone,
/// - monitors are restarted rather than resumed (see
///   `OVSDBConnection.monitorUpdates()`), and
/// - `connect()` itself does not retry: it tries each remote once and throws if
///   none answers, so a misconfigured endpoint fails immediately instead of
///   after a silent hour of backoff.
public struct OVSDBReconnectPolicy: Sendable, Equatable {
    /// Whether a session that ends unexpectedly is re-established at all. With
    /// this off, a dropped connection leaves the transport closed and every
    /// later request fails until the caller calls `connect()` again — the
    /// behaviour SwiftOVN had before reconnection existed.
    public var isEnabled: Bool

    /// Delay before the first retry. Each further consecutive failed pass over
    /// the remotes doubles it, up to `maximumBackoff`.
    public var initialBackoff: TimeAmount

    /// Ceiling for the doubling delay.
    public var maximumBackoff: TimeAmount

    /// How far the delay is randomised, as a fraction of itself: `0.25` spreads
    /// each delay over ±25%. Zero disables jitter.
    ///
    /// This is what keeps a cluster restart from producing a thundering herd —
    /// without it every client that lost its session retries in the same
    /// millisecond, forever in step.
    public var jitter: Double

    /// How many consecutive passes over the remotes may fail before the
    /// transport gives up and closes for good, or nil to retry indefinitely
    /// (the default: an OVN control plane is expected to come back).
    public var maximumAttempts: Int?

    public init(
        isEnabled: Bool = true,
        initialBackoff: TimeAmount = .seconds(1),
        maximumBackoff: TimeAmount = .seconds(8),
        jitter: Double = 0.25,
        maximumAttempts: Int? = nil
    ) {
        self.isEnabled = isEnabled
        self.initialBackoff = initialBackoff
        self.maximumBackoff = maximumBackoff
        self.jitter = jitter
        self.maximumAttempts = maximumAttempts
    }

    /// Reconnects indefinitely with a 1s–8s jittered backoff.
    public static let `default` = OVSDBReconnectPolicy()

    /// Never reconnects: a dropped session stays dropped until the caller
    /// reconnects by hand.
    public static let disabled = OVSDBReconnectPolicy(isEnabled: false)

    /// The un-jittered delay before `attempt` (1-based): `initialBackoff`
    /// doubled once per preceding attempt, capped at `maximumBackoff`.
    func baseBackoff(forAttempt attempt: Int) -> TimeAmount {
        let cap = max(0, maximumBackoff.nanoseconds)
        let base = max(0, initialBackoff.nanoseconds)
        guard attempt > 1 else { return .nanoseconds(min(base, cap)) }

        // Shift rather than repeated multiplication, and clamp the shift itself:
        // an unbounded `1 << (attempt - 1)` overflows within 64 attempts, which
        // an unlimited retry loop reaches in under a minute.
        let shift = min(attempt - 1, 62)
        let (scaled, overflowed) = base.multipliedReportingOverflow(by: 1 << shift)
        return .nanoseconds(overflowed ? cap : min(scaled, cap))
    }

    /// `baseBackoff(forAttempt:)` spread over ±`jitter`.
    ///
    /// Takes the generator so the randomisation is testable; the transport
    /// passes a `SystemRandomNumberGenerator`.
    func backoff(forAttempt attempt: Int, using generator: inout some RandomNumberGenerator) -> TimeAmount {
        let base = baseBackoff(forAttempt: attempt)
        let spread = min(max(jitter, 0), 1)
        guard spread > 0, base.nanoseconds > 0 else { return base }

        let factor = Double.random(in: (1 - spread)...(1 + spread), using: &generator)
        let jittered = Double(base.nanoseconds) * factor
        // Clamped to the cap so jitter can widen the spread without pushing a
        // single delay past the ceiling the caller configured.
        return .nanoseconds(min(Int64(jittered.rounded()), max(0, maximumBackoff.nanoseconds)))
    }
}
