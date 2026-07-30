import Foundation
import Testing
import Synchronization
import NIO
import NIOPosix
@testable import SwiftOVN

// MARK: - Request encoding

@Suite("Conditional monitor requests")
struct ConditionalMonitorRequestTests {

    @Test("A monitor request encodes its conditions as 'where'")
    func monitorRequestEncodesConditions() throws {
        let requests = [
            "Logical_Flow": OVSDBMonitorRequest(
                columns: ["match", "actions"],
                whereConditions: [
                    OVSDBCondition(column: "logical_datapath", function: "==", value: .string("dp-1"))
                ]
            ),
        ]

        let json = try JSONValueEncoder.encode(requests)

        #expect(json == .object([
            "Logical_Flow": .object([
                "columns": .array([.string("match"), .string("actions")]),
                "where": .array([
                    .array([.string("logical_datapath"), .string("=="), .string("dp-1")]),
                ]),
            ]),
        ]))
    }

    @Test("A request without conditions omits 'where' entirely")
    func requestWithoutConditionsOmitsWhere() throws {
        let json = try JSONValueEncoder.encode(["Logical_Switch": OVSDBMonitorRequest(columns: ["name"])])
        let request = try #require(json.objectValue?["Logical_Switch"]?.objectValue)

        #expect(request.keys.sorted() == ["columns"])
    }

    /// Plain `monitor` fails the whole request over an unexpected member, so the
    /// conditions have to be removed rather than left empty.
    @Test("Dropping conditions leaves the rest of the request intact")
    func droppingConditionsKeepsColumnsAndSelect() throws {
        let request = OVSDBMonitorRequest(
            columns: ["name"],
            select: OVSDBMonitorSelect(initial: true, insert: false, delete: false, modify: false),
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("ls0"))]
        )

        let stripped = request.droppingConditions()
        #expect(stripped.whereConditions == nil)
        #expect(stripped.columns == ["name"])
        #expect(stripped.select?.initial == true)

        let json = try JSONValueEncoder.encode(stripped)
        #expect(json.objectValue?["where"] == nil)
    }

    @Test("A round trip keeps the conditions")
    func monitorRequestRoundTripsConditions() throws {
        let request = OVSDBMonitorRequest(
            whereConditions: [OVSDBCondition(column: "name", function: "!=", value: .string("ls0"))]
        )

        let decoded = try JSONDecoder().decode(
            OVSDBMonitorRequest.self,
            from: JSONEncoder().encode(request)
        )

        #expect(decoded.whereConditions?.count == 1)
        #expect(decoded.whereConditions?.first?.column == "name")
        #expect(decoded.whereConditions?.first?.function == "!=")
        #expect(decoded.whereConditions?.first?.value == .string("ls0"))
    }
}

// MARK: - Row update2 parsing

/// `<row-update2>` names its change instead of pairing `old` with `new`, and a
/// `modify` carries only the columns that changed.
@Suite("Table updates2 parsing")
struct TableUpdates2ParsingTests {

    private func updates(_ json: String) throws -> [OVSDBUpdate] {
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        return OVSDBConnection.parseTableUpdates2(value)
    }

