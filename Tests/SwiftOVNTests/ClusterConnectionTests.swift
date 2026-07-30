import Foundation
import Testing
import NIO
import NIOPosix
import Logging
@testable import SwiftOVN

/// Thrown by `ClusterConnectionTests.withDeadline` when the operation under test
/// never completes.
private struct ClusterDeadlineExceeded: Error {}

// MARK: - Remote lists

@Suite("OVSDB remotes")
struct OVSDBRemotesTests {

    @Test("Parses the comma-separated list `ovn-nbctl --db` takes")
    func parsesCommaSeparatedList() throws {
        let remotes = try OVSDBRemotes(parsing: "tcp:10.0.0.1:6641,tcp:10.0.0.2:6641,tcp:10.0.0.3:6641")
        #expect(remotes.endpoints == [
            .tcp(host: "10.0.0.1", port: 6641),
            .tcp(host: "10.0.0.2", port: 6641),
            .tcp(host: "10.0.0.3", port: 6641)
        ])
        #expect(remotes.count == 3)
        #expect(remotes.first == .tcp(host: "10.0.0.1", port: 6641))
    }

    @Test("Mixes transports and tolerates whitespace")
    func mixesTransportsAndToleratesWhitespace() throws {
        let remotes = try OVSDBRemotes(parsing: " unix:/var/run/ovn/ovnnb_db.sock , tcp:[2001:db8::1]:6641 ")
        #expect(remotes.endpoints == [
            .unix(path: "/var/run/ovn/ovnnb_db.sock"),
            .tcp(host: "2001:db8::1", port: 6641)
        ])
    }

    @Test("`description` round trips")
    func descriptionRoundTrips() throws {
        let string = "tcp:a.example.com:6641,tcp:[2001:db8::1]:6642,unix:/run/db.sock"
        #expect(try OVSDBRemotes(parsing: string).description == string)
    }

    @Test("A repeated remote is kept once, in its first position")
    func repeatedRemoteIsKeptOnce() throws {
        // A duplicate would otherwise cost a connection attempt for a remote
        // that has already been tried in the same pass.
        let remotes = try OVSDBRemotes(parsing: "tcp:a:6641,tcp:b:6641,tcp:a:6641")
        #expect(remotes.endpoints == [.tcp(host: "a", port: 6641), .tcp(host: "b", port: 6641)])
    }

    @Test("A single endpoint needs no error handling")
    func singleEndpointInitialiserDoesNotThrow() {
        let remotes = OVSDBRemotes(.unix(path: "/run/db.sock"))
        #expect(remotes.count == 1)
        #expect(remotes[0] == .unix(path: "/run/db.sock"))
    }

    @Test("Rejects an empty list")
    func rejectsEmptyList() {
        #expect(throws: OVNManagerError.self) { try OVSDBRemotes([]) }
    }

    @Test("Rejects a malformed list", arguments: [
        "",                              // no remotes at all
        "tcp:a:6641,",                   // trailing separator
        ",tcp:a:6641",                   // leading separator
        "tcp:a:6641,,tcp:b:6641",        // empty element
        "tcp:a:6641,udp:b:6641"          // an element that is not an endpoint
    ])
    func rejectsMalformedList(string: String) {
        #expect(throws: OVNManagerError.self) { try OVSDBRemotes(parsing: string) }
    }
}

// MARK: - Backoff

@Suite("Reconnect policy")
struct OVSDBReconnectPolicyTests {

    private static let policy = OVSDBReconnectPolicy(
        initialBackoff: .seconds(1),
        maximumBackoff: .seconds(8),
        jitter: 0.25
    )

    /// Attempt number to un-jittered delay: doubling from 1s, capped at 8s.
    @Test("The base delay doubles per attempt and then stops at the cap", arguments: [
        (1, TimeAmount.seconds(1)),
        (2, .seconds(2)),
        (3, .seconds(4)),
        (4, .seconds(8)),
        (5, .seconds(8)),
        // Far enough out that a naive `1 << (attempt - 1)` would have overflowed
        // rather than clamped — reachable, because the default policy retries
        // without limit.
        (200, .seconds(8))
    ])
    func baseDelayDoublesThenCaps(attempt: Int, expected: TimeAmount) {
        #expect(Self.policy.baseBackoff(forAttempt: attempt) == expected)
    }

    @Test("Zero jitter yields exactly the base delay")
    func zeroJitterYieldsTheBaseDelay() {
        var policy = Self.policy
        policy.jitter = 0
        var generator = SystemRandomNumberGenerator()
        #expect(policy.backoff(forAttempt: 2, using: &generator) == .seconds(2))
    }

