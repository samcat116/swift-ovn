#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import Logging
import NIOCore
import NIOFoundationCompat
import Synchronization

/// The state machine behind `OVSDBSocketConnection`: the supervisor that keeps a
/// session up across the remotes it was given, the live channel and its write
/// side, the in-flight request map, and inbound message routing.
///
/// This used to be three separate `NSLock`-guarded types, each carrying
/// `@unchecked Sendable` — thread safety asserted rather than checked, with
/// routing driven from `channelRead` on the event loop. Here the inbound side is
/// a `NIOAsyncChannel` sequence consumed by a single task (`runReadLoop`), so
/// ordering comes from actor isolation and reads are demand-driven: when the
/// consumer falls behind, the async channel stops issuing reads and the socket
/// applies real backpressure instead of buffering without limit.
///
/// Above that sits one long-lived `supervisor` task (`runSupervisor`), which owns
/// the whole connect/serve/reconnect cycle: it walks the remote list, vets each
/// session against `_Server` when leader-only mode is on, publishes every
/// transition to `stateHub`, and backs off between failed passes. Everything a
/// session owns — the writer, the pending requests, the internal `_Server`
/// monitor — is scoped to one iteration of that loop, so a reconnect starts from
/// a clean slate by construction.
actor OVSDBConnectionCore {
    private let remotes: OVSDBRemotes
    private let reconnectPolicy: OVSDBReconnectPolicy
    /// The database whose RAFT leader this connection insists on, or nil to use
    /// whichever remote answers. Enforced only when there is more than one
    /// remote: with a single one there is nothing better to switch to, so
    /// rejecting a follower would just refuse to work at all.
    private let leaderOnlyDatabase: String?
    private let eventLoopGroup: EventLoopGroup
    nonisolated let logger: Logger
    private let decoder = JSONDecoder()
    /// Reused across sends: constructing a `JSONEncoder` is not free, and one
    /// per outbound request adds up on the paths that write large transactions
    /// (a port-group update emits a `wait` op per port). Only ever used from
    /// this actor, so the reuse is serialized.
    private let encoder = JSONEncoder()

    /// The live connection: present only between a successful `connect()` and
    /// the read loop's teardown.
    private struct Session {
        let channel: Channel
        let writer: NIOAsyncChannelOutboundWriter<ByteBuffer>
    }

    /// Only this actor's own methods mutate the session, but
    /// `isConnectionActive` is a synchronous property, so it is held behind a
    /// `Mutex` (compiler-checked `Sendable`, uncontended in practice) rather
    /// than as isolated state.
    private nonisolated let liveSession = Mutex<Session?>(nil)
    nonisolated let notificationHub: JSONRPCNotificationHub
    nonisolated let stateHub = OVSDBConnectionStateHub()

    /// The in-flight `connect()`, so concurrent callers share one attempt
    /// instead of each starting — and leaking — their own supervisor.
    private var connectTask: Task<Void, Error>?
    /// The connect/serve/reconnect loop. Alive from the first `connect()` until
    /// it gives up or `disconnect()` stops it.
    private var supervisor: Task<Void, Never>?
    private var isSupervising = false
    private var readLoop: Task<Void, Never>?
    /// Completed by the supervisor once a session is up *and* vetted, or failed
    /// when it gives up. This is how `connect()` waits: it must not return on a
    /// session that the leader check is about to reject.
    private var activation: EventLoopPromise<Void>?
    /// Completed by `activate` once the read loop is running, or failed by
    /// `tearDown` if the connection dies first. This is how the supervisor waits
    /// for the write side, which only exists inside the read loop's
    /// `executeThenClose` scope.
    private var sessionReady: EventLoopPromise<Void>?
    private var pendingRequests: [JSONRPCIdentifier: PendingRequest] = [:]
    /// Set by `disconnect()`: the supervisor must stop rather than reconnect.
    private var isStopping = false
    /// The remote the current (or most recent) session belongs to.
    private var currentEndpoint: OVSDBEndpoint
    /// The `monitor` id of this session's internal `_Server` monitor, when one
    /// is in place. Updates carrying it are consumed here and never published,
    /// so a caller's monitor stream sees only the caller's own monitors.
    private var serverMonitorId: String?
    /// Set when the current session's remote reported that it stopped being the
    /// leader, so the supervisor can tell an election apart from a plain drop.
    private var hasLostLeadership = false
    /// Serial number for the ids of requests this layer issues itself. String
    /// ids cannot collide with `JSONRPCClient`'s numeric ones, so an internal
    /// request can never displace a caller's.
    private var internalRequestCount = 0

    init(
        remotes: OVSDBRemotes,
        eventLoopGroup: EventLoopGroup,
        logger: Logger,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        notificationBufferSize: Int = OVSDBSocketConnection.notificationBufferSize
    ) {
        self.remotes = remotes
        self.currentEndpoint = remotes.first
        self.reconnectPolicy = reconnect
        self.leaderOnlyDatabase = leaderOnlyDatabase
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.notificationHub = JSONRPCNotificationHub(bufferSize: notificationBufferSize, logger: logger)
    }

    init(
        endpoint: OVSDBEndpoint,
        eventLoopGroup: EventLoopGroup,
        logger: Logger,
        notificationBufferSize: Int = OVSDBSocketConnection.notificationBufferSize
    ) {
        self.init(
            remotes: OVSDBRemotes(endpoint),
            eventLoopGroup: eventLoopGroup,
            logger: logger,
            notificationBufferSize: notificationBufferSize
        )
    }

    // MARK: - Lifecycle

    nonisolated var isConnected: Bool {
        return liveSession.withLock { $0?.channel.isActive == true }
    }

    func connect() async throws {
        if isConnected {
            logger.debug("Already connected to \(currentEndpoint)")
            return
        }
        if let connectTask {
            logger.debug("connect() already in progress, reusing it")
            return try await connectTask.value
        }

        let task = Task {
            // Cleared here, before awaiting callers resume, so a later
            // reconnect starts fresh and cannot clear the slot of an attempt
            // that began after this one finished.
            defer { self.connectTask = nil }
            try await self.startSupervisor()
        }
        connectTask = task
        try await task.value
    }

    private func startSupervisor() async throws {
        // A supervisor that is already reconnecting must not be joined by a
        // second one: wait for the session it is working on instead. This is the
        // `connect()`-while-backing-off case, which is easy to reach because
        // `isConnected` is false for the whole backoff window.
        if isSupervising && !isStopping {
            logger.debug("A reconnect is already in progress; waiting for it")
            let promise = activation ?? eventLoopGroup.any().makePromise(of: Void.self)
            activation = promise
            return try await promise.futureResult.get()
        }

        // A supervisor from a previous connect/disconnect cycle may still be
        // unwinding. Letting it finish first is what stops its teardown from
        // closing the session this call is about to open. Awaiting releases this
        // actor, so the teardown can acquire it.
        if let supervisor {
            await supervisor.value
            // Only if it is still the one that was awaited — see the matching
            // check in `disconnect()`.
            if self.supervisor == supervisor {
                self.supervisor = nil
            }
        }

        isStopping = false
        let activation = eventLoopGroup.any().makePromise(of: Void.self)
        self.activation = activation
        isSupervising = true
        supervisor = Task.detached { [self] in
            await runSupervisor()
        }
        try await activation.futureResult.get()
    }

    /// Keeps a session up for as long as the policy allows, then closes
    /// everything down exactly once.
    private func runSupervisor() async {
        let reason = await superviseSessions()
        isSupervising = false
        logger.info("OVSDB connection closed: \(reason)")
        // A `connect()` still waiting when the supervisor gives up has to fail
        // rather than hang. A no-op once activation succeeded.
        failActivation(OVNManagerError.connectionFailed(reason))
        notificationHub.finishAll()
        stateHub.publish(.closed(reason: reason))
    }

    /// The connect/serve/reconnect loop. Returns why it stopped.
    ///
    /// One iteration is one *pass*: each remote is tried in turn until one gives
    /// a usable session, that session is served until it ends, and then the next
    /// pass begins at the remote after it — an election means the remote that
    /// just dropped is the least likely to be the new leader.
    ///
    /// A pass in which no remote worked increments the failure count, which
    /// drives the backoff, and so does a session lost to a leadership change — a
    /// remote that keeps handing leadership back is a reason to slow down. A
    /// session that simply dropped resets the count, but never skips the wait:
    /// see `waitBeforeRetry`.
    private func superviseSessions() async -> String {
        var failures = 0
        var next = 0
        var sessionsThisRun = 0
        var lastFailure: Error?

        while true {
            if let stop = stoppingReason() { return stop }

            var servedIndex: Int?
            for offset in 0..<remotes.count {
                if let stop = stoppingReason() { return stop }
                let index = (next + offset) % remotes.count
                let endpoint = remotes[index]
                stateHub.publish(.connecting(endpoint: endpoint, attempt: failures + 1))
                do {
                    try await openSession(to: endpoint)
                    servedIndex = index
                    break
                } catch {
                    lastFailure = error
                    logger.warning("Cannot use OVSDB remote \(endpoint): \(error)")
                    await endSession()
                }
            }

            guard let servedIndex else {
                // Nothing in the whole list answered.
                if sessionsThisRun == 0 {
                    // The very first connect fails rather than retrying: an
                    // unreachable or misconfigured remote must surface at the
                    // `connect()` call, not after an hour of silent backoff.
                    let failure = lastFailure ?? OVNManagerError.connectionFailed(
                        "No OVSDB remote in \(remotes) could be reached"
                    )
                    failActivation(failure)
                    return "no remote in \(remotes) could be reached: \(failure)"
                }
                failures += 1
                if let exhausted = exhaustedReason(failures: failures) { return exhausted }
                guard await waitBeforeRetry(failures: failures) else {
                    return stoppingReason() ?? "disconnected while waiting to reconnect"
                }
                continue
            }

            // A session is up, and vetted if leader-only mode asked for it.
            //
            // Checked here and not only at the top of the pass, because
            // `disconnect()` closes the live session and this one did not exist
            // when it looked: `activate` installs it part-way through
            // `openSession`, so a disconnect landing in that window finds
            // nothing to close and cancelling this task does not help either
            // (`openSession` waits on an `EventLoopPromise`, and
            // `EventLoopFuture.get()` ignores cancellation). Serving the session
            // anyway would park `awaitSessionEnd()` on a channel nobody will
            // ever close, while `disconnect()` waits on this task — both
            // forever. Closing it here is what breaks that.
            if let stop = stoppingReason() {
                await endSession()
                return stop
            }

            sessionsThisRun += 1
            next = (servedIndex + 1) % remotes.count
            if sessionsThisRun > 1 {
                // Server-side monitor state did not survive the drop. Told to
                // subscribers before anything from the new session reaches them:
                // no monitor exists on it yet, so no update can overtake this.
                notificationHub.publishReconnected()
            }
            stateHub.publish(.connected(endpoint: remotes[servedIndex]))
            succeedActivation()

            await awaitSessionEnd()

            if let stop = stoppingReason() { return stop }
            if !reconnectPolicy.isEnabled {
                return "the connection to \(remotes[servedIndex]) was lost and automatic reconnection is disabled"
            }

            if hasLostLeadership {
                // Counted as a failure: a remote that hands leadership back the
                // moment we arrive would otherwise never let the delay grow.
                hasLostLeadership = false
                failures += 1
                if let exhausted = exhaustedReason(failures: failures) { return exhausted }
            } else {
                // A session that was up resets the backoff, so recovery from a
                // genuine drop starts at `initialBackoff` however long the
                // connection had been flapping before it.
                failures = 0
            }
            // Waited even with the backoff reset, and this is load-bearing: a
            // server that accepts a connection and closes it immediately (a
            // half-open middlebox, a server shutting down) would otherwise be
            // reconnected to in a tight loop, with every session counting as a
            // success.
            guard await waitBeforeRetry(failures: max(1, failures)) else {
                return stoppingReason() ?? "disconnected while waiting to reconnect"
            }
        }
    }

    /// Bootstraps a channel to `endpoint`, starts its read loop and vets the
    /// resulting session. Throws if any of that fails, leaving the caller to
    /// clean up with `endSession()` and move on to the next remote.
    private func openSession(to endpoint: OVSDBEndpoint) async throws {
        logger.info("Connecting to OVSDB endpoint: \(endpoint)")
        let asyncChannel = try await OVSDBChannelBootstrap.connect(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )

        currentEndpoint = endpoint
        serverMonitorId = nil
        hasLostLeadership = false

        let ready = eventLoopGroup.any().makePromise(of: Void.self)
        sessionReady = ready
        readLoop = Task.detached { [self] in
            await runReadLoop(asyncChannel)
        }
        try await ready.futureResult.get()

        if let leaderOnlyDatabase, remotes.count > 1 {
            try await requireLeadership(of: leaderOnlyDatabase, at: endpoint)
        }

        logger.info("Successfully connected to \(endpoint)")
    }

    /// Closes the current session, if any, and waits for its read loop to
    /// finish, so the next attempt cannot race the previous teardown.
    private func endSession() async {
        if let session = liveSession.withLock({ $0 }) {
            session.channel.close(promise: nil)
        }
        await awaitSessionEnd()
    }

    private func awaitSessionEnd() async {
        guard let readLoop else { return }
        // Awaiting releases this actor, so the read loop can acquire it to run
        // its teardown.
        await readLoop.value
    }

    /// Runs `consumeInbound` for the lifetime of the connection.
    /// `executeThenClose` closes the channel on the way out, so the socket
    /// cannot be left open once the loop ends.
    private func runReadLoop(_ asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>) async {
        do {
            try await asyncChannel.executeThenClose { inbound, outbound in
                await consumeInbound(channel: asyncChannel.channel, inbound: inbound, outbound: outbound)
            }
        } catch {
            // The loop handles its own errors; this is a failure to close.
            logger.debug("Closing the channel to \(currentEndpoint) failed: \(error)")
        }
    }

    /// Installs the write side and consumes inbound frames until the connection
    /// ends, then fails everything still waiting on it.
    ///
    /// Not private so the routing tests can drive it with
    /// `NIOAsyncChannelInboundStream.makeTestingStream()` and
    /// `NIOAsyncChannelOutboundWriter.makeTestingWriter()` in place of a socket.
    func consumeInbound(
        channel: Channel,
        inbound: NIOAsyncChannelInboundStream<ByteBuffer>,
        outbound: NIOAsyncChannelOutboundWriter<ByteBuffer>
    ) async {
        activate(channel: channel, writer: outbound)
        do {
            for try await frame in inbound {
                await handleInbound(frame)
            }
            tearDown(error: nil)
        } catch {
            logger.error("Connection to \(currentEndpoint) ended with an error: \(error)")
            tearDown(error: error)
        }
    }

    private func activate(channel: Channel, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        liveSession.withLock { $0 = Session(channel: channel, writer: writer) }
        notificationHub.reopen()
        sessionReady?.succeed(())
        sessionReady = nil
        logger.debug("Channel active: \(channel.isActive), writable: \(channel.isWritable)")
    }

    /// Fails everything that was waiting on this connection. Runs exactly once
    /// per session, from the read loop.
    private func tearDown(error: Error?) {
        liveSession.withLock { $0 = nil }
        readLoop = nil
        serverMonitorId = nil

        let failure = error ?? OVNManagerError.connectionFailed("Connection closed")
        if let sessionReady {
            self.sessionReady = nil
            sessionReady.fail(failure)
        }

        if !pendingRequests.isEmpty {
            // In-flight requests always fail on a drop, reconnection or not:
            // their responses died with the session, and re-sending them is not
            // this layer's call to make (a `transact` may have been applied).
            logger.info("Connection ended, failing \(pendingRequests.count) in-flight request(s)")
        }
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.settle(with: failure)
        }

        // Finishing every subscription and marking the hub closed is what makes
        // a `notifications()` call after the connection is gone return a
        // finished stream instead of one that hangs. Skipped while a supervisor
        // is going to reconnect: there, subscriptions outlive the session and
        // are told about the gap with a `.reconnected` event instead.
        if isStopping || !isSupervising || !reconnectPolicy.isEnabled {
            notificationHub.finishAll()
        }
    }

    func disconnect() async {
        isStopping = true
        guard let supervisor else {
            // Never connected, or already closed for good.
            return
        }
        logger.info("Disconnecting from \(currentEndpoint)")
        if let session = liveSession.withLock({ $0 }) {
            // Closing the channel ends the inbound sequence, which returns the
            // read loop and runs `tearDown`.
            session.channel.close(promise: nil)
        }
        // Interrupts a backoff sleep; the supervisor then sees `isStopping`.
        supervisor.cancel()
        await supervisor.value
        // Cleared only if it is still the supervisor this call awaited. A
        // `connect()` blocked on the same task resumes first on the same actor,
        // installs a *new* supervisor and returns; clearing the handle then
        // dropped the only reference to a running supervisor. Nothing could
        // stop it afterwards — every later `disconnect()`, including the
        // `shutdown()` from `OVSDBSocketConnection.deinit`, returns at the
        // `guard let supervisor` above — so it reconnected forever, holding the
        // core and its event loops alive, which is exactly what that guarantee
        // exists to prevent.
        if self.supervisor == supervisor {
            self.supervisor = nil
        }
        logger.info("Successfully disconnected")
    }

    /// Disconnects and closes the state stream. Called when the owning
    /// `OVSDBSocketConnection` is released: a reconnecting supervisor holds this
    /// actor strongly and would otherwise keep re-establishing a session that
    /// nobody can use any more.
    func shutdown() async {
        await disconnect()
        stateHub.finish(reason: "the connection was released")
    }

    // MARK: - Supervisor helpers

    private func stoppingReason() -> String? {
        if isStopping { return "disconnected by request" }
        if Task.isCancelled { return "the connection task was cancelled" }
        return nil
    }

    private func exhaustedReason(failures: Int) -> String? {
        guard let limit = reconnectPolicy.maximumAttempts, failures >= limit else { return nil }
        return "gave up reconnecting after \(failures) failed attempt(s)"
    }

    /// Sleeps out the policy's backoff. Returns false when the wait was
    /// interrupted by a `disconnect()` or cancellation.
    private func waitBeforeRetry(failures: Int) async -> Bool {
        var generator = SystemRandomNumberGenerator()
        let delay = reconnectPolicy.backoff(forAttempt: failures, using: &generator)
        stateHub.publish(.waiting(retryIn: delay, attempt: failures))
        logger.info("Reconnecting to OVSDB in \(delay.nanoseconds / 1_000_000)ms (attempt \(failures + 1))")
        if delay.nanoseconds > 0 {
            do {
                try await Task.sleep(for: .nanoseconds(delay.nanoseconds))
            } catch {
                return false
            }
        }
        return stoppingReason() == nil
    }

    private func succeedActivation() {
        activation?.succeed(())
        activation = nil
    }

    private func failActivation(_ error: Error) {
        activation?.fail(error)
        activation = nil
    }

    // MARK: - Leader discovery

    /// Asks the remote, through the `_Server` database, whether it is the leader
    /// of `database`, and rejects the session if it is not.
    ///
    /// The monitor stays in place for the life of the session, so a *later*
    /// leadership change arrives as an update (see `handleServerStatusUpdate`)
    /// rather than as a failed write. A remote that cannot answer — `_Server`
    /// predates neither OVN nor every ovsdb-server in the field — is accepted
    /// with a warning; refusing to connect over a question we could not ask
    /// would be worse than talking to a follower.
    private func requireLeadership(of database: String, at endpoint: OVSDBEndpoint) async throws {
        let monitorId = nextInternalIdentifier("server-monitor")
        let requestId = JSONRPCIdentifier.string(nextInternalIdentifier("request"))
        let request = JSONRPCRequest(
            method: "monitor",
            params: .array([
                .string(OVSDBServerStatus.database),
                .string(monitorId),
                OVSDBServerStatus.monitorRequests
            ]),
            id: requestId
        )

        // Recorded before the request goes out, not after the reply is read.
        // ovsdb-server can create the monitor and answer late — past the
        // timeout below — and an id this connection has not recorded is an id
        // `handleNotification` cannot match, so every `_Server` update for it
        // was published to the hub and reached callers' monitor streams as
        // `Database` rows they never asked for. Leaving it unrecorded also cost
        // the leadership tracking: a later loss of leadership on this session
        // never reached `handleServerStatusUpdate`, so a leader-only connection
        // sat on a follower until a write failed. Recording an id for a monitor
        // the server ends up refusing is harmless — nothing will ever quote it.
        serverMonitorId = monitorId

        let response: JSONRPCResponse<JSONValue>
        do {
            response = try await sendRequest(
                request,
                id: requestId,
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .seconds(10)
            )
        } catch {
            // A session that died mid-check is no use to anyone, so that
            // propagates. Anything else means the remote would not answer the
            // question — a timeout, or a reply this client cannot read — and an
            // unanswerable question is not grounds for refusing to connect. (A
            // server that answers with an *error*, as one without `_Server`
            // does, lands in the `response.error` case below instead.)
            guard isConnected else { throw error }
            logger.warning("\(endpoint) did not answer the _Server monitor (\(error)); using it anyway")
            return
        }

        guard response.error == nil, let updates = response.result else {
            let detail = response.error?.message ?? "no result"
            logger.warning("\(endpoint) cannot report leadership of \(database) (\(detail)); using it anyway")
            return
        }
        switch OVSDBServerStatus.leadership(ofDatabase: database, in: updates) {
        case .leader:
            logger.debug("\(endpoint) is the leader of \(database)")
        case .follower:
            throw OVNManagerError.connectionFailed(
                "\(endpoint) is not the leader of \(database)"
            )
        case .notConnected:
            throw OVNManagerError.connectionFailed(
                "\(endpoint) is not currently serving \(database)"
            )
        case .unknown:
            logger.warning("\(endpoint) did not report a \(database) row in _Server; using it anyway")
        }
    }

    /// Handles an update on this session's internal `_Server` monitor. A remote
    /// that has stopped leading is abandoned: the channel is closed, and the
    /// supervisor's next pass starts at the following remote.
    private func handleServerStatusUpdate(_ params: JSONValue?) {
        guard let database = leaderOnlyDatabase,
              let tableUpdates = params?.arrayValue?.dropFirst().first else {
            return
        }

        switch OVSDBServerStatus.leadership(ofDatabase: database, in: tableUpdates) {
        case .leader, .unknown:
            return
        case .follower:
            logger.notice("\(currentEndpoint) is no longer the leader of \(database); reconnecting")
        case .notConnected:
            logger.notice("\(currentEndpoint) stopped serving \(database); reconnecting")
        }

        hasLostLeadership = true
        if let session = liveSession.withLock({ $0 }) {
            session.channel.close(promise: nil)
        }
    }

    private func nextInternalIdentifier(_ kind: String) -> String {
        internalRequestCount += 1
        return "swiftovn-\(kind)-\(internalRequestCount)"
    }

    // MARK: - Sending

    func send<T: Codable & Sendable>(_ message: T) async throws {
        let writer = try requireWriter()
        try await writer.write(try encodeFrame(message))
    }

    func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response {
        let writer = try requireWriter()
        let frame = try encodeFrame(request)

        // Registered before the write, because the response can arrive while
        // `write` is still suspended on channel writability and must find the
        // pending entry when it does.
        let promise = eventLoopGroup.any().makePromise(of: Response.self)
        register(id: id, promise: promise, timeout: timeout)
        logger.debug("Added pending request for ID: \(id)")

        do {
            try await writer.write(frame)
        } catch {
            pendingRequests.removeValue(forKey: id)?.settle(with: error)
            throw error
        }

        return try await promise.futureResult.get()
    }

    private func requireWriter() throws -> NIOAsyncChannelOutboundWriter<ByteBuffer> {
        guard let session = liveSession.withLock({ $0 }), session.channel.isActive else {
            throw OVNManagerError.connectionFailed("Not connected to \(currentEndpoint)")
        }
        return session.writer
    }

    private func encodeFrame<T: Encodable>(_ message: T) throws -> ByteBuffer {
        // Encoded straight into the buffer the channel writes. Going via
        // `String` — encode, decode the UTF-8, concatenate the newline, re-encode
        // — cost two more full copies of the payload, wasted work on exactly the
        // writes that are already large.
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        do {
            try encoder.encode(message, into: &buffer)
        } catch {
            logger.error("Failed to encode message: \(error)")
            throw OVNManagerError.encodingError(error)
        }
        // The trailing newline is not needed for framing (the peer parses a
        // stream of JSON objects, as does `OVSDBJSONFrameDecoder`), but it keeps
        // the wire readable in a packet capture, so it stays.
        buffer.writeInteger(UInt8(ascii: "\n"))
        // `debug` takes an autoclosure, so the payload is only rendered when
        // debug logging is actually enabled.
        logger.debug("Sending message: \(String(buffer: buffer))")
        return buffer
    }

    private func register<Response: Codable & Sendable>(
        id: JSONRPCIdentifier,
        promise: EventLoopPromise<Response>,
        timeout: TimeAmount
    ) {
        // Scheduled on the event loop the promise already lives on, rather than
        // a detached task parked in `Task.sleep`. That cost a task allocation, a
        // clock registration and — on the overwhelmingly common fast path — a
        // cancellation, for *every* request, including the small transacts a
        // busy caller issues thousands of times a second. A task is now spawned
        // only when a request actually times out, to hop back onto the actor.
        let timeoutTask: Scheduled<Void> = promise.futureResult.eventLoop.scheduleTask(in: timeout) { [weak self] in
            _ = Task { await self?.expire(id) }
        }
        let request = PendingRequest(
            timeoutTask: timeoutTask,
            deliver: { [decoder] frame in
                do {
                    // One parse of the frame's bytes, read without a copy
                    // straight out of the channel's buffer.
                    promise.succeed(try decoder.decode(Response.self, from: frame))
                } catch {
                    promise.fail(OVNManagerError.decodingError(error))
                }
            },
            fail: { promise.fail($0) }
        )

        if let displaced = pendingRequests.updateValue(request, forKey: id) {
            // Only reachable if a caller reuses an id (JSONRPCClient's are
            // monotonic, and this layer's own are strings). Failing the
            // displaced request turns what would otherwise be a caller waiting
            // forever into an error.
            logger.error("Request ID \(id) was reused; failing the earlier request")
            displaced.settle(with: OVNManagerError.operationFailed("Request ID \(id) was reused"))
        }
    }

    private func expire(_ id: JSONRPCIdentifier) {
        // Only fails a request that is still pending: a response may have
        // fulfilled the promise already.
        pendingRequests.removeValue(forKey: id)?.settle(with: OVNManagerError.timeoutError)
    }

    // MARK: - Inbound routing

    /// Routes one framed JSON-RPC message:
    ///
    /// - a `method` with a real `id` is a server-to-client *request*. RFC 7047
    ///   §4.1.11 requires `echo` to be answered (ovsdb-server's inactivity
    ///   probe closes the connection otherwise), so it is replied to here.
    /// - a `method` with a null or absent `id` is a *notification* (`update`
    ///   etc.) and goes to the subscribers.
    /// - an `id` with no `method` is a *response* and completes the matching
    ///   pending request.
    ///
    /// The routing members are found by scanning the frame rather than parsing
    /// it, so the only full parse is the one the matched consumer performs.
    private func handleInbound(_ frame: ByteBuffer) async {
        guard let envelope = JSONRPCFrameScanner.scanEnvelope(frame) else {
            logger.error("Failed to parse inbound message as a JSON object")
            return
        }

        if let method = envelope.method {
            switch envelope.identifier {
            case .absent:
                handleNotification(frame, method: method)
            case .value, .unsupported:
                await handleServerRequest(frame, method: method)
            }
            return
        }

        switch envelope.identifier {
        case .value(let id):
            logger.debug("Processing response for request ID: \(id)")
            handleResponse(frame, id: id)
        case .unsupported:
            logger.debug("Received response with unsupported ID type, ignoring")
        case .absent:
            logger.debug("Received message with neither method nor id, ignoring")
        }
    }

    private func handleResponse(_ frame: ByteBuffer, id: JSONRPCIdentifier) {
        guard let request = pendingRequests.removeValue(forKey: id) else {
            logger.debug("No pending request found for response ID: \(id)")
            return
        }
        logger.debug("Found matching pending request for ID: \(id)")
        request.timeoutTask.cancel()
        request.deliver(frame)
    }

    private func handleNotification(_ frame: ByteBuffer, method: String) {
        let inbound: InboundNotificationMessage
        do {
            inbound = try decoder.decode(InboundNotificationMessage.self, from: frame)
        } catch {
            logger.error("Failed to decode notification '\(method)': \(error)")
            return
        }

        // The internal `_Server` monitor is this layer's business, not the
        // caller's: consumed here so a `monitorUpdates()` consumer never sees
        // `Database` rows it did not ask for.
        if inbound.method == "update",
           let serverMonitorId,
           inbound.params?.arrayValue?.first?.stringValue == serverMonitorId {
            handleServerStatusUpdate(inbound.params)
            return
        }

        logger.debug("Dispatching notification: \(inbound.method)")
        notificationHub.publish(JSONRPCNotification(method: inbound.method, params: inbound.params))
    }

    private func handleServerRequest(_ frame: ByteBuffer, method: String) async {
        guard method == "echo" else {
            logger.warning("Received unsupported server-to-client request '\(method)', ignoring")
            return
        }

        let request: EchoRequest
        do {
            request = try decoder.decode(EchoRequest.self, from: frame)
        } catch {
            logger.error("Failed to decode echo request: \(error)")
            return
        }

        // RFC 7047 §4.1.11: the echo reply's result mirrors the request params.
        let reply = EchoReply(id: request.id ?? .null, result: request.params ?? .array([]))
        do {
            logger.debug("Replying to server echo request")
            try await requireWriter().write(try encodeFrame(reply))
        } catch {
            logger.error("Failed to send echo reply: \(error)")
        }
    }
}

// MARK: - Pending requests

/// A request waiting for its response. The closures capture the typed promise,
/// so one map can hold requests with differing response types without an
/// existential wrapper.
private struct PendingRequest {
    let timeoutTask: Scheduled<Void>
    /// Decodes the response frame and completes the waiter.
    let deliver: (ByteBuffer) -> Void
    let fail: (Error) -> Void

    /// Cancels the timeout and fails the waiter, for every path that abandons a
    /// request without a response.
    func settle(with error: Error) {
        timeoutTask.cancel()
        fail(error)
    }
}

// MARK: - Wire messages

private struct InboundNotificationMessage: Decodable {
    let method: String
    let params: JSONValue?
}

private struct EchoRequest: Decodable {
    let id: JSONRPCIdentifier?
    let params: JSONValue?
}

private struct EchoReply: Encodable {
    let id: JSONRPCIdentifier
    let result: JSONValue
    let error: JSONValue = .null
}
