import Foundation
import Testing
import NIO
@testable import SwiftOVN

@Suite("Models and wire formats")
struct OVNManagerTests {

    @Test("A JSON-RPC request keeps its method, params and id")
    func jsonRPCRequest() throws {
        let request = JSONRPCRequest(
            method: "list_dbs",
            params: nil,
            id: .string("test-1")
        )

        #expect(request.method == "list_dbs")
        #expect(request.params == nil)
        #expect(request.id == .string("test-1"))
    }

    @Test("Every JSONValue shape round trips through Codable", arguments: [
        JSONValue.null,
        .boolean(true),
        .number(42.5),
        .string("hello"),
        .array([.string("a"), .number(1), .boolean(false)]),
        .object(["key": .string("value"), "number": .number(123)]),
    ])
    func jsonValueEncodingDecoding(value: JSONValue) throws {
        let encoded = try JSONEncoder().encode(value)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)

        #expect(decoded == value)
    }

    @Test("A logical switch keeps what it was created with")
    func ovnLogicalSwitchCreation() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "test-switch",
            external_ids: ["test": "value"]
        )

        #expect(logicalSwitch.name == "test-switch")
        #expect(logicalSwitch.external_ids?["test"] == "value")
        #expect(logicalSwitch.uuid == nil)
    }

    @Test("A bridge keeps what it was created with")
    func ovsBridgeCreation() throws {
        let bridge = OVSBridge(
            name: "br-test",
            fail_mode: "secure",
            external_ids: ["description": "Test bridge"]
        )

        #expect(bridge.name == "br-test")
        #expect(bridge.fail_mode == "secure")
        #expect(bridge.external_ids?["description"] == "Test bridge")
    }

    @Test("The equality condition builder fills in column, function and value")
    func ovsdbConditionCreation() throws {
        let condition = OVSDBCondition.equal(column: "name", to: "test-value")

        #expect(condition.column == "name")
        #expect(condition.function == "==")
        #expect(condition.value == .string("test-value"))
    }

    @Test("The add mutation builder fills in column, mutator and value")
    func ovsdbMutationCreation() throws {
        let mutation = OVSDBMutation.add(column: "count", value: 5)

        #expect(mutation.column == "count")
        #expect(mutation.mutator == "+=")
        #expect(mutation.value == .number(5))
    }

    @Test("A string set exposes its elements")
    func jsonValueSetHandling() throws {
        let stringSet = JSONValue.set(["a", "b", "c"])
        let setValues = try #require(stringSet.setStringValues)

        #expect(setValues.count == 3)
        #expect(setValues.contains("a"))
        #expect(setValues.contains("b"))
        #expect(setValues.contains("c"))
    }

    @Test("A string map exposes its entries")
    func jsonValueMapHandling() throws {
        let stringMap = JSONValue.map(["key1": "value1", "key2": "value2"])
        let mapValues = try #require(stringMap.mapStringValues)

        #expect(mapValues.count == 2)
        #expect(mapValues["key1"] == "value1")
        #expect(mapValues["key2"] == "value2")
    }

    @Test("A UUID atom exposes its UUID")
    func jsonValueUUIDHandling() throws {
        let uuidValue = JSONValue.uuid("12345678-1234-5678-9abc-123456789012")

        #expect(uuidValue.uuidValue == "12345678-1234-5678-9abc-123456789012")
    }

    // MARK: - JSONValue set/map wire-format assertions

    @Test("A set of booleans keeps its booleans")
    func jsonValueSetOfBoolsPreservesBooleans() throws {
        // Regression: set(_:) previously dropped Bool elements, silently
        // producing an empty set on the wire.
        let set = JSONValue.set([true, false])

        let outer = try #require(set.arrayValue, "Expected [\"set\", [...]] shape, got \(set)")
        #expect(outer.count == 2)
        #expect(outer.first == .string("set"))
        #expect(outer.last?.arrayValue == [.boolean(true), .boolean(false)])

        // And it must serialize as JSON booleans, not 0/1.
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(set))
        let serialized = try #require(json as? [Any], "Expected 2-element array, got \(json)")
        #expect(serialized.count == 2)
        #expect(serialized.first as? String == "set")
        #expect(serialized.last as? [Bool] == [true, false])
    }

    /// RFC 7047: a one-element set is the bare value, not ["set", [value]].
    @Test("A single-element set is the bare scalar", arguments: [
        (JSONValue.set(["only"]), JSONValue.string("only")),
        (JSONValue.set([true]), .boolean(true)),
        (JSONValue.set([42]), .number(42)),
    ])
    func jsonValueSingleElementSetIsBareScalar(set: JSONValue, expected: JSONValue) {
        #expect(set == expected)
    }

    /// Regression: the old impossible conjunction made setValue return nil for
    /// a bare scalar instead of a single-element set.
    @Test("setValue unwraps a bare scalar as a one-element set", arguments: [
        (JSONValue.string("x"), [JSONValue.string("x")]),
        (.number(7), [.number(7)]),
        (.boolean(true), [.boolean(true)]),
        // The wrapped multi-element form still round-trips.
        (JSONValue.set(["a", "b"]), [.string("a"), .string("b")]),
    ])
    func jsonValueSetValueUnwrapsBareScalar(value: JSONValue, expected: [JSONValue]) {
        #expect(value.setValue == expected)
    }

    @Test("A string dictionary converts to the map wire format")
    func stringDictionaryToJSONValueIsMapWireFormat() throws {
        // toJSONValue() must produce ["map", [[k, v], ...]] so it can build row
        // columns directly, not a bare JSON object.
        let value = ["a": "b"].toJSONValue()

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let array = try #require(json as? [Any], "Expected [\"map\", [[k, v]]] shape, got \(json)")
        #expect(array.count == 2)
        #expect(array.first as? String == "map")
        let pairs = try #require(array.last as? [[Any]])
        #expect(pairs.count == 1)
        #expect(pairs[0][0] as? String == "a")
        #expect(pairs[0][1] as? String == "b")
    }

    @Test("An integer dictionary encodes integer values")
    func intDictionaryToJSONValueEncodesIntegerValues() throws {
        // Integer map values must serialize as JSON integers, not 5.0.
        let value = ["ttl": 5].toJSONValue()

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        let pairs = try #require((json as? [Any])?[1] as? [[Any]])
        #expect(pairs.first?[0] as? String == "ttl")
        #expect(pairs.first?[1] as? Int == 5)
    }

    @Test("The mutation convenience builders encode as an array")
    func ovsdbMutationConvenienceEncodesAsArray() throws {
        // The convenience builders must produce the RFC 7047 3-tuple wire form.
        let mutation = OVSDBMutation.insert(column: "ports", value: "lsp0")

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(mutation))
        #expect(json as? [String] == ["ports", "insert", "lsp0"])
    }

    @Test("An ACL keeps what it was created with")
    func ovnACLCreation() throws {
        let acl = OVNACL(
            priority: 1000,
            direction: "to-lport",
            match: "ip4.src == 192.168.1.0/24",
            action: "allow",
            log: true,
            name: "test-acl"
        )

        #expect(acl.priority == 1000)
        #expect(acl.direction == "to-lport")
        #expect(acl.match == "ip4.src == 192.168.1.0/24")
        #expect(acl.action == "allow")
        #expect(acl.log == true)
        #expect(acl.name == "test-acl")
    }

    @Test("A load balancer keeps what it was created with")
    func ovnLoadBalancerCreation() throws {
        let loadBalancer = OVNLoadBalancer(
            name: "test-lb",
            vips: ["192.168.1.100:80": "192.168.1.10:8080,192.168.1.11:8080"],
            protocolType: "tcp"
        )

        #expect(loadBalancer.name == "test-lb")
        #expect(loadBalancer.vips.count == 1)
        #expect(loadBalancer.vips["192.168.1.100:80"] == "192.168.1.10:8080,192.168.1.11:8080")
        #expect(loadBalancer.protocolType == "tcp")
    }

    @Test("The logical router dynamic-routing helpers write and clear options")
    func logicalRouterDynamicRoutingHelpers() throws {
        let router = OVNLogicalRouter(
            name: "lr0",
            options: ["existing": "kept"]
        )

        let dynamicRouter = router.withDynamicRouting(
            redistribute: [.connected, .staticRoutes, .nat, .loadBalancer],
            vrfID: 42,
            vrfName: "tenant-a",
            noLearning: true,
            ipv4PrefixNexthop: "192.0.2.1",
            ipv6PrefixNexthop: "2001:db8::1"
        )

        #expect(dynamicRouter.dynamicRoutingEnabled)
        #expect(dynamicRouter.dynamicRoutingRedistribute == [.connected, .staticRoutes, .nat, .loadBalancer])
        #expect(dynamicRouter.options?["dynamic-routing"] == "true")
        #expect(dynamicRouter.options?["dynamic-routing-redistribute"] == "connected,lb,nat,static")
        #expect(dynamicRouter.options?["dynamic-routing-vrf-id"] == "42")
        #expect(dynamicRouter.options?["dynamic-routing-vrf-name"] == "tenant-a")
        #expect(dynamicRouter.options?["dynamic-routing-no-learning"] == "true")
        #expect(dynamicRouter.options?["dynamic-routing-v4-prefix-nexthop"] == "192.0.2.1")
        #expect(dynamicRouter.options?["dynamic-routing-v6-prefix-nexthop"] == "2001:db8::1")
        #expect(dynamicRouter.options?["existing"] == "kept")

        let disabledRouter = dynamicRouter.withoutDynamicRouting()
        #expect(disabledRouter.options == ["existing": "kept"])
    }

    @Test("The logical router port dynamic-routing helpers write and clear options")
    func logicalRouterPortDynamicRoutingHelpers() throws {
        let port = OVNLogicalRouterPort(
            name: "lrp0",
            mac: "00:00:00:00:00:01",
            networks: ["10.0.0.1/24"],
            options: ["existing": "kept"]
        )

        let dynamicPort = port.withDynamicRouting(
            redistribute: [.connectedAsHost],
            maintainVRF: true,
            noLearning: false,
            portName: "fabric0",
            routingProtocols: [.bgp, .bfd],
            routingProtocolRedirect: "bgp-speaker-lsp"
        )

        #expect(dynamicPort.dynamicRoutingRedistribute == [.connectedAsHost])
        #expect(dynamicPort.routingProtocols == [.bgp, .bfd])
        #expect(dynamicPort.options?["dynamic-routing-redistribute"] == "connected-as-host")
        #expect(dynamicPort.options?["dynamic-routing-maintain-vrf"] == "true")
        #expect(dynamicPort.options?["dynamic-routing-no-learning"] == "false")
        #expect(dynamicPort.options?["dynamic-routing-port-name"] == "fabric0")
        #expect(dynamicPort.options?["routing-protocols"] == "BFD,BGP")
        #expect(dynamicPort.options?["routing-protocol-redirect"] == "bgp-speaker-lsp")
        #expect(dynamicPort.options?["existing"] == "kept")

        let clearedPort = dynamicPort.withoutDynamicRoutingOverrides()
        #expect(clearedPort.options == ["existing": "kept"])
    }

    @Test("A JSON-RPC error keeps its code, message and data")
    func jsonRPCErrorHandling() throws {
        let error = JSONRPCError(
            code: -32600,
            message: "Invalid Request",
            data: .string("Additional error information")
        )

        #expect(error.code == -32600)
        #expect(error.message == "Invalid Request")
        #expect(error.data == .string("Additional error information"))
    }

    @Test("Manager errors carry their payloads")
    func ovnManagerError() throws {
        let connectionError = OVNManagerError.connectionFailed("Socket not found")

        guard case .connectionFailed(let message) = connectionError else {
            Issue.record("Expected connectionFailed, got \(connectionError.errorCase)")
            return
        }
        #expect(message == "Socket not found")
        #expect(OVNManagerError.timeoutError.errorCase == .timeoutError)
    }
}