    @Test("Jitter stays inside the configured spread and under the cap")
    func jitterStaysInsideTheSpread() {
        var generator = SystemRandomNumberGenerator()
        var seen: Set<Int64> = []
        for attempt in 1...6 {
            let base = Self.policy.baseBackoff(forAttempt: attempt).nanoseconds
            for _ in 0..<50 {
                let delay = Self.policy.backoff(forAttempt: attempt, using: &generator).nanoseconds
                seen.insert(delay)
                #expect(delay >= Int64(Double(base) * 0.75) - 1)
                #expect(delay <= Int64(Double(base) * 1.25) + 1)
                #expect(delay <= TimeAmount.seconds(8).nanoseconds)
            }
        }
        // The point of jitter: clients that lost the same server must not all
        // come back in the same millisecond.
        #expect(seen.count > 1, "Jitter produced a constant delay")
    }

    @Test("The defaults are enabled, jittered and unlimited")
    func defaultsAreEnabledAndUnlimited() {
        #expect(OVSDBReconnectPolicy.default.isEnabled)
        #expect(OVSDBReconnectPolicy.default.jitter > 0)
        #expect(OVSDBReconnectPolicy.default.maximumAttempts == nil)
        #expect(!OVSDBReconnectPolicy.disabled.isEnabled)
    }
}

// MARK: - _Server leadership parsing

@Suite("_Server leadership")
struct OVSDBServerStatusTests {

    private func tableUpdates(_ json: String) throws -> JSONValue {
        return try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
    }

    @Test("Reads the verdict for the database being served", arguments: [
        (#"{"Database":{"u1":{"new":{"name":"OVN_Northbound","connected":true,"leader":true}}}}"#,
         OVSDBLeadership.leader),
        (#"{"Database":{"u1":{"new":{"name":"OVN_Northbound","connected":true,"leader":false}}}}"#,
         .follower),
        // Not serving the database yet: leadership is beside the point.
        (#"{"Database":{"u1":{"new":{"name":"OVN_Northbound","connected":false,"leader":true}}}}"#,
         .notConnected),
        // An optional boolean column arrives as a single-element set.
        (#"{"Database":{"u1":{"new":{"name":"OVN_Northbound","connected":true,"leader":["set",[true]]}}}}"#,
         .leader),
        // A row for another database says nothing about this one.
        (#"{"Database":{"u1":{"new":{"name":"OVN_Southbound","connected":true,"leader":true}}}}"#,
         .unknown),
        // A deleted row carries only `old`.
        (#"{"Database":{"u1":{"old":{"name":"OVN_Northbound","leader":true}}}}"#, .unknown),
        // A server too old for `_Server`, or a monitor that returned nothing.
        ("{}", .unknown),
        (#"{"Database":{}}"#, .unknown)
    ])
    func readsTheVerdict(json: String, expected: OVSDBLeadership) throws {
        let verdict = OVSDBServerStatus.leadership(
            ofDatabase: "OVN_Northbound",
            in: try tableUpdates(json)
        )
        #expect(verdict == expected)
    }

    @Test("Picks this database's row out of several")
    func picksTheRightRowOutOfSeveral() throws {
        let updates = try tableUpdates("""
        {"Database":{
          "u1":{"new":{"name":"_Server","connected":true,"leader":true}},
          "u2":{"new":{"name":"OVN_Northbound","connected":true,"leader":false}}
        }}
        """)
        #expect(OVSDBServerStatus.leadership(ofDatabase: "OVN_Northbound", in: updates) == .follower)
    }

    @Test("The monitor never asks for the schema column")
    func monitorRequestsOmitTheSchemaColumn() throws {
        // `_Server.Database.schema` carries the whole schema as a string —
        // megabytes for OVN Southbound, re-sent on every reconnect for nothing.
        let columns = try #require(
            OVSDBServerStatus.monitorRequests.objectValue?["Database"]?
                .objectValue?["columns"]?.asStringArray()
        )
        #expect(columns == ["name", "connected", "leader"])
    }
}

// MARK: - Clustered connections

/// Reconnection, remote failover and leader discovery against in-process stub
/// servers that behave like the members of a clustered `ovsdb-server`: they can
/// report leadership through `_Server`, hand it back mid-session, and drop their
/// client connections the way a leader election does.
///
/// A `final class` rather than a `struct` so the per-test event loop group can be
/// torn down in `deinit`.
@Suite("Clustered connection")
final class ClusterConnectionTests {

