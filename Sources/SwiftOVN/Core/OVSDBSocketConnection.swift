#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import NIO
import NIOPosix
#if TLS
import NIOSSL
import NIOTLS
#endif
import Logging

/// Preserved name from when the connection was Unix-socket only.
public typealias UnixSocketConnection = OVSDBSocketConnection

/// A JSON-RPC transport to an OVSDB server over a Unix domain socket, TCP or
/// TLS.
///
/// All mutable state lives in `OVSDBConnectionCore`, so this type is `Sendable`
/// by inspection rather than by assertion: every stored property is an immutable
/// `let` holding a `Sendable` value.
public final class OVSDBSocketConnection: OVSDBTransport {
    /// Notifications buffered per notification-stream consumer before the
    /// oldest are discarded.
    ///
    /// Large enough to ride out a consumer that is briefly busy, small enough
    /// that a consumer which stops draining altogether cannot exhaust memory
    /// on a high-volume monitor (Southbound `Logical_Flow`). Applies at every
    /// layer that re-buffers notifications, including `monitorUpdates()`.
    public static let notificationBufferSize = 256

    private let core: OVSDBConnectionCore
    private let eventLoopGroup: EventLoopGroup
    /// True when we created `eventLoopGroup` ourselves and are therefore
    /// responsible for shutting it down; false when the caller injected one.
    private let ownsEventLoopGroup: Bool

    /// Connects to one of `remotes`, in order, and — unless `reconnect` is
    /// disabled — keeps re-establishing that session for as long as this object
    /// lives.
    ///
    /// - Parameters:
    ///   - remotes: The servers of one OVSDB cluster, tried in order. See
    ///     `OVSDBRemotes`.
    ///   - reconnect: How a lost session is re-established. See
    ///     `OVSDBReconnectPolicy`, whose documentation also covers what
    ///     reconnection deliberately does not paper over.
    ///   - leaderOnlyDatabase: The clustered database whose RAFT leader this
    ///     connection must be attached to, or nil to use whichever remote
    ///     answers. Writes are only accepted by the leader, so a connection used
    ///     for anything but reads wants this set. Enforced only when there is
    ///     more than one remote, and only as far as the remote's own `_Server`
    ///     database can report it.
    public init(
        remotes: OVSDBRemotes,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }
        self.core = OVSDBConnectionCore(
            remotes: remotes,
            eventLoopGroup: self.eventLoopGroup,
            logger: logger ?? Logger(label: "ovn-manager.socket"),
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnlyDatabase
        )
    }

    public convenience init(
        endpoint: OVSDBEndpoint,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.init(
            remotes: OVSDBRemotes(endpoint),
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnlyDatabase,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
    }

    public convenience init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
    }

    deinit {
        // The reconnect supervisor holds the core strongly and, with the default
        // policy, retries forever: without this it would outlive the last
        // reference to this object and keep re-establishing a session nobody can
        // use. Asynchronously, because `deinit` cannot await.
        let core = self.core
        let eventLoopGroup = self.eventLoopGroup
        // Only shut down a group we created; an injected one is the caller's
        // to manage. Without this, each connection created with no injected
        // group leaks its event-loop thread. After the core, since it makes
        // promises on that group while stopping.
        let ownsEventLoopGroup = self.ownsEventLoopGroup
        Task {
            await core.shutdown()
            if ownsEventLoopGroup {
                eventLoopGroup.shutdownGracefully { _ in }
            }
        }
    }

    public func connect() async throws {
        try await core.connect()
    }

    public func disconnect() async {
        await core.disconnect()
    }

    public func send<T: Codable & Sendable>(_ message: T) async throws {
        try await core.send(message)
    }

    public func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response {
        return try await core.sendRequest(request, id: id, responseType: responseType, timeout: timeout)
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
        let events = core.notificationHub.subscribe()
        let logger = core.logger
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
                    case .reconnected:
                        // The stream carries notifications only, so the reconnect
                        // is reported rather than delivered. A consumer that has
                        // to act on it wants notificationEvents().
                        logger.info("Connection re-established; monitors from the previous session are gone. Use notificationEvents() to observe this in-stream.")
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
        return core.notificationHub.subscribe()
    }

    /// Whether a session is up *right now*.
    ///
    /// With reconnection enabled this flickers: it is false for the duration of
    /// a leader election and true again once the new leader answers, and nothing
    /// in a boolean distinguishes that from a connection that has given up. It
    /// keeps its original meaning — a request issued while it is false fails —
    /// but for anything that acts on the answer, prefer `connectionState`.
    public var isConnectionActive: Bool {
        return core.isConnected
    }

    /// The connection's lifecycle state, including where reconnection has got
    /// to. See `OVSDBConnectionState`.
    public var connectionState: OVSDBConnectionState {
        return core.stateHub.current
    }

    /// Streams every connection-state transition, starting with the current
    /// state so a subscriber never has to guess where things stand.
    ///
    /// This is how up/down transitions are observed rather than inferred from a
    /// thrown error. The stream finishes when this connection is released; a
    /// consumer that falls behind loses intermediate transitions but never the
    /// latest state.
    public func connectionStates() -> AsyncStream<OVSDBConnectionState> {
        return core.stateHub.subscribe()
    }
}

