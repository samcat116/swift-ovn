import XCTest
import NIO
@testable import SwiftOVN

final class OVNManagerTests: XCTestCase {
    
    func testJSONRPCRequest() throws {
        let request = JSONRPCRequest(
            method: "list_dbs",
            params: nil,
            id: .string("test-1")
        )
        
        XCTAssertEqual(request.method, "list_dbs")
        XCTAssertNil(request.params)
        
        if case .string(let id) = request.id {
            XCTAssertEqual(id, "test-1")
        } else {
            XCTFail("Expected string ID")
        }
    }
    
    func testJSONValueEncodingDecoding() throws {
        let testCases: [JSONValue] = [
            .null,
            .boolean(true),
            .number(42.5),
            .string("hello"),
            .array([.string("a"), .number(1), .boolean(false)]),
            .object(["key": .string("value"), "number": .number(123)])
        ]
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        for testValue in testCases {
            let encoded = try encoder.encode(testValue)
            let decoded = try decoder.decode(JSONValue.self, from: encoded)
            XCTAssertEqual(testValue, decoded)
        }
    }
    
    func testOVNLogicalSwitchCreation() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "test-switch",
            external_ids: ["test": "value"]
        )
        
        XCTAssertEqual(logicalSwitch.name, "test-switch")
        XCTAssertEqual(logicalSwitch.external_ids?["test"], "value")
        XCTAssertNil(logicalSwitch.uuid)
    }
    
    func testOVSBridgeCreation() throws {
        let bridge = OVSBridge(
            name: "br-test",
            fail_mode: "secure",
            external_ids: ["description": "Test bridge"]
        )
        
        XCTAssertEqual(bridge.name, "br-test")
        XCTAssertEqual(bridge.fail_mode, "secure")
        XCTAssertEqual(bridge.external_ids?["description"], "Test bridge")
    }
    
    func testOVSDBConditionCreation() throws {
        let condition = OVSDBCondition.equal(column: "name", to: "test-value")
        
        XCTAssertEqual(condition.column, "name")
        XCTAssertEqual(condition.function, "==")
        
        if case .string(let value) = condition.value {
            XCTAssertEqual(value, "test-value")
        } else {
            XCTFail("Expected string value")
        }
    }
    
    func testOVSDBMutationCreation() throws {
        let mutation = OVSDBMutation.add(column: "count", value: 5)
        
        XCTAssertEqual(mutation.column, "count")
        XCTAssertEqual(mutation.mutator, "+=")
        
        if case .number(let value) = mutation.value {
            XCTAssertEqual(value, 5.0)
        } else {
            XCTFail("Expected number value")
        }
    }
    
    func testJSONValueSetHandling() throws {
        let stringSet = JSONValue.set(["a", "b", "c"])
        let setValues = stringSet.setStringValues
        
        XCTAssertEqual(setValues?.count, 3)
        XCTAssertTrue(setValues?.contains("a") == true)
        XCTAssertTrue(setValues?.contains("b") == true)
        XCTAssertTrue(setValues?.contains("c") == true)
    }
    
    func testJSONValueMapHandling() throws {
        let stringMap = JSONValue.map(["key1": "value1", "key2": "value2"])
        let mapValues = stringMap.mapStringValues
        
        XCTAssertEqual(mapValues?.count, 2)
        XCTAssertEqual(mapValues?["key1"], "value1")
        XCTAssertEqual(mapValues?["key2"], "value2")
    }
    
    func testJSONValueUUIDHandling() throws {
        let uuidValue = JSONValue.uuid("12345678-1234-5678-9abc-123456789012")
        let extractedUUID = uuidValue.uuidValue
        
        XCTAssertEqual(extractedUUID, "12345678-1234-5678-9abc-123456789012")
    }
    
    func testOVNACLCreation() throws {
        let acl = OVNACL(
            priority: 1000,
            direction: "to-lport",
            match: "ip4.src == 192.168.1.0/24",
            action: "allow",
            log: true,
            name: "test-acl"
        )
        
        XCTAssertEqual(acl.priority, 1000)
        XCTAssertEqual(acl.direction, "to-lport")
        XCTAssertEqual(acl.match, "ip4.src == 192.168.1.0/24")
        XCTAssertEqual(acl.action, "allow")
        XCTAssertEqual(acl.log, true)
        XCTAssertEqual(acl.name, "test-acl")
    }
    
    func testOVNLoadBalancerCreation() throws {
        let loadBalancer = OVNLoadBalancer(
            name: "test-lb",
            vips: ["192.168.1.100:80": "192.168.1.10:8080,192.168.1.11:8080"],
            protocolType: "tcp"
        )
        
        XCTAssertEqual(loadBalancer.name, "test-lb")
        XCTAssertEqual(loadBalancer.vips.count, 1)
        XCTAssertEqual(loadBalancer.vips["192.168.1.100:80"], "192.168.1.10:8080,192.168.1.11:8080")
        XCTAssertEqual(loadBalancer.protocolType, "tcp")
    }
    
    func testOVSFlowBuilder() throws {
        let flow = OVSFlowBuilder()
            .table(0)
            .priority(1000)
            .match("in_port=1")
            .actions("output:2")
            .idleTimeout(60)
            .build()
        
        XCTAssertEqual(flow.table, 0)
        XCTAssertEqual(flow.priority, 1000)
        XCTAssertEqual(flow.match, "in_port=1")
        XCTAssertEqual(flow.actions, "output:2")
        XCTAssertEqual(flow.idle_timeout, 60)
    }
    
    func testJSONRPCErrorHandling() throws {
        let error = JSONRPCError(
            code: -32600,
            message: "Invalid Request",
            data: .string("Additional error information")
        )
        
        XCTAssertEqual(error.code, -32600)
        XCTAssertEqual(error.message, "Invalid Request")
        
        if case .string(let data) = error.data {
            XCTAssertEqual(data, "Additional error information")
        } else {
            XCTFail("Expected string data")
        }
    }
    
    func testOVNManagerError() throws {
        let connectionError = OVNManagerError.connectionFailed("Socket not found")
        let timeoutError = OVNManagerError.timeoutError
        
        switch connectionError {
        case .connectionFailed(let message):
            XCTAssertEqual(message, "Socket not found")
        default:
            XCTFail("Expected connection failed error")
        }
        
        switch timeoutError {
        case .timeoutError:
            break // Expected
        default:
            XCTFail("Expected timeout error")
        }
    }
}

