import Foundation
import Testing
import NIOCore
import Synchronization
@testable import SwiftOVN

/// A transport that records every message written and answers each request from
/// a queue of canned replies, so the RPC methods can be checked against the wire
/// format RFC 7047 specifies without a server.
private final class StubTransport: OVSDBTransport {
    /// Replies handed to requests in order, as raw JSON-RPC response objects.
    private let replies: Mutex<[String]>
    private let events: [JSONRPCNotificationEvent]
    /// Every frame written, request or notification, in order.
    private let written = Mutex<[Data]>([])

    init(replies: [String] = [], events: [JSONRPCNotificationEvent] = []) {
        self.replies = Mutex(replies)
        self.events = events
    }

    func connect() async throws {}
    func disconnect() async throws {}
    var isConnectionActive: Bool { true }

    func send<T: Codable & Sendable>(_ message: T) async throws {
        let frame = try JSONEncoder().encode(message)
        written.withLock { $0.append(frame) }
    }

    func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response {
        try await send(request)
        let reply = try replies.withLock { queue -> String in
            guard !queue.isEmpty else {
                throw OVNManagerError.invalidResponse("StubTransport ran out of canned replies")
            }
            return queue.removeFirst()
        }
        return try JSONDecoder().decode(Response.self, from: Data(reply.utf8))
    }

    func notifications() -> AsyncStream<JSONRPCNotification> {
        let events = self.events
        return AsyncStream { continuation in
            for case .notification(let notification) in events {
                continuation.yield(notification)
            }
            continuation.finish()
        }
    }

    func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent> {
        let events = self.events
        return AsyncStream { continuation in
            for event in events {
                continuation.yield(event)
            }
            continuation.finish()
        }
    }

    // MARK: - Assertions

    /// The message written at `index`, as JSON.
    func message(at index: Int) throws -> [String: Any] {
        let frames = written.withLock { $0 }
        let frame = try #require(frames.indices.contains(index) ? frames[index] : nil,
                                 "Expected at least \(index + 1) written message(s), got \(frames.count)")
        return try #require(JSONSerialization.jsonObject(with: frame) as? [String: Any])
    }

    var messageCount: Int { written.withLock { $0.count } }
}

/// The RPC methods added for the rest of the RFC 7047 surface: locking,
/// `set_db_change_aware`, `get_server_id`, `convert` and `cancel`.
@Suite("OVSDB RPC surface")
struct OVSDBRPCSurfaceTests {

