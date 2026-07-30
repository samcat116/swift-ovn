#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif
import NIO
import Logging

/// Speaks JSON-RPC over an `OVSDBTransport`.
///
/// Every throwing method is `throws(OVNManagerError)`. This is where that
/// contract starts: the transport below throws untyped — it surfaces NIO channel
/// and TLS failures — and `JSONValueEncoder` throws `EncodingError`, so every
/// transport call and every parameter encode here is wrapped.
public actor JSONRPCClient {
    private let connection: any OVSDBTransport
    private let logger: Logger
    private var requestId: Int = 0

    /// See `OVSDBSocketConnection.init(remotes:reconnect:leaderOnlyDatabase:…)`
    /// for what the cluster parameters mean.
    public init(
        remotes: OVSDBRemotes,
        reconnect: OVSDBReconnectPolicy = .default,
        leaderOnlyDatabase: String? = nil,
        eventLoopGroup: EventLoopGroup? = nil,
        logger: Logger? = nil
    ) {
        self.connection = OVSDBSocketConnection(
            remotes: remotes,
            reconnect: reconnect,
            leaderOnlyDatabase: leaderOnlyDatabase,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.jsonrpc-client")
    }

    public init(
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

    public init(socketPath: String, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.init(endpoint: .unix(path: socketPath), eventLoopGroup: eventLoopGroup, logger: logger)
    }

    /// Runs the client over a caller-supplied transport (e.g. a mock in tests).
    public init(transport: any OVSDBTransport, logger: Logger? = nil) {
        self.connection = transport
        self.logger = logger ?? Logger(label: "ovn-manager.jsonrpc-client")
    }
    
    public func connect() async throws(OVNManagerError) {
        logger.info("JSONRPCClient: Starting connection process...")
        do {
            try await connection.connect()
        } catch {
            throw OVNManagerError.wrapping(error) { .connectionFailed("Failed to connect: \($0)") }
        }
        logger.info("JSONRPCClient: Connection established successfully")
    }

    public func disconnect() async throws(OVNManagerError) {
        do {
            try await connection.disconnect()
        } catch {
            throw OVNManagerError.wrapping(error) { .connectionFailed("Failed to disconnect: \($0)") }
        }
    }
    
    nonisolated public var isConnected: Bool {
        return connection.isConnectionActive
    }

    /// See `OVSDBSocketConnection.connectionState`.
    nonisolated public var connectionState: OVSDBConnectionState {
        return connection.connectionState
    }

    /// See `OVSDBSocketConnection.connectionStates()`.
    nonisolated public func connectionStates() -> AsyncStream<OVSDBConnectionState> {
        return connection.connectionStates()
    }

    /// The transport's raw notification events, including the `.reconnected`
    /// event that says server-side monitor state was lost.
    ///
    /// `monitorUpdates()` is the typed view of the same stream; this is here for
    /// callers that track monitors themselves and have to re-create them after a
    /// reconnect — which is exactly what `OVSDBConnection` does with it.
    nonisolated public func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent> {
        return connection.notificationEvents()
    }
    
    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }
    
    // MARK: - Generic JSON-RPC Methods
    
    public func call<T: Codable & Sendable>(
        method: String,
        params: JSONRPCParams? = nil,
        responseType: T.Type
    ) async throws(OVNManagerError) -> T {
        let id = JSONRPCIdentifier.number(nextRequestId())
        let request = JSONRPCRequest(method: method, params: params, id: id)

        logger.debug("Sending JSON-RPC request: \(method) with ID: \(id)")

        logger.debug("Connection active before send: \(connection.isConnectionActive)")

        // One operation: the transport registers its interest in `id` before it
        // writes, so a reply that arrives immediately cannot be missed.
        let response: JSONRPCResponse<T>
        do {
            response = try await connection.sendRequest(
                request,
                id: id,
                responseType: JSONRPCResponse<T>.self
            )
        } catch {
            // The transport already reports its own failures as
            // `OVNManagerError` (timeout, closed connection, response
            // decoding); anything left is a channel-level failure it forwarded
            // verbatim.
            throw OVNManagerError.wrapping(error) { .connectionFailed("Failed to complete '\(method)' request: \($0)") }
        }

        logger.debug("Received response for request ID: \(id)")

        if let error = response.error {
            logger.error("JSON-RPC error response: \(error.message)")
            throw OVNManagerError.rpcError(error)
        }
        
        guard let result = response.result else {
            throw OVNManagerError.invalidResponse("No result in response")
        }
        
        return result
    }
    
    public func notify(method: String, params: JSONRPCParams? = nil) async throws(OVNManagerError) {
        let request = JSONRPCRequest(method: method, params: params, id: nil)

        logger.debug("Sending JSON-RPC notification: \(method)")

        do {
            try await connection.send(request)
        } catch {
            throw OVNManagerError.wrapping(error) { .connectionFailed("Failed to send '\(method)' notification: \($0)") }
        }
    }

    /// Encodes a request parameter, wrapping the `EncodingError` a general
    /// `Encoder` throws into `encodingError`.
    private func encodeParameter<T: Encodable>(_ value: T) throws(OVNManagerError) -> JSONValue {
        do {
            return try JSONValueEncoder.encode(value)
        } catch {
            throw OVNManagerError.wrapping(error) { .encodingError($0) }
        }
    }

    // MARK: - OVSDB Specific Methods

    public func echo() async throws(OVNManagerError) -> [String] {
        logger.info("Performing echo test...")
        let params = JSONRPCParams.array([.string("echo")])
        let result = try await call(
            method: "echo",
            params: params,
            responseType: [String].self
        )
        logger.info("Echo test completed successfully")
        return result
    }
    
    public func listDatabases() async throws(OVNManagerError) -> [String] {
        logger.info("Listing databases...")
        let result = try await call(
            method: "list_dbs",
            responseType: [String].self
        )
        logger.info("Found \(result.count) databases: \(result)")
        return result
    }
    
    public func getSchema(database: String) async throws(OVNManagerError) -> JSONValue {
        let params = JSONRPCParams.array([.string(database)])
        return try await call(
            method: "get_schema",
            params: params,
            responseType: JSONValue.self
        )
    }
    
    public func transact(database: String, operations: [OVSDBOperation]) async throws(OVNManagerError) -> [JSONValue] {
        var paramsArray: [JSONValue] = [.string(database)]

        for operation in operations {
            paramsArray.append(try encodeParameter(operation))
        }

        let params = JSONRPCParams.array(paramsArray)
        
        return try await call(
            method: "transact",
            params: params,
            responseType: [JSONValue].self
        )
    }
    
    public func monitor(
        database: String,
        monitorId: String,
        requests: [String: OVSDBMonitorRequest]
    ) async throws(OVNManagerError) -> JSONValue {
        let requestsValue = try encodeParameter(requests)

        let params = JSONRPCParams.array([
            .string(database),
            .string(monitorId),
            requestsValue
        ])
        
        return try await call(
            method: "monitor",
            params: params,
            responseType: JSONValue.self
        )
    }
    
    public func cancelMonitor(monitorId: String) async throws(OVNManagerError) {
        let params = JSONRPCParams.array([.string(monitorId)])

        // RFC 7047 §4.1.7: monitor_cancel is a request; the server replies
        // with an empty result once the monitor is torn down.
        _ = try await call(
            method: "monitor_cancel",
            params: params,
            responseType: JSONValue.self
        )
    }

    // MARK: - Monitoring Stream

    /// Streams `update` notifications as `(monitorId, tableUpdates)` pairs.
    ///
    /// Subscribe *before* calling `monitor(...)` so no update is missed; the
    /// underlying stream buffers notifications between iterations. The stream
    /// has no idle timeout — it lives until the connection closes or the
    /// consumer cancels.
    ///
    /// Buffering is bounded (`OVSDBSocketConnection.notificationBufferSize`).
    /// A consumer that falls further behind than that would otherwise make the
    /// client buffer without limit, so instead the stream throws
    /// `OVNManagerError.notificationsDropped`: updates were lost, and the only
    /// correct recovery is to restart the monitor for a fresh snapshot.
    ///
    /// The stream also throws `OVNManagerError.monitorInterrupted` when the
    /// transport reconnects, because monitors live in the server's
    /// per-connection state and did not survive it. This client does not track
    /// monitors, so re-creating them is the caller's job; `OVSDBConnection` does
    /// it for you.
    ///
    /// Everything this stream can fail with is an `OVNManagerError`, but the
    /// failure type stays `any Error`: every `AsyncThrowingStream` initializer
    /// is constrained to `Failure == any Error`, so a typed-failure stream
    /// cannot be built. Match on `OVNManagerError` in the `catch`.
    nonisolated public func monitorUpdates() -> AsyncThrowingStream<(String, JSONValue), Error> {
        let events = connection.notificationEvents()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                for await event in events {
                    switch event {
                    case .dropped(let count):
                        continuation.finish(throwing: OVNManagerError.notificationsDropped(count: count))
                        return
                    case .reconnected:
                        continuation.finish(throwing: OVNManagerError.monitorInterrupted)
                        return
                    case .notification(let notification):
                        guard notification.method == "update",
                              case .array(let paramsArray)? = notification.params,
                              paramsArray.count >= 2,
                              case .string(let monitorId) = paramsArray[0] else {
                            continue
                        }
                        // `.bufferingOldest` keeps the updates already buffered
                        // and rejects this one, so the consumer sees an unbroken
                        // run of updates followed by the error rather than a
                        // silent gap.
                        if case .dropped = continuation.yield((monitorId, paramsArray[1])) {
                            continuation.finish(throwing: OVNManagerError.notificationsDropped(count: 1))
                            return
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}