// MARK: - Mock Tests

@Suite("JSON-RPC and OVSDB serialization")
struct JSONRPCClientMockTests {

    @Test("A JSON-RPC request round trips")
    func jsonRPCRequestSerialization() throws {
        let request = JSONRPCRequest(
            method: "transact",
            params: .array([.string("OVN_Northbound"), .object(["op": .string("select"), "table": .string("Logical_Switch")])]),
            id: .number(1)
        )

        let data = try JSONEncoder().encode(request)

        // Verify that the JSON can be decoded back
        let decodedRequest = try JSONDecoder().decode(JSONRPCRequest.self, from: data)

        #expect(decodedRequest.method == request.method)
    }

    @Test("An OVSDB operation round trips")
    func ovsdbOperationSerialization() throws {
        let operation = OVSDBOperation.select(
            from: "Logical_Switch",
            where: [OVSDBCondition(column: "name", function: "==", value: .string("test"))],
            columns: ["name", "ports"]
        )

        let data = try JSONEncoder().encode(operation)
        let decodedOperation = try JSONDecoder().decode(OVSDBOperation.self, from: data)

        #expect(decodedOperation.op == operation.op)
        #expect(decodedOperation.table == operation.table)
        #expect(decodedOperation.columns == operation.columns)
    }

    @Test("A condition encodes as an array")
    func ovsdbConditionEncodesAsArray() throws {
        let condition = OVSDBCondition(column: "name", function: "==", value: .string("ls0"))

        let data = try JSONEncoder().encode(condition)
        let json = try JSONSerialization.jsonObject(with: data)

        #expect(json as? [String] == ["name", "==", "ls0"])
    }