    private let group: MultiThreadedEventLoopGroup
    /// Every stub started by this test, so its channels can be closed before the
    /// group goes away.
    private var servers: [ClusterStubServer] = []

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    deinit {
        // Closed before the group is shut down: leaving registered channels for
        // the group's own teardown to deal with left the event loops running
        // after the test run had finished.
        for server in servers {
            server.close()
        }
        // Asynchronously, and never `syncShutdownGracefully()` — see the note on
        // `MessageRoutingTests.deinit`.
        group.shutdownGracefully { _ in }
    }

    /// Backoff short enough to keep the tests quick, with no jitter so a wait is
    /// predictable.
    private static let fastReconnect = OVSDBReconnectPolicy(
        initialBackoff: .milliseconds(10),
        maximumBackoff: .milliseconds(50),
        jitter: 0
    )

    private static let database = "OVN_Northbound"

    private func startServer(
        isLeader: Bool = true,
        answersServerDatabase: Bool = true,
        unixPath: String? = nil
    ) async throws -> ClusterStubServer {
        let server = ClusterStubServer(
            database: Self.database,
            isLeader: isLeader,
            answersServerDatabase: answersServerDatabase
        )
        try await server.start(group: group, unixPath: unixPath)
        servers.append(server)
        return server
    }

    /// A unique socket path, for a stub that has to be unreachable later on: a
    /// released TCP port can be handed straight to another test's stub, which
    /// would then answer the connection this test needs to fail.
    ///
    /// Short and directly under `/tmp` because a unix socket path is limited to
    /// about a hundred characters, which `NSTemporaryDirectory()` plus a UUID
    /// exceeds on its own.
    private func temporarySocketPath() -> String {
        return "/tmp/sovn-\(UUID().uuidString.prefix(8)).sock"
    }

    /// Drops the server's live sessions the way a leader election does, first
    /// making sure the session under test has actually been accepted.
    ///
    /// `connect()` returns as soon as the *client* side of the connection is up,
    /// which can be before the server has finished accepting it. Dropping at that
    /// moment closes nothing, and the test then waits for a reconnect that has no
    /// reason to happen.
    private func dropSessions(of server: ClusterStubServer, expecting count: Int = 1) async {
        let accepted = await eventually { server.liveConnectionCount >= count }
        #expect(accepted, "The stub never accepted \(count) connection(s)")
        server.dropConnections()
    }

