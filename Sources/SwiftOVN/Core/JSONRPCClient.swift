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

    public init(endpoint: OVSDBEndpoint, eventLoopGroup: EventLoopGroup? = nil, logger: Logger? = nil) {
        self.connection = OVSDBSocketConnection(
            endpoint: endpoint,
            eventLoopGroup: eventLoopGroup,
            logger: logger
        )
        self.logger = logger ?? Logger(label: "ovn-manager.jsonrpc-client")
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
    
    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }
    
    // MARK: - Generic JSON-RPC Methods
    
    /// Sends a request and awaits its response.
    ///
    /// `onRequestID` is handed the id this call was assigned, from inside the
    /// actor and before the request is written. It exists so a caller can
    /// `cancel(requestID:)` a long-running request from another task: ids are
    /// allocated here, so there is no other way to learn one.
    public func call<T: Codable & Sendable>(
        method: String,
        params: JSONRPCParams? = nil,
        responseType: T.Type,
        onRequestID: (@Sendable (JSONRPCIdentifier) -> Void)? = nil
    ) async throws(OVNManagerError) -> T {
        let id = JSONRPCIdentifier.number(nextRequestId())
        let request = JSONRPCRequest(method: method, params: params, id: id)

        logger.debug("Sending JSON-RPC request: \(method) with ID: \(id)")

        logger.debug("Connection active before send: \(connection.isConnectionActive)")

        onRequestID?(id)

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
        // Explicitly empty rather than absent: RFC 7047 §4.1.1 gives list_dbs
        // `"params": []`, and a request is specified to carry the member, so a
        // server is free to reject one that omits it.
        let result = try await call(
            method: "list_dbs",
            params: .array([]),
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
    
    /// Runs `operations` as one transaction (RFC 7047 §4.1.3).
    ///
    /// Pass `onRequestID` to learn the request's id while it is in flight, so
    /// it can be given to `cancel(requestID:)`.
    public func transact(
        database: String,
        operations: [OVSDBOperation],
        onRequestID: (@Sendable (JSONRPCIdentifier) -> Void)? = nil
    ) async throws(OVNManagerError) -> [JSONValue] {
        var paramsArray: [JSONValue] = [.string(database)]

        for operation in operations {
            paramsArray.append(try encodeParameter(operation))
        }

        let params = JSONRPCParams.array(paramsArray)

        return try await call(
            method: "transact",
            params: params,
            responseType: [JSONValue].self,
            onRequestID: onRequestID
        )
    }

    /// Asks the server to abandon the request identified by `requestID`
    /// (RFC 7047 §4.1.4) — the way to give up on a `transact` that is blocked
    /// behind a `wait` operation instead of holding the connection until it
    /// times out.
    ///
    /// A notification, not a request: nothing replies to the cancel itself.
    /// What completes the caller still awaiting the cancelled request is that
    /// request's own reply, which comes back as a `canceled` error if the
    /// cancellation won the race and as the normal result if it did not.
    public func cancel(requestID: JSONRPCIdentifier) async throws(OVNManagerError) {
        // Sent with an explicit null id, the form RFC 7047 §4.1.4 shows for a
        // notification, rather than by omitting the member.
        let request = JSONRPCRequest(
            method: "cancel",
            params: .array([requestID.jsonValue]),
            id: .null
        )

        logger.debug("Cancelling in-flight request \(requestID)")

        do {
            try await connection.send(request)
        } catch {
            throw OVNManagerError.wrapping(error) { .connectionFailed("Failed to send 'cancel' notification: \($0)") }
        }
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

    // MARK: - Locking

    /// Requests ownership of the lock named `id` (RFC 7047 §4.1.8).
    ///
    /// Returns true when this connection owns the lock as of the reply. False
    /// means the request is *queued* behind the current owner, not that it
    /// failed: ownership arrives later as a `locked` notification on
    /// `lockUpdates()`, and stays queued until then or until `unlock(id:)`.
    ///
    /// Ownership can be taken away at any time by another client's
    /// `steal(id:)`, so a writer that holds a lock should still make its
    /// transactions conditional on it with `OVSDBOperation.assert(lock:)`.
    /// Locks are per-connection and released when the connection drops.
    @discardableResult
    public func lock(id: String) async throws(OVNManagerError) -> Bool {
        logger.info("Requesting OVSDB lock '\(id)'")
        return try await lockRequest(method: "lock", id: id)
    }

    /// Takes ownership of the lock named `id` away from its current owner
    /// (RFC 7047 §4.1.8), which is told with a `stolen` notification.
    ///
    /// Returns true — a steal is granted immediately — unless the server
    /// answers otherwise; the boolean is reported rather than assumed.
    @discardableResult
    public func steal(id: String) async throws(OVNManagerError) -> Bool {
        logger.info("Stealing OVSDB lock '\(id)'")
        return try await lockRequest(method: "steal", id: id)
    }

    /// Releases the lock named `id`, or withdraws a queued request for it
    /// (RFC 7047 §4.1.8).
    public func unlock(id: String) async throws(OVNManagerError) {
        logger.info("Releasing OVSDB lock '\(id)'")
        _ = try await call(
            method: "unlock",
            params: .array([.string(id)]),
            responseType: JSONValue.self
        )
    }

    /// Issues a `lock`/`steal` request and reads the `locked` member out of the
    /// `{"locked": <boolean>}` reply both share.
    private func lockRequest(method: String, id: String) async throws(OVNManagerError) -> Bool {
        let result = try await call(
            method: method,
            params: .array([.string(id)]),
            responseType: JSONValue.self
        )

        guard case .object(let object) = result,
              case .boolean(let locked)? = object["locked"] else {
            throw OVNManagerError.invalidResponse("'\(method)' reply has no boolean 'locked' member: \(result)")
        }
        return locked
    }

    // MARK: - Server and Session
    //
    // `set_db_change_aware`, `get_server_id` and `convert` are ovsdb-server's
    // own additions to the RFC 7047 method set, documented in ovsdb-server(7)
    // rather than in the RFC — which is also why a server that predates them
    // answers with an "unknown method" error rather than ignoring them.

    /// Declares whether this connection wants to be told about databases being
    /// added and removed.
    ///
    /// A clustered ovsdb-server adds and removes databases while clients are
    /// connected, and only tells the ones that asked. This is also what a
    /// client monitoring the `_Server` database wants, since the whole point of
    /// that monitor is to follow the set of databases and their cluster state.
    public func setDatabaseChangeAware(_ aware: Bool) async throws(OVNManagerError) {
        _ = try await call(
            method: "set_db_change_aware",
            params: .array([.boolean(aware)]),
            responseType: JSONValue.self
        )
    }

    /// The UUID identifying the server on the other end of this connection.
    ///
    /// Distinguishes which member of a cluster a connection landed on — the
    /// same address can be answered by a different member after a reconnect.
    public func getServerID() async throws(OVNManagerError) -> String {
        return try await call(
            method: "get_server_id",
            params: .array([]),
            responseType: String.self
        )
    }

    /// Converts `database` to `schema`, migrating the data it holds.
    ///
    /// A cluster-wide, destructive operation: the server applies the new schema
    /// to the stored data, dropping whatever the new schema has no place for.
    public func convert(database: String, schema: JSONValue) async throws(OVNManagerError) {
        logger.info("Converting database \(database) to a new schema")
        _ = try await call(
            method: "convert",
            params: .array([.string(database), schema]),
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
    /// Everything this stream can fail with is an `OVNManagerError`, but the
    /// failure type stays `any Error`: every `AsyncThrowingStream` initializer
    /// is constrained to `Failure == any Error`, so a typed-failure stream
    /// cannot be built. Match on `OVNManagerError` in the `catch`.
    nonisolated public func monitorUpdates() -> AsyncThrowingStream<(String, JSONValue), Error> {
        return notificationStream { notification in
            guard notification.method == "update",
                  case .array(let paramsArray)? = notification.params,
                  paramsArray.count >= 2,
                  case .string(let monitorId) = paramsArray[0] else {
                return nil
            }
            return (monitorId, paramsArray[1])
        }
    }

    /// Streams the `locked` and `stolen` notifications that report this
    /// connection gaining or losing an OVSDB lock.
    ///
    /// Create the stream *before* calling `lock(id:)`, or the promotion of a
    /// queued request can land before there is anything subscribed to see it.
    /// Notifications for every lock this connection has asked for arrive here;
    /// filter on `lockID` if it holds more than one.
    ///
    /// Failure behaves as `monitorUpdates()`: dropped notifications end the
    /// stream with `OVNManagerError.notificationsDropped` rather than leaving
    /// the consumer believing a stale ownership state.
    nonisolated public func lockUpdates() -> AsyncThrowingStream<OVSDBLockNotification, Error> {
        return notificationStream { OVSDBLockNotification($0) }
    }

    /// Bounded stream of the notifications `transform` accepts, mapped by it;
    /// the notifications it returns nil for are skipped.
    ///
    /// Shared by every typed notification stream so that the drop handling —
    /// the part that decides what a consumer falling behind is told — has one
    /// implementation rather than one per stream.
    private nonisolated func notificationStream<Element: Sendable>(
        _ transform: @escaping @Sendable (JSONRPCNotification) -> Element?
    ) -> AsyncThrowingStream<Element, Error> {
        let events = connection.notificationEvents()
        return AsyncThrowingStream(
            bufferingPolicy: .bufferingOldest(OVSDBSocketConnection.notificationBufferSize)
        ) { continuation in
            let task = Task {
                for await event in events {
                    guard case .notification(let notification) = event else {
                        guard case .dropped(let count) = event else { continue }
                        continuation.finish(throwing: OVNManagerError.notificationsDropped(count: count))
                        return
                    }
                    guard let element = transform(notification) else { continue }
                    // `.bufferingOldest` keeps the elements already buffered and
                    // rejects this one, so the consumer sees an unbroken run
                    // followed by the error rather than a silent gap.
                    if case .dropped = continuation.yield(element) {
                        continuation.finish(throwing: OVNManagerError.notificationsDropped(count: 1))
                        return
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