// MARK: - Mock Tests

final class JSONRPCClientMockTests: XCTestCase {
    
    func testJSONRPCRequestSerialization() throws {
        let request = JSONRPCRequest(
            method: "transact",
            params: .array([.string("OVN_Northbound"), .object(["op": .string("select"), "table": .string("Logical_Switch")])]),
            id: .number(1)
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(request)
        
        // Verify that the JSON can be decoded back
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(JSONRPCRequest.self, from: data)
        
        XCTAssertEqual(decodedRequest.method, request.method)
    }
    
    func testOVSDBOperationSerialization() throws {
        let operation = OVSDBOperation(
            op: "select",
            table: "Logical_Switch",
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("test"))],
            columns: ["name", "ports"]
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(operation)
        
        let decoder = JSONDecoder()
        let decodedOperation = try decoder.decode(OVSDBOperation.self, from: data)
        
        XCTAssertEqual(decodedOperation.op, operation.op)
        XCTAssertEqual(decodedOperation.table, operation.table)
        XCTAssertEqual(decodedOperation.columns, operation.columns)
    }
    
    func testOVSDBConditionEncodesAsArray() throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string("ls0"))

        let data = try JSONEncoder().encode(condition)
        let json = try JSONSerialization.jsonObject(with: data)

        XCTAssertEqual(json as? [String], ["name", "==", "ls0"])
    }

    func testOVSDBMutationEncodesAsArray() throws {
        // RFC 7047 requires mutations on the wire as [column, mutator, value],
        // not a keyed object — ovsdb-server rejects the object form.
        let mutation = OVSDBMutation(
            column: "ports",
            mutator: "insert",
            value: .array([.string("named-uuid"), .string("new_lsp")])
        )

        let data = try JSONEncoder().encode(mutation)
        let json = try JSONSerialization.jsonObject(with: data)

        guard let array = json as? [Any], array.count == 3 else {
            return XCTFail("Expected 3-element array, got \(json)")
        }
        XCTAssertEqual(array[0] as? String, "ports")
        XCTAssertEqual(array[1] as? String, "insert")
        XCTAssertEqual(array[2] as? [String], ["named-uuid", "new_lsp"])

        let decoded = try JSONDecoder().decode(OVSDBMutation.self, from: data)
        XCTAssertEqual(decoded.column, mutation.column)
        XCTAssertEqual(decoded.mutator, mutation.mutator)
        XCTAssertEqual(decoded.value, mutation.value)
    }

    func testOVSDBOperationEncodesUUIDNameAndWaitFields() throws {
        let insert = OVSDBOperation(
            op: "insert",
            table: "Logical_Switch_Port",
            row: ["name": .string("vm1-port")],
            uuidName: "new_lsp"
        )

        let insertJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as? [String: Any]
        XCTAssertEqual(insertJSON?["uuid-name"] as? String, "new_lsp")
        XCTAssertNil(insertJSON?["uuidName"])
        XCTAssertNil(insertJSON?["where"], "insert must not carry a where clause")

        let wait = OVSDBOperation(
            op: "wait",
            table: "Logical_Switch",
            whereConditions: [OVSDBCondition(column: "name", function: "==", value: .string("ls0"))],
            columns: ["name"],
            rows: [["name": .string("ls0")]],
            until: "==",
            timeout: 0
        )

        let waitJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wait)) as? [String: Any]
        XCTAssertEqual(waitJSON?["until"] as? String, "==")
        XCTAssertEqual(waitJSON?["timeout"] as? Int, 0)
        XCTAssertEqual((waitJSON?["rows"] as? [[String: Any]])?.first?["name"] as? String, "ls0")
        XCTAssertEqual((waitJSON?["where"] as? [[Any]])?.count, 1)
    }

    private func encodeOperations(_ operations: [OVSDBOperation]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(operations)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Operations did not encode as an array of objects")
            return []
        }
        return json
    }

    func testInsertAttachedTransactionWireFormat() throws {
        let operations = OVSDBReferenceTransactions.insertAttached(
            row: ["priority": .number(1000), "direction": .string("to-lport")],
            into: "ACL",
            uuidName: "new_acl",
            parentTable: "Logical_Switch",
            parentColumn: "acls",
            parentCondition: OVSDBCondition(column: "name", function: "==", value: .string("ls0"))
        )

        let json = try encodeOperations(operations)
        XCTAssertEqual(json.count, 3)

        // Op 0: wait guarding the parent's existence, aborting on mismatch
        XCTAssertEqual(json[0]["op"] as? String, "wait")
        XCTAssertEqual(json[0]["table"] as? String, "Logical_Switch")
        XCTAssertEqual(json[0]["until"] as? String, "==")
        XCTAssertEqual(json[0]["timeout"] as? Int, 0)
        XCTAssertEqual(json[0]["columns"] as? [String], ["name"])
        XCTAssertEqual((json[0]["rows"] as? [[String: Any]])?.first?["name"] as? String, "ls0")

        // Op 1: insert carrying the uuid-name for the mutate to reference
        XCTAssertEqual(json[1]["op"] as? String, "insert")
        XCTAssertEqual(json[1]["table"] as? String, "ACL")
        XCTAssertEqual(json[1]["uuid-name"] as? String, "new_acl")
        XCTAssertNil(json[1]["where"], "insert must not carry a where clause")

        // Op 2: mutate adding the named-uuid to the parent's reference set
        XCTAssertEqual(json[2]["op"] as? String, "mutate")
        XCTAssertEqual(json[2]["table"] as? String, "Logical_Switch")
        guard let mutation = (json[2]["mutations"] as? [[Any]])?.first, mutation.count == 3 else {
            return XCTFail("Expected one [column, mutator, value] mutation")
        }
        XCTAssertEqual(mutation[0] as? String, "acls")
        XCTAssertEqual(mutation[1] as? String, "insert")
        XCTAssertEqual(mutation[2] as? [String], ["named-uuid", "new_acl"])
    }

    func testInsertAttachedToRootParentSkipsWaitAndMatchesAllRows() throws {
        // The Open_vSwitch root table holds a single row that always exists:
        // no wait op, and the mutate's empty where matches that one row.
        let operations = OVSDBReferenceTransactions.insertAttached(
            row: ["name": .string("br0")],
            into: "Bridge",
            uuidName: "new_bridge",
            parentTable: "Open_vSwitch",
            parentColumn: "bridges",
            parentCondition: nil
        )

        let json = try encodeOperations(operations)
        XCTAssertEqual(json.count, 2)

        XCTAssertEqual(json[0]["op"] as? String, "insert")
        XCTAssertEqual(json[0]["uuid-name"] as? String, "new_bridge")

        XCTAssertEqual(json[1]["op"] as? String, "mutate")
        XCTAssertEqual(json[1]["table"] as? String, "Open_vSwitch")
        XCTAssertEqual((json[1]["where"] as? [Any])?.count, 0)
        guard let mutation = (json[1]["mutations"] as? [[Any]])?.first, mutation.count == 3 else {
            return XCTFail("Expected one [column, mutator, value] mutation")
        }
        XCTAssertEqual(mutation[0] as? String, "bridges")
        XCTAssertEqual(mutation[2] as? [String], ["named-uuid", "new_bridge"])
    }

    func testDeleteDetachingTransactionWireFormat() throws {
        let uuid = "5e9b0a79-6f38-4e5f-b112-3f0a35b4d2a1"
        let operations = OVSDBReferenceTransactions.deleteDetaching(
            uuid: uuid,
            from: "ACL",
            parentReferences: [
                OVSDBParentReference(table: "Logical_Switch", column: "acls"),
                OVSDBParentReference(table: "Port_Group", column: "acls")
            ]
        )

        let json = try encodeOperations(operations)
        XCTAssertEqual(json.count, 3)

        // Ops 0-1: one detach mutate per parent, selecting rows whose
        // reference set includes the uuid atom and removing it.
        for (index, expectedTable) in ["Logical_Switch", "Port_Group"].enumerated() {
            XCTAssertEqual(json[index]["op"] as? String, "mutate")
            XCTAssertEqual(json[index]["table"] as? String, expectedTable)

            guard let condition = (json[index]["where"] as? [[Any]])?.first, condition.count == 3 else {
                return XCTFail("Expected one [column, function, value] condition")
            }
            XCTAssertEqual(condition[0] as? String, "acls")
            XCTAssertEqual(condition[1] as? String, "includes")
            XCTAssertEqual(condition[2] as? [String], ["uuid", uuid])

            guard let mutation = (json[index]["mutations"] as? [[Any]])?.first, mutation.count == 3 else {
                return XCTFail("Expected one [column, mutator, value] mutation")
            }
            XCTAssertEqual(mutation[0] as? String, "acls")
            XCTAssertEqual(mutation[1] as? String, "delete")
            XCTAssertEqual(mutation[2] as? [String], ["uuid", uuid])
        }

        // Op 2: the row delete itself, in the same transaction
        XCTAssertEqual(json[2]["op"] as? String, "delete")
        XCTAssertEqual(json[2]["table"] as? String, "ACL")
        guard let deleteCondition = (json[2]["where"] as? [[Any]])?.first, deleteCondition.count == 3 else {
            return XCTFail("Expected one [column, function, value] condition")
        }
        XCTAssertEqual(deleteCondition[0] as? String, "_uuid")
        XCTAssertEqual(deleteCondition[1] as? String, "==")
        XCTAssertEqual(deleteCondition[2] as? [String], ["uuid", uuid])
    }

    func testInsertResultUUIDExtraction() throws {
        let results: [JSONValue] = [
            .object([:]),  // wait result
            .object(["uuid": .array([.string("uuid"), .string("11111111-2222-3333-4444-555555555555")])]),
            .object(["count": .number(1)])
        ]

        XCTAssertEqual(
            try OVSDBConnection.uuid(fromInsertResults: results, at: 1),
            "11111111-2222-3333-4444-555555555555"
        )

        XCTAssertThrowsError(try OVSDBConnection.uuid(fromInsertResults: results, at: 0))
        XCTAssertThrowsError(try OVSDBConnection.uuid(fromInsertResults: results, at: 3))
    }

    func testMonitorRequestSerialization() throws {
        let monitorRequest = OVSDBMonitorRequest(
            columns: ["name", "ports"],
            select: OVSDBMonitorSelect(initial: true, insert: true, delete: true, modify: true)
        )
        
        let encoder = JSONEncoder()
        let data = try encoder.encode(monitorRequest)
        
        let decoder = JSONDecoder()
        let decodedRequest = try decoder.decode(OVSDBMonitorRequest.self, from: data)
        
        XCTAssertEqual(decodedRequest.columns, monitorRequest.columns)
        XCTAssertEqual(decodedRequest.select?.initial, monitorRequest.select?.initial)
    }
}