    @Test("A mutation encodes as an array")
    func ovsdbMutationEncodesAsArray() throws {
        // RFC 7047 requires mutations on the wire as [column, mutator, value],
        // not a keyed object — ovsdb-server rejects the object form.
        let mutation = OVSDBMutation(
            column: "ports",
            mutator: "insert",
            value: .array([.string("named-uuid"), .string("new_lsp")])
        )

        let data = try JSONEncoder().encode(mutation)
        let json = try JSONSerialization.jsonObject(with: data)

        let array = try #require(json as? [Any], "Expected 3-element array, got \(json)")
        #expect(array.count == 3)
        #expect(array[0] as? String == "ports")
        #expect(array[1] as? String == "insert")
        #expect(array[2] as? [String] == ["named-uuid", "new_lsp"])

        let decoded = try JSONDecoder().decode(OVSDBMutation.self, from: data)
        #expect(decoded.column == mutation.column)
        #expect(decoded.mutator == mutation.mutator)
        #expect(decoded.value == mutation.value)
    }

    @Test("An operation encodes uuid-name and the wait fields")
    func ovsdbOperationEncodesUUIDNameAndWaitFields() throws {
        let insert = OVSDBOperation.insert(
            into: "Logical_Switch_Port",
            row: ["name": .string("vm1-port")],
            uuidName: "new_lsp"
        )

        let insertJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(insert)) as? [String: Any]
        #expect(insertJSON?["uuid-name"] as? String == "new_lsp")
        #expect(insertJSON?["uuidName"] == nil)
        #expect(insertJSON?["where"] == nil, "insert must not carry a where clause")