    /// `lock` reports the reply's `locked` member as-is: false is not a
    /// failure, it means the request is queued behind the current owner and
    /// ownership will arrive as a `locked` notification.
    @Test("lock reports whether ownership was granted", arguments: [true, false])
    func lockReportsOwnership(granted: Bool) async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":{"locked":\#(granted)},"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        #expect(try await client.lock(id: "ovn_nb_lock") == granted)

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "lock")
        #expect(request["params"] as? [String] == ["ovn_nb_lock"])
        #expect(request["id"] as? Int == 1)
    }

    @Test("steal sends the lock id and reports ownership")
    func stealReportsOwnership() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":{"locked":true},"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        #expect(try await client.steal(id: "ovn_nb_lock") == true)

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "steal")
        #expect(request["params"] as? [String] == ["ovn_nb_lock"])
    }

    @Test("unlock sends the lock id")
    func unlockSendsTheLockID() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":{},"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        try await client.unlock(id: "ovn_nb_lock")

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "unlock")
        #expect(request["params"] as? [String] == ["ovn_nb_lock"])
    }

    /// A reply that is not `{"locked": <boolean>}` has to surface as an error
    /// rather than be guessed at: reporting "not the owner" for a malformed
    /// reply would be indistinguishable from a real queued request.
    @Test("A lock reply without a boolean 'locked' member is rejected", arguments: [
        #"{"id":1,"result":{},"error":null}"#,
        #"{"id":1,"result":{"locked":"yes"},"error":null}"#,
        #"{"id":1,"result":[],"error":null}"#,
    ])
    func malformedLockReplyIsRejected(reply: String) async throws {
        let client = JSONRPCClient(transport: StubTransport(replies: [reply]))

        let error = await #expect(throws: OVNManagerError.self) {
            try await client.lock(id: "ovn_nb_lock")
        }
        #expect(error?.errorCase == .invalidResponse)
    }

    @Test("set_db_change_aware sends a boolean parameter", arguments: [true, false])
    func setDatabaseChangeAwareSendsBoolean(aware: Bool) async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":{},"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        try await client.setDatabaseChangeAware(aware)

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "set_db_change_aware")
        // A JSON boolean, not 0/1: ovsdb-server type-checks this parameter.
        #expect(request["params"] as? [Bool] == [aware])
    }

    @Test("get_server_id returns the server's UUID")
    func getServerIDReturnsTheUUID() async throws {
        let serverID = "d7a4f4ba-6b6e-4c1e-8a2e-9f1d6f2a4c31"
        let transport = StubTransport(replies: [#"{"id":1,"result":"\#(serverID)","error":null}"#])
        let client = JSONRPCClient(transport: transport)

        #expect(try await client.getServerID() == serverID)

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "get_server_id")
        // Empty rather than absent: a JSON-RPC request must carry "params".
        #expect((request["params"] as? [Any])?.isEmpty == true)
    }

    @Test("list_dbs sends an empty params array")
    func listDatabasesSendsEmptyParams() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":["_Server","OVN_Northbound"],"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        #expect(try await client.listDatabases() == ["_Server", "OVN_Northbound"])

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "list_dbs")
        #expect((request["params"] as? [Any])?.isEmpty == true, "RFC 7047 §4.1.1 gives list_dbs \"params\": []")
    }

    @Test("convert sends the database name and the new schema")
    func convertSendsDatabaseAndSchema() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":{},"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        try await client.convert(
            database: "OVN_Northbound",
            schema: .object(["name": .string("OVN_Northbound"), "version": .string("7.0.0")])
        )

        let request = try transport.message(at: 0)
        #expect(request["method"] as? String == "convert")
        let params = try #require(request["params"] as? [Any])
        #expect(params.count == 2)
        #expect(params[0] as? String == "OVN_Northbound")
        #expect((params[1] as? [String: Any])?["version"] as? String == "7.0.0")
    }

    // MARK: - cancel

    @Test("cancel is a notification carrying the target request's id")
    func cancelIsANotificationCarryingTheTargetID() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":[],"error":null}"#])
        let client = JSONRPCClient(transport: transport)

        try await client.cancel(requestID: .number(17))

        let notification = try transport.message(at: 0)
        #expect(notification["method"] as? String == "cancel")
        #expect(notification["params"] as? [Int] == [17])
        // Null, not absent: RFC 7047 §4.1.4 identifies a notification by a null
        // id, and a non-null one would make the server expect to reply.
        #expect(notification["id"] is NSNull)
    }

    @Test("cancel carries a string id unchanged")
    func cancelCarriesAStringID() async throws {
        let transport = StubTransport()
        let client = JSONRPCClient(transport: transport)

        try await client.cancel(requestID: .string("txn-4"))

        #expect(try transport.message(at: 0)["params"] as? [String] == ["txn-4"])
    }

    /// Ids are allocated inside the client, so without this hook a caller has
    /// no way to name an in-flight request to `cancel`.
    @Test("transact reports the id it put on the wire")
    func transactReportsItsRequestID() async throws {
        let transport = StubTransport(replies: [#"{"id":1,"result":[{"count":1}],"error":null}"#])
        let client = JSONRPCClient(transport: transport)
        let reported = Mutex<JSONRPCIdentifier?>(nil)

        _ = try await client.transact(
            database: "OVN_Northbound",
            operations: [.select(from: "Logical_Switch")],
            onRequestID: { id in reported.withLock { $0 = id } }
        )

        let request = try transport.message(at: 0)
        let id = try #require(request["id"] as? Int)
        #expect(reported.withLock { $0 } == .number(id))
    }

    // MARK: - Lock notifications

    @Test("lockUpdates surfaces locked and stolen notifications")
    func lockUpdatesSurfacesLockedAndStolen() async throws {
        let transport = StubTransport(events: [
            // An unrelated monitor update in the middle: the lock stream has to
            // skip it, not stop at it.
            .notification(JSONRPCNotification(method: "locked", params: .array([.string("ovn_nb_lock")]))),
            .notification(JSONRPCNotification(method: "update", params: .array([.string("mon1"), .object([:])]))),
            .notification(JSONRPCNotification(method: "stolen", params: .array([.string("ovn_nb_lock")]))),
        ])
        let client = JSONRPCClient(transport: transport)

        var received: [OVSDBLockNotification] = []
        for try await update in client.lockUpdates() {
            received.append(update)
        }

        #expect(received == [
            OVSDBLockNotification(kind: .locked, lockID: "ovn_nb_lock"),
            OVSDBLockNotification(kind: .stolen, lockID: "ovn_nb_lock"),
        ])
    }

    /// A dropped notification may have been the `stolen` that demoted this
    /// client, so the stream fails rather than let a consumer keep believing it
    /// owns the lock.
    @Test("lockUpdates fails once notifications were dropped")
    func lockUpdatesFailsAfterADrop() async throws {
        let transport = StubTransport(events: [
            .notification(JSONRPCNotification(method: "locked", params: .array([.string("l")]))),
            .dropped(count: 3),
            .notification(JSONRPCNotification(method: "stolen", params: .array([.string("l")]))),
        ])
        let client = JSONRPCClient(transport: transport)

        var delivered = 0
        do {
            for try await _ in client.lockUpdates() {
                delivered += 1
            }
            Issue.record("Expected the stream to fail after notifications were dropped")
        } catch OVNManagerError.notificationsDropped(let count) {
            #expect(count == 3)
        }
        #expect(delivered == 1)
    }

    @Test("A malformed lock notification is skipped", arguments: [
        JSONRPCNotification(method: "locked", params: nil),
        JSONRPCNotification(method: "locked", params: .array([])),
        JSONRPCNotification(method: "locked", params: .string("ovn_nb_lock")),
        JSONRPCNotification(method: "unlocked", params: .array([.string("ovn_nb_lock")])),
    ])
    func malformedLockNotificationIsSkipped(notification: JSONRPCNotification) async throws {
        #expect(OVSDBLockNotification(notification) == nil)
    }
}