// MARK: - Channel Bootstrap

/// Builds the `NIOAsyncChannel` for an endpoint: pipeline, TLS, and the
/// endpoint-specific connect call.
enum OVSDBChannelBootstrap {
    /// Connects and returns the wrapped channel. For `ssl:` endpoints the
    /// returned channel has completed its TLS handshake, so a certificate that
    /// fails verification surfaces here rather than on a later request.
    static func connect(
        endpoint: OVSDBEndpoint,
        eventLoopGroup: EventLoopGroup,
        logger: Logger
    ) async throws -> NIOAsyncChannel<ByteBuffer, ByteBuffer> {
        // `access(F_OK)` rather than `FileManager.fileExists` — the answer is
        // advisory either way (the socket can vanish before connect(2)), and it
        // keeps this file off full Foundation.
        if case .unix(let path) = endpoint, access(path, F_OK) != 0 {
            logger.error("Socket file does not exist at path: \(path)")
            throw OVNManagerError.connectionFailed("Socket file not found: \(path)")
        }

        #if TLS
        // TLS state that must exist before the pipeline is built. nil for the
        // cleartext endpoints.
        let tlsSetup: TLSSetup?
        do {
            tlsSetup = try makeTLSSetup(for: endpoint)
        } catch {
            logger.error("Failed to build TLS context: \(error)")
            throw OVNManagerError.connectionFailed("Invalid TLS configuration: \(error)")
        }
        // The handshake promise is created here rather than inside the handler,
        // so the handler owns no state that has to cross a concurrency domain.
        let handshake = tlsSetup == nil ? nil : eventLoopGroup.any().makePromise(of: Void.self)
        #endif

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let initializer: @Sendable (Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> = { channel in
            channel.eventLoop.makeCompletedFuture {
                logger.debug("Initializing channel pipeline...")
                let operations = channel.pipeline.syncOperations
                #if TLS
                if let tlsSetup, let handshake {
                    try operations.addHandler(
                        NIOSSLClientHandler(context: tlsSetup.sslContext, serverHostname: tlsSetup.serverHostname)
                    )
                    try operations.addHandler(TLSHandshakeWaitHandler(handshake: handshake))
                }
                #endif
                // Outbound needs no handler: every write is already a
                // `ByteBuffer`, which is what the TLS handler (or the socket)
                // wants.
                try operations.addHandler(ByteToMessageHandler(OVSDBJSONFrameDecoder()))
                return try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        // The default watermarks (low 2, high 10) are the
                        // backpressure the `EventLoopFuture` pipeline had none
                        // of: once that many framed messages are waiting for the
                        // consumer, the channel stops issuing reads and the
                        // backlog sits in the server's socket buffer rather than
                        // this process's memory.
                        inboundType: ByteBuffer.self,
                        outboundType: ByteBuffer.self
                    )
                )
            }
        }