        let wait = OVSDBOperation.wait(
            "Logical_Switch",
            where: [OVSDBCondition(column: "name", function: "==", value: .string("ls0"))],
            columns: ["name"],
            rows: [["name": .string("ls0")]],
            until: "==",
            timeout: 0
        )

        let waitJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(wait)) as? [String: Any]
        #expect(waitJSON?["until"] as? String == "==")
        #expect(waitJSON?["timeout"] as? Int == 0)
        #expect((waitJSON?["rows"] as? [[String: Any]])?.first?["name"] as? String == "ls0")
        #expect((waitJSON?["where"] as? [[Any]])?.count == 1)
    }

    /// The four operations RFC 7047 defines with no table: each must encode its
    /// own member and nothing else, since ovsdb-server rejects an operation
    /// carrying members its `op` does not define.
    @Test("The table-less operations encode only their own members")
    func tableLessOperationsEncodeOnlyTheirOwnMembers() throws {
        let cases: [(OVSDBOperation, [String: Any])] = [
            (.commit(durable: true), ["op": "commit", "durable": true]),
            (.commit(durable: false), ["op": "commit", "durable": false]),
            (.abort, ["op": "abort"]),
            (.comment("ovn-nbctl ls-add ls0"), ["op": "comment", "comment": "ovn-nbctl ls-add ls0"]),
            (.assert(lock: "ovn_nb_lock"), ["op": "assert", "lock": "ovn_nb_lock"]),
        ]

        for (operation, expected) in cases {
            let json = try #require(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(operation)) as? [String: Any]
            )
            #expect(json.keys.sorted() == expected.keys.sorted(), "unexpected members on \(operation.op)")
            #expect(json["op"] as? String == expected["op"] as? String)
            #expect(json["table"] == nil, "\(operation.op) must not carry a table")
            #expect(json["durable"] as? Bool == expected["durable"] as? Bool)
            #expect(json["comment"] as? String == expected["comment"] as? String)
            #expect(json["lock"] as? String == expected["lock"] as? String)
        }
    }

    /// The builders exist so the `op` and the members set can't disagree.
    @Test("Each builder sets its own operation type and no foreign members")
    func buildersSetTheirOwnOperationType() throws {
        let condition = OVSDBCondition.equal(column: "name", to: "ls0")

        let select = OVSDBOperation.select(from: "Logical_Switch")
        #expect(select.op == .select)
        // An absent where clause selects every row, so it is [] and not nil.
        #expect(select.whereConditions == [])

        let insert = OVSDBOperation.insert(into: "Logical_Switch", row: ["name": .string("ls0")])
        #expect(insert.op == .insert)
        #expect(insert.whereConditions == nil, "insert takes no where clause")
        #expect(insert.uuidName == nil)

        let update = OVSDBOperation.update("Logical_Switch", where: [condition], row: ["name": .string("ls1")])
        #expect(update.op == .update)
        #expect(update.mutations == nil)

        let mutate = OVSDBOperation.mutate(
            "Logical_Switch",
            where: [condition],
            mutations: [OVSDBMutation.insert(column: "ports", value: "lsp0")]
        )
        #expect(mutate.op == .mutate)
        #expect(mutate.row == nil)

        let delete = OVSDBOperation.delete(from: "Logical_Switch", where: [condition])
        #expect(delete.op == .delete)
        #expect(delete.row == nil)

        #expect(OVSDBOperation.wait("Logical_Switch", where: [condition], rows: []).op == .wait)
        #expect(OVSDBOperation.commit(durable: true).durable == true)
        #expect(OVSDBOperation.assert(lock: "l").lock == "l")
        #expect(OVSDBOperation.comment("c").comment == "c")
        #expect(OVSDBOperation.abort.table == nil)
    }

    private func encodeOperations(_ operations: [OVSDBOperation]) throws -> [[String: Any]] {
        let data = try JSONEncoder().encode(operations)
        return try #require(
            JSONSerialization.jsonObject(with: data) as? [[String: Any]],
            "Operations did not encode as an array of objects"
        )
    }

    @Test("insertAttached produces the wait/insert/mutate wire format")
    func insertAttachedTransactionWireFormat() throws {
        let operations = OVSDBReferenceTransactions.insertAttached(
            row: ["priority": .number(1000), "direction": .string("to-lport")],
            into: "ACL",
            uuidName: "new_acl",
            parentTable: "Logical_Switch",
            parentColumn: "acls",
            parentCondition: OVSDBCondition(column: "name", function: "==", value: .string("ls0"))
        )

        let json = try encodeOperations(operations)
        #expect(json.count == 3)

        // Op 0: wait guarding the parent's existence, aborting on mismatch
        #expect(json[0]["op"] as? String == "wait")
        #expect(json[0]["table"] as? String == "Logical_Switch")
        #expect(json[0]["until"] as? String == "==")
        #expect(json[0]["timeout"] as? Int == 0)
        #expect(json[0]["columns"] as? [String] == ["name"])
        #expect((json[0]["rows"] as? [[String: Any]])?.first?["name"] as? String == "ls0")

        // Op 1: insert carrying the uuid-name for the mutate to reference
        #expect(json[1]["op"] as? String == "insert")
        #expect(json[1]["table"] as? String == "ACL")
        #expect(json[1]["uuid-name"] as? String == "new_acl")
        #expect(json[1]["where"] == nil, "insert must not carry a where clause")

        // Op 2: mutate adding the named-uuid to the parent's reference set
        #expect(json[2]["op"] as? String == "mutate")
        #expect(json[2]["table"] as? String == "Logical_Switch")
        let mutation = try #require(
            (json[2]["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "acls")
        #expect(mutation[1] as? String == "insert")
        #expect(mutation[2] as? [String] == ["named-uuid", "new_acl"])
    }

    @Test("insertAttached to a root parent skips the wait and matches all rows")
    func insertAttachedToRootParentSkipsWaitAndMatchesAllRows() throws {
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
        #expect(json.count == 2)

        #expect(json[0]["op"] as? String == "insert")
        #expect(json[0]["uuid-name"] as? String == "new_bridge")

        #expect(json[1]["op"] as? String == "mutate")
        #expect(json[1]["table"] as? String == "Open_vSwitch")
        #expect((json[1]["where"] as? [Any])?.count == 0)
        let mutation = try #require(
            (json[1]["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "bridges")
        #expect(mutation[2] as? [String] == ["named-uuid", "new_bridge"])
    }

    @Test("insertWithChildren inserts the children first and references them from the parent")
    func insertWithChildrenTransactionWireFormat() throws {
        // `ovn-nbctl meter-add` semantics: Meter.bands has a schema minimum of
        // one, so the bands have to be inserted and referenced in the same
        // transaction as the meter or the insert is a constraint violation.
        let operations = OVSDBReferenceTransactions.insertWithChildren(
            row: ["name": .string("acl-log-meter"), "bands": .string("stale-caller-value")],
            into: "Meter",
            uuidName: "new_meter",
            referenceColumn: "bands",
            childRows: [["rate": .number(100)], ["rate": .number(200)]],
            childTable: "Meter_Band",
            childUUIDNamePrefix: "new_meter_band_"
        )

        let json = try encodeOperations(operations)
        #expect(json.count == 3)

        // Ops 0-1: one insert per band, each carrying its own uuid-name.
        for (index, expectedRate) in [100, 200].enumerated() {
            #expect(json[index]["op"] as? String == "insert")
            #expect(json[index]["table"] as? String == "Meter_Band")
            #expect(json[index]["uuid-name"] as? String == "new_meter_band_\(index)")
            #expect((json[index]["row"] as? [String: Any])?["rate"] as? Int == expectedRate)
        }

        // Op 2: the meter, its bands overwritten with the new bands' references.
        #expect(json[2]["op"] as? String == "insert")
        #expect(json[2]["table"] as? String == "Meter")
        #expect(json[2]["uuid-name"] as? String == "new_meter")
        #expect((json[2]["row"] as? [String: Any])?["name"] as? String == "acl-log-meter")
        let bands = try #require(
            (json[2]["row"] as? [String: Any])?["bands"] as? [Any],
            "Expected a tagged set for bands"
        )
        #expect(bands.count == 2)
        #expect(bands[0] as? String == "set")
        #expect(bands[1] as? [[String]] == [["named-uuid", "new_meter_band_0"], ["named-uuid", "new_meter_band_1"]])
    }

    @Test("insertBridgeAttached creates the internal port pair")
    func insertBridgeAttachedCreatesInternalPortWireFormat() throws {
        // `ovs-vsctl add-br` semantics: Interface + Port + Bridge inserted and
        // chained by named-uuid, then referenced from the Open_vSwitch root.
        // Without the internal Port/Interface pair, ovs-vswitchd never creates
        // the bridge's Linux netdev.
        let operations = OVSDBReferenceTransactions.insertBridgeAttached(
            bridgeRow: ["name": .string("br-ex"), "ports": .string("stale-caller-value")],
            portRow: ["name": .string("br-ex")],
            interfaceRow: ["name": .string("br-ex"), "type": .string("internal")]
        )

        let json = try encodeOperations(operations)
        #expect(json.count == 4)

        // Op 0: the internal interface, carrying its uuid-name for the port.
        #expect(json[0]["op"] as? String == "insert")
        #expect(json[0]["table"] as? String == "Interface")
        #expect(json[0]["uuid-name"] as? String == "new_interface")
        #expect((json[0]["row"] as? [String: Any])?["type"] as? String == "internal")

        // Op 1: the port, its interfaces chained to the new interface.
        #expect(json[1]["op"] as? String == "insert")
        #expect(json[1]["table"] as? String == "Port")
        #expect(json[1]["uuid-name"] as? String == "new_port")
        #expect((json[1]["row"] as? [String: Any])?["interfaces"] as? [String] == ["named-uuid", "new_interface"])

        // Op 2: the bridge, its ports overwritten with the new port.
        #expect(json[2]["op"] as? String == "insert")
        #expect(json[2]["table"] as? String == "Bridge")
        #expect(json[2]["uuid-name"] as? String == "new_bridge")
        #expect((json[2]["row"] as? [String: Any])?["ports"] as? [String] == ["named-uuid", "new_port"])

        // Op 3: root reference, unconditioned (the one Open_vSwitch row).
        #expect(json[3]["op"] as? String == "mutate")
        #expect(json[3]["table"] as? String == "Open_vSwitch")
        #expect((json[3]["where"] as? [Any])?.count == 0)
        let mutation = try #require(
            (json[3]["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "bridges")
        #expect(mutation[1] as? String == "insert")
        #expect(mutation[2] as? [String] == ["named-uuid", "new_bridge"])
    }

    @Test("deleteDetaching detaches from every parent, then deletes")
    func deleteDetachingTransactionWireFormat() throws {
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
        #expect(json.count == 3)

        // Ops 0-1: one detach mutate per parent, selecting rows whose
        // reference set includes the uuid atom and removing it.
        for (index, expectedTable) in ["Logical_Switch", "Port_Group"].enumerated() {
            #expect(json[index]["op"] as? String == "mutate")
            #expect(json[index]["table"] as? String == expectedTable)

            let condition = try #require(
                (json[index]["where"] as? [[Any]])?.first,
                "Expected one [column, function, value] condition"
            )
            #expect(condition.count == 3)
            #expect(condition[0] as? String == "acls")
            #expect(condition[1] as? String == "includes")
            #expect(condition[2] as? [String] == ["uuid", uuid])

            let mutation = try #require(
                (json[index]["mutations"] as? [[Any]])?.first,
                "Expected one [column, mutator, value] mutation"
            )
            #expect(mutation.count == 3)
            #expect(mutation[0] as? String == "acls")
            #expect(mutation[1] as? String == "delete")
            #expect(mutation[2] as? [String] == ["uuid", uuid])
        }

        // Op 2: the row delete itself, in the same transaction
        #expect(json[2]["op"] as? String == "delete")
        #expect(json[2]["table"] as? String == "ACL")
        let deleteCondition = try #require(
            (json[2]["where"] as? [[Any]])?.first,
            "Expected one [column, function, value] condition"
        )
        #expect(deleteCondition.count == 3)
        #expect(deleteCondition[0] as? String == "_uuid")
        #expect(deleteCondition[1] as? String == "==")
        #expect(deleteCondition[2] as? [String] == ["uuid", uuid])
    }

    /// The sync barrier's first half: bumping nb_cfg is useless unless the
    /// caller learns the value it reached, and only a select in the *same*
    /// transaction can tell them — another client's increment could land
    /// between two transactions.
    @Test("increment mutates by one and selects the column back")
    func incrementTransactionWireFormat() throws {
        let operations = OVSDBColumnTransactions.increment(column: "nb_cfg", in: "NB_Global")

        let json = try encodeOperations(operations)
        #expect(json.count == 2)

        // Op 0: the increment. An empty where matches the one row of a
        // maxRows: 1 table.
        #expect(json[0]["op"] as? String == "mutate")
        #expect(json[0]["table"] as? String == "NB_Global")
        #expect((json[0]["where"] as? [Any])?.count == 0)
        let mutation = try #require(
            (json[0]["mutations"] as? [[Any]])?.first,
            "Expected one [column, mutator, value] mutation"
        )
        #expect(mutation.count == 3)
        #expect(mutation[0] as? String == "nb_cfg")
        #expect(mutation[1] as? String == "+=")
        #expect(mutation[2] as? Int == 1)

        // Op 1: the read-back, narrowed to the counter.
        #expect(json[1]["op"] as? String == "select")
        #expect(json[1]["table"] as? String == "NB_Global")
        #expect(json[1]["columns"] as? [String] == ["nb_cfg"])
        #expect((json[1]["where"] as? [Any])?.count == 0)
    }

    /// An `insert` into a map column ignores keys that already exist, so an
    /// upsert has to delete the keys first — and both mutations have to belong
    /// to the same mutate op, or a reader sees the column without them.
    @Test("upsertMapEntries deletes the keys before inserting the pairs")
    func upsertMapEntriesWireFormat() throws {
        let mutations = OVSDBColumnTransactions.upsertMapEntries(
            ["mac_prefix": "0a:5c:1f", "northd_probe_interval": "5000"],
            column: "options"
        )

        let data = try JSONEncoder().encode(mutations)
        let json = try #require(
            JSONSerialization.jsonObject(with: data) as? [[Any]],
            "Mutations did not encode as an array of arrays"
        )
        #expect(json.count == 2)

        // Mutation 0: delete by key set — a set, not a map, so an entry is
        // removed whatever it maps to.
        #expect(json[0][0] as? String == "options")
        #expect(json[0][1] as? String == "delete")
        let deleted = try #require(json[0][2] as? [Any], "Expected a tagged set of keys")
        #expect(deleted[0] as? String == "set")
        // Dictionary iteration order is not stable across processes.
        #expect((deleted[1] as? [String])?.sorted() == ["mac_prefix", "northd_probe_interval"])

        // Mutation 1: insert the pairs, which now land because the keys are gone.
        #expect(json[1][0] as? String == "options")
        #expect(json[1][1] as? String == "insert")
        let inserted = try #require(json[1][2] as? [Any], "Expected a tagged map of pairs")
        #expect(inserted[0] as? String == "map")
        let pairs = try #require(inserted[1] as? [[String]], "Expected [[key, value], ...]")
        #expect(pairs.sorted { $0[0] < $1[0] } == [["mac_prefix", "0a:5c:1f"], ["northd_probe_interval", "5000"]])
    }

    /// A single key still gets the tagged `["set", [...]]` spelling: the bare
    /// atom RFC 7047 also allows for a one-element set would read as a
    /// string-valued delete.
    @Test("removeMapEntries deletes a single key as a tagged set")
    func removeMapEntriesWireFormat() throws {
        let mutation = OVSDBColumnTransactions.removeMapEntries(keys: ["mac_prefix"], column: "options")

        let data = try JSONEncoder().encode(mutation)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [Any], "Expected a 3-element array")

        #expect(json.count == 3)
        #expect(json[0] as? String == "options")
        #expect(json[1] as? String == "delete")
        let keys = try #require(json[2] as? [Any], "Expected a tagged set of keys")
        #expect(keys[0] as? String == "set")
        #expect(keys[1] as? [String] == ["mac_prefix"])
    }

    @Test("An insert's UUID is extracted from the right result, and only from there")
    func insertResultUUIDExtraction() throws {
        let results: [JSONValue] = [
            .object([:]),  // wait result
            .object(["uuid": .array([.string("uuid"), .string("11111111-2222-3333-4444-555555555555")])]),
            .object(["count": .number(1)])
        ]

        #expect(
            try OVSDBConnection.uuid(fromInsertResults: results, at: 1)
                == "11111111-2222-3333-4444-555555555555"
        )

        // A result with no uuid member, and an index past the end.
        for index in [0, 3] {
            #expect(throws: OVNManagerError.self) {
                try OVSDBConnection.uuid(fromInsertResults: results, at: index)
            }
        }
    }

    @Test("A monitor request round trips")
    func monitorRequestSerialization() throws {
        let monitorRequest = OVSDBMonitorRequest(
            columns: ["name", "ports"],
            select: OVSDBMonitorSelect(initial: true, insert: true, delete: true, modify: true)
        )

        let data = try JSONEncoder().encode(monitorRequest)
        let decodedRequest = try JSONDecoder().decode(OVSDBMonitorRequest.self, from: data)

        #expect(decodedRequest.columns == monitorRequest.columns)
        #expect(decodedRequest.select?.initial == monitorRequest.select?.initial)
    }
}

