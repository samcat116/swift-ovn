import XCTest
import NIO
import Logging
@testable import SwiftOVN

/// Tests for the inbound JSON-RPC message routing: notifications (null/absent
/// id) reach subscribers, server `echo` requests are answered, responses are
/// matched to pending requests, and connection loss fails everything cleanly.
final class MessageRoutingTests: XCTestCase {

    private func makeChannel() -> (channel: EmbeddedChannel, hub: JSONRPCNotificationHub, router: JSONRPCResponseRouter) {
        let hub = JSONRPCNotificationHub()
        let loop = EmbeddedEventLoop()
        let router = JSONRPCResponseRouter(
            logger: Logger(label: "test"),
            eventLoopGroup: loop,
            notificationHub: hub
        )
        let channel = EmbeddedChannel(handler: router, loop: loop)
        return (channel, hub, router)
    }

    // MARK: - Notifications

    func testUpdateNotificationWithNullIdIsDispatched() async throws {
        let (channel, hub, _) = makeChannel()
        defer { _ = try? channel.finish() }

        let stream = hub.subscribe()

        // Real ovsdb-server update notifications carry "id": null.
        try channel.writeInbound(#"{"method":"update","params":["mon1",{"Logical_Switch":{"aa-bb":{"new":{"name":"ls0"}}}}],"id":null}"#)

        var iterator = stream.makeAsyncIterator()
        let notification = await iterator.next()

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
        let notification = await iterator.next()
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
            guard let notification = await iterator.next(),
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
        let fromFirst = await firstIterator.next()
        let fromSecond = await secondIterator.next()
        XCTAssertEqual(fromFirst?.method, "update")
        XCTAssertEqual(fromSecond?.method, "update")
    }

    // MARK: - Server echo requests

    func testServerEchoRequestGetsReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":["ping"],"id":42}"#)

        guard let reply = try channel.readOutbound(as: String.self) else {
            XCTFail("Expected an echo reply to be written")
            return
        }

        let replyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        XCTAssertEqual(replyObject["id"] as? Int, 42)
        XCTAssertEqual(replyObject["result"] as? [String], ["ping"])
        XCTAssertTrue(replyObject["error"] is NSNull)
    }

    func testServerEchoReplyPreservesStringId() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"echo","params":[],"id":"echo-7"}"#)

        guard let reply = try channel.readOutbound(as: String.self) else {
            XCTFail("Expected an echo reply to be written")
            return
        }

        let replyObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any]
        )
        XCTAssertEqual(replyObject["id"] as? String, "echo-7")
        XCTAssertEqual((replyObject["result"] as? [Any])?.count, 0)
    }

    func testUnknownServerRequestProducesNoReply() throws {
        let (channel, _, _) = makeChannel()
        defer { _ = try? channel.finish() }

        try channel.writeInbound(#"{"method":"frobnicate","params":[],"id":9}"#)

        XCTAssertNil(try channel.readOutbound(as: String.self))
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
