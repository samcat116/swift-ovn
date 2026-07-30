import XCTest
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
final class MessageRoutingTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
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
        // can send straight away.
        for _ in 0..<10_000 where !core.isConnected {
            await Task.yield()
        }
        XCTAssertTrue(core.isConnected, "read loop never activated the session")

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
        let frame = try XCTUnwrap(next, "Expected the core to write a frame")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(buffer: frame)) as? [String: Any])
    }

    /// Unwraps a notification event, returning nil for a drop report.
    private func notification(_ event: JSONRPCNotificationEvent?) -> JSONRPCNotification? {
        guard case .notification(let notification)? = event else { return nil }
        return notification
    }

    // MARK: - Notifications

    func testUpdateNotificationWithNullIdIsDispatched() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        // Real ovsdb-server update notifications carry "id": null.
        harness.receive(#"{"method":"update","params":["mon1",{"Logical_Switch":{"aa-bb":{"new":{"name":"ls0"}}}}],"id":null}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = notification(await iterator.next())

        XCTAssertEqual(notification?.method, "update")
        guard let notification,
              case .array(let params)? = notification.params,
              params.count == 2,
              case .string(let monitorId) = params[0] else {
            XCTFail("Expected array params with monitor ID first")
            return
        }
        XCTAssertEqual(monitorId, "mon1")

        await harness.endConnection()
    }

    func testNotificationWithoutIdKeyIsDispatched() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        harness.receive(#"{"method":"update","params":["mon2",{}]}"#)

        var iterator = stream.makeAsyncIterator()
        let received = notification(await iterator.next())
        XCTAssertEqual(received?.method, "update")

        await harness.endConnection()
    }

    func testNotificationsAreBufferedBetweenReads() async throws {
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
            guard let notification = notification(await iterator.next()),
                  case .array(let params)? = notification.params,
                  case .string(let monitorId) = params[0] else {
                XCTFail("Missing buffered notification")
                return
            }
            received.append(monitorId)
        }
        XCTAssertEqual(received, ["mon1", "mon2", "mon3"])

        await harness.endConnection()
    }

    func testEverySubscriberReceivesEachNotification() async throws {
        let harness = try await makeHarness()
        let first = harness.core.notificationHub.subscribe()
        let second = harness.core.notificationHub.subscribe()

        harness.receive(#"{"method":"update","params":["mon1",{}],"id":null}"#)

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let fromFirst = notification(await firstIterator.next())
        let fromSecond = notification(await secondIterator.next())
        XCTAssertEqual(fromFirst?.method, "update")
        XCTAssertEqual(fromSecond?.method, "update")

        await harness.endConnection()
    }

    func testLaggingSubscriberIsBoundedAndToldAboutTheGap() async throws {
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
        XCTAssertEqual(reply["id"] as? Int, 99)

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

        XCTAssertLessThanOrEqual(delivered, 2, "Buffer must not grow past its bound")
        XCTAssertGreaterThan(dropped, 0, "The consumer fell behind, so drops must be reported")
        XCTAssertLessThanOrEqual(delivered + dropped, 6)
    }

    func testSubscribingAfterTheConnectionEndedYieldsAFinishedStream() async throws {
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
        XCTAssertNil(event, "A stream created after the close must be finished")
    }

    func testConnectionEndFinishesNotificationStreams() async throws {
        let harness = try await makeHarness()
        let stream = harness.core.notificationHub.subscribe()

        await harness.endConnection()

        let event = try await withDeadline { () -> JSONRPCNotificationEvent? in
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        XCTAssertNil(event, "Stream should finish when the connection closes")
    }

    func testResubscribingWorksAfterAReconnect() async throws {
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
        XCTAssertEqual(received?.method, "update")

        source.finish()
        await loop.value
    }

    // MARK: - Server echo requests

    func testServerEchoRequestGetsReply() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        harness.receive(#"{"method":"echo","params":["ping"],"id":42}"#)

        let reply = try await nextWritten(&iterator)
        XCTAssertEqual(reply["id"] as? Int, 42)
        XCTAssertEqual(reply["result"] as? [String], ["ping"])
        XCTAssertTrue(reply["error"] is NSNull)

        await harness.endConnection()
    }

    func testServerEchoReplyPreservesStringId() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        harness.receive(#"{"method":"echo","params":[],"id":"echo-7"}"#)

        let reply = try await nextWritten(&iterator)
        XCTAssertEqual(reply["id"] as? String, "echo-7")
        XCTAssertEqual((reply["result"] as? [Any])?.count, 0)

        await harness.endConnection()
    }

    func testUnknownServerRequestProducesNoReply() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        // Nothing may be written for the unknown method: the next frame the
        // core writes has to be the reply to the echo that follows it.
        harness.receive(#"{"method":"frobnicate","params":[],"id":9}"#)
        harness.receive(#"{"method":"echo","params":[],"id":10}"#)

        let reply = try await nextWritten(&iterator)
        XCTAssertEqual(reply["id"] as? Int, 10)

        await harness.endConnection()
    }

    // MARK: - Responses

    func testResponseIsRoutedToPendingRequest() async throws {
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
        XCTAssertEqual(request["method"] as? String, "list_dbs")

        harness.receive(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#)

        let value = try await response.value
        XCTAssertEqual(value.result, ["OVN_Northbound"])
        XCTAssertNil(value.error)

        await harness.endConnection()
    }

    func testTimedOutRequestFailsAndLateResponseIsIgnored() async throws {
        let harness = try await makeHarness()

        do {
            _ = try await harness.core.sendRequest(
                JSONRPCRequest(method: "list_dbs", params: nil, id: .number(1)),
                id: .number(1),
                responseType: JSONRPCResponse<JSONValue>.self,
                timeout: .milliseconds(50)
            )
            XCTFail("Expected the request to time out")
        } catch {
            guard case OVNManagerError.timeoutError = error else {
                XCTFail("Expected timeoutError, got \(error)")
                return
            }
        }

        // A response arriving after the timeout must be ignored gracefully, not
        // fulfil the already-failed promise (which would crash).
        harness.receive(#"{"id":1,"result":{},"error":null}"#)
        harness.receive(#"{"method":"echo","params":[],"id":2}"#)
        var iterator = harness.written.makeAsyncIterator()
        // The request frame, then the echo reply that proves the core survived.
        _ = try await nextWritten(&iterator)
        let reply = try await nextWritten(&iterator)
        XCTAssertEqual(reply["id"] as? Int, 2)

        await harness.endConnection()
    }

    func testResponseWithUnsupportedIdIsIgnored() async throws {
        let harness = try await makeHarness()
        var iterator = harness.written.makeAsyncIterator()

        // No request this library issues carries a fractional id, so there is
        // nothing to correlate and the core must simply keep going.
        harness.receive(#"{"id":1.5,"result":{},"error":null}"#)
        harness.receive(#"{"method":"echo","params":[],"id":3}"#)

        let reply = try await nextWritten(&iterator)
        XCTAssertEqual(reply["id"] as? Int, 3)

        await harness.endConnection()
    }

    // MARK: - Connection loss

    func testConnectionEndFailsPendingRequests() async throws {
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

        do {
            _ = try await response.value
            XCTFail("Expected the in-flight request to fail")
        } catch {
            guard case OVNManagerError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
    }

    func testConnectionFailureFailsPendingRequests() async throws {
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

        do {
            _ = try await response.value
            XCTFail("Expected the read failure to fail the in-flight request")
        } catch {
            XCTAssertTrue(error is SocketDied, "Got \(error)")
        }
    }

    func testSendingWithoutAConnectionFails() async throws {
        let core = OVSDBConnectionCore(
            endpoint: .unix(path: "/tmp/swiftovn-never-connected"),
            eventLoopGroup: group,
            logger: Logger(label: "test")
        )
        XCTAssertFalse(core.isConnected)

        do {
            try await core.send(JSONRPCRequest(method: "echo", params: nil, id: nil))
            XCTFail("Expected send to fail without a connection")
        } catch {
            guard case OVNManagerError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
    }
}

// MARK: - Notification Hub

/// The hub's buffering and drop accounting, driven directly: it is what keeps a
/// stalled consumer from growing the process without limit, and what tells that
/// consumer its view has a hole.
final class JSONRPCNotificationHubTests: XCTestCase {

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

    func testSlowSubscriberBufferIsBoundedAndDropsAreReported() async throws {
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
                guard case .string(let payload)? = notification.params else {
                    XCTFail("Unexpected notification payload")
                    return
                }
                notifications.append(payload)
            case .dropped(let count):
                dropped += count
            }
        }

        XCTAssertLessThanOrEqual(notifications.count, bufferSize,
                                 "Buffer must not grow past its bound")
        XCTAssertGreaterThan(dropped, 0, "The consumer fell behind, so drops must be reported")
        // A report is never inflated; the one emitted at close can undercount,
        // since squeezing it into a full buffer costs another element.
        XCTAssertLessThanOrEqual(notifications.count + dropped, published)
        // Newest are kept: the final publish must have survived.
        XCTAssertEqual(notifications.last, "n\(published)")
    }

    func testDropCountIsExactOnceTheConsumerCatchesUp() async throws {
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
                guard case .string(let payload)? = notification.params else {
                    XCTFail("Unexpected notification payload")
                    return
                }
                notifications.append(payload)
            case .dropped(let count):
                dropped += count
            case nil:
                XCTFail("Stream finished early")
                return
            }
        }

        XCTAssertEqual(notifications, ["n4", "n5", "n6", "n7"])
        XCTAssertEqual(dropped, 3, "n1, n2 and n3 were discarded")
        XCTAssertEqual(notifications.count + dropped, 7,
                       "Every notification is either delivered or reported as dropped")
    }

    func testKeptUpSubscriberSeesNoDrops() async throws {
        let hub = JSONRPCNotificationHub(bufferSize: 2, logger: Logger(label: "test"))
        let stream = hub.subscribe()
        var iterator = stream.makeAsyncIterator()

        for index in 1...10 {
            hub.publish(JSONRPCNotification(method: "update", params: .string("n\(index)")))
            guard case .notification(let notification)? = await iterator.next(),
                  case .string(let payload)? = notification.params else {
                XCTFail("Expected notification \(index)")
                return
            }
            XCTAssertEqual(payload, "n\(index)")
        }
    }

    func testSubscribingAfterCloseReturnsAFinishedStream() async throws {
        let hub = JSONRPCNotificationHub(logger: Logger(label: "test"))
        hub.finishAll()

        // Before the hub tracked being closed, this stream's continuation was
        // never finished and the consumer's `for await` hung forever.
        let outcome = await firstOutcome(of: hub.subscribe())
        guard case .finished = outcome else {
            XCTFail("Expected a finished stream, got \(outcome)")
            return
        }
    }

    func testSubscribingAfterReopenReceivesNotifications() async throws {
        let hub = JSONRPCNotificationHub(logger: Logger(label: "test"))
        hub.finishAll()

        // A reconnect makes the hub live again; subscriptions taken after it
        // must not come back already finished.
        hub.reopen()
        let stream = hub.subscribe()
        hub.publish(JSONRPCNotification(method: "update", params: .string("after-reconnect")))

        guard case .event(.notification(let notification)) = await firstOutcome(of: stream),
              case .string(let payload)? = notification.params else {
            XCTFail("Expected a notification after reopen")
            return
        }
        XCTAssertEqual(payload, "after-reconnect")
    }
}

// MARK: - Monitor Stream Backpressure

/// A monitor consumer that falls behind must be told its view is incomplete
/// rather than have the client buffer updates until memory runs out.
final class MonitorStreamDropTests: XCTestCase {

    func testMonitorUpdatesThrowsWhenNotificationsWereDropped() async throws {
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
            XCTFail("Expected the stream to fail after notifications were dropped")
        } catch OVNManagerError.notificationsDropped(let count) {
            XCTAssertEqual(count, 7)
        }

        // Updates before the gap are still delivered; nothing after it is,
        // because the consumer must restart the monitor to resynchronize.
        XCTAssertEqual(delivered, 1)
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

final class OVSDBTableUpdatesParsingTests: XCTestCase {

    private func tableUpdates(_ json: String) throws -> [OVSDBUpdate] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return OVSDBConnection.parseTableUpdates(value)
    }

    func testParsingCarriesTableUUIDOldAndNew() throws {
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

        XCTAssertEqual(updates.count, 3)

        let insert = try XCTUnwrap(updates.first { $0.uuid == "uuid-insert" })
        XCTAssertEqual(insert.table, "Logical_Switch")
        XCTAssertNil(insert.old)
        XCTAssertEqual(insert.new?["name"], .string("ls0"))

        let delete = try XCTUnwrap(updates.first { $0.uuid == "uuid-delete" })
        XCTAssertEqual(delete.table, "Logical_Switch")
        XCTAssertEqual(delete.old?["name"], .string("ls1"))
        XCTAssertNil(delete.new)

        let modify = try XCTUnwrap(updates.first { $0.uuid == "uuid-modify" })
        XCTAssertEqual(modify.table, "Logical_Switch_Port")
        XCTAssertEqual(modify.old?["name"], .string("p0"))
        XCTAssertEqual(modify.new?["name"], .string("p1"))
    }

    func testParsingNonObjectValueReturnsEmpty() throws {
        XCTAssertTrue(try tableUpdates(#"[1,2,3]"#).isEmpty)
    }
}
