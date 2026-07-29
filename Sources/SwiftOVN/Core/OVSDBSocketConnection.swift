import Foundation
import NIO
import NIOPosix
import NIOSSL
import NIOTLS
import Logging

/// Preserved name from when the connection was Unix-socket only.
public typealias UnixSocketConnection = OVSDBSocketConnection

public final class OVSDBSocketConnection: OVSDBTransport, @unchecked Sendable {
    /// Notifications buffered per notification-stream consumer before the
    /// oldest are discarded.
    ///
    /// Large enough to ride out a consumer that is briefly busy, small enough
    /// that a consumer which stops draining altogether cannot exhaust memory
    /// on a high-volume monitor (Southbound `Logical_Flow`). Applies at every
    /// layer that re-buffers notifications, including `monitorUpdates()`.
    public static let notificationBufferSize = 256

    private let eventLoopGroup: EventLoopGroup
    /// True when we created `eventLoopGroup` ourselves and are therefore
    /// responsible for shutting it down; false when the caller injected one.
    private let ownsEventLoopGroup: Bool
    private let logger: Logger
    private var channel: Channel?
    private let endpoint: OVSDBEndpoint
    private var isConnected: Bool = false
    private var responseRouter: JSONRPCResponseRouter?
    /// The in-flight `connect()` future, if any. Guards against concurrent
    /// `connect()` calls each bootstrapping their own channel (which would
    /// leak all but the last). All access is under `connectionLock`.
    private var inFlightConnect: EventLoopFuture<Void>?
    private let connectionLock = NSLock()
    private let notificationHub: JSONRPCNotificationHub
    /// Reused across sends: constructing a `JSONEncoder` is not free, and one
    /// per outbound request adds up on the paths that write large transactions
    /// (a port-group update emits a `wait` op per port). Its configuration is
    /// never mutated after this point, so concurrent `encode` calls only read
    /// it — the same reason `JSONRPCResponseRouter` keeps a single decoder.
    private let encoder = Foundation.JSONEncoder()

