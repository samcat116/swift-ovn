import Foundation
import Logging
import NIOCore
import NIOFoundationCompat
import Synchronization

/// The state machine behind `OVSDBSocketConnection`: the live channel and its
/// write side, the in-flight request map, and inbound message routing.
///
/// This used to be three separate `NSLock`-guarded types, each carrying
/// `@unchecked Sendable` — thread safety asserted rather than checked, with
/// routing driven from `channelRead` on the event loop. Here the inbound side is
/// a `NIOAsyncChannel` sequence consumed by a single task (`runReadLoop`), so
/// ordering comes from actor isolation and reads are demand-driven: when the
/// consumer falls behind, the async channel stops issuing reads and the socket
/// applies real backpressure instead of buffering without limit.
actor OVSDBConnectionCore {
    private let endpoint: OVSDBEndpoint
    private let eventLoopGroup: EventLoopGroup
    nonisolated let logger: Logger
    private let decoder = Foundation.JSONDecoder()
    /// Reused across sends: constructing a `JSONEncoder` is not free, and one
    /// per outbound request adds up on the paths that write large transactions
    /// (a port-group update emits a `wait` op per port). Only ever used from
    /// this actor, so the reuse is serialized.
    private let encoder = Foundation.JSONEncoder()

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

    /// The in-flight `connect()`, so concurrent callers share one attempt
    /// instead of each bootstrapping — and leaking — their own channel.
    private var connectTask: Task<Void, Error>?
    private var readLoop: Task<Void, Never>?
    /// Completed by `activate` once the read loop is running, or failed by
    /// `tearDown` if the connection dies first. This is how `connect()` waits
    /// for the write side, which only exists inside the read loop's
    /// `executeThenClose` scope.
    private var activation: EventLoopPromise<Void>?
    private var pendingRequests: [JSONRPCIdentifier: PendingRequest] = [:]

    init(
        endpoint: OVSDBEndpoint,
        eventLoopGroup: EventLoopGroup,
        logger: Logger,
        notificationBufferSize: Int = OVSDBSocketConnection.notificationBufferSize
    ) {
        self.endpoint = endpoint
        self.eventLoopGroup = eventLoopGroup
        self.logger = logger
        self.notificationHub = JSONRPCNotificationHub(bufferSize: notificationBufferSize, logger: logger)
    }

    // MARK: - Lifecycle

    nonisolated var isConnected: Bool {
        return liveSession.withLock { $0?.channel.isActive == true }
    }

    func connect() async throws {
        if isConnected {
            logger.debug("Already connected to \(endpoint)")
            return
        }
        if let connectTask {
            logger.debug("connect() already in progress for \(endpoint), reusing it")
            return try await connectTask.value
        }

        let task = Task {
            // Cleared here, before awaiting callers resume, so a later
            // reconnect starts fresh and cannot clear the slot of an attempt
            // that began after this one finished.
            defer { self.connectTask = nil }
            try await self.performConnect()
        }
        connectTask = task
        try await task.value
    }

    private func performConnect() async throws {
        // A previous session whose channel has already gone inactive may still
        // be inside `tearDown`. Letting it finish first is what stops its
        // teardown from clearing the session this call is about to install —
        // the exact sequence a reconnect-on-failure loop produces. Awaiting
        // releases this actor, so the teardown can acquire it.
        if let readLoop {
            await readLoop.value
        }

        logger.info("Connecting to OVSDB endpoint: \(endpoint)")

        let asyncChannel = try await OVSDBChannelBootstrap.connect(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )

        let activation = eventLoopGroup.any().makePromise(of: Void.self)
        self.activation = activation
        readLoop = Task.detached { [self] in
            await runReadLoop(asyncChannel)
        }

        try await activation.futureResult.get()
        logger.info("Successfully connected to \(endpoint)")
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
            logger.debug("Closing the channel to \(endpoint) failed: \(error)")
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
            logger.error("Connection to \(endpoint) ended with an error: \(error)")
            tearDown(error: error)
        }
    }

    private func activate(channel: Channel, writer: NIOAsyncChannelOutboundWriter<ByteBuffer>) {
        liveSession.withLock { $0 = Session(channel: channel, writer: writer) }
        notificationHub.reopen()
        activation?.succeed(())
        activation = nil
        logger.debug("Channel active: \(channel.isActive), writable: \(channel.isWritable)")
    }

    /// Fails everything that was waiting on this connection. Runs exactly once
    /// per session, from the read loop.
    private func tearDown(error: Error?) {
        liveSession.withLock { $0 = nil }
        readLoop = nil

        let failure = error ?? OVNManagerError.connectionFailed("Connection closed")
        if let activation {
            self.activation = nil
            activation.fail(failure)
        }

        if !pendingRequests.isEmpty {
            logger.info("Connection ended, failing \(pendingRequests.count) in-flight request(s)")
        }
        let pending = pendingRequests
        pendingRequests.removeAll()
        for request in pending.values {
            request.settle(with: failure)
        }

        // Finishes every subscription and marks the hub closed, so a
        // `notifications()` call after the connection is gone gets a finished
        // stream instead of one that hangs.
        notificationHub.finishAll()
    }

    func disconnect() async {
        guard let session = liveSession.withLock({ $0 }), let readLoop else {
            return
        }
        logger.info("Disconnecting from \(endpoint)")
        // Closing the channel ends the inbound sequence, which returns the read
        // loop and runs `tearDown`. Awaiting the loop releases this actor so
        // that teardown can acquire it.
        session.channel.close(promise: nil)
        await readLoop.value
        logger.info("Successfully disconnected from \(endpoint)")
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
            throw OVNManagerError.connectionFailed("Not connected to \(endpoint)")
        }
        return session.writer
    }

    private func encodeFrame<T: Encodable>(_ message: T) throws -> ByteBuffer {
        // Encoded straight into the buffer: the old path went
        // Data → String → String + "\n" → ByteBuffer, re-encoding UTF-8 twice.
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        do {
            try encoder.encode(message, into: &buffer)
        } catch {
            logger.error("Failed to encode message: \(error)")
            throw OVNManagerError.encodingError(error)
        }
        // RFC 7047 needs no delimiter, but ovsdb-server's own clients send one
        // and it keeps a captured stream readable.
        buffer.writeInteger(UInt8(ascii: "\n"))
        return buffer
    }

    private func register<Response: Codable & Sendable>(
        id: JSONRPCIdentifier,
        promise: EventLoopPromise<Response>,
        timeout: TimeAmount
    ) {
        let timeoutTask = Task.detached { [weak self] in
            try? await Task.sleep(for: .nanoseconds(max(0, timeout.nanoseconds)))
            guard !Task.isCancelled else { return }
            await self?.expire(id)
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
            // monotonic). Failing the displaced request turns what would
            // otherwise be a caller waiting forever into an error.
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
    let timeoutTask: Task<Void, Never>
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
