import Foundation
import NIO
import NIOPosix
import NIOSSL
import NIOTLS
import Logging

/// Preserved name from when the connection was Unix-socket only.
public typealias UnixSocketConnection = OVSDBSocketConnection

public final class OVSDBSocketConnection: OVSDBTransport, @unchecked Sendable {
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
    private let notificationHub = JSONRPCNotificationHub()

    public init(endpoint: OVSDBEndpoint, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.endpoint = endpoint
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }
        self.logger = logger ?? Logger(label: "ovn-manager.socket")
    }

    public convenience init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
    }

    deinit {
        // Only shut down a group we created; an injected one is the caller's
        // to manage. Without this, each connection created with no injected
        // group leaks its event-loop thread.
        if ownsEventLoopGroup {
            try? eventLoopGroup.syncShutdownGracefully()
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
        let future = makeConnectFuture()
        // Clear the in-flight slot once this attempt settles so a later
        // reconnect can start fresh.
        let deduplicated = future.always { [weak self] _ in
            guard let self else { return }
            self.connectionLock.lock()
            self.inFlightConnect = nil
            self.connectionLock.unlock()
        }
        inFlightConnect = deduplicated
        connectionLock.unlock()
        return deduplicated
    }

    private func makeConnectFuture() -> EventLoopFuture<Void> {
        logger.info("Connecting to OVSDB endpoint: \(endpoint)")

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
                handlers.append(contentsOf: [
                    ByteToMessageHandler(OVSDBJSONFrameDecoder()),
                    MessageToByteHandler(StringToByteEncoder()),
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

    public func send<T: Codable>(_ message: T) -> EventLoopFuture<Void> {
        connectionLock.lock()
        guard let channel = channel, isConnected else {
            connectionLock.unlock()
            return eventLoopGroup.next().makeFailedFuture(
                OVNManagerError.connectionFailed("Not connected to socket")
            )
        }
        connectionLock.unlock()

        do {
            let encoder = Foundation.JSONEncoder()
            let data = try encoder.encode(message)
            guard let jsonString = String(data: data, encoding: .utf8) else {
                throw OVNManagerError.encodingError(
                    NSError(domain: "OVSDBSocketConnection", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to convert data to string"])
                )
            }

            logger.debug("Sending message: \(jsonString)")
            return channel.writeAndFlush(jsonString + "\n")
        } catch {
            logger.error("Failed to encode message: \(error)")
            return eventLoopGroup.next().makeFailedFuture(OVNManagerError.encodingError(error))
        }
    }

    public func receive<T: Codable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount = .seconds(30)) -> EventLoopFuture<T> {
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
    /// `monitor`) and no notification is lost even while the consumer is busy.
    /// The stream finishes when the connection closes. Subscribing is valid
    /// before `connect()` and multiple subscribers each receive every
    /// notification.
    public func notifications() -> AsyncStream<JSONRPCNotification> {
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
/// Each subscriber gets an unbounded `AsyncStream`, so notifications that
/// arrive while the consumer is between iterations are buffered rather than
/// dropped. Outlives the channel handler so subscriptions can be created
/// before the connection is established.
final class JSONRPCNotificationHub: @unchecked Sendable {
    private let lock = NSLock()
    private var subscribers: [UUID: AsyncStream<JSONRPCNotification>.Continuation] = [:]

    func subscribe() -> AsyncStream<JSONRPCNotification> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: JSONRPCNotification.self)
        continuation.onTermination = { [weak self] _ in
            self?.removeSubscriber(id)
        }
        lock.lock()
        subscribers[id] = continuation
        lock.unlock()
        return stream
    }

    func publish(_ notification: JSONRPCNotification) {
        lock.lock()
        let continuations = Array(subscribers.values)
        lock.unlock()

        for continuation in continuations {
            continuation.yield(notification)
        }
    }

    func finishAll() {
        lock.lock()
        let continuations = Array(subscribers.values)
        subscribers.removeAll()
        lock.unlock()

        for continuation in continuations {
            continuation.finish()
        }
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
            guard let jsonString = String(data: data, encoding: .utf8) else {
                logger.error("Failed to encode echo reply as UTF-8")
                return
            }
            logger.debug("Replying to server echo request")
            context.writeAndFlush(NIOAny(jsonString + "\n"), promise: nil)
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

    func waitForResponse<T: Codable>(requestId: JSONRPCIdentifier, type: T.Type, timeout: TimeAmount) -> EventLoopFuture<T> {
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

private struct PendingRequestWrapper<T: Codable>: PendingRequestProtocol {
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
final class OVSDBJSONFrameDecoder: ByteToMessageDecoder, @unchecked Sendable {
    typealias InboundOut = String

    func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        let view = buffer.readableBytesView

        var depth = 0
        var inString = false
        var escaped = false
        var objectStart: Int?

        var index = view.startIndex
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
                        objectStart = index
                    }
                    depth += 1
                case UInt8(ascii: "}"):
                    if depth > 0 {
                        depth -= 1
                        if depth == 0, let start = objectStart {
                            // A complete top-level object spans start...index inclusive.
                            let leading = view.distance(from: view.startIndex, to: start)
                            let length = view.distance(from: start, to: index) + 1

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
        }

        // No complete object yet — wait for more data.
        return .needMoreData
    }
}

private final class StringToByteEncoder: MessageToByteEncoder, @unchecked Sendable {
    typealias OutboundIn = String

    func encode(data: String, out: inout ByteBuffer) throws {
        out.writeString(data)
    }
}