// MARK: - Frame Decoder Tests

/// One framing scenario: the byte chunks as they arrive off the socket, and
/// every message the decoder has to emit for them.
struct FramingCase: Sendable, CustomTestStringConvertible {
    let testDescription: String
    let chunks: [String]
    let expected: [String]

    init(_ description: String, chunks: [String], expected: [String]) {
        self.testDescription = description
        self.chunks = chunks
        self.expected = expected
    }

    /// A message that must come back out exactly as it went in.
    init(_ description: String, verbatim message: String) {
        self.init(description, chunks: [message], expected: [message])
    }
}

@Suite("OVSDB JSON framing")
struct OVSDBJSONFrameDecoderTests {

    /// Feeds the given byte chunks through the decoder in order and returns every
    /// framed message the decoder produced. Frames come out as `ByteBuffer`s and
    /// are rendered back to `String` here only so the expectations stay readable.
    private func frames(feeding chunks: [String]) throws -> [String] {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(OVSDBJSONFrameDecoder()))
        defer { _ = try? channel.finish() }

        for chunk in chunks {
            var buffer = channel.allocator.buffer(capacity: chunk.utf8.count)
            buffer.writeString(chunk)
            try channel.writeInbound(buffer)
        }

        var results: [String] = []
        while let framed = try channel.readInbound(as: ByteBuffer.self) {
            results.append(String(buffer: framed))
        }
        return results
    }

    static let singleReadCases: [FramingCase] = [
        FramingCase("single object", verbatim: #"{"id":1,"result":[]}"#),
        FramingCase("nested object", verbatim: #"{"id":1,"result":{"rows":[{"name":"ls0"}]}}"#),
        FramingCase("braces inside strings are ignored",
                    verbatim: #"{"error":"unexpected } or { char","id":1}"#),
        FramingCase("escaped quotes inside strings",
                    verbatim: #"{"match":"name==\"a}b{c\"","id":1}"#),
        // The client appends a trailing newline; leading/trailing whitespace is dropped.
        FramingCase("newline delimited object",
                    chunks: ["\n" + #"{"id":1}"# + "\n"],
                    expected: [#"{"id":1}"#]),
        // Two objects with no delimiter arriving in a single read must be split.
        FramingCase("concatenated objects",
                    chunks: [#"{"id":1}{"id":2}"#],
                    expected: [#"{"id":1}"#, #"{"id":2}"#]),
    ]

    @Test("Frames messages arriving in a single read",
          arguments: OVSDBJSONFrameDecoderTests.singleReadCases)
    func framesSingleRead(testCase: FramingCase) throws {
        #expect(try frames(feeding: testCase.chunks) == testCase.expected)
    }

    // MARK: - Scan-state continuity across reads
    //
    // The decoder resumes scanning where the previous read stopped instead of
    // re-scanning from the start, so every piece of scanner state (string
    // membership, backslash escaping, nesting depth, object start) has to
    // survive a chunk boundary landing in the middle of it.

    static let splitReadCases: [FramingCase] = [
        FramingCase("partial object split across reads",
                    chunks: [#"{"id":1,"resu"#, #"lt":[]}"#],
                    expected: [#"{"id":1,"result":[]}"#]),
        // First read carries a full object plus the start of the next one.
        FramingCase("trailing bytes buffered for the next object",
                    chunks: [#"{"id":1}{"id":"#, #"2}"#],
                    expected: [#"{"id":1}"#, #"{"id":2}"#]),
        // The chunk boundary falls between a backslash and the quote it
        // escapes. If `escaped` did not persist, the quote would be read as
        // closing the string and the `}` after it would end the object early.
        FramingCase("backslash escape split across reads",
                    chunks: [#"{"match":"a\"#, #""b}c","id":1}"#],
                    expected: [#"{"match":"a\"b}c","id":1}"#]),
        // Boundary inside a string that contains braces; `inString` must persist.
        FramingCase("brace inside a string split across reads",
                    chunks: [#"{"e":"x{y"#, #"}z","id":1}"#],
                    expected: [#"{"e":"x{y}z","id":1}"#]),
        // Boundary between nested opening braces; `depth` must persist so the
        // first inner `}` is not mistaken for the end of the top-level object.
        FramingCase("nesting depth split across reads",
                    chunks: [#"{"a":{"b":{"#, #""c":1}}}"#],
                    expected: [#"{"a":{"b":{"c":1}}}"#]),
        // Whitespace before the object arrives in its own reads, so the object
        // does not start at the reader index; `objectStartOffset` must persist.
        FramingCase("leading whitespace split across reads",
                    chunks: ["\n\n", "  ", #"{"id"#, #"":1}"#],
                    expected: [#"{"id":1}"#]),
        // Scan state must be reset once an object is consumed, so the offsets
        // recorded for the first object do not leak into the second.
        FramingCase("second object split after the first is emitted",
                    chunks: [#"{"id":1}"#, #"{"na"#, #"me":"x"}"#],
                    expected: [#"{"id":1}"#, #"{"name":"x"}"#]),
    ]

    @Test("Scan state survives a chunk boundary",
          arguments: OVSDBJSONFrameDecoderTests.splitReadCases)
    func framesSplitReads(testCase: FramingCase) throws {
        #expect(try frames(feeding: testCase.chunks) == testCase.expected)
    }

    @Test("A nested object delivered a byte at a time is framed")
    func byteAtATimeDeliveryOfNestedObject() throws {
        // Maximal fragmentation: every byte is its own read, so the decoder
        // resumes on each one. This is also the pathological case for the old
        // rescan-from-the-start framer.
        let message = #"{"id":1,"result":{"rows":[{"name":"ls0","other":"a\"b{}"}]}}"#
        #expect(try frames(feeding: message.map { String($0) }) == [message])
    }

    @Test("Many concatenated objects in one read are all framed")
    func manyConcatenatedObjectsInOneRead() throws {
        let messages = (1...50).map { #"{"id":\#($0)}"# }

        #expect(try frames(feeding: [messages.joined()]) == messages)
    }
}