// MARK: - Frame Decoder Tests

final class OVSDBJSONFrameDecoderTests: XCTestCase {

    /// Feeds the given byte chunks through the decoder in order and returns every
    /// framed message the decoder produced.
    private func frames(feeding chunks: [String]) throws -> [String] {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(OVSDBJSONFrameDecoder()))
        defer { _ = try? channel.finish() }

        for chunk in chunks {
            var buffer = channel.allocator.buffer(capacity: chunk.utf8.count)
            buffer.writeString(chunk)
            try channel.writeInbound(buffer)
        }

        var results: [String] = []
        while let framed = try channel.readInbound(as: String.self) {
            results.append(framed)
        }
        return results
    }

    func testSingleObject() throws {
        let framed = try frames(feeding: [#"{"id":1,"result":[]}"#])
        XCTAssertEqual(framed, [#"{"id":1,"result":[]}"#])
    }

    func testNewlineDelimitedObject() throws {
        // The client appends a trailing newline; leading/trailing whitespace is dropped.
        let framed = try frames(feeding: ["\n" + #"{"id":1}"# + "\n"])
        XCTAssertEqual(framed, [#"{"id":1}"#])
    }

    func testConcatenatedObjects() throws {
        // Two objects with no delimiter arriving in a single read must be split.
        let framed = try frames(feeding: [#"{"id":1}{"id":2}"#])
        XCTAssertEqual(framed, [#"{"id":1}"#, #"{"id":2}"#])
    }

    func testNestedObject() throws {
        let message = #"{"id":1,"result":{"rows":[{"name":"ls0"}]}}"#
        let framed = try frames(feeding: [message])
        XCTAssertEqual(framed, [message])
    }

    func testBracesInsideStringsAreIgnored() throws {
        let message = #"{"error":"unexpected } or { char","id":1}"#
        let framed = try frames(feeding: [message])
        XCTAssertEqual(framed, [message])
    }

    func testEscapedQuotesInsideStrings() throws {
        let message = #"{"match":"name==\"a}b{c\"","id":1}"#
        let framed = try frames(feeding: [message])
        XCTAssertEqual(framed, [message])
    }

    func testPartialObjectSplitAcrossReads() throws {
        let framed = try frames(feeding: [#"{"id":1,"resu"#, #"lt":[]}"#])
        XCTAssertEqual(framed, [#"{"id":1,"result":[]}"#])
    }

    func testTrailingBytesBufferedForNextObject() throws {
        // First read carries a full object plus the start of the next one.
        let framed = try frames(feeding: [#"{"id":1}{"id":"#, #"2}"#])
        XCTAssertEqual(framed, [#"{"id":1}"#, #"{"id":2}"#])
    }
}