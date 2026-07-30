import Foundation
import Testing
import NIO
import Logging
@testable import SwiftOVN

/// Tests for the inbound JSON-RPC message routing: notifications (null/absent
/// id) reach subscribers, server `echo` requests are answered, responses are
/// matched to pending requests, and connection loss fails everything cleanly.
@Suite("JSON-RPC message routing")
struct MessageRoutingTests {

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

    /// The monitor ID an `update` notification carries as its first parameter.
    private func monitorId(of notification: JSONRPCNotification) throws -> String {
        let params = try #require(notification.params?.arrayValue)
        return try #require(params.first?.stringValue)
    }

    // MARK: - Notifications

    @Test("An update notification with a null id is dispatched")
    func updateNotificationWithNullIdIsDispatched() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        // Real ovsdb-server update notifications carry "id": null.
        try channel.writeInbound(#"{"method":"update","params":["mon1",{"Logical_Switch":{"aa-bb":{"new":{"name":"ls0"}}}}],"id":null}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = try #require(notification(await iterator.next()))

        #expect(notification.method == "update")
        let params = try #require(notification.params?.arrayValue)
        #expect(params.count == 2)
        #expect(try monitorId(of: notification) == "mon1")
    }

    @Test("A notification with no id key at all is dispatched")
    func notificationWithoutIdKeyIsDispatched() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        try channel.writeInbound(#"{"method":"update","params":["mon2",{}]}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = notification(await iterator.next())
        #expect(notification?.method == "update")
    }

    @Test("Notifications are buffered between reads")
    func notificationsAreBufferedBetweenReads() async throws {
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
            let notification = try #require(
                notification(await iterator.next()),
                "Missing buffered notification"
            )
            received.append(try monitorId(of: notification))
        }
        #expect(received == ["mon1", "mon2", "mon3"])
    }

    @Test("Every subscriber receives each notification")
    func everySubscriberReceivesEachNotification() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let first = hub.subscribe()
        let second = hub.subscribe()

        try channel.writeInbound(#"{"method":"update","params":["mon1",{}],"id":null}"#)

        var firstIterator = first.makeAsyncIterator()
        var secondIterator = second.makeAsyncIterator()
        let fromFirst = notification(await firstIterator.next())
        let fromSecond = notification(await secondIterator.next())
        #expect(fromFirst?.method == "update")
        #expect(fromSecond?.method == "update")
    }

    // MARK: - Bounded buffering

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
            let notification = try #require(
                notification(await iterator.next()),
                "Expected notification \(index)"
            )
            #expect(notification.params?.stringValue == "n\(index)")
        }
    }

    // MARK: - Subscribing after close

    @Test("Subscribing after close returns an already-finished stream")
    func subscribingAfterCloseReturnsAFinishedStream() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        channel.pipeline.fireChannelInactive()

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

    // MARK: - Server echo requests

    @Test("A server echo request gets a reply")
    func serverEchoRequestGetsReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":["ping"],"id":42}"#)

        let replyObject = try #require(
            try readOutboundObject(from: channel),
            "Expected an echo reply to be written"
        )
        #expect(replyObject["id"] as? Int == 42)
        #expect(replyObject["result"] as? [String] == ["ping"])
        #expect(replyObject["error"] is NSNull)
    }

    @Test("A server echo reply preserves a string id")
    func serverEchoReplyPreservesStringId() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":[],"id":"echo-7"}"#)

        let replyObject = try #require(
            try readOutboundObject(from: channel),
            "Expected an echo reply to be written"
        )
        #expect(replyObject["id"] as? String == "echo-7")
        #expect((replyObject["result"] as? [Any])?.count == 0)
    }

    @Test("An unknown server request produces no reply")
    func unknownServerRequestProducesNoReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"frobnicate","params":[],"id":9}"#)

        #expect(try channel.readOutbound(as: ByteBuffer.self) == nil)
    }

    // MARK: - Responses

    @Test("A response is routed to its pending request")
    func responseIsRoutedToPendingRequest() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(7),
            type: JSONRPCResponse<[String]>.self,
            timeout: .seconds(30)
        )

        try channel.writeInbound(#"{"id":7,"result":["OVN_Northbound"],"error":null}"#)

        let response = try future.wait()
        #expect(response.result == ["OVN_Northbound"])
        #expect(response.error == nil)
    }

    @Test("A timed-out request is removed and a late response is ignored")
    func timedOutRequestIsRemovedAndLateResponseIsIgnored() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(1),
            type: JSONRPCResponse<JSONValue>.self,
            timeout: .seconds(5)
        )

        channel.embeddedEventLoop.advanceTime(by: .seconds(5))

        let error = #expect(throws: OVNManagerError.self) { try future.wait() }
        #expect(error?.errorCase == .timeoutError)

        // A response arriving after the timeout must be ignored gracefully,
        // not fulfill the already-failed promise (which would crash) — so the
        // write below must not throw.
        try channel.writeInbound(#"{"id":1,"result":{},"error":null}"#)
    }

    // MARK: - Connection loss

    @Test("Channel inactive fails pending requests")
    func channelInactiveFailsPendingRequests() throws {
        let (channel, _, router) = makeChannel()
        defer { _ = try? channel.finish() }

        let future = router.waitForResponse(
            requestId: .number(3),
            type: JSONRPCResponse<JSONValue>.self,
            timeout: .seconds(30)
        )

        channel.pipeline.fireChannelInactive()

        let error = #expect(throws: OVNManagerError.self) { try future.wait() }
        #expect(error?.errorCase == .connectionFailed)
    }

    @Test("Channel inactive finishes notification streams")
    func channelInactiveFinishesNotificationStreams() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        channel.pipeline.fireChannelInactive()

        var iterator = stream.makeAsyncIterator()
        let value = await iterator.next()
        #expect(value == nil, "Stream should finish when the connection closes")
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
