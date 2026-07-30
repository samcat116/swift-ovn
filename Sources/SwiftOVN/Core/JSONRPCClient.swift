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
    
    /// `monitor_cond` (ovsdb-server(7)): as `monitor`, but each table request may
    /// carry `where` conditions the server filters rows by, and row changes
    /// arrive as `update2` notifications.
    ///
    /// Returns the initial `<table-updates2>` — the matching rows, each as an
    /// `initial` row update.
    public func monitorCond(
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
            method: OVSDBMonitorMethod.monitorCond.rpcMethod,
            params: params,
            responseType: JSONValue.self
        )
    }

    /// `monitor_cond_since` (ovsdb-server(7)): a `monitor_cond` that resumes from
    /// a transaction id, so a reconnecting client is sent a delta instead of the
    /// whole database. Row changes arrive as `update3` notifications, each
    /// carrying the transaction id to resume from next.
    ///
    /// `found` is false when the server could not resume from
    /// `lastTransactionId` — it has been compacted away, or this is a different
    /// server in the cluster — in which case the returned `<table-updates2>` is a
    /// complete snapshot and the caller must discard whatever state it hoped to
    /// resume.
    public func monitorCondSince(
        database: String,
        monitorId: String,
        requests: [String: OVSDBMonitorRequest],
        since lastTransactionId: String = OVSDBMonitorMethod.initialTransactionId
    ) async throws(OVNManagerError) -> (found: Bool, lastTransactionId: String, tableUpdates: JSONValue) {
        let requestsValue = try encodeParameter(requests)

        let params = JSONRPCParams.array([
            .string(database),
            .string(monitorId),
            requestsValue,
            .string(lastTransactionId)
        ])

        let result = try await call(
            method: OVSDBMonitorMethod.monitorCondSince.rpcMethod,
            params: params,
            responseType: JSONValue.self
        )

        guard case .array(let parts) = result,
              parts.count >= 3,
              case .boolean(let found) = parts[0],
              case .string(let transactionId) = parts[1] else {
            throw OVNManagerError.invalidResponse(
                "monitor_cond_since reply is not [found, last-txn-id, table-updates2]: \(result)"
            )
        }

        return (found: found, lastTransactionId: transactionId, tableUpdates: parts[2])
    }

    /// `monitor_cond_change` (ovsdb-server(7)): replaces the `where` conditions of
    /// a running conditional monitor in place. Rows that newly match arrive as
    /// inserts and rows that stopped matching as deletes, without the full
    /// resynchronization that cancelling the monitor and starting another costs.
    ///
    /// Only conditions can be changed: ovsdb-server parses a
    /// `<monitor-cond-update-request>` strictly and takes nothing but `where`.
    /// Passing an empty condition list for a table makes it match every row
    /// again.
    public func monitorCondChange(
        monitorId: String,
        newMonitorId: String? = nil,
        conditions: [String: [OVSDBCondition]]
    ) async throws(OVNManagerError) {
        let requests = conditions.mapValues { MonitorConditionChange(whereConditions: $0) }
        let requestsValue = try encodeParameter(requests)

        let params = JSONRPCParams.array([
            .string(monitorId),
            .string(newMonitorId ?? monitorId),
            requestsValue
        ])

        // The server replies with the string "ok"; there is nothing in it to
        // check that the absence of an error has not already established.
        _ = try await call(
            method: "monitor_cond_change",
            params: params,
            responseType: JSONValue.self
        )
    }

    /// One table's entry in a `monitor_cond_change`'s
    /// `<monitor-cond-update-requests>`.
    private struct MonitorConditionChange: Encodable {
        let whereConditions: [OVSDBCondition]

        private enum CodingKeys: String, CodingKey {
            case whereConditions = "where"
        }
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
    /// Plain `monitor` only: a conditional monitor's `update2`/`update3`
    /// notifications are not delivered here — use `monitorNotifications()`.
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
            guard notification.method == OVSDBMonitorMethod.monitor.notificationMethod,
                  case .array(let paramsArray)? = notification.params,
                  paramsArray.count >= 2,
                  case .string(let monitorId) = paramsArray[0] else {
                return nil
            }
            return (monitorId, paramsArray[1])
        }
    }

    /// Streams every monitor notification — `update`, `update2` and `update3` —
    /// tagged with the method that produced it, with the row payload left
    /// unparsed.
    ///
    /// Use this rather than `monitorUpdates()` for a monitor started with
    /// `monitor_cond` or `monitor_cond_since`: those report changes as `update2`
    /// and `update3`, which `monitorUpdates()` filters out, and only `update3`
    /// carries the transaction id a later `monitor_cond_since` resumes from.
    ///
    /// The subscription and buffering rules are `monitorUpdates()`': subscribe
    /// before starting the monitor, and a consumer that falls further behind than
    /// `OVSDBSocketConnection.notificationBufferSize` gets
    /// `OVNManagerError.notificationsDropped`.
    nonisolated public func monitorNotifications() -> AsyncThrowingStream<OVSDBMonitorNotification, Error> {
        return notificationStream { notification in
            guard let method = OVSDBMonitorMethod(notificationMethod: notification.method),
                  case .array(let paramsArray)? = notification.params,
                  case .string(let monitorId)? = paramsArray.first else {
                return nil
            }

            switch method {
            case .monitor, .monitorCond:
                // [<monitor-id>, <table-updates>]
                guard paramsArray.count >= 2 else { return nil }
                return OVSDBMonitorNotification(
                    monitorId: monitorId,
                    method: method,
                    tableUpdates: paramsArray[1]
                )
            case .monitorCondSince:
                // [<monitor-id>, <last-txn-id>, <table-updates2>]
                guard paramsArray.count >= 3,
                      case .string(let transactionId) = paramsArray[1] else {
                    return nil
                }
                return OVSDBMonitorNotification(
                    monitorId: monitorId,
                    method: method,
                    lastTransactionId: transactionId,
                    tableUpdates: paramsArray[2]
                )
            }
        }
    }

    /// Builds one bounded stream over the transport's notifications, keeping the
    /// notifications `transform` maps to a value and skipping the rest.
    ///
    /// The gap handling is the point of sharing this: a `dropped` event and a
    /// rejected `yield` both have to finish the stream with
    /// `notificationsDropped`, so that every public monitor stream fails the same
    /// way rather than each re-deriving it.
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
                    // `.bufferingOldest` keeps the updates already buffered and
                    // rejects this one, so the consumer sees an unbroken run of
                    // updates followed by the error rather than a silent gap.
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