    @Test("Each row update reports its own kind")
    func rowUpdatesReportTheirKind() throws {
        let parsed = try updates(#"""
        {
          "Logical_Switch": {
            "uuid-initial": {"initial": {"name": "ls0"}},
            "uuid-insert": {"insert": {"name": "ls1"}},
            "uuid-delete": {"delete": null}
          },
          "Logical_Switch_Port": {
            "uuid-modify": {"modify": {"addresses": ["set", [["uuid", "a1"]]]}}
          }
        }
        """#)

        #expect(parsed.count == 4)

        let initial = try #require(parsed.first { $0.uuid == "uuid-initial" })
        #expect(initial.kind == .initial)
        #expect(initial.table == "Logical_Switch")
        #expect(initial.new == ["name": .string("ls0")])
        #expect(initial.diff == nil)

        let insert = try #require(parsed.first { $0.uuid == "uuid-insert" })
        #expect(insert.kind == .insert)
        #expect(insert.new == ["name": .string("ls1")])

        // ovsdb-server sends `"delete": null`: the client is assumed to hold the
        // row already, so there is no `old` to report and inventing one would be
        // a lie.
        let delete = try #require(parsed.first { $0.uuid == "uuid-delete" })
        #expect(delete.kind == .delete)
        #expect(delete.old == nil)
        #expect(delete.new == nil)

        let modify = try #require(parsed.first { $0.uuid == "uuid-modify" })
        #expect(modify.kind == .modify)
        #expect(modify.table == "Logical_Switch_Port")
        #expect(modify.old == nil)
        #expect(modify.new == nil)
        #expect(modify.diff == ["addresses": .array([.string("set"), .array([.array([.string("uuid"), .string("a1")])])])])
    }

    @Test("A delete that does carry the row keeps it")
    func deleteCarryingTheRowKeepsIt() throws {
        let parsed = try updates(#"{"Logical_Switch": {"uuid-1": {"delete": {"name": "ls0"}}}}"#)

        let delete = try #require(parsed.first)
        #expect(delete.kind == .delete)
        #expect(delete.old == ["name": .string("ls0")])
    }

    @Test("A row update naming no change is skipped")
    func rowUpdateWithoutAKnownMemberIsSkipped() throws {
        #expect(try updates(#"{"Logical_Switch": {"uuid-1": {"whatever": {}}}}"#).isEmpty)
    }

    @Test("A payload that is not an object parses as nothing")
    func nonObjectPayloadParsesAsNothing() throws {
        #expect(OVSDBConnection.parseTableUpdates2(.string("nonsense")).isEmpty)
        #expect(OVSDBConnection.parseTableUpdates2(.null).isEmpty)
    }

    /// RFC 7047 makes an initial row look exactly like an insert, so only the
    /// reply's own parse can mark them.
    @Test("Legacy reply rows are marked initial, notification rows are not")
    func legacyReplyRowsAreMarkedInitial() throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"Logical_Switch": {"uuid-1": {"new": {"name": "ls0"}}}}"#.utf8)
        )

        let reply = OVSDBConnection.parseTableUpdates(value, method: .monitor, isReply: true)
        #expect(reply.first?.kind == .initial)
        #expect(reply.first?.new == ["name": .string("ls0")])

        let notification = OVSDBConnection.parseTableUpdates(value, method: .monitor)
        #expect(notification.first?.kind == .insert)
    }

    @Test("The method picks the parse", arguments: [
        OVSDBMonitorMethod.monitorCond, .monitorCondSince,
    ])
    func conditionalMethodsParseRowUpdate2(_ method: OVSDBMonitorMethod) throws {
        let value = try JSONDecoder().decode(
            JSONValue.self,
            from: Data(#"{"Logical_Switch": {"uuid-1": {"modify": {"name": "ls9"}}}}"#.utf8)
        )

        let parsed = OVSDBConnection.parseTableUpdates(value, method: method, isReply: true)
        #expect(parsed.first?.kind == .modify)
        #expect(parsed.first?.diff == ["name": .string("ls9")])
    }

    /// `kind` post-dates the type; an encoded update written without it still has
    /// to decode.
    @Test("An update decodes without a kind by deriving it")
    func updateDecodesWithoutAKind() throws {
        let decoded = try JSONDecoder().decode(
            OVSDBUpdate.self,
            from: Data(#"{"table": "Logical_Switch", "uuid": "uuid-1", "old": {"name": "ls0"}}"#.utf8)
        )

        #expect(decoded.kind == .delete)
        #expect(decoded.old == ["name": .string("ls0")])
    }

    @Test("An update round trips its kind and diff")
    func updateRoundTripsKindAndDiff() throws {
        let update = OVSDBUpdate(
            table: "Logical_Flow",
            uuid: "uuid-1",
            kind: .modify,
            diff: ["match": .string("ip4.dst == 10.0.0.1")]
        )

        let decoded = try JSONDecoder().decode(OVSDBUpdate.self, from: JSONEncoder().encode(update))
        #expect(decoded.kind == .modify)
        #expect(decoded.diff == update.diff)
        #expect(decoded.old == nil)
        #expect(decoded.new == nil)
    }
}

// MARK: - Error shapes

/// RFC 7047 is JSON-RPC 1.0, whose `error` member is an arbitrary value, and
/// ovsdb-server uses that latitude. Decoding by synthesis failed on every one of
/// these shapes, which buried the server's reason under a `decodingError`.
@Suite("JSON-RPC error shapes")
struct JSONRPCErrorShapeTests {

    private func error(_ json: String) throws -> JSONRPCError {
        return try JSONDecoder().decode(JSONRPCError.self, from: Data(json.utf8))
    }

    @Test("A bare string error decodes and is recognized as an unknown method")
    func bareStringError() throws {
        let decoded = try error(#""unknown method""#)

        #expect(decoded.message == "unknown method")
        #expect(decoded.code == JSONRPCError.noCode)
        #expect(decoded.isUnknownMethod)
    }

    @Test("An ovsdb error object keeps its name and details")
    func ovsdbErrorObject() throws {
        let decoded = try error(#"{"error": "constraint violation", "details": "row is referenced"}"#)

        #expect(decoded.message == "constraint violation: row is referenced")
        #expect(!decoded.isUnknownMethod)
        #expect(decoded.data?.objectValue?["details"] == .string("row is referenced"))
    }

    @Test("A JSON-RPC 2.0 error keeps its code, message and data")
    func jsonRPC2Error() throws {
        let decoded = try error(#"{"code": -32601, "message": "Method not found", "data": "monitor_cond_since"}"#)

        #expect(decoded.code == -32601)
        #expect(decoded.message == "Method not found")
        #expect(decoded.data == .string("monitor_cond_since"))
        #expect(decoded.isUnknownMethod)
    }

    @Test("An error of an unexpected shape still decodes")
    func unexpectedShapeError() throws {
        let decoded = try error(#"["unknown method", 2]"#)

        #expect(!decoded.message.isEmpty)
        #expect(decoded.data?.arrayValue?.count == 2)
    }

    /// The whole point: an error reply used to fail to decode as a *response*,
    /// so the caller never saw the server's reason at all.
    @Test("A response carrying an ovsdb error decodes")
    func responseCarryingAnOVSDBErrorDecodes() throws {
        let response = try JSONDecoder().decode(
            JSONRPCResponse<JSONValue>.self,
            from: Data(#"{"id": 3, "result": null, "error": "unknown method"}"#.utf8)
        )

        #expect(response.result == nil)
        #expect(response.error?.isUnknownMethod == true)
    }
}

// MARK: - Monitor methods

@Suite("Monitor methods")
struct OVSDBMonitorMethodTests {

    @Test("Each method names its RPC and its notification")
    func methodsNameTheirWireForms() {
        #expect(OVSDBMonitorMethod.monitor.rpcMethod == "monitor")
        #expect(OVSDBMonitorMethod.monitorCond.rpcMethod == "monitor_cond")
        #expect(OVSDBMonitorMethod.monitorCondSince.rpcMethod == "monitor_cond_since")

        for method in OVSDBMonitorMethod.allCases {
            #expect(OVSDBMonitorMethod(notificationMethod: method.notificationMethod) == method)
        }
        #expect(OVSDBMonitorMethod(notificationMethod: "locked") == nil)
    }

    @Test("The fallback chain runs from most to least capable and stops at monitor")
    func fallbackChainEndsAtMonitor() {
        #expect(OVSDBMonitorMethod.monitorCondSince.fallback == .monitorCond)
        #expect(OVSDBMonitorMethod.monitorCond.fallback == .monitor)
        #expect(OVSDBMonitorMethod.monitor.fallback == nil)
    }

    @Test("Only the conditional methods use row-update2")
    func onlyConditionalMethodsUseRowUpdate2() {
        #expect(!OVSDBMonitorMethod.monitor.usesRowUpdate2)
        #expect(OVSDBMonitorMethod.monitorCond.usesRowUpdate2)
        #expect(OVSDBMonitorMethod.monitorCondSince.usesRowUpdate2)
    }
}

// MARK: - Negotiation and resume

@Suite("Conditional monitoring")
struct ConditionalMonitoringTests {

    private static let datapathCondition = OVSDBCondition(
        column: "logical_datapath",
        function: "==",
        value: .string("dp-1")
    )

    private func filteredTables() -> [String: OVSDBMonitorRequest] {
        return ["Logical_Flow": OVSDBMonitorRequest(whereConditions: [Self.datapathCondition])]
    }

    @Test("monitor_cond_since is preferred, and its reply is a resumable delta")
    func monitorCondSinceIsPreferred() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        let session = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )

        #expect(transport.requestedMethods == ["monitor_cond_since"])
        #expect(session.method == .monitorCondSince)
        #expect(session.resumed)
        #expect(session.lastTransactionId == MonitorStubTransport.replyTransactionId)
        #expect(session.initialUpdates.count == 1)
        #expect(session.initialUpdates.first?.kind == .initial)

        // Nothing to resume from yet, so the all-zero transaction id goes out.
        let params = try #require(transport.requests.first?.params)
        #expect(params.count == 4)
        #expect(params[3] == .string(OVSDBMonitorMethod.initialTransactionId))
        #expect(params[2].objectValue?["Logical_Flow"]?.objectValue?["where"] != nil)

        let tracked = await connection.lastTransactionId(forMonitor: "mon-1")
        #expect(tracked == MonitorStubTransport.replyTransactionId)
    }

    @Test("A resume point is sent as last-txn-id")
    func resumePointIsSent() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            since: "txn-42"
        )

        #expect(transport.requests.first?.params.last == .string("txn-42"))
    }

    /// A server that cannot resume answers `found: false` and sends everything;
    /// the caller has to be able to tell, because merging a full snapshot into
    /// resumed state would silently keep rows that are gone.
    @Test("A server that cannot resume reports a full snapshot")
    func serverThatCannotResumeReportsAFullSnapshot() async throws {
        let transport = MonitorStubTransport(resumes: false)
        let connection = OVSDBConnection(transport: transport)

        let session = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            since: "txn-42"
        )

        #expect(!session.resumed)
        #expect(session.method == .monitorCondSince)
    }

    @Test("An old server falls back to monitor_cond")
    func fallsBackToMonitorCond() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since"])
        let connection = OVSDBConnection(transport: transport)

        let session = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1",
            since: "txn-42"
        )

        #expect(transport.requestedMethods == ["monitor_cond_since", "monitor_cond"])
        #expect(session.method == .monitorCond)
        // monitor_cond cannot resume, so the requested `since` was not honored and
        // the reply is a snapshot — said plainly rather than implied.
        #expect(!session.resumed)
        #expect(session.lastTransactionId == nil)
        #expect(session.initialUpdates.first?.kind == .initial)

        let method = await connection.monitorMethod(forMonitor: "mon-1")
        #expect(method == .monitorCond)
    }

    @Test("Feature detection happens once per connection")
    func featureDetectionHappensOnce() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since"])
        let connection = OVSDBConnection(transport: transport)

        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )
        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-2"
        )

        #expect(transport.requestedMethods == ["monitor_cond_since", "monitor_cond", "monitor_cond"])
    }

    @Test("An unfiltered monitor falls all the way back to monitor")
    func unfilteredMonitorFallsBackToMonitor() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since", "monitor_cond"])
        let connection = OVSDBConnection(transport: transport)

        let session = try await connection.startConditionalMonitoring(
            database: "OVN_Northbound",
            tables: ["Logical_Switch": OVSDBMonitorRequest(columns: ["name"], whereConditions: [])]
        )

        #expect(transport.requestedMethods == ["monitor_cond_since", "monitor_cond", "monitor"])
        #expect(session.method == .monitor)
        // The reply is in old/new form, and its rows are the ones that already
        // existed.
        #expect(session.initialUpdates.first?.kind == .initial)
        #expect(session.initialUpdates.first?.new != nil)

        // Even an empty condition list cannot be sent to `monitor`: ovsdb-server
        // fails the request over the unexpected member.
        let monitorRequest = try #require(transport.requests.last?.params)
        #expect(monitorRequest[2].objectValue?["Logical_Switch"]?.objectValue?["where"] == nil)
    }

    /// Downgrading a filtered monitor would deliver every row of the table as
    /// though it matched, which is worse than failing.
    @Test("A filtered monitor is refused rather than downgraded to monitor")
    func filteredMonitorIsRefusedRatherThanDowngraded() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since", "monitor_cond"])
        let connection = OVSDBConnection(transport: transport)

        let error = await #expect(throws: OVNManagerError.self) {
            try await connection.startConditionalMonitoring(
                database: "OVN_Southbound",
                tables: self.filteredTables(),
                monitorId: "mon-1"
            )
        }

        #expect(error?.errorCase == .operationFailed)
        #expect(transport.requestedMethods == ["monitor_cond_since", "monitor_cond"])

        // A monitor that never started must not be left registered, or a
        // disconnect would try to cancel it.
        let method = await connection.monitorMethod(forMonitor: "mon-1")
        #expect(method == nil)
    }

    /// Once the server is known to support neither conditional method, a filtered
    /// request is refused without a round trip.
    @Test("A filtered monitor is refused outright on a known-old server")
    func filteredMonitorIsRefusedOutrightOnAKnownOldServer() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since", "monitor_cond"])
        let connection = OVSDBConnection(transport: transport)

        // Negotiates all the way down to `monitor`, which this unfiltered request
        // can be served by.
        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Northbound",
            tables: ["Logical_Switch": OVSDBMonitorRequest()]
        )
        let afterNegotiation = transport.requestedMethods

        let error = await #expect(throws: OVNManagerError.self) {
            try await connection.startConditionalMonitoring(
                database: "OVN_Southbound",
                tables: self.filteredTables()
            )
        }

        #expect(error?.errorCase == .operationFailed)
        #expect(transport.requestedMethods == afterNegotiation)
    }

    /// Any other error is the server's answer, not a reason to try a weaker
    /// method.
    @Test("An error that is not 'unknown method' is not a fallback signal")
    func otherErrorsAreNotFallbackSignals() async throws {
        let transport = MonitorStubTransport(failingMethods: ["monitor_cond_since"])
        let connection = OVSDBConnection(transport: transport)

        let error = await #expect(throws: OVNManagerError.self) {
            try await connection.startConditionalMonitoring(
                database: "OVN_Southbound",
                tables: self.filteredTables()
            )
        }

        #expect(error?.errorCase == .rpcError)
        #expect(transport.requestedMethods == ["monitor_cond_since"])
    }

    @Test("Changing conditions sends monitor_cond_change with only 'where'")
    func changingConditionsSendsOnlyWhere() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )
        try await connection.updateMonitorConditions(
            monitorId: "mon-1",
            conditions: ["Logical_Flow": [Self.datapathCondition]]
        )

        let change = try #require(transport.requests.last)
        #expect(change.method == "monitor_cond_change")
        #expect(change.params.count == 3)
        // The same monitor ID twice: the monitor is not being renamed.
        #expect(change.params[0] == .string("mon-1"))
        #expect(change.params[1] == .string("mon-1"))
        #expect(change.params[2] == .object([
            "Logical_Flow": .object([
                "where": .array([
                    .array([.string("logical_datapath"), .string("=="), .string("dp-1")]),
                ]),
            ]),
        ]))
    }

    @Test("Changing the conditions of a plain monitor is refused")
    func changingConditionsOfAPlainMonitorIsRefused() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        _ = try await connection.startMonitoring(
            database: "OVN_Northbound",
            tables: ["Logical_Switch": OVSDBMonitorRequest()],
            monitorId: "mon-1"
        )

        let error = await #expect(throws: OVNManagerError.self) {
            try await connection.updateMonitorConditions(
                monitorId: "mon-1",
                conditions: ["Logical_Switch": []]
            )
        }
        #expect(error?.errorCase == .operationFailed)
        #expect(!transport.requestedMethods.contains("monitor_cond_change"))
    }

    @Test("Changing the conditions of an unknown monitor is refused")
    func changingConditionsOfAnUnknownMonitorIsRefused() async throws {
        let connection = OVSDBConnection(transport: MonitorStubTransport())

        let error = await #expect(throws: OVNManagerError.self) {
            try await connection.updateMonitorConditions(monitorId: "nope", conditions: [:])
        }
        #expect(error?.errorCase == .operationFailed)
    }

    @Test("update3 batches carry the transaction id and advance the resume point")
    func update3BatchesCarryTheTransactionId() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        // Subscribed before the monitor is started, so nothing can be missed.
        let batches = connection.monitorTableUpdates(monitorId: "mon-1")
        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )

        transport.publish(MonitorStubTransport.update3(
            monitorId: "mon-1",
            transactionId: "txn-99",
            tableUpdates: .object([
                "Logical_Flow": .object([
                    "uuid-1": .object(["modify": .object(["match": .string("ip4.dst == 10.0.0.1")])]),
                ]),
            ])
        ))

        var iterator = batches.makeAsyncIterator()
        let batch = try #require(try await iterator.next())

        #expect(batch.monitorId == "mon-1")
        #expect(batch.method == .monitorCondSince)
        #expect(batch.lastTransactionId == "txn-99")
        #expect(batch.updates.count == 1)
        #expect(batch.updates.first?.kind == .modify)
        #expect(batch.updates.first?.diff == ["match": .string("ip4.dst == 10.0.0.1")])

        let tracked = await connection.lastTransactionId(forMonitor: "mon-1")
        #expect(tracked == "txn-99")
    }

    @Test("Batches are filtered by monitor ID")
    func batchesAreFilteredByMonitorId() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        let batches = connection.monitorTableUpdates(monitorId: "mon-2")
        transport.publish(MonitorStubTransport.update3(
            monitorId: "mon-1",
            transactionId: "txn-1",
            tableUpdates: .object(["Logical_Flow": .object(["uuid-1": .object(["insert": .object([:])])])])
        ))
        transport.publish(MonitorStubTransport.update3(
            monitorId: "mon-2",
            transactionId: "txn-2",
            tableUpdates: .object(["Logical_Flow": .object(["uuid-2": .object(["insert": .object([:])])])])
        ))

        var iterator = batches.makeAsyncIterator()
        let batch = try #require(try await iterator.next())
        #expect(batch.monitorId == "mon-2")
        #expect(batch.updates.first?.uuid == "uuid-2")
    }

    /// A consumer that upgrades to a conditional monitor but keeps using the
    /// per-row stream still sees its rows, rather than silently nothing.
    @Test("update2 rows reach the per-row stream")
    func update2RowsReachThePerRowStream() async throws {
        let transport = MonitorStubTransport()
        let connection = OVSDBConnection(transport: transport)

        let updates = connection.monitorUpdates()
        transport.publish(JSONRPCNotification(
            method: "update2",
            params: .array([
                .string("mon-1"),
                .object([
                    "Logical_Switch": .object([
                        "uuid-1": .object(["modify": .object(["name": .string("ls9")])]),
                    ]),
                ]),
            ])
        ))

        var iterator = updates.makeAsyncIterator()
        let update = try #require(try await iterator.next())
        #expect(update.kind == .modify)
        #expect(update.diff == ["name": .string("ls9")])
    }

    @Test("Notifications are tagged with the method that produced them")
    func notificationsAreTaggedWithTheirMethod() async throws {
        let transport = MonitorStubTransport()
        let client = JSONRPCClient(transport: transport)

        let notifications = client.monitorNotifications()
        transport.publish(JSONRPCNotification(
            method: "update",
            params: .array([.string("mon-1"), .object([:])])
        ))
        transport.publish(JSONRPCNotification(
            method: "update2",
            params: .array([.string("mon-2"), .object([:])])
        ))
        transport.publish(MonitorStubTransport.update3(
            monitorId: "mon-3",
            transactionId: "txn-1",
            tableUpdates: .object([:])
        ))
        // Not a monitor notification, and not correctly shaped: neither may reach
        // the consumer.
        transport.publish(JSONRPCNotification(method: "locked", params: .array([.string("lock-1")])))
        transport.publish(JSONRPCNotification(method: "update3", params: .array([.string("mon-4")])))
        transport.finish()

        var received: [(String, OVSDBMonitorMethod, String?)] = []
        for try await notification in notifications {
            received.append((notification.monitorId, notification.method, notification.lastTransactionId))
        }

        #expect(received.count == 3)
        #expect(received.map(\.0) == ["mon-1", "mon-2", "mon-3"])
        #expect(received.map(\.1) == [.monitor, .monitorCond, .monitorCondSince])
        #expect(received.map(\.2) == [nil, nil, "txn-1"])
    }

    @Test("Disconnecting forgets the negotiated method")
    func disconnectingForgetsTheNegotiatedMethod() async throws {
        let transport = MonitorStubTransport(unsupportedMethods: ["monitor_cond_since"])
        let connection = OVSDBConnection(transport: transport)

        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )
        try await connection.disconnect()

        // A reconnect may land on a different member of a clustered database, so
        // the probe runs again rather than assuming the last server's answer.
        _ = try await connection.startConditionalMonitoring(
            database: "OVN_Southbound",
            tables: filteredTables(),
            monitorId: "mon-1"
        )

        #expect(transport.requestedMethods == [
            "monitor_cond_since", "monitor_cond", "monitor_cancel", "monitor_cond_since", "monitor_cond",
        ])
    }
}

// MARK: - Manager surface

/// The manager methods are thin forwarders, but a forwarder that reaches the
/// wrong stream or loses the transaction id is exactly the kind of mistake that
/// only shows up end to end.
///
/// A `final class` rather than a `struct` so the per-test event loop group can be
/// torn down in `deinit`.
@Suite("Conditional monitoring through a manager")
final class ManagerConditionalMonitoringTests {

    private let group: MultiThreadedEventLoopGroup

    init() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    deinit {
        // Asynchronously, and never `syncShutdownGracefully()` — see the note on
        // `MessageRoutingTests.deinit`. This also closes the test server.
        group.shutdownGracefully { _ in }
    }

    @Test("A manager starts a conditional monitor and streams its batches")
    func managerStartsAConditionalMonitor() async throws {
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(JSONRPCStubServerHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(server.localAddress?.port)

        let manager = OVNManager(
            endpoint: .tcp(host: "127.0.0.1", port: port),
            database: OVNDatabase.southbound,
            eventLoopGroup: group
        )
        try await manager.connect()

        let batches = manager.monitorTableUpdates(monitorId: "mon-1")
        let session = try await manager.startConditionalMonitoring(
            tables: [
                "Logical_Flow": OVSDBMonitorRequest(
                    whereConditions: [
                        OVSDBCondition(column: "logical_datapath", function: "==", value: .string("dp-1"))
                    ]
                ),
            ],
            monitorId: "mon-1"
        )

        #expect(session.method == .monitorCondSince)
        #expect(session.lastTransactionId == JSONRPCStubServerHandler.replyTransactionId)

        var iterator = batches.makeAsyncIterator()
        let batch = try #require(try await iterator.next())
        #expect(batch.monitorId == "mon-1")
        #expect(batch.lastTransactionId == JSONRPCStubServerHandler.notificationTransactionId)
        #expect(batch.updates.first?.kind == .modify)

        let resumePoint = await manager.lastTransactionId(forMonitor: "mon-1")
        #expect(resumePoint == JSONRPCStubServerHandler.notificationTransactionId)

        try await manager.disconnect()
    }
}

// MARK: - Stub transport

/// An `OVSDBTransport` that answers monitor requests the way ovsdb-server does —
/// including its JSON-RPC 1.0 error replies, which are a bare string rather than
/// a `{code, message}` object — and can push notifications on demand.
///
/// Replies are built as JSON and decoded into the caller's response type, so the
/// tests run the same encode/decode path a real server's bytes would, rather
/// than handing back pre-made Swift values.
private final class MonitorStubTransport: OVSDBTransport {
    struct Request: Sendable {
        let method: String
        let params: [JSONValue]
    }

    /// The transaction id every `monitor_cond_since` reply reports.
    static let replyTransactionId = "5f2e9d1c-0000-4000-8000-000000000001"

    private struct State {
        var requests: [Request] = []
        var subscribers: [AsyncStream<JSONRPCNotificationEvent>.Continuation] = []
    }

    /// Methods answered with ovsdb-server's `unknown method` error.
    private let unsupportedMethods: Set<String>
    /// Methods answered with an error that is *not* about the method being
    /// unknown.
    private let failingMethods: Set<String>
    /// What `monitor_cond_since` reports as `found`.
    private let resumes: Bool
    private let state = Mutex(State())

    init(
        unsupportedMethods: Set<String> = [],
        failingMethods: Set<String> = [],
        resumes: Bool = true
    ) {
        self.unsupportedMethods = unsupportedMethods
        self.failingMethods = failingMethods
        self.resumes = resumes
    }

    var requests: [Request] {
        return state.withLock { $0.requests }
    }

    var requestedMethods: [String] {
        return requests.map(\.method)
    }

    // MARK: Transport

    func connect() async throws {}

    func disconnect() async throws {
        finish()
    }

    func send<T: Codable & Sendable>(_ message: T) async throws {}

    func sendRequest<Outbound: Codable & Sendable, Response: Codable & Sendable>(
        _ request: Outbound,
        id: JSONRPCIdentifier,
        responseType: Response.Type,
        timeout: TimeAmount
    ) async throws -> Response {
        let wire = try JSONDecoder().decode(WireRequest.self, from: JSONEncoder().encode(request))
        let params = wire.params?.arrayValue ?? []
        state.withLock { $0.requests.append(Request(method: wire.method, params: params)) }

        let reply: JSONValue = .object([
            "id": wire.id ?? .null,
            "result": error(for: wire.method) == nil ? result(for: wire.method) : .null,
            "error": error(for: wire.method) ?? .null,
        ])

        return try JSONDecoder().decode(Response.self, from: JSONEncoder().encode(reply))
    }

    func notifications() -> AsyncStream<JSONRPCNotification> {
        let events = notificationEvents()
        return AsyncStream { continuation in
            let task = Task {
                for await event in events {
                    guard case .notification(let notification) = event else { continue }
                    continuation.yield(notification)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func notificationEvents() -> AsyncStream<JSONRPCNotificationEvent> {
        return AsyncStream { continuation in
            state.withLock { $0.subscribers.append(continuation) }
        }
    }

    var isConnectionActive: Bool { true }

    // MARK: Notifications

    func publish(_ notification: JSONRPCNotification) {
        let subscribers = state.withLock { $0.subscribers }
        for subscriber in subscribers {
            subscriber.yield(.notification(notification))
        }
    }

    func finish() {
        let subscribers = state.withLock { subscribers -> [AsyncStream<JSONRPCNotificationEvent>.Continuation] in
            defer { subscribers.subscribers = [] }
            return subscribers.subscribers
        }
        for subscriber in subscribers {
            subscriber.finish()
        }
    }

    static func update3(monitorId: String, transactionId: String, tableUpdates: JSONValue) -> JSONRPCNotification {
        return JSONRPCNotification(
            method: "update3",
            params: .array([.string(monitorId), .string(transactionId), tableUpdates])
        )
    }

    // MARK: Replies

    private func error(for method: String) -> JSONValue? {
        if unsupportedMethods.contains(method) {
            return .string("unknown method")
        }
        if failingMethods.contains(method) {
            return .object([
                "error": .string("syntax error"),
                "details": .string("stub rejected \(method)"),
            ])
        }
        return nil
    }

    private func result(for method: String) -> JSONValue {
        switch method {
        case "monitor":
            return Self.tableUpdates
        case "monitor_cond":
            return Self.tableUpdates2
        case "monitor_cond_since":
            return .array([.boolean(resumes), .string(Self.replyTransactionId), Self.tableUpdates2])
        case "monitor_cond_change":
            return .string("ok")
        default:
            return .object([:])
        }
    }

    /// One existing row, RFC 7047 form.
    private static let tableUpdates = JSONValue.object([
        "Logical_Switch": .object([
            "uuid-existing": .object(["new": .object(["name": .string("ls0")])]),
        ]),
    ])

    /// The same row, ovsdb-server(7) form.
    private static let tableUpdates2 = JSONValue.object([
        "Logical_Switch": .object([
            "uuid-existing": .object(["initial": .object(["name": .string("ls0")])]),
        ]),
    ])

    private struct WireRequest: Decodable {
        let method: String
        let params: JSONValue?
        let id: JSONValue?
    }
}