    /// Polls `condition` until it holds, returning false if it never does.
    /// Reconnection is asynchronous by nature, so there is nothing to await on.
    private func eventually(
        seconds: Double = 5,
        _ condition: @Sendable () async -> Bool
    ) async -> Bool {
        let steps = Int(seconds * 200)
        for _ in 0..<steps {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return await condition()
    }

    /// Runs `operation` with a deadline, so a stream that never yields another
    /// element fails the test instead of hanging the whole run (the pattern
    /// `MessageRoutingTests.withDeadline` established).
    private func withDeadline<T: Sendable>(
        _ seconds: Double = 5,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw ClusterDeadlineExceeded()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    // MARK: Leader discovery

    @Test("A follower is skipped in favour of the leader")
    func followerIsSkippedInFavourOfTheLeader() async throws {
        let follower = try await startServer(isLeader: false)
        let leader = try await startServer(isLeader: true)

        let client = JSONRPCClient(
            remotes: OVSDBRemotes(follower.endpoint, leader.endpoint),
            reconnect: Self.fastReconnect,
            leaderOnlyDatabase: Self.database,
            eventLoopGroup: group
        )
        try await client.connect()

        // The follower answers TCP and the handshake perfectly well; only
        // `_Server` distinguishes it, and writes sent there would be rejected.
        #expect(client.connectionState.endpoint == leader.endpoint)
        #expect(follower.connectionCount == 1, "The follower should have been tried and dropped")
        #expect(try await client.echo() == ["echo"])

        try await client.disconnect()
    }

    @Test("A remote that cannot answer for `_Server` is used anyway")
    func remoteThatCannotAnswerForServerIsUsedAnyway() async throws {
        // ovsdb-server before 2.9 has no `_Server` database and answers the
        // monitor with the JSON-RPC 1.0 error string `unknown database`. Refusing
        // to connect over a question the server cannot answer would be worse than
        // talking to a follower.
        let old = try await startServer(answersServerDatabase: false)
        let leader = try await startServer(isLeader: true)

        let client = JSONRPCClient(
            remotes: OVSDBRemotes(old.endpoint, leader.endpoint),
            reconnect: Self.fastReconnect,
            leaderOnlyDatabase: Self.database,
            eventLoopGroup: group
        )
        try await client.connect()

        #expect(client.connectionState.endpoint == old.endpoint)
        #expect(try await client.echo() == ["echo"])

        try await client.disconnect()
    }

    @Test("Leadership handed back mid-session moves the connection on")
    func leadershipHandedBackMidSessionMovesTheConnectionOn() async throws {
        // The failure this whole feature exists for: an election takes the
        // leadership away from the server we are attached to, and without the
        // `_Server` monitor the next write would simply be rejected.
        let first = try await startServer(isLeader: true)
        let second = try await startServer(isLeader: true)

        let client = JSONRPCClient(
            remotes: OVSDBRemotes(first.endpoint, second.endpoint),
            reconnect: Self.fastReconnect,
            leaderOnlyDatabase: Self.database,
            eventLoopGroup: group
        )
        try await client.connect()
        #expect(client.connectionState.endpoint == first.endpoint)

        // The `_Server` monitor has to be in place, or the hand-back would be
        // reported to nobody.
        #expect(await eventually { first.serverMonitorCount == 1 })
        first.handBackLeadership()

        let movedOn = await eventually {
            client.connectionState == .connected(endpoint: second.endpoint)
        }
        #expect(movedOn, "Expected a move to the new leader, state is \(client.connectionState)")
        #expect(try await client.echo() == ["echo"])

        try await client.disconnect()
    }

    @Test("Leader-only is not enforced against a single remote")
    func leaderOnlyIsNotEnforcedAgainstASingleRemote() async throws {
        // With one remote there is nothing better to switch to, so rejecting a
        // follower would just refuse to work — and reads are still served.
        let follower = try await startServer(isLeader: false)

        let client = JSONRPCClient(
            remotes: OVSDBRemotes(follower.endpoint),
            reconnect: Self.fastReconnect,
            leaderOnlyDatabase: Self.database,
            eventLoopGroup: group
        )
        try await client.connect()

        #expect(client.isConnected)
        #expect(follower.serverMonitorCount == 0, "No _Server monitor is needed for one remote")

        try await client.disconnect()
    }

    // MARK: Reconnection

    @Test("A dropped session is re-established")
    func droppedSessionIsReestablished() async throws {
        let server = try await startServer()
        let client = JSONRPCClient(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await client.connect()
        #expect(try await client.echo() == ["echo"])

        // What a leader election does to every client of the old leader.
        await dropSessions(of: server)

        // The server's own count, not the client's state: a state that has not
        // caught up with the drop yet still reads as connected, so waiting on it
        // would let this pass without a reconnect ever happening.
        let reconnected = await eventually { server.connectionCount == 2 }
        #expect(reconnected, "Expected a second connection, state is \(client.connectionState)")
        #expect(await eventually { client.connectionState.isConnected })
        // The session is genuinely usable again, not merely reported as up.
        #expect(try await client.echo() == ["echo"])

        try await client.disconnect()
    }

    @Test("A dropped session fails the requests that were in flight")
    func droppedSessionFailsInFlightRequests() async throws {
        // Reconnection must not paper over a lost response: the request's reply
        // died with the session, and re-sending a `transact` is not the
        // transport's call to make.
        let server = try await startServer()
        let connection = OVSDBSocketConnection(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await connection.connect()

        let pending = Task {
            try await connection.sendRequest(
                JSONRPCRequest(method: "never_answered", params: nil, id: .number(1)),
                id: .number(1),
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .seconds(30)
            )
        }
        #expect(await eventually { server.requestCount(for: "never_answered") == 1 })
        await dropSessions(of: server)

        await #expect(throws: OVNManagerError.self) { try await pending.value }
        // The failure is not the connection giving up: it reconnects regardless.
        #expect(await eventually { server.connectionCount == 2 })

        await connection.disconnect()
    }

    @Test("With reconnection disabled a dropped session stays closed")
    func withReconnectionDisabledADroppedSessionStaysClosed() async throws {
        let server = try await startServer()
        let client = JSONRPCClient(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: .disabled,
            eventLoopGroup: group
        )
        try await client.connect()
        await dropSessions(of: server)

        let closed = await eventually {
            if case .closed = client.connectionState { return true }
            return false
        }
        #expect(closed, "Expected a closed connection, state is \(client.connectionState)")
        #expect(!client.isConnected)
        #expect(server.connectionCount == 1, "Nothing may reconnect once the policy says not to")
    }

    @Test("Reconnection gives up after the configured number of attempts")
    func reconnectionGivesUpAfterTheConfiguredNumberOfAttempts() async throws {
        // Over a unix socket, so that stopping the stub makes the address
        // genuinely unreachable: a freed TCP port can be picked up by another
        // test's stub, which would then answer the connections this test needs to
        // fail.
        let server = try await startServer(unixPath: temporarySocketPath())
        let client = JSONRPCClient(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: OVSDBReconnectPolicy(
                initialBackoff: .milliseconds(5),
                maximumBackoff: .milliseconds(5),
                jitter: 0,
                maximumAttempts: 2
            ),
            eventLoopGroup: group
        )
        try await client.connect()

        // Stop listening *and* drop the live session: every later attempt fails.
        try await server.stopListening()
        await dropSessions(of: server)

        let closed = await eventually {
            if case .closed = client.connectionState { return true }
            return false
        }
        #expect(closed, "Expected the reconnect loop to give up, state is \(client.connectionState)")
        #expect(!client.isConnected)
    }

    @Test("The first connect fails rather than retrying behind the caller's back")
    func firstConnectFailsRatherThanRetrying() async throws {
        // With unlimited retries the alternative would be a `connect()` that
        // hangs forever on a typo in the endpoint.
        let client = JSONRPCClient(
            remotes: OVSDBRemotes(
                .unix(path: temporarySocketPath()),
                .unix(path: temporarySocketPath())
            ),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        let error = await #expect(throws: OVNManagerError.self) {
            try await client.connect()
        }
        #expect(error?.errorCase == .connectionFailed)
        if case .closed = client.connectionState {} else {
            Issue.record("Expected a closed connection, got \(client.connectionState)")
        }
    }

    // MARK: Connection state stream

    @Test("The state stream opens with the current state and reports transitions")
    func stateStreamOpensWithTheCurrentStateAndReportsTransitions() async throws {
        let server = try await startServer()
        let client = JSONRPCClient(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )

        let states = client.connectionStates()
        // Consumed by one task, so the states can be collected in order with a
        // deadline around them: a stream that stops reporting must fail this test
        // rather than hang the run.
        let collected = Task {
            var seen: [OVSDBConnectionState] = []
            var sawDisconnection = false
            for await state in states {
                seen.append(state)
                if seen.count > 1 && !state.isConnected { sawDisconnection = true }
                if sawDisconnection && state.isConnected { break }
            }
            return seen
        }

        try await client.connect()
        // A drop and its recovery are observable as transitions rather than only
        // as a thrown error on the next request.
        #expect(await eventually { client.connectionState.isConnected })
        await dropSessions(of: server)

        let seen = try await withDeadline { await collected.value }

        // A subscriber must not have to wait for a transition to learn where
        // things stand.
        #expect(seen.first == .idle)
        #expect(seen.contains { if case .connecting = $0 { return true } else { return false } })
        #expect(seen.contains(.connected(endpoint: server.endpoint)))
        #expect(seen.last?.isConnected == true, "Expected the recovery to be reported, saw \(seen)")

        try await client.disconnect()
    }

    // MARK: Monitors across a reconnect

    @Test("Monitors are restarted on the new session")
    func monitorsAreRestartedOnTheNewSession() async throws {
        // Without this, `OVSDBConnection.activeMonitors` would go on naming
        // monitors that the server threw away when the connection dropped.
        let server = try await startServer()
        let connection = OVSDBConnection(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await connection.connect()

        let started = try await connection.startMonitoring(
            database: Self.database,
            tables: ["Logical_Switch": OVSDBMonitorRequest(columns: ["name"])]
        )
        #expect(server.monitors.count == 1)

        await dropSessions(of: server)

        let restarted = await eventually { server.monitors.count == 2 }
        #expect(restarted, "Expected the monitor to be restarted, saw \(server.monitors)")
        #expect(server.monitors.last?.monitorId == started.monitorId)
        #expect(server.monitors.last?.database == Self.database)

        try await connection.disconnect()
    }

    @Test("A conditional monitor is resumed from its last transaction id")
    func conditionalMonitorIsResumedFromItsLastTransactionId() async throws {
        // The point of restarting a `monitor_cond_since` monitor with `since`:
        // the alternative is the server re-sending an entire Southbound database
        // on every leader election.
        let server = try await startServer()
        let connection = OVSDBConnection(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await connection.connect()

        let session = try await connection.startConditionalMonitoring(
            database: Self.database,
            tables: ["Logical_Switch": OVSDBMonitorRequest(columns: ["name"])],
            monitorId: "flows"
        )
        #expect(session.method == .monitorCondSince)
        // The first request has nothing to resume from, so it asks from zero.
        #expect(server.monitors == [
            ClusterStubServer.RecordedMonitor(
                database: Self.database,
                monitorId: "flows",
                since: OVSDBMonitorMethod.initialTransactionId
            )
        ])

        await dropSessions(of: server)

        #expect(await eventually { server.monitors.count == 2 })
        #expect(server.monitors.last?.since == ClusterStubServer.transactionId,
                "Expected the reconnect to resume, saw \(server.monitors)")
        // And the resumed monitor keeps its identity, so the caller's handle to
        // it still works.
        #expect(await connection.monitorMethod(forMonitor: "flows") == .monitorCondSince)

        try await connection.disconnect()
    }

    @Test("A stopped monitor is not restarted")
    func stoppedMonitorIsNotRestarted() async throws {
        let server = try await startServer()
        let connection = OVSDBConnection(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await connection.connect()

        let started = try await connection.startMonitoring(
            database: Self.database,
            tables: ["Logical_Switch": OVSDBMonitorRequest(columns: ["name"])]
        )
        try await connection.stopMonitoring(monitorId: started.monitorId)

        await dropSessions(of: server)
        #expect(await eventually { server.connectionCount == 2 })
        // Give the recovery task the same window the restart test relies on.
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.monitors.count == 1, "A cancelled monitor must stay cancelled")

        try await connection.disconnect()
    }

    @Test("A monitor stream is told the reconnect left a hole")
    func monitorStreamIsToldTheReconnectLeftAHole() async throws {
        // The updates that happened while the connection was down were sent to
        // nobody, so continuing the stream silently would hand the consumer an
        // incomplete view. Resuming without a gap needs monitor_cond_since.
        let server = try await startServer()
        let connection = OVSDBConnection(
            remotes: OVSDBRemotes(server.endpoint),
            reconnect: Self.fastReconnect,
            eventLoopGroup: group
        )
        try await connection.connect()

        let updates = connection.monitorUpdates()
        _ = try await connection.startMonitoring(
            database: Self.database,
            tables: ["Logical_Switch": OVSDBMonitorRequest()]
        )

        // Drained by one task with a deadline: a stream that neither yields nor
        // fails must show up as a failure, not as a hung test run.
        let drained = Task {
            var tables: [String] = []
            for try await update in updates {
                tables.append(update.table)
            }
            return tables
        }

        // The stub pushes one update per monitor, the way ovsdb-server does.
        #expect(await eventually { server.monitors.count == 1 })
        await dropSessions(of: server)

        let error = await #expect(throws: OVNManagerError.self) {
            try await withDeadline { try await drained.value }
        }
        #expect(error?.errorCase == .monitorInterrupted)

        try await connection.disconnect()
    }

    @Test("The internal `_Server` monitor never reaches a caller's stream")
    func internalServerMonitorNeverReachesACallersStream() async throws {
        // Leader discovery monitors `_Server.Database`, and those updates are
        // this library's business: a caller replicating Logical_Switch rows must
        // not be handed `Database` rows it never asked for.
        let first = try await startServer(isLeader: true)
        let second = try await startServer(isLeader: true)

        let connection = OVSDBConnection(
            remotes: OVSDBRemotes(first.endpoint, second.endpoint),
            reconnect: Self.fastReconnect,
            leaderOnlyDatabase: Self.database,
            eventLoopGroup: group
        )
        try await connection.connect()
        #expect(first.serverMonitorCount == 1, "Leader discovery should have monitored _Server")

        let updates = connection.monitorUpdates()
        _ = try await connection.startMonitoring(
            database: Self.database,
            tables: ["Logical_Switch": OVSDBMonitorRequest()]
        )

        let drained = Task {
            var tables: [String] = []
            do {
                for try await update in updates {
                    tables.append(update.table)
                }
            } catch {
                return (tables, error as? OVNManagerError)
            }
            return (tables, nil)
        }

        #expect(await eventually { first.monitors.count == 1 })
        // This pushes a `_Server` update, then loses the session.
        first.handBackLeadership()

        let (tables, error) = try await withDeadline { await drained.value }
        #expect(error?.errorCase == .monitorInterrupted)
        #expect(tables == ["Logical_Switch"], "A _Server row leaked into the caller's stream")

        try await connection.disconnect()
    }
}

// MARK: - Stub cluster member

/// One stand-in `ovsdb-server`: answers the JSON-RPC handshake, reports its
/// `_Server` leadership, records the monitors it is asked for, and can hand back
/// leadership or drop its client connections the way a leader election does.
///
/// `@unchecked Sendable` with a lock, matching the other stub handlers in this
/// suite: the state is touched from event-loop threads and from tests.
final class ClusterStubServer: @unchecked Sendable {
    struct RecordedMonitor: Sendable, Equatable {
        let database: String
        let monitorId: String
        /// The `monitor_cond_since` resume point, nil for the other methods.
        var since: String?
    }

    private let lock = NSLock()
    private let database: String
    /// Whether a server too old for `_Server` is being simulated; such a server
    /// answers with a bare-string error rather than a JSON-RPC error object.
    private let answersServerDatabase: Bool

    private var listener: Channel?
    private var boundEndpoint: OVSDBEndpoint?
    private var clients: [ObjectIdentifier: Channel] = [:]
    private var serverMonitors: [(channel: Channel, monitorId: String)] = []
    private var recordedMonitors: [RecordedMonitor] = []
    private var requestCounts: [String: Int] = [:]
    private var connections = 0
    private var isLeader: Bool

    init(database: String, isLeader: Bool, answersServerDatabase: Bool = true) {
        self.database = database
        self.isLeader = isLeader
        self.answersServerDatabase = answersServerDatabase
    }

    /// Binds on loopback TCP, or on `unixPath` when a test needs an address that
    /// cannot be reused by another stub once this one stops listening.
    func start(group: EventLoopGroup, unixPath: String? = nil) async throws {
        // Bound after `init` so the child-channel initializer can capture a fully
        // formed `self`.
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ClusterStubHandler(server: self))
            }

        let channel: Channel
        let endpoint: OVSDBEndpoint
        if let unixPath {
            channel = try await bootstrap.bind(unixDomainSocketPath: unixPath).get()
            endpoint = .unix(path: unixPath)
        } else {
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
            endpoint = .tcp(host: "127.0.0.1", port: channel.localAddress?.port ?? 0)
        }
        lock.withLock {
            self.listener = channel
            self.boundEndpoint = endpoint
        }
    }