        let asyncChannel: NIOAsyncChannel<ByteBuffer, ByteBuffer>
        do {
            switch endpoint {
            case .unix(let path):
                asyncChannel = try await bootstrap.connect(
                    unixDomainSocketPath: path,
                    channelInitializer: initializer
                )
            case .tcp(let host, let port):
                asyncChannel = try await bootstrap.connect(
                    host: host,
                    port: port,
                    channelInitializer: initializer
                )
            #if TLS
            case .ssl(let host, let port, _):
                asyncChannel = try await bootstrap.connect(
                    host: host,
                    port: port,
                    channelInitializer: initializer
                )
            #endif
            }
        } catch {
            logger.error("Failed to connect to \(endpoint): \(error)")
            logger.error("Error type: \(type(of: error))")
            if let ioError = error as? IOError {
                logger.error("IO error code: \(ioError.errnoCode)")
            }
            throw OVNManagerError.connectionFailed("Failed to connect to \(endpoint): \(error)")
        }

        #if TLS
        // For ssl: endpoints the TCP connect completing is not enough:
        // certificate verification happens during the TLS handshake, so hold the
        // connect until the handshake finishes and fail it if verification
        // fails.
        if let handshake {
            do {
                try await handshake.futureResult.get()
            } catch {
                logger.error("TLS handshake with \(endpoint) failed: \(error)")
                // Consume both halves before dropping the channel, rather than
                // closing it and letting the `throw` release it. An
                // `NIOAsyncChannel` whose outbound writer deinits without
                // `finish()` traps — a `fatalError` in `NIOAsyncWriter`, so it
                // takes the process down instead of reporting the failed
                // handshake — and a fire-and-forget `close` only avoids that
                // when it happens to finish the writer before the release wins
                // the race. `executeThenClose` finishes the writer and closes
                // the channel, in that order, before returning.
                try? await asyncChannel.executeThenClose { _, _ in }
                throw OVNManagerError.connectionFailed("Failed to connect to \(endpoint): \(error)")
            }
        }
        #endif

        logger.debug("Channel pipeline initialized successfully")
        return asyncChannel
    }

    #if TLS
    /// Everything the channel initializer needs to install the TLS handler.
    private struct TLSSetup {
        let sslContext: NIOSSLContext
        /// SNI/verification hostname, or nil for IP-literal hosts.
        let serverHostname: String?
    }

    /// The TLS state for an `ssl:` endpoint, or nil for the cleartext ones.
    private static func makeTLSSetup(for endpoint: OVSDBEndpoint) throws -> TLSSetup? {
        guard case .ssl(let host, _, let tls) = endpoint else { return nil }
        // NIOSSL rejects IP literals as SNI hostnames (RFC 6066), so pass
        // nil for them. This does not weaken verification: under
        // .fullVerification NIOSSL still validates identity with a nil
        // hostname by matching the connection's remote address against
        // the certificate's IP SANs (NIOSSLHandler.validateHostname →
        // validIdentityForService), and fails the handshake on no match.
        let hostname = tls.serverHostname ?? host
        return TLSSetup(
            sslContext: try makeSSLContext(tls),
            serverHostname: isIPAddressLiteral(hostname) ? nil : hostname
        )
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
    #endif
}

// MARK: - TLS Handshake Wait

#if TLS
/// Surfaces TLS handshake completion on a caller-supplied promise, so
/// `connect()` on an `ssl:` endpoint succeeds only after certificate
/// verification instead of at TCP establishment.
///
/// The promise is the handler's only link to the outside world, which is what
/// lets this be an ordinary (non-`Sendable`) handler: everything else it owns is
/// touched on the channel's event loop only, and the one closure that leaves the
/// handler — the timeout task — reaches back through `NIOLoopBound`.
final class TLSHandshakeWaitHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    private let handshake: EventLoopPromise<Void>
    private let timeout: TimeAmount
    private var timeoutTask: Scheduled<Void>?
    private var isComplete = false

    init(handshake: EventLoopPromise<Void>, timeout: TimeAmount = .seconds(30)) {
        self.handshake = handshake
        self.timeout = timeout
    }

    func handlerAdded(context: ChannelHandlerContext) {
        // A server that accepts TCP but never answers the ClientHello (e.g. an
        // ssl: endpoint pointed at a cleartext port) would otherwise hang the
        // connect forever.
        let channel = context.channel
        let handler = NIOLoopBound(self, eventLoop: context.eventLoop)
        timeoutTask = context.eventLoop.scheduleTask(in: timeout) {
            handler.value.complete(.failure(OVNManagerError.connectionFailed("TLS handshake timed out")))
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
            handshake.succeed(())
        case .failure(let error):
            handshake.fail(error)
        }
    }
}
#endif