    public init(endpoint: OVSDBEndpoint, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.endpoint = endpoint
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }
        let resolvedLogger = logger ?? Logger(label: "ovn-manager.socket")
        self.logger = resolvedLogger
        self.notificationHub = JSONRPCNotificationHub(logger: resolvedLogger)
    }

    public convenience init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
    }

    deinit {
        // Only shut down a group we created; an injected one is the caller's
        // to manage. Without this, each connection created with no injected
        // group leaks its event-loop thread. Shut down asynchronously: if the
        // last reference is released by one of the group's own EventLoop
        // callbacks, `deinit` runs on that EventLoop, where the synchronous
        // variant would fatally trap.
        if ownsEventLoopGroup {
            eventLoopGroup.shutdownGracefully { _ in }
        }
    }

    public func connect() -> EventLoopFuture<Void> {
        connectionLock.lock()
        if isConnected {
            connectionLock.unlock()
            logger.debug("Already connected to \(endpoint)")
            return eventLoopGroup.next().makeSucceededFuture(())
        }
        if let inFlightConnect {
            connectionLock.unlock()
            logger.debug("connect() already in progress for \(endpoint), reusing it")
            return inFlightConnect
        }
        // Reserve the in-flight slot with a promise so concurrent callers
        // dedup, then release the lock *before* wiring up the real future.
        // `makeConnectFuture()` can return an already-completed future (missing
        // socket, invalid TLS); cascading it — and the slot-clearing callback —
        // would otherwise run synchronously while we still hold the
        // non-reentrant lock and deadlock when called on the group's EventLoop.
        let promise = eventLoopGroup.next().makePromise(of: Void.self)
        inFlightConnect = promise.futureResult
        connectionLock.unlock()

        // Clear the in-flight slot once this attempt settles so a later
        // reconnect can start fresh.
        promise.futureResult.whenComplete { [weak self] _ in
            guard let self else { return }
            self.connectionLock.lock()
            self.inFlightConnect = nil
            self.connectionLock.unlock()
        }
        makeConnectFuture().cascade(to: promise)
        return promise.futureResult
    }

    private func makeConnectFuture() -> EventLoopFuture<Void> {
        logger.info("Connecting to OVSDB endpoint: \(endpoint)")

        // A previous channel going inactive marked the hub closed so that late
        // subscribers got a finished stream instead of a hang; this connection
        // will publish again, so subscriptions from here on are live.
        notificationHub.reopen()

        // Created here (not in the channel initializer) so it can be assigned
        // to `responseRouter` under the lock once the connection succeeds.
        let router = JSONRPCResponseRouter(
            logger: logger,
            eventLoopGroup: eventLoopGroup,
            notificationHub: notificationHub
        )

        // TLS state that must exist before the pipeline is built.
        let sslContext: NIOSSLContext?
        let sslServerHostname: String?
        switch endpoint {
        case .unix(let path):
            if !FileManager.default.fileExists(atPath: path) {
                logger.error("Socket file does not exist at path: \(path)")
                return eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Socket file not found: \(path)"))
            }
            sslContext = nil
            sslServerHostname = nil
        case .tcp:
            sslContext = nil
            sslServerHostname = nil
        case .ssl(let host, _, let tls):
            do {
                sslContext = try Self.makeSSLContext(tls)
            } catch {
                logger.error("Failed to build TLS context: \(error)")
                return eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Invalid TLS configuration: \(error)"))
            }
            // NIOSSL rejects IP literals as SNI hostnames (RFC 6066), so pass
            // nil for them. This does not weaken verification: under
            // .fullVerification NIOSSL still validates identity with a nil
            // hostname by matching the connection's remote address against
            // the certificate's IP SANs (NIOSSLHandler.validateHostname →
            // validIdentityForService), and fails the handshake on no match.
            let hostname = tls.serverHostname ?? host
            sslServerHostname = Self.isIPAddressLiteral(hostname) ? nil : hostname
        }

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                self.logger.debug("Initializing channel pipeline...")

                var handlers: [ChannelHandler] = []
                if let sslContext {
                    do {
                        handlers.append(try NIOSSLClientHandler(context: sslContext, serverHostname: sslServerHostname))
                    } catch {
                        self.logger.error("Failed to create TLS handler: \(error)")
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                    handlers.append(TLSHandshakeWaitHandler())
                }
                // Outbound needs no handler: `send` and the router's echo reply
                // both write a `ByteBuffer`, which is what the TLS handler (or
                // the socket) wants already.
                handlers.append(contentsOf: [
                    ByteToMessageHandler(OVSDBJSONFrameDecoder()),
                    router
                ] as [ChannelHandler])
                return channel.pipeline.addHandlers(handlers).map { _ in
                    self.logger.debug("Channel pipeline initialized successfully")
                }.flatMapError { error in
                    self.logger.error("Failed to initialize channel pipeline: \(error)")
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let connectFuture: EventLoopFuture<Channel>
        switch endpoint {
        case .unix(let path):
            connectFuture = bootstrap.connect(unixDomainSocketPath: path)
        case .tcp(let host, let port), .ssl(let host, let port, _):
            connectFuture = bootstrap.connect(host: host, port: port)
        }

        return connectFuture
            .flatMap { channel -> EventLoopFuture<Channel> in
                // For ssl: endpoints the TCP connect completing is not enough;
                // certificate verification happens during the TLS handshake,
                // so hold the connect future until the handshake finishes and
                // fail it if verification fails.
                guard sslContext != nil else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                return channel.pipeline.handler(type: TLSHandshakeWaitHandler.self)
                    .flatMap { handler in
                        handler.handshakeFuture ?? channel.eventLoop.makeSucceededFuture(())
                    }
                    .map { channel }
            }
            .map { channel in
                self.logger.debug("Raw connection established, setting up channel...")
                self.connectionLock.lock()
                self.channel = channel
                self.responseRouter = router
                self.isConnected = true
                self.connectionLock.unlock()
                self.logger.info("Successfully connected to \(self.endpoint)")
                self.logger.debug("Channel active: \(channel.isActive), writable: \(channel.isWritable)")
            }
            .flatMapError { error in
                self.logger.error("Failed to connect to \(self.endpoint): \(error)")
                self.logger.error("Error type: \(type(of: error))")
                if let ioError = error as? IOError {
                    self.logger.error("IO error code: \(ioError.errnoCode)")
                }
                return self.eventLoopGroup.next().makeFailedFuture(OVNManagerError.connectionFailed("Failed to connect to \(self.endpoint): \(error)"))
            }
    }

    private static func makeSSLContext(_ tls: OVSDBTLSConfiguration) throws -> NIOSSLContext {
        var configuration = TLSConfiguration.makeClientConfiguration()
        if let caPath = tls.caCertificatePath {
            configuration.trustRoots = .file(caPath)
        }
        if let certPath = tls.clientCertificatePath {
            configuration.certificateChain = try NIOSSLCertificate.fromPEMFile(certPath).map { .certificate($0) }
        }
        if let keyPath = tls.clientPrivateKeyPath {
            configuration.privateKey = .file(keyPath)
        }
        if !tls.verifiesServerCertificate {
            configuration.certificateVerification = .none
        }
        return try NIOSSLContext(configuration: configuration)
    }

    private static func isIPAddressLiteral(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return host.withCString { pointer in
            inet_pton(AF_INET, pointer, &ipv4) == 1 || inet_pton(AF_INET6, pointer, &ipv6) == 1
        }
    }

    public func disconnect() -> EventLoopFuture<Void> {
        connectionLock.lock()
        guard let channel = channel, isConnected else {
            connectionLock.unlock()
            return eventLoopGroup.next().makeSucceededFuture(())
        }

        logger.info("Disconnecting from \(endpoint)")
        self.isConnected = false
        self.responseRouter = nil
        connectionLock.unlock()

        // Closing the channel fires channelInactive on the router, which fails
        // all in-flight requests and finishes the notification streams.
        return channel.close().map {
            self.connectionLock.lock()
            self.channel = nil
            self.connectionLock.unlock()
            self.logger.info("Successfully disconnected from \(self.endpoint)")
        }
    }

    public func send<T: Codable & Sendable>(_ message: T) -> EventLoopFuture<Void> {
        connectionLock.lock()
        guard let channel = channel, isConnected else {
            connectionLock.unlock()
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        connectionLock.unlock()

        do {
            let data = try encoder.encode(message)

            // Straight from the encoder's bytes into the channel's buffer. Going
            // via `String` cost two more full copies of the payload — one to
            // decode the UTF-8, one for the `+ "\n"` concatenation — before the
            // outbound handler copied it into a `ByteBuffer` anyway. That is
            // wasted work on exactly the writes that are already large.
            //
            // The trailing newline is not needed for framing (the peer parses a
            // stream of JSON objects, as does `OVSDBJSONFrameDecoder`), but it
            // keeps the wire readable in a packet capture, so it stays.
            var buffer = channel.allocator.buffer(capacity: data.count + 1)
            buffer.writeBytes(data)
            buffer.writeInteger(UInt8(ascii: "\n"))

            // `debug` takes an autoclosure, so this decodes the payload only
            // when debug logging is actually enabled.
            logger.debug("Sending message: \(String(decoding: data, as: UTF8.self))")
            return channel.writeAndFlush(buffer)
        } catch {
            logger.error("Failed to encode message: \(error)")
            return eventLoopGroup.next().makeFailedFuture(OVNManagerError.encodingError(error))
        }
    }

    public func receive<T: Codable & Sendable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount = .seconds(30)) -> EventLoopFuture<T> {
        connectionLock.lock()
        guard let responseRouter = responseRouter, isConnected else {
            connectionLock.unlock()
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        connectionLock.unlock()

        return responseRouter.waitForResponse(requestId: requestId, type: T.self, timeout: timeout)
    }

    /// Returns a buffered stream of server-initiated JSON-RPC notifications
    /// (messages with a `method` and a null or absent `id`, e.g. `update`).
    ///
    /// The stream buffers notifications from the moment it is created, so
    /// subscribe *before* issuing the request that triggers them (e.g.
    /// `monitor`) and no notification is lost while the consumer is busy —
    /// up to `notificationBufferSize` of them. A consumer that falls further
    /// behind has its oldest notifications discarded (with a warning logged);
    /// use `notificationEvents()` to observe those gaps in-stream.
    ///
    /// The stream finishes when the connection closes, and a stream created
    /// after the connection has closed is already finished. Subscribing is
    /// valid before `connect()` and multiple subscribers each receive every
    /// notification.
    public func notifications() -> AsyncStream<JSONRPCNotification> {
        let events = notificationHub.subscribe()
        let logger = self.logger
        return AsyncStream(bufferingPolicy: .bufferingNewest(Self.notificationBufferSize)) { continuation in
            let task = Task {
                var isOverflowing = false
                for await event in events {
                    switch event {
                    case .notification(let notification):
                        if case .dropped = continuation.yield(notification) {
                            if !isOverflowing {
                                isOverflowing = true
                                logger.warning("Notification buffer full (\(Self.notificationBufferSize)); the consumer of notifications() is not keeping up. Use notificationEvents() to see how many were discarded.")
                            }
                        } else {
                            isOverflowing = false
                        }
                    case .dropped(let count):
                        logger.warning("Discarded \(count) notification(s): the consumer of notifications() is not keeping up. Use notificationEvents() to observe this in-stream.")
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Like `notifications()`, but reports discarded notifications in-stream as
    /// `.dropped(count:)` events instead of only logging them.
    ///
    /// Prefer this when a gap matters — a monitor consumer, for instance, must
    /// re-take a snapshot rather than continue from an incomplete view.
    public func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent> {
        return notificationHub.subscribe()
    }

    public var isConnectionActive: Bool {
        connectionLock.lock()
        defer { connectionLock.unlock() }
        return isConnected && channel?.isActive == true
    }
}

// MARK: - TLS Handshake Wait

/// Surfaces TLS handshake completion as a future, so `connect()` on an `ssl:`
/// endpoint succeeds only after certificate verification instead of at TCP
/// establishment. All members are accessed on the channel's event loop.
final class TLSHandshakeWaitHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let timeout: TimeAmount
    private var promise: EventLoopPromise<Void>?
    private var timeoutTask: Scheduled<Void>?
    private var isComplete = false

    init(timeout: TimeAmount = .seconds(30)) {
        self.timeout = timeout
    }

    /// nil only before the handler is added to a pipeline.
    var handshakeFuture: EventLoopFuture<Void>? {
        return promise?.futureResult
    }

    func handlerAdded(context: ChannelHandlerContext) {
        promise = context.eventLoop.makePromise(of: Void.self)
        // A server that accepts TCP but never answers the ClientHello (e.g. an
        // ssl: endpoint pointed at a cleartext port) would otherwise hang the
        // connect forever.
        let channel = context.channel
        timeoutTask = context.eventLoop.scheduleTask(in: timeout) {
            self.complete(.failure(OVNManagerError.connectionFailed("TLS handshake timed out")))
            channel.close(promise: nil)
        }
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let tlsEvent = event as? TLSUserEvent, case .handshakeCompleted = tlsEvent {
            complete(.success(()))
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.fireErrorCaught(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.failure(OVNManagerError.connectionFailed("Connection closed during TLS handshake")))
        context.fireChannelInactive()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        complete(.failure(OVNManagerError.connectionFailed("Connection closed before TLS handshake completed")))
    }

    private func complete(_ result: Result<Void, Error>) {
        guard !isComplete else { return }
        isComplete = true
        timeoutTask?.cancel()
        switch result {
        case .success:
            promise?.succeed(())
        case .failure(let error):
            promise?.fail(error)
        }
    }
}

// MARK: - Notification Hub

/// Fans server-initiated notifications out to any number of subscribers.
///
/// Each subscriber gets its own `AsyncStream` buffering up to `bufferSize`
/// notifications, so notifications arriving while the consumer is between
/// iterations are still delivered. The buffer is bounded on purpose: an
/// unbounded one lets a single stalled consumer grow the process without limit
/// (Southbound `Logical_Flow` updates are both large and frequent). When it
/// overflows the oldest notifications are discarded and the subscriber is sent
/// a `.dropped(count:)` event so the gap is visible rather than silent.
///
/// Outlives the channel handler so subscriptions can be created before the
/// connection is established, and survives a reconnect (see `reopen()`).
final class JSONRPCNotificationHub: @unchecked Sendable {
    private struct Subscriber {
        let continuation: AsyncStream<JSONRPCNotificationEvent>.Continuation
        /// Notifications discarded since this subscriber was last told about
        /// a gap. Reported with the next event that reaches its buffer.
        var pendingDrops: Int = 0
    }

    private let lock = NSLock()
    private let bufferSize: Int
    private let logger: Logger
    private var subscribers: [UUID: Subscriber] = [:]
    /// Set by `finishAll()` when the connection drops. Without it a
    /// `subscribe()` after the connection is gone would hand back a stream
    /// whose continuation nothing ever finishes, hanging the consumer's
    /// `for await` forever. Cleared by `reopen()` on the next connect.
    private var isClosed = false

    init(bufferSize: Int = OVSDBSocketConnection.notificationBufferSize, logger: Logger? = nil) {
        // A zero-length buffer would make `yield` report the value it was just
        // handed as the dropped one, which breaks the drop accounting below.
        self.bufferSize = max(1, bufferSize)
        self.logger = logger ?? Logger(label: "ovn-manager.notifications")
    }

    func subscribe() -> AsyncStream<JSONRPCNotificationEvent> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(
            of: JSONRPCNotificationEvent.self,
            bufferingPolicy: .bufferingNewest(bufferSize)
        )

        lock.lock()
        if isClosed {
            lock.unlock()
            // Nothing will ever publish on this hub again; finish immediately
            // rather than leave the consumer waiting on a dead stream.
            continuation.finish()
            return stream
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        subscribers[id] = Subscriber(continuation: continuation)
        lock.unlock()
        return stream
    }

    /// Publishes to every subscriber. Called from the channel's event loop, so
    /// calls are serialized with respect to each other and the per-subscriber
    /// drop counts below stay consistent.
    func publish(_ notification: JSONRPCNotification) {
        lock.lock()
        let entries = Array(subscribers)
        lock.unlock()

        for (id, subscriber) in entries {
            var delta = 0

            if subscriber.pendingDrops > 0 {
                // `.bufferingNewest` always accepts the value and evicts the
                // oldest instead, so the report itself is guaranteed a slot;
                // whatever it displaced is folded back into the count.
                let result = subscriber.continuation.yield(.dropped(count: subscriber.pendingDrops))
                if case .terminated = result { continue }
                delta -= subscriber.pendingDrops
                if case .dropped(let evicted) = result {
                    delta += Self.notificationCount(of: evicted)
                }
            }

            if case .dropped(let evicted) = subscriber.continuation.yield(.notification(notification)) {
                delta += Self.notificationCount(of: evicted)
            }

            if delta > 0 && subscriber.pendingDrops == 0 {
                // Log once per overflow episode rather than once per discarded
                // notification, which under a sustained overflow would itself
                // flood.
                logger.warning("Notification buffer full (\(bufferSize)); a subscriber is not keeping up and notifications are being discarded")
            }
            adjustPendingDrops(id, by: delta)
        }
    }

    func finishAll() {
        lock.lock()
        let entries = Array(subscribers.values)
        subscribers.removeAll()
        isClosed = true
        lock.unlock()

        for subscriber in entries {
            // Last chance to tell a lagging consumer about the gap; after the
            // finish below nothing more can be delivered.
            if subscriber.pendingDrops > 0 {
                subscriber.continuation.yield(.dropped(count: subscriber.pendingDrops))
            }
            subscriber.continuation.finish()
        }
    }

    /// Clears the closed flag so a reconnect can publish again. The hub is
    /// created once per connection object but each connect builds a fresh
    /// channel, so without this every subscription after the first disconnect
    /// would come back already finished.
    func reopen() {
        lock.lock()
        isClosed = false
        lock.unlock()
    }

    /// How many server notifications an evicted stream element represents.
    private static func notificationCount(of event: JSONRPCNotificationEvent) -> Int {
        switch event {
        case .notification:
            return 1
        case .dropped(let count):
            return count
        }
    }

    private func adjustPendingDrops(_ id: UUID, by delta: Int) {
        guard delta != 0 else { return }
        lock.lock()
        if var subscriber = subscribers[id] {
            subscriber.pendingDrops = max(0, subscriber.pendingDrops + delta)
            subscribers[id] = subscriber
        }
        lock.unlock()
    }

    private func removeSubscriber(_ id: UUID) {
        lock.lock()
        subscribers.removeValue(forKey: id)
        lock.unlock()
    }
}

// MARK: - JSON-RPC Response Router

/// Routes each inbound JSON-RPC message to the right consumer:
///
/// - Messages with a `method` and a real `id` are server-to-client *requests*.
///   RFC 7047 §4.1.11 requires `echo` to be answered (ovsdb-server's
///   inactivity probe closes the connection otherwise), so those are replied
///   to inline.
/// - Messages with a `method` and a null/absent `id` are *notifications*
///   (`update` etc.) and are published to the notification hub.
/// - Messages with an `id` and no `method` are *responses* to our requests
///   and complete the matching pending promise.
final class JSONRPCResponseRouter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = String

    private let logger: Logger
    private let decoder = Foundation.JSONDecoder()
    private var pendingRequests: [JSONRPCIdentifier: PendingRequestProtocol] = [:]
    private let lock = NSLock()
    private var eventLoop: EventLoop?
    private let eventLoopGroup: EventLoopGroup
    private let notificationHub: JSONRPCNotificationHub

    init(logger: Logger, eventLoopGroup: EventLoopGroup, notificationHub: JSONRPCNotificationHub) {
        self.logger = logger
        self.eventLoopGroup = eventLoopGroup
        self.notificationHub = notificationHub
    }

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let message = unwrapInboundIn(data)
        logger.debug("Received raw message: \(message)")

        guard let messageData = message.data(using: .utf8) else {
            logger.error("Failed to convert message to UTF-8 data")
            return
        }

        guard let jsonObject = (try? JSONSerialization.jsonObject(with: messageData, options: [])) as? [String: Any] else {
            logger.error("Failed to parse inbound message as a JSON object")
            return
        }

        let idValue = jsonObject["id"]
        let hasRealId = idValue != nil && !(idValue is NSNull)

        if let method = jsonObject["method"] as? String {
            if hasRealId {
                // Server-to-client request; a reply is expected.
                handleServerRequest(context: context, method: method, jsonObject: jsonObject)
            } else {
                // JSON-RPC marks notifications with a null (or absent) id.
                handleNotification(messageData: messageData, method: method)
            }
        } else if hasRealId {
            let responseId: JSONRPCIdentifier
            if let idNumber = idValue as? Int {
                responseId = .number(idNumber)
            } else if let idString = idValue as? String {
                responseId = .string(idString)
            } else {
                logger.debug("Received response with unsupported ID type, ignoring")
                return
            }

            logger.debug("Processing response for request ID: \(responseId)")
            handleResponse(responseId: responseId, messageData: messageData)
        } else {
            logger.debug("Received message with neither method nor id, ignoring")
        }
    }

    private func handleServerRequest(context: ChannelHandlerContext, method: String, jsonObject: [String: Any]) {
        guard method == "echo" else {
            logger.warning("Received unsupported server-to-client request '\(method)', ignoring")
            return
        }

        // RFC 7047 §4.1.11: the echo reply's result mirrors the request params.
        let reply: [String: Any] = [
            "id": jsonObject["id"] ?? NSNull(),
            "result": jsonObject["params"] ?? [Any](),
            "error": NSNull()
        ]

        do {
            let data = try JSONSerialization.data(withJSONObject: reply)
            var buffer = context.channel.allocator.buffer(capacity: data.count + 1)
            buffer.writeBytes(data)
            buffer.writeInteger(UInt8(ascii: "\n"))
            logger.debug("Replying to server echo request")
            context.writeAndFlush(NIOAny(buffer), promise: nil)
        } catch {
            logger.error("Failed to serialize echo reply: \(error)")
        }
    }

    private func handleNotification(messageData: Data, method: String) {
        do {
            let inbound = try decoder.decode(InboundNotificationMessage.self, from: messageData)
            logger.debug("Dispatching notification: \(method)")
            notificationHub.publish(JSONRPCNotification(method: inbound.method, params: inbound.params))
        } catch {
            logger.error("Failed to decode notification '\(method)': \(error)")
        }
    }

    private func handleResponse(responseId: JSONRPCIdentifier, messageData: Data) {
        lock.lock()
        let pendingRequest = pendingRequests.removeValue(forKey: responseId)
        lock.unlock()

        if let pendingRequest {
            logger.debug("Found matching pending request for ID: \(responseId)")
            pendingRequest.timeoutTask.cancel()
            pendingRequest.fulfill(with: messageData, decoder: decoder)
        } else {
            logger.debug("No pending request found for response ID: \(responseId)")
        }
    }

    func waitForResponse<T: Codable & Sendable>(requestId: JSONRPCIdentifier, type: T.Type, timeout: TimeAmount) -> EventLoopFuture<T> {
        guard let eventLoop = eventLoop else {
            let failedPromise = eventLoopGroup.next().makePromise(of: T.self)
            failedPromise.fail(OVNManagerError.connectionFailed("Event loop not available"))
            return failedPromise.futureResult
        }

        let promise = eventLoop.makePromise(of: T.self)

        let timeoutTask = eventLoop.scheduleTask(in: timeout) {
            self.lock.lock()
            let removed = self.pendingRequests.removeValue(forKey: requestId)
            self.lock.unlock()
            // Only fail if the request was still pending; a response may have
            // already fulfilled the promise on another path.
            if removed != nil {
                promise.fail(OVNManagerError.timeoutError)
            }
        }

        let pendingRequest = PendingRequestWrapper<T>(
            promise: promise,
            timeoutTask: timeoutTask
        )

        lock.lock()
        pendingRequests[requestId] = pendingRequest
        lock.unlock()

        logger.debug("Added pending request for ID: \(requestId)")

        return promise.futureResult
    }

    func channelInactive(context: ChannelHandlerContext) {
        logger.info("Channel became inactive, failing in-flight requests and finishing notification streams")
        failAllPending(with: OVNManagerError.connectionFailed("Connection closed"))
        notificationHub.finishAll()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.error("Channel error caught: \(error)")
        failAllPending(with: error)
        context.fireErrorCaught(error)
    }

    private func failAllPending(with error: Error) {
        lock.lock()
        let allPendingRequests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        lock.unlock()

        for request in allPendingRequests {
            request.timeoutTask.cancel()
            request.fail(with: error)
        }
    }
}

private struct InboundNotificationMessage: Decodable {
    let method: String
    let params: JSONValue?
}

private protocol PendingRequestProtocol {
    var timeoutTask: Scheduled<Void> { get }
    func fulfill(with data: Data, decoder: JSONDecoder)
    func fail(with error: Error)
}

private struct PendingRequestWrapper<T: Codable & Sendable>: PendingRequestProtocol {
    let promise: EventLoopPromise<T>
    let timeoutTask: Scheduled<Void>

    func fulfill(with data: Data, decoder: JSONDecoder) {
        do {
            let response = try decoder.decode(T.self, from: data)
            promise.succeed(response)
        } catch {
            promise.fail(OVNManagerError.decodingError(error))
        }
    }

    func fail(with error: Error) {
        promise.fail(error)
    }
}

// MARK: - Frame Handling

/// Frames a byte stream into individual JSON-RPC objects.
///
/// OVSDB (RFC 7047) streams JSON-RPC objects with no delimiters — the server may
/// concatenate several objects in a single read, or split one object across reads.
/// A newline-based framer therefore mis-frames these messages. This decoder instead
/// tracks `{`/`}` nesting depth to emit exactly one complete top-level object per
/// message, ignoring braces that appear inside JSON strings and honoring `\` escapes.
///
/// The scan position and brace state persist across `decode` calls. `decode` is
/// re-invoked on every arriving chunk, so restarting the scan at the beginning
/// each time would re-examine the whole accumulated message — O(N·k) for a
/// message of N bytes delivered in k reads. That is quadratic for the
/// multi-megabyte `monitor` updates ovsdb-server sends for large tables
/// (Southbound `Logical_Flow` in particular). Resuming where the previous call
/// stopped keeps framing linear in the message size.
struct OVSDBJSONFrameDecoder: ByteToMessageDecoder {
    typealias InboundOut = String

    /// Brace-nesting depth within the object currently being scanned.
    private var depth = 0
    private var inString = false
    private var escaped = false
    /// Offset from the reader index of the `{` opening the object currently
    /// being scanned; nil while between objects.
    private var objectStartOffset: Int?
    /// How many bytes from the reader index have already been examined.
    private var scannedOffset = 0

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView

        // Clamped defensively: the scan cursor is only ever advanced over bytes
        // that remain buffered, so it cannot exceed the readable range, but a
        // stale cursor would trap rather than merely re-scan.
        let resumeOffset = min(scannedOffset, view.count)

        var offset = resumeOffset
        var index = view.index(view.startIndex, offsetBy: resumeOffset)
        while index < view.endIndex {
            let byte = view[index]

            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
            } else {
                switch byte {
                case UInt8(ascii: "\""):
                    inString = true
                case UInt8(ascii: "{"):
                    if depth == 0 {
                        objectStartOffset = offset
                    }
                    depth += 1
                case UInt8(ascii: "}"):
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let leading = objectStartOffset {
                            // A complete top-level object spans leading...offset inclusive.
                            let length = offset - leading + 1

                            // Everything up to and including this object leaves the
                            // buffer, so the next scan starts clean at the new reader
                            // index regardless of which branch below is taken.
                            resetScanState()

                            // Discard any leading whitespace/delimiters before the object,
                            // then read the object itself and fire it downstream.
                            buffer.moveReaderIndex(forwardBy: leading)
                            guard let objectString = buffer.readString(length: length) else {
                                return .needMoreData
                            }
                            context.fireChannelRead(wrapInboundOut(objectString))

                            // Keep any trailing bytes buffered for the next object.
                            return .continue
                        }
                    }
                default:
                    break
                }
            }

            index = view.index(after: index)
            offset += 1
        }

        // No complete object yet — remember how far we got so the next chunk
        // resumes here instead of re-scanning from the start.
        scannedOffset = offset
        return .needMoreData
    }

    private mutating func resetScanState() {
        depth = 0
        inString = false
        escaped = false
        objectStartOffset = nil
        scannedOffset = 0
    }
}