    /// Stops accepting new connections, so every later attempt fails. A unix
    /// stub's socket file is removed too, which is what makes a later connect
    /// fail deterministically rather than depending on who else has the port.
    func stopListening() async throws {
        let channel = lock.withLock { listener }
        try await channel?.close()
        let endpoint = lock.withLock { () -> OVSDBEndpoint? in
            listener = nil
            return boundEndpoint
        }
        if case .unix(let path)? = endpoint {
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    /// Closes the listener and every client connection, without awaiting: safe to
    /// call from a `deinit`.
    func close() {
        let (listener, clients) = lock.withLock { (self.listener, Array(self.clients.values)) }
        for client in clients {
            client.close(promise: nil)
        }
        listener?.close(promise: nil)
    }

    var endpoint: OVSDBEndpoint {
        return lock.withLock { boundEndpoint ?? .tcp(host: "127.0.0.1", port: 0) }
    }

    /// How many client connections this server has accepted, which is how a test
    /// tells a reconnect from a connection that never dropped.
    var connectionCount: Int {
        return lock.withLock { connections }
    }

    /// Connections that are up right now, as opposed to `connectionCount`, which
    /// counts every one this server has ever accepted.
    var liveConnectionCount: Int {
        return lock.withLock { clients.count }
    }

    var monitors: [RecordedMonitor] {
        return lock.withLock { recordedMonitors }
    }

    var serverMonitorCount: Int {
        return lock.withLock { serverMonitors.count }
    }

    func requestCount(for method: String) -> Int {
        return lock.withLock { requestCounts[method] ?? 0 }
    }

    /// Drops every live client connection, as an `ovsdb-server` losing an
    /// election (or being restarted) does.
    func dropConnections() {
        let channels = lock.withLock { Array(clients.values) }
        for channel in channels {
            channel.close(promise: nil)
        }
    }

    /// Reports, on every `_Server` monitor of this server, that it is no longer
    /// the leader.
    func handBackLeadership() {
        let monitors: [(channel: Channel, monitorId: String)] = lock.withLock {
            isLeader = false
            return serverMonitors
        }
        for monitor in monitors {
            write([
                "id": NSNull(),
                "method": "update",
                "params": [
                    monitor.monitorId,
                    Self.serverTableUpdates(database: database, connected: true, leader: false)
                ]
            ], to: monitor.channel)
        }
    }

    // MARK: Handler callbacks

    func register(_ channel: Channel) {
        lock.withLock {
            clients[ObjectIdentifier(channel)] = channel
            connections += 1
        }
    }

    func unregister(_ channel: Channel) {
        lock.withLock {
            clients.removeValue(forKey: ObjectIdentifier(channel))
            serverMonitors.removeAll { $0.channel === channel }
        }
    }

    func respond(to method: String, request: [String: Any], on channel: Channel) {
        lock.withLock { requestCounts[method, default: 0] += 1 }
        let params = request["params"] as? [Any] ?? []
        let id = request["id"] ?? NSNull()

        switch method {
        case "echo":
            write(["id": id, "result": params, "error": NSNull()], to: channel)
        case "list_dbs":
            write(["id": id, "result": [database, "_Server"], "error": NSNull()], to: channel)
        case "monitor":
            respondToMonitor(params: params, id: id, on: channel)
        case "monitor_cond_since":
            respondToMonitorCondSince(params: params, id: id, on: channel)
        case "never_answered":
            // Deliberately no reply: lets a test hold a request in flight.
            break
        default:
            write(["id": id, "result": [String: Any](), "error": NSNull()], to: channel)
        }
    }

    /// `[<db>, <monitor-id>, <requests>, <last-txn-id>]` in, `[found,
    /// last-txn-id, table-updates2]` out. The resume point is recorded rather
    /// than acted on, so a test can assert what the client asked to resume from.
    private func respondToMonitorCondSince(params: [Any], id: Any, on channel: Channel) {
        let requestedDatabase = params.first as? String ?? ""
        let monitorId = params.dropFirst().first as? String ?? ""
        let since = params.count > 3 ? params[3] as? String : nil
        let found = since != nil && since != "00000000-0000-0000-0000-000000000000"

        lock.withLock {
            recordedMonitors.append(
                RecordedMonitor(database: requestedDatabase, monitorId: monitorId, since: since)
            )
        }
        write([
            "id": id,
            "result": [found, Self.transactionId, [String: Any]()] as [Any],
            "error": NSNull()
        ], to: channel)
    }

    /// The transaction id this stub reports as its latest, i.e. the point a
    /// reconnect should resume from.
    static let transactionId = "6c6ee2f0-0000-0000-0000-000000000001"

    private func respondToMonitor(params: [Any], id: Any, on channel: Channel) {
        let requestedDatabase = params.first as? String ?? ""
        let monitorId = params.dropFirst().first as? String ?? ""

        guard requestedDatabase == "_Server" else {
            lock.withLock {
                recordedMonitors.append(RecordedMonitor(database: requestedDatabase, monitorId: monitorId))
            }
            write(["id": id, "result": [String: Any](), "error": NSNull()], to: channel)
            // RFC 7047 §4.1.5: the reply is followed by `update` notifications as
            // rows change. One is enough to prove the path.
            write([
                "id": NSNull(),
                "method": "update",
                "params": [monitorId, ["Logical_Switch": ["3f2e-uuid": ["new": ["name": "ls0"]]]]]
            ], to: channel)
            return
        }

        guard answersServerDatabase else {
            // The shape an ovsdb-server without `_Server` replies with: JSON-RPC
            // 1.0's bare-string error, not an error object.
            write(["id": id, "result": NSNull(), "error": "unknown database"], to: channel)
            return
        }

        let leader = lock.withLock { isLeader }
        lock.withLock { serverMonitors.append((channel, monitorId)) }
        write([
            "id": id,
            "result": Self.serverTableUpdates(database: database, connected: true, leader: leader),
            "error": NSNull()
        ], to: channel)
    }

    private static func serverTableUpdates(database: String, connected: Bool, leader: Bool) -> [String: Any] {
        return [
            "Database": [
                "db-row-uuid": [
                    "new": ["name": database, "connected": connected, "leader": leader]
                ]
            ]
        ]
    }

    private func write(_ message: [String: Any], to channel: Channel) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var buffer = channel.allocator.buffer(capacity: data.count)
        buffer.writeBytes(data)
        channel.writeAndFlush(buffer, promise: nil)
    }
}

/// Splits the client's byte stream into frames and hands each one to its server.
final class ClusterStubHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let server: ClusterStubServer
    private var accumulated: [UInt8] = []

    init(server: ClusterStubServer) {
        self.server = server
    }

    func channelActive(context: ChannelHandlerContext) {
        server.register(context.channel)
        context.fireChannelActive()
    }

    func channelInactive(context: ChannelHandlerContext) {
        server.unregister(context.channel)
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard let bytes = buffer.readBytes(length: buffer.readableBytes) else { return }
        accumulated.append(contentsOf: bytes)

        // Every frame this client writes ends in a newline, so framing needs no
        // brace counting here.
        while let newline = accumulated.firstIndex(of: UInt8(ascii: "\n")) {
            let frame = Data(accumulated[..<newline])
            accumulated.removeSubrange(...newline)
            guard let request = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any],
                  let method = request["method"] as? String else {
                continue
            }
            server.respond(to: method, request: request, on: context.channel)
        }
    }
}
