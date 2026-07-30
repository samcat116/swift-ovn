import XCTest
import NIO
import Logging
@testable import SwiftOVN

/// Tests for the inbound JSON-RPC message routing: notifications (null/absent
/// id) reach subscribers, server `echo` requests are answered, responses are
/// matched to pending requests, and connection loss fails everything cleanly.
final class MessageRoutingTests: XCTestCase {

    private func makeChannel(notificationBufferSize: Int = OVSDBSocketConnection.notificationBufferSize) -> (channel: EmbeddedChannel, hub: JSONRPCNotificationHub, router: JSONRPCResponseRouter) {
        let hub = JSONRPCNotificationHub(bufferSize: notificationBufferSize, logger: Logger(label: "test"))
        let loop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            logger: Logger(label: "test"),
            eventLoopGroup: loop,
            notificationHub: hub
        )
        let channel = EmbeddedChannel(handler: router, loop: loop)
        return (channel, hub, router)
    }

    /// Reads the router's next outbound write and parses it as a JSON object.
    /// The router writes raw bytes — nothing downstream serializes for it — so
    /// the reply arrives as a `ByteBuffer`.
    private func readOutboundObject(from channel: EmbeddedChannel) throws -> [String: Any]? {
        guard var buffer = try channel.readOutbound(as: ByteBuffer.self),
              let bytes = buffer.readBytes(length: buffer.readableBytes) else {
            return nil
        }
        return try JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any]
    }

    /// Unwraps a notification event, returning nil for a drop report.
    private func notification(_ event: JSONRPCNotificationEvent?) -> JSONRPCNotification? {
        guard case .notification(let notification)? = event else { return nil }
        return notification
    }

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
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return .timedOut
            }
            let outcome = await group.next() ?? .timedOut
            group.cancelAll()
            return outcome
        }
    }

    // MARK: - Notifications

    func testUpdateNotificationWithNullIdIsDispatched() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        // Real ovsdb-server update notifications carry "id": null.
        try channel.writeInbound(#"{"method":"update","params":["mon1",{"Logical_Switch":{"aa-bb":{"new":{"name":"ls0"}}}}],"id":null}"#)

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
    }

    func testNotificationWithoutIdKeyIsDispatched() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        try channel.writeInbound(#"{"method":"update","params":["mon2",{}]}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = notification(await iterator.next())
        XCTAssertEqual(notification?.method, "update")
    }

    func testNotificationsAreBufferedBetweenReads() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        // Deliver several notifications before the consumer starts iterating;
        // none may be dropped.
        for index in 1...3 {
            try channel.writeInbound(#"{"method":"update","params":["mon\#(index)",{}],"id":null}"#)
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
    }

    func testEverySubscriberReceivesEachNotification() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let first = hub.subscribe()
        let second = hub.subscribe()

        try channel.writeInbound(#"{"method":"update","params":["mon1",{}],"id":null}"#)

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let fromFirst = notification(await firstIterator.next())
        let fromSecond = notification(await secondIterator.next())
        XCTAssertEqual(fromFirst?.method, "update")
        XCTAssertEqual(fromSecond?.method, "update")
    }

    // MARK: - Bounded buffering

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

    // MARK: - Subscribing after close

    func testSubscribingAfterCloseReturnsAFinishedStream() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        channel.pipeline.fireChannelInactive()

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

    // MARK: - Server echo requests

    func testServerEchoRequestGetsReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":["ping"],"id":42}"#)

        let replyObject = try XCTUnwrap(
            readOutboundObject(from: channel),
            "Expected an echo reply to be written"
        )
        XCTAssertEqual(replyObject["id"] as? Int, 42)
        XCTAssertEqual(replyObject["result"] as? [String], ["ping"])
        XCTAssertTrue(replyObject["error"] is NSNull)
    }

    func testServerEchoReplyPreservesStringId() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":[],"id":"echo-7"}"#)

        let replyObject = try XCTUnwrap(
            readOutboundObject(from: channel),
            "Expected an echo reply to be written"
        )
        XCTAssertEqual(replyObject["id"] as? String, "echo-7")
        XCTAssertEqual((replyObject["result"] as? [Any])?.count, 0)
    }

    func testUnknownServerRequestProducesNoReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"frobnicate","params":[],"id":9}"#)

        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
    }

    // MARK: - Responses

    func testResponseIsRoutedToPendingRequest() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(7),
            type: JSONRPCResponse<[String]>.self,
            timeout: .seconds(30)
        )

        try channel.writeInbound(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#)

        let response = try future.wait()
        XCTAssertEqual(response.result, ["OVN_Northbound"])
        XCTAssertNil(response.error)
    }

    func testTimedOutRequestIsRemovedAndLateResponseIsIgnored() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(1),
            type: JSONRPCResponse<JSONValue>.self,
            timeout: .seconds(5)
        )

        channel.embeddedEventLoop.advanceTime(by: .seconds(5))

        XCTAssertThrowsError(try future.wait()) { error in
            guard case OVNManagerError.timeoutError = error else {
                XCTFail("Expected timeoutError, got \(error)")
                return
            }
        }

        // A response arriving after the timeout must be ignored gracefully,
        // not fulfill the already-failed promise (which would crash).
        XCTAssertNoThrow(try channel.writeInbound(#"{"id":1,"result":{},"error":null}"#))
    }

    // MARK: - Connection loss

    func testChannelInactiveFailsPendingRequests() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(3),
            type: JSONRPCResponse<JSONValue>.self,
            timeout: .seconds(30)
        )

        channel.pipeline.fireChannelInactive()

        XCTAssertThrowsError(try future.wait()) { error in
            guard case OVNManagerError.connectionFailed = error else {
                XCTFail("Expected connectionFailed, got \(error)")
                return
            }
        }
    }

    func testChannelInactiveFinishesNotificationStreams() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        channel.pipeline.fireChannelInactive()

        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        XCTAssertNil(value, "Stream should finish when the connection closes")
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
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    func connect() -> EventLoopFuture<Void> { group.next().makeSucceededFuture(()) }
    func disconnect() -> EventLoopFuture<Void> { group.next().makeSucceededFuture(()) }
    func send<T: Codable>(_ message: T) -> EventLoopFuture<Void> { group.next().makeSucceededFuture(()) }

    func receive<T: Codable>(as type: T.Type, requestId: JSONRPCIdentifier, timeout: TimeAmount) -> EventLoopFuture<T> {
        return group.next().makeFailedFuture(OVNManagerError.invalidResponse("stub"))
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
