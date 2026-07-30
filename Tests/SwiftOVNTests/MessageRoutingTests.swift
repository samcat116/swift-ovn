import Foundation
import Testing
import NIOCore
import NIOEmbedded
import NIOPosix
import Logging
@testable import SwiftOVN

/// Thrown by `withDeadline` when the operation under test never completes.
private struct DeadlineExceeded: Error {}

/// Tests for the inbound JSON-RPC message routing: notifications (null/absent
/// id) reach subscribers, server `echo` requests are answered, responses are
/// matched to pending requests, and connection loss fails everything cleanly.
///
/// `OVSDBConnectionCore.consumeInbound` is driven with NIO's testing inbound
/// stream and outbound writer, so these exercise the same code path a socket
/// does without needing one.
///
/// A `final class` rather than a `struct` so the per-test event loop group can
/// be torn down in `deinit`, the way `tearDown` used to.
@Suite("JSON-RPC message routing")
final class MessageRoutingTests {

    private let group: MultiThreadedEventLoopGroup

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Asynchronously, and never `syncShutdownGracefully()`: Swift Testing
        // runs tests as tasks, so `deinit` lands on a cooperative thread, and
        // blocking one of the pool's few threads while other suites' read-loop
        // tasks are waiting for a thread deadlocks the whole run.
        group.shutdownGracefully { _ in }
    }

    /// A core driven by a test stream, plus the handles to feed it frames and
    /// read what it wrote.
    private struct Harness {
        let core: OVSDBConnectionCore
        let source: NIOAsyncChannelInboundStream<ByteBuffer>.TestSource
        let written: NIOAsyncChannelOutboundWriter<ByteBuffer>.TestSink
        let loop: Task<Void, Never>

        /// Feeds one framed JSON-RPC message in, exactly as the framer would.
        func receive(_ json: String) {
            source.yield(ByteBuffer(string: json))
        }

        /// Ends the connection: cleanly when `error` is nil, otherwise as a
        /// failure the read loop propagates.
        func endConnection(throwing error: Error? = nil) async {
            source.finish(throwing: error)
            await loop.value
        }
    }

    private func makeHarness(notificationBufferSize: Int = OVSDBSocketConnection.notificationBufferSize) async throws -> Harness {
        // A stand-in for the socket channel: the core only reads `isActive` off
        // it, since writes go through the outbound writer.
        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/swiftovn-routing-test"))

        let core = OVSDBConnectionCore(
            endpoint: .unix(path: "/tmp/swiftovn-routing-test"),
            eventLoopGroup: group,
            logger: Logger(label: "test"),
            notificationBufferSize: notificationBufferSize
        )
        let (inbound, source) = NIOAsyncChannelInboundStream<ByteBuffer>.makeTestingStream()
        let (outbound, written) = NIOAsyncChannelOutboundWriter<ByteBuffer>.makeTestingWriter()

        let loop = Task {
            await core.consumeInbound(channel: channel, inbound: inbound, outbound: outbound)
        }

        // consumeInbound installs the write side first; wait for that so a test
        // can send straight away. A `#require` rather than an expectation: every
        // test below would hang on an inactive session, so stop here instead.
        for _ in 0..<10_000 where !core.isConnected {
            await Task.yield()
        }
        try #require(core.isConnected, "read loop never activated the session")

        return Harness(core: core, source: source, written: written, loop: loop)
    }

    /// Runs `operation` with a deadline, so a regression that stops a stream
    /// from ever finishing fails the test instead of hanging the suite.
    private func withDeadline<T: Sendable>(
        _ seconds: Double = 2,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw DeadlineExceeded()
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    /// Decodes one message the core wrote.
    private func nextWritten(
        _ iterator: inout NIOAsyncChannelOutboundWriter<ByteBuffer>.TestSink.AsyncIterator
    ) async throws -> [String: Any] {
        let next = await iterator.next()
        let frame = try #require(next, "Expected the core to write a frame")
        return try #require(JSONSerialization.jsonObject(with: Data(buffer: frame)) as? [String: Any])
    }

    /// Unwraps a notification event, returning nil for a drop report.
    private func notification(_ event: JSONRPCNotificationEvent?) -> JSONRPCNotification? {
        guard case .notification(let notification)? = event else { return nil }
        return notification
    }

    /// The monitor ID an `update` notification carries as its first parameter.
    private func monitorId(of notification: JSONRPCNotification) throws -> String {
        let params = try #require(notification.params?.arrayValue)
        return try #require(params.first?.stringValue)
    }

    // MARK: - Notifications

    @Test("An update notification with a null id is dispatched")
    func updateNotificationWithNullIdIsDispatched() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        // Real ovsdb-server update notifications carry "id": null.
        harness.receive(#"{"method":"update","params":["mon1",{"Logical_Switch":{"aa-bb":{"new":{"name":"ls0"}}}}],"id":null}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = try #require(notification(await iterator.next()))

        #expect(notification.method == "update")
        let params = try #require(notification.params?.arrayValue)
        #expect(params.count == 2)
        #expect(try monitorId(of: notification) == "mon1")

        await harness.endConnection()
    }

    @Test("A notification with no id key at all is dispatched")
    func notificationWithoutIdKeyIsDispatched() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        harness.receive(#"{"method":"update","params":["mon2",{}]}"#)

        var iterator = stream.makeAsyncIterator()
        let received = notification(await iterator.next())
        #expect(received?.method == "update")

        await harness.endConnection()
    }

    @Test("Notifications are buffered between reads")
    func notificationsAreBufferedBetweenReads() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        // Deliver several notifications before the consumer starts iterating;
        // none may be dropped.
        for index in 1...3 {
            harness.receive(#"{"method":"update","params":["mon\#(index)",{}],"id":null}"#)
        }

        var received: [String] = []
        var iterator = stream.makeAsyncIterator()
        for _ in 1...3 {
            let notification = try #require(
                notification(await iterator.next()),
                "Missing buffered notification"
            )
            received.append(try monitorId(of: notification))
        }
        #expect(received == ["mon1", "mon2", "mon3"])

        await harness.endConnection()
    }

    @Test("Every subscriber receives each notification")
    func everySubscriberReceivesEachNotification() async throws {
        let harness = try await makeHarness()
        let first = harness.core.notificationHub.subscribe()
        let second = harness.core.notificationHub.subscribe()

        harness.receive(#"{"method":"update","params":["mon1",{}],"id":null}"#)

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let fromFirst = notification(await firstIterator.next())
        let fromSecond = notification(await secondIterator.next())
        #expect(fromFirst?.method == "update")
        #expect(fromSecond?.method == "update")

        await harness.endConnection()
    }

    @Test("A lagging subscriber is bounded and told about the gap")
    func laggingSubscriberIsBoundedAndToldAboutTheGap() async throws {
        // The point of the bounded buffer: a consumer that stops reading must
        // not make the process grow, and must be told it lost updates rather
        // than silently receiving an incomplete picture.
        let harness = try await makeHarness(notificationBufferSize: 2)
        let stream = harness.core.notificationHub.subscribe()

        for index in 1...6 {
            harness.receive(#"{"method":"update","params":["mon\#(index)",{}],"id":null}"#)
        }

        // The consumer must not read anything until the buffer has overflowed,
        // or it would keep up and there would be nothing to report. The read
        // loop is strictly sequential, so an echo reply arriving proves all six
        // updates were published first.
        harness.receive(#"{"method":"echo","params":[],"id":99}"#)
        var writtenIterator = harness.written.makeAsyncIterator()
        let reply = try await nextWritten(&writtenIterator)
        #expect(reply["id"] as? Int == 99)

        await harness.endConnection()

        let (delivered, dropped) = try await withDeadline { () -> (Int, Int) in
            var delivered = 0
            var dropped = 0
            for await event in stream {
                switch event {
                case .notification:
                    delivered += 1
                case .dropped(let count):
                    dropped += count
                }
            }
            return (delivered, dropped)
        }

        #expect(delivered <= 2, "Buffer must not grow past its bound")
        #expect(dropped > 0, "The consumer fell behind, so drops must be reported")
        #expect(delivered + dropped <= 6)
    }

    @Test("Subscribing after the connection ended yields a finished stream")
    func subscribingAfterTheConnectionEndedYieldsAFinishedStream() async throws {
        // Previously the hub kept no record of being closed, so a late
        // subscriber got a stream that never finished and hung its consumer.
        let harness = try await makeHarness()
        await harness.endConnection()

        let stream = harness.core.notificationHub.subscribe()
        // Deadlined deliberately: the bug this guards against is a hang, so a
        // regression has to fail the test rather than stall the suite.
        let event = try await withDeadline { () -> JSONRPCNotificationEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(event == nil, "A stream created after the close must be finished")
    }

    @Test("The connection ending finishes notification streams")
    func connectionEndFinishesNotificationStreams() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        await harness.endConnection()

        let event = try await withDeadline { () -> JSONRPCNotificationEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        #expect(event == nil, "Stream should finish when the connection closes")
    }

    @Test("Resubscribing works after a reconnect")
    func resubscribingWorksAfterAReconnect() async throws {
        // A dropped connection closes the hub; a new session has to reopen it,
        // or every subscriber after the first reconnect would get a finished
        // stream.
        let harness = try await makeHarness()
        await harness.endConnection()

        let channel = EmbeddedChannel()
        try await channel.connect(to: SocketAddress(unixDomainSocketPath: "/tmp/swiftovn-routing-test"))
        let (inbound, source) = NIOAsyncChannelInboundStream<ByteBuffer>.makeTestingStream()
        let (outbound, _) = NIOAsyncChannelOutboundWriter<ByteBuffer>.makeTestingWriter()
        let loop = Task {
            await harness.core.consumeInbound(channel: channel, inbound: inbound, outbound: outbound)
        }
        for _ in 0..<10_000 where !harness.core.isConnected {
            await Task.yield()
        }

        let stream = harness.core.notificationHub.subscribe()
        source.yield(ByteBuffer(string: #"{"method":"update","params":["mon9",{}],"id":null}"#))

        var iterator = stream.makeAsyncIterator()
        let received = notification(await iterator.next())
        #expect(received?.method == "update")

        source.finish()
        await loop.value
    }

    // MARK: - Server echo requests

    @Test("A server echo request gets a reply")
    func serverEchoRequestGetsReply() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        harness.receive(#"{"method":"echo","params":["ping"],"id":42}"#)

        let reply = try await nextWritten(&iterator)
        #expect(reply["id"] as? Int == 42)
        #expect(reply["result"] as? [String] == ["ping"])
        #expect(reply["error"] is NSNull)

        await harness.endConnection()
    }

    @Test("A server echo reply preserves a string id")
    func serverEchoReplyPreservesStringId() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        harness.receive(#"{"method":"echo","params":[],"id":"echo-7"}"#)

        let reply = try await nextWritten(&iterator)
        #expect(reply["id"] as? String == "echo-7")
        #expect((reply["result"] as? [Any])?.count == 0)

        await harness.endConnection()
    }

    @Test("An unknown server request produces no reply")
    func unknownServerRequestProducesNoReply() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        // Nothing may be written for the unknown method: the next frame the
        // core writes has to be the reply to the echo that follows it.
        harness.receive(#"{"method":"frobnicate","params":[],"id":9}"#)
        harness.receive(#"{"method":"echo","params":[],"id":10}"#)

        let reply = try await nextWritten(&iterator)
        #expect(reply["id"] as? Int == 10)

        await harness.endConnection()
    }

    // MARK: - Responses

    @Test("A response is routed to its pending request")
    func responseIsRoutedToPendingRequest() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        let response = Task {
            try await harness.core.sendRequest(
                JSONRPCRequest(method: "list_dbs", params: nil, id: .number(7)),
                id: .number(7),
                responseType: JSONRPCResponse<[String]>.self,
                timeout: .seconds(30)
            )
        }

        // The request has to be on the wire before the reply is fed back, so the
        // ordering matches a real server's. That the reply is never missed even
        // when it arrives the instant the request is read is structural:
        // `sendRequest` registers the pending entry and writes inside one
        // actor-isolated stretch, with the registration first.
        let request = try await nextWritten(&iterator)
        #expect(request["method"] as? String == "list_dbs")

        harness.receive(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#)

        let value = try await response.value
        #expect(value.result == ["OVN_Northbound"])
        #expect(value.error == nil)

        await harness.endConnection()
    }

    @Test("A timed-out request fails and a late response is ignored")
    func timedOutRequestFailsAndLateResponseIsIgnored() async throws {
        let harness = try await makeHarness()

        let error = await #expect(throws: OVNManagerError.self) {
            try await harness.core.sendRequest(
                JSONRPCRequest(method: "list_dbs", params: nil, id: .number(1)),
                id: .number(1),
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .milliseconds(50)
            )
        }
        #expect(error?.errorCase == .timeoutError)

        // A response arriving after the timeout must be ignored gracefully, not
        // fulfil the already-failed promise (which would crash).
        harness.receive(#"{"id":1,"result":{},"error":null}"#)
        harness.receive(#"{"method":"echo","params":[],"id":2}"#)
        var iterator = harness.written.makeAsyncIterator()
        // The request frame, then the echo reply that proves the core survived.
        _ = try await nextWritten(&iterator)
        let reply = try await nextWritten(&iterator)
        #expect(reply["id"] as? Int == 2)

        await harness.endConnection()
    }

    @Test("A response with an unsupported id is ignored")
    func responseWithUnsupportedIdIsIgnored() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        // No request this library issues carries a fractional id, so there is
        // nothing to correlate and the core must simply keep going.
        harness.receive(#"{"id":1.5,"result":{},"error":null}"#)
        harness.receive(#"{"method":"echo","params":[],"id":3}"#)

        let reply = try await nextWritten(&iterator)
        #expect(reply["id"] as? Int == 3)

        await harness.endConnection()
    }

    // MARK: - Connection loss

    @Test("The connection ending fails pending requests")
    func connectionEndFailsPendingRequests() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        let response = Task {
            try await harness.core.sendRequest(
                JSONRPCRequest(method: "list_dbs", params: nil, id: .number(3)),
                id: .number(3),
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .seconds(30)
            )
        }
        _ = try await nextWritten(&iterator)

        await harness.endConnection()

        let error = await #expect(throws: OVNManagerError.self) {
            try await response.value
        }
        #expect(error?.errorCase == .connectionFailed)
    }

    @Test("A read failure fails pending requests")
    func connectionFailureFailsPendingRequests() async throws {
        struct SocketDied: Error {}
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        let response = Task {
            try await harness.core.sendRequest(
                JSONRPCRequest(method: "list_dbs", params: nil, id: .number(4)),
                id: .number(4),
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .seconds(30)
            )
        }
        _ = try await nextWritten(&iterator)

        await harness.endConnection(throwing: SocketDied())

        await #expect(throws: SocketDied.self) {
            try await response.value
        }
    }

    @Test("Sending without a connection fails")
    func sendingWithoutAConnectionFails() async throws {
        let core = OVSDBConnectionCore(
            endpoint: .unix(path: "/tmp/swiftovn-never-connected"),
            eventLoopGroup: group,
            logger: Logger(label: "test")
        )
        #expect(!core.isConnected)

        let error = await #expect(throws: OVNManagerError.self) {
            try await core.send(JSONRPCRequest(method: "echo", params: nil, id: nil))
        }
        #expect(error?.errorCase == .connectionFailed)
    }
}

// MARK: - Notification Hub

/// The hub's buffering and drop accounting, driven directly: it is what keeps a
/// stalled consumer from growing the process without limit, and what tells that
/// consumer its view has a hole.
@Suite("Notification hub")
struct JSONRPCNotificationHubTests {

    private enum StreamOutcome {
        case event(JSONRPCNotificationEvent)
        case finished
        case timedOut
    }

    /// Awaits the first element of `stream`, reporting a timeout instead of
    /// hanging the suite when the stream neither yields nor finishes.
    private func firstOutcome(of stream: AsyncStream<JSONRPCNotificationEvent>) async -> StreamOutcome {
        return await withTaskGroup(of: StreamOutcome.self) { group in
            group.addTask {
                var iterator = stream.makeAsyncIterator()
                guard let event = await iterator.next() else { return .finished }
                return .event(event)
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return .timedOut
            }
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            return outcome
        }
    }

    @Test("A slow subscriber's buffer is bounded and drops are reported")
    func slowSubscriberBufferIsBoundedAndDropsAreReported() async throws {
        let bufferSize = 4
        let published = 20
        let hub = JSONRPCNotificationHub(bufferSize: bufferSize, logger: Logger(label: "test"))

        let stream = hub.subscribe()

        // Nothing consumes while these arrive: an unbounded buffer would hold
        // all 20 (and, with real Southbound updates, exhaust memory).
        for index in 1...published {
            hub.publish(JSONRPCNotification(method: "update", params: .string("n\(index)")))
        }
        hub.finishAll()

        var notifications: [String] = []
        var dropped = 0
        for await event in stream {
            switch event {
            case .notification(let notification):
                notifications.append(try #require(notification.params?.stringValue))
            case .dropped(let count):
                dropped += count
            }
        }

        #expect(notifications.count <= bufferSize, "Buffer must not grow past its bound")
        #expect(dropped > 0, "The consumer fell behind, so drops must be reported")
        // A report is never inflated; the one emitted at close can undercount,
        // since squeezing it into a full buffer costs another element.
        #expect(notifications.count + dropped <= published)
        // Newest are kept: the final publish must have survived.
        #expect(notifications.last == "n\(published)")
    }

    @Test("The drop count is exact once the consumer catches up")
    func dropCountIsExactOnceTheConsumerCatchesUp() async throws {
        let hub = JSONRPCNotificationHub(bufferSize: 4, logger: Logger(label: "test"))
        let stream = hub.subscribe()
        var iterator = stream.makeAsyncIterator()

        // Overrun the buffer by two while nothing consumes.
        for index in 1...6 {
            hub.publish(JSONRPCNotification(method: "update", params: .string("n\(index)")))
        }

        var notifications: [String] = []
        var dropped = 0
        // Drain the buffer, then publish once more: the catch-up notification
        // carries the outstanding drop report with it.
        for step in 1...6 {
            if step == 5 {
                hub.publish(JSONRPCNotification(method: "update", params: .string("n7")))
            }
            switch await iterator.next() {
            case .notification(let notification):
                notifications.append(try #require(notification.params?.stringValue))
            case .dropped(let count):
                dropped += count
            case nil:
                Issue.record("Stream finished early")
                return
            }
        }

        #expect(notifications == ["n4", "n5", "n6", "n7"])
        #expect(dropped == 3, "n1, n2 and n3 were discarded")
        #expect(
            notifications.count + dropped == 7,
            "Every notification is either delivered or reported as dropped"
        )
    }

    @Test("A subscriber that keeps up sees no drops")
    func keptUpSubscriberSeesNoDrops() async throws {
        let hub = JSONRPCNotificationHub(bufferSize: 2, logger: Logger(label: "test"))
        let stream = hub.subscribe()
        var iterator = stream.makeAsyncIterator()

        for index in 1...10 {
            hub.publish(JSONRPCNotification(method: "update", params: .string("n\(index)")))
            guard case .notification(let notification)? = await iterator.next() else {
                Issue.record("Expected notification \(index)")
                return
            }
            #expect(notification.params?.stringValue == "n\(index)")
        }
    }

    @Test("Subscribing after close returns an already-finished stream")
    func subscribingAfterCloseReturnsAFinishedStream() async throws {
        let hub = JSONRPCNotificationHub(logger: Logger(label: "test"))
        hub.finishAll()

        // Before the hub tracked being closed, this stream's continuation was
        // never finished and the consumer's `for await` hung forever.
        let outcome = await firstOutcome(of: hub.subscribe())
        guard case .finished = outcome else {
            Issue.record("Expected a finished stream, got \(outcome)")
            return
        }
    }

    @Test("Subscribing after a reopen receives notifications")
    func subscribingAfterReopenReceivesNotifications() async throws {
        let hub = JSONRPCNotificationHub(logger: Logger(label: "test"))
        hub.finishAll()

        // A reconnect makes the hub live again; subscriptions taken after it
        // must not come back already finished.
        hub.reopen()
        let stream = hub.subscribe()
        hub.publish(JSONRPCNotification(method: "update", params: .string("after-reconnect")))

        guard case .event(.notification(let notification)) = await firstOutcome(of: stream) else {
            Issue.record("Expected a notification after reopen")
            return
        }
        #expect(notification.params?.stringValue == "after-reconnect")
    }
}

// MARK: - Monitor Stream Backpressure

/// A monitor consumer that falls behind must be told its view is incomplete
/// rather than have the client buffer updates until memory runs out.
@Suite("Monitor stream backpressure")
struct MonitorStreamDropTests {

    @Test("monitorUpdates() throws once notifications were dropped")
    func monitorUpdatesThrowsWhenNotificationsWereDropped() async throws {
        let transport = StubNotificationTransport(events: [
            .notification(Self.updateNotification(monitorId: "mon1")),
            .dropped(count: 7),
            .notification(Self.updateNotification(monitorId: "mon1"))
        ])
        let client = JSONRPCClient(transport: transport)

        var delivered = 0
        do {
            for try await _ in client.monitorUpdates() {
                delivered += 1
            }
            Issue.record("Expected the stream to fail after notifications were dropped")
        } catch OVNManagerError.notificationsDropped(let count) {
            #expect(count == 7)
        }

        // Updates before the gap are still delivered; nothing after it is,
        // because the consumer must restart the monitor to resynchronize.
        #expect(delivered == 1)
    }

    private static func updateNotification(monitorId: String) -> JSONRPCNotification {
        return JSONRPCNotification(
            method: "update",
            params: .array([.string(monitorId), .object([:])])
        )
    }
}

/// Replays a fixed list of notification events; every other transport
/// operation is unsupported.
private struct StubNotificationTransport: OVSDBTransport {
    let events: [JSONRPCNotificationEvent]

    func connect() async throws {}
    func disconnect() async throws {}
    func send<T: Codable & Sendable>(_ message: T) async throws {}

    func sendRequest<Request: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Request,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response {
        throw OVNManagerError.invalidResponse("stub")
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

    var isConnectionActive: Bool { true }
}

// MARK: - Table Updates Parsing

@Suite("Table update parsing")
struct OVSDBTableUpdatesParsingTests {

    private func tableUpdates(_ json: String) throws -> [OVSDBUpdate] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return OVSDBConnection.parseTableUpdates(value)
    }

    @Test("Parsing carries the table, uuid, old and new")
    func parsingCarriesTableUUIDOldAndNew() throws {
        let updates = try tableUpdates(#"""
        {
          "Logical_Switch": {
            "uuid-insert": {"new": {"name": "ls0"}},
            "uuid-delete": {"old": {"name": "ls1"}}
          },
          "Logical_Switch_Port": {
            "uuid-modify": {"old": {"name": "p0"}, "new": {"name": "p1"}}
          }
        }
        """#)

        #expect(updates.count == 3)

        let insert = try #require(updates.first { $0.uuid == "uuid-insert" })
        #expect(insert.table == "Logical_Switch")
        #expect(insert.old == nil)
        #expect(insert.new?["name"] == .string("ls0"))

        let delete = try #require(updates.first { $0.uuid == "uuid-delete" })
        #expect(delete.table == "Logical_Switch")
        #expect(delete.old?["name"] == .string("ls1"))
        #expect(delete.new == nil)

        let modify = try #require(updates.first { $0.uuid == "uuid-modify" })
        #expect(modify.table == "Logical_Switch_Port")
        #expect(modify.old?["name"] == .string("p0"))
        #expect(modify.new?["name"] == .string("p1"))
    }

    @Test("Parsing a non-object value returns nothing")
    func parsingNonObjectValueReturnsEmpty() throws {
        #expect(try tableUpdates(#"[1,2,3]"#).isEmpty)
    }
}
