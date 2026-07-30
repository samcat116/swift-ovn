import Foundation
import NIO
import NIOPosix
import NIOSSL
import NIOTLS
import Logging

/// Preserved name from when the connection was Unix-socket only.
public typealias UnixSocketConnection = OVSDBSocketConnection

/// A JSON-RPC transport to an OVSDB server over a Unix domain socket, TCP or
/// TLS.
///
/// All mutable state lives in `OVSDBConnectionCore`, an actor, so this type is
/// `Sendable` by inspection rather than by assertion: every stored property is
/// an immutable `let` holding a `Sendable` value.
public final class OVSDBSocketConnection: OVSDBTransport {
    /// Default bound on how far a `notifications()` consumer may fall behind.
    public static let defaultNotificationBufferSize = 1024

    private let core: OVSDBConnectionCore
    private let eventLoopGroup: EventLoopGroup
    /// True when we created `eventLoopGroup` ourselves and are therefore
    /// responsible for shutting it down; false when the caller injected one.
    private let ownsEventLoopGroup: Bool

    /// - Parameter notificationBufferSize: How many notifications may queue up
    ///   for one `notifications()` consumer before its stream is terminated with
    ///   `OVNManagerError.notificationsDropped`. Raise it for consumers that do
    ///   slow work per update; lowering it surfaces a lagging consumer sooner.
    public init(
        endpoint: OVSDBEndpoint,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil,
        notificationBufferSize: Int = OVSDBSocketConnection.defaultNotificationBufferSize
    ) {
        if let eventLoopGroup {
            self.eventLoopGroup = eventLoopGroup
            self.ownsEventLoopGroup = false
        } else {
            self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.ownsEventLoopGroup = true
        }
        self.core = OVSDBConnectionCore(
            endpoint: endpoint,
            eventLoopGroup: self.eventLoopGroup,
            logger: logger ?? Logger(label: "ovn-manager.socket"),
            notificationBufferSize: notificationBufferSize
        )
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
    /// The stream buffers notifications from the moment this call returns, so
    /// subscribe *before* issuing the request that triggers them (e.g.
    /// `monitor`) and no notification is lost while the consumer is busy.
    /// Subscribing is valid before `connect()`, and multiple subscribers each
    /// receive every notification.
    ///
    /// The stream finishes when the connection closes, and throws
    /// `OVNManagerError.notificationsDropped` if the consumer falls further than
    /// this connection's notification buffer behind. A subscription taken out
    /// after the connection has closed is returned already finished.
    public func notifications() -> AsyncThrowingStream<JSONRPCNotification, Error> {
        return core.notifications.subscribe()
    }

    public var isConnectionActive: Bool {
        return core.isConnected
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
        let tls: (context: NIOSSLContext, serverHostname: String?)?

        switch endpoint {
        case .unix(let path):
            guard FileManager.default.fileExists(atPath: path) else {
                logger.error("Socket file does not exist at path: \(path)")
                throw OVNManagerError.connectionFailed("Socket file not found: \(path)")
            }
            tls = nil
        case .tcp:
            tls = nil
        case .ssl(let host, _, let configuration):
            let context: NIOSSLContext
            do {
                context = try makeSSLContext(configuration)
            } catch {
                logger.error("Failed to build TLS context: \(error)")
                throw OVNManagerError.connectionFailed("Invalid TLS configuration: \(error)")
            }
            // NIOSSL rejects IP literals as SNI hostnames (RFC 6066), so pass
            // nil for them. This does not weaken verification: under
            // .fullVerification NIOSSL still validates identity with a nil
            // hostname by matching the connection's remote address against
            // the certificate's IP SANs (NIOSSLHandler.validateHostname →
            // validIdentityForService), and fails the handshake on no match.
            let hostname = configuration.serverHostname ?? host
            tls = (context, isIPAddressLiteral(hostname) ? nil : hostname)
        }

        // The handshake promise is created outside the pipeline so the handler
        // itself holds no state that has to cross a concurrency domain.
        let handshake = tls == nil ? nil : eventLoopGroup.any().makePromise(of: Void.self)

        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)

        let initializer: @Sendable (Channel) -> EventLoopFuture<NIOAsyncChannel<ByteBuffer, ByteBuffer>> = { channel in
            channel.eventLoop.makeCompletedFuture {
                let operations = channel.pipeline.syncOperations
                if let tls, let handshake {
                    try operations.addHandler(
                        NIOSSLClientHandler(context: tls.context, serverHostname: tls.serverHostname)
                    )
                    try operations.addHandler(TLSHandshakeWaitHandler(handshake: handshake))
                }
                // No outbound handler: frames are written as ByteBuffers, so
                // there is nothing left to encode on the way out.
                try operations.addHandler(ByteToMessageHandler(OVSDBJSONFrameDecoder()))
                return try NIOAsyncChannel(
                    wrappingChannelSynchronously: channel,
                    configuration: NIOAsyncChannel.Configuration(
                        // The default watermarks (low 2, high 10) are the
                        // backpressure the old pipeline had none of: once that
                        // many framed messages are waiting for the consumer, the
                        // channel stops issuing reads and the server's socket
                        // buffer — not this process's memory — holds the backlog.
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
            case .tcp(let host, let port), .ssl(let host, let port, _):
                asyncChannel = try await bootstrap.connect(
                    host: host,
                    port: port,
                    channelInitializer: initializer
                )
            }
        } catch {
            logger.error("Failed to connect to \(endpoint): \(error)")
            if let ioError = error as? IOError {
                logger.error("IO error code: \(ioError.errnoCode)")
            }
            throw OVNManagerError.connectionFailed("Failed to connect to \(endpoint): \(error)")
        }

        if let handshake {
            do {
                try await handshake.futureResult.get()
            } catch {
                logger.error("TLS handshake with \(endpoint) failed: \(error)")
                asyncChannel.channel.close(promise: nil)
                throw OVNManagerError.connectionFailed("Failed to connect to \(endpoint): \(error)")
            }
        }

        return asyncChannel
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
}

// MARK: - TLS Handshake Wait

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
