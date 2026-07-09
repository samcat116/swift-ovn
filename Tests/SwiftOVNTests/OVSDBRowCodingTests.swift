import XCTest
@testable import SwiftOVN

/// Wire-format helpers matching what ovsdb-server actually sends (RFC 7047):
/// UUIDs as `["uuid", ...]` atoms, sets tagged as `["set", [...]]` — except a
/// single-element set, which is sent as the bare atom — and maps as
/// `["map", [[k, v], ...]]`.
private func wireUUID(_ uuid: String) -> JSONValue {
    return .array([.string("uuid"), .string(uuid)])
}

private func wireSet(_ items: [JSONValue]) -> JSONValue {
    return .array([.string("set"), .array(items)])
}

private let emptySet = wireSet([])

private func wireMap(_ pairs: [(JSONValue, JSONValue)]) -> JSONValue {
    return .array([.string("map"), .array(pairs.map { .array([$0.0, $0.1]) })])
}

private func wireStringMap(_ dictionary: [String: String]) -> JSONValue {
    return wireMap(dictionary.map { (.string($0.key), .string($0.value)) })
}

private let uuidA = "0d53b52f-7f4c-4c8f-9b1e-1a2b3c4d5e6f"
private let uuidB = "550e8400-e29b-41d4-a716-446655440000"
private let uuidC = "9a3e11a4-9f7a-4d0a-8f5e-0123456789ab"

final class OVSDBRowDecoderTests: XCTestCase {

    // MARK: OVN Northbound

    /// The headline regression: a Logical_Switch_Port fresh from ovn-nbctl has
    /// every optional scalar column transmitted as the empty set ["set",[]],
    /// and its single address as a bare string atom.
    func testLogicalSwitchPortWithUnsetOptionalScalars() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lsp-1"),
            "type": .string(""),
            "addresses": .string("50:6b:8d:d1:00:01 10.0.0.11"),
            "port_security": emptySet,
            "tag": emptySet,
            "tag_request": emptySet,
            "up": emptySet,
            "enabled": emptySet,
            "dhcpv4_options": emptySet,
            "dhcpv6_options": emptySet,
            "options": wireMap([]),
            "external_ids": wireStringMap(["neutron:port_id": uuidB]),
        ]

        let port = try OVSDBRowDecoder.decode(OVNLogicalSwitchPort.self, from: row)

        XCTAssertEqual(port.uuid, uuidA)
        XCTAssertEqual(port.name, "lsp-1")
        XCTAssertEqual(port.addresses, ["50:6b:8d:d1:00:01 10.0.0.11"])
        XCTAssertNil(port.port_security)
        XCTAssertNil(port.tag)
        XCTAssertNil(port.tag_request)
        XCTAssertNil(port.up)
        XCTAssertNil(port.enabled)
        XCTAssertNil(port.dhcpv4_options)
        XCTAssertNil(port.dhcpv6_options)
        XCTAssertEqual(port.options, [:])
        XCTAssertEqual(port.external_ids, ["neutron:port_id": uuidB])
    }

    func testLogicalSwitchPortWithPopulatedOptionalScalars() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lsp-2"),
            "tag": .number(100),
            "up": .boolean(true),
            "enabled": wireSet([.boolean(false)]),
            "dhcpv4_options": wireUUID(uuidC),
            "addresses": wireSet([.string("dynamic"), .string("unknown")]),
        ]

        let port = try OVSDBRowDecoder.decode(OVNLogicalSwitchPort.self, from: row)

        XCTAssertEqual(port.tag, 100)
        XCTAssertEqual(port.up, true)
        XCTAssertEqual(port.enabled, false)
        XCTAssertEqual(port.dhcpv4_options, uuidC)
        XCTAssertEqual(port.addresses, ["dynamic", "unknown"])
    }

    /// A set column with exactly one element arrives as the bare atom itself.
    func testLogicalSwitchWithSinglePortAtom() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("ls-1"),
            "ports": wireUUID(uuidB),
            "acls": emptySet,
            "external_ids": wireMap([]),
        ]

        let logicalSwitch = try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: row)

        XCTAssertEqual(logicalSwitch.ports, [uuidB])
        XCTAssertNil(logicalSwitch.acls)
    }

    func testLogicalSwitchWithMultiplePorts() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("ls-2"),
            "ports": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
        ]

        let logicalSwitch = try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: row)

        XCTAssertEqual(logicalSwitch.ports, [uuidB, uuidC])
    }

    func testChassisWithNonOptionalStringSet() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("chassis-1"),
            "hostname": .string("node-1"),
            "encaps": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
            "nb_cfg": .number(7),
            "transport_zones": emptySet,
        ]

        let chassis = try OVSDBRowDecoder.decode(OVNChassis.self, from: row)

        XCTAssertEqual(chassis.encaps, [uuidB, uuidC])
        XCTAssertEqual(chassis.nb_cfg, 7)
        XCTAssertNil(chassis.transport_zones)
    }

    // MARK: Open_vSwitch

    func testInterfaceWithUnsetAndBareScalars() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("eth0"),
            "type": .string(""),
            "mtu": .number(1500),
            "ifindex": .number(2),
            "mac": emptySet,
            "mac_in_use": .string("aa:bb:cc:dd:ee:ff"),
            "admin_state": .string("up"),
            "link_state": wireSet([.string("up")]),
            "link_speed": emptySet,
            "duplex": emptySet,
            "error": emptySet,
            "statistics": wireMap([
                (.string("rx_packets"), .number(1024)),
                (.string("tx_packets"), .number(2048)),
            ]),
            "status": wireStringMap(["driver_name": "veth"]),
        ]

        let interface = try OVSDBRowDecoder.decode(OVSInterface.self, from: row)

        XCTAssertEqual(interface.mtu, 1500)
        XCTAssertEqual(interface.ifindex, 2)
        XCTAssertNil(interface.mac)
        XCTAssertEqual(interface.mac_in_use, "aa:bb:cc:dd:ee:ff")
        XCTAssertEqual(interface.link_state, "up")
        XCTAssertNil(interface.link_speed)
        XCTAssertEqual(interface.statistics, ["rx_packets": 1024, "tx_packets": 2048])
        XCTAssertEqual(interface.status, ["driver_name": "veth"])
    }

    func testPortWithSingleInterfaceAndUnsetOptionals() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("port-1"),
            "interfaces": wireUUID(uuidB),
            "tag": emptySet,
            "trunks": wireSet([.number(10), .number(20)]),
            "qos": emptySet,
            "mac": emptySet,
            "bond_mode": emptySet,
            "external_ids": wireMap([]),
        ]

        let port = try OVSDBRowDecoder.decode(OVSPort.self, from: row)

        XCTAssertEqual(port.interfaces, [uuidB])
        XCTAssertNil(port.tag)
        XCTAssertEqual(port.trunks, [10, 20])
        XCTAssertNil(port.qos)
        XCTAssertNil(port.mac)
    }

    func testBridgeRow() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("br-int"),
            "ports": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
            "mirrors": emptySet,
            "netflow": wireUUID(uuidC),
            "sflow": emptySet,
            "ipfix": emptySet,
            "controller": wireUUID(uuidB),
            "protocols": wireSet([.string("OpenFlow13"), .string("OpenFlow15")]),
            "fail_mode": .string("secure"),
            "flood_vlans": .number(42),
            "flow_tables": wireMap([(.number(0), wireUUID(uuidC))]),
            "stp_enable": .boolean(false),
            "external_ids": wireStringMap(["system-id": uuidB]),
        ]

        let bridge = try OVSDBRowDecoder.decode(OVSBridge.self, from: row)

        XCTAssertEqual(bridge.uuid, uuidA)
        XCTAssertEqual(bridge.ports, [uuidB, uuidC])
        XCTAssertNil(bridge.mirrors)
        XCTAssertEqual(bridge.netflow, uuidC)
        XCTAssertNil(bridge.sflow)
        XCTAssertEqual(bridge.controller, [uuidB])
        XCTAssertEqual(bridge.protocols, ["OpenFlow13", "OpenFlow15"])
        XCTAssertEqual(bridge.fail_mode, "secure")
        XCTAssertEqual(bridge.flood_vlans, [42])
        XCTAssertEqual(bridge.flow_tables, ["0": uuidC])
        XCTAssertEqual(bridge.stp_enable, false)
        XCTAssertEqual(bridge.external_ids, ["system-id": uuidB])
    }

    /// QoS.queues is a map<integer,uuid>: integer keys and UUID-atom values.
    func testQoSWithIntegerKeyedQueues() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "type": .string("linux-htb"),
            "queues": wireMap([
                (.number(0), wireUUID(uuidB)),
                (.number(1), wireUUID(uuidC)),
            ]),
            "other_config": wireStringMap(["max-rate": "1000000"]),
        ]

        let qos = try OVSDBRowDecoder.decode(OVSQoS.self, from: row)

        XCTAssertEqual(qos.qosType, "linux-htb")
        XCTAssertEqual(qos.queues, [0: uuidB, 1: uuidC])
        XCTAssertEqual(qos.other_config, ["max-rate": "1000000"])
    }

    /// One bad row must not sink the whole getter: all rows in a realistic
    /// select response decode.
    func testMixedRowsAllDecode() throws {
        let rows: [OVSDBRow] = [
            ["_uuid": wireUUID(uuidA), "name": .string("ls-a"), "ports": emptySet],
            ["_uuid": wireUUID(uuidB), "name": .string("ls-b"), "ports": wireUUID(uuidC)],
            ["_uuid": wireUUID(uuidC), "name": .string("ls-c"), "ports": wireSet([wireUUID(uuidA), wireUUID(uuidB)])],
        ]

        let switches = try rows.map { try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: $0) }

        XCTAssertNil(switches[0].ports)
        XCTAssertEqual(switches[1].ports, [uuidC])
        XCTAssertEqual(switches[2].ports?.count, 2)
    }
}

final class OVSDBRowEncoderTests: XCTestCase {

    /// A UUID-shaped string in a string-typed column (a switch literally named
    /// like a UUID, or a UUID stored in external_ids) must stay a plain string.
    func testUUIDShapedStringsInStringColumnsStayStrings() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: uuidB,
            external_ids: ["vm-id": uuidC]
        )

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        XCTAssertEqual(row["name"], .string(uuidB))
        XCTAssertEqual(row["external_ids"], wireMap([(.string("vm-id"), .string(uuidC))]))
    }

    func testReferenceSetColumnEncodesUUIDAtoms() throws {
        let logicalSwitch = OVNLogicalSwitch(name: "ls-1", ports: [uuidB, uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        XCTAssertEqual(row["ports"], wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        XCTAssertNil(row["_uuid"])
    }

    func testScalarReferenceColumnEncodesUUIDAtom() throws {
        let port = OVSPort(name: "port-1", interfaces: [uuidB], tag: 100, qos: uuidC, bond_fake_iface: true)

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovs)

        XCTAssertEqual(row["interfaces"], wireSet([wireUUID(uuidB)]))
        XCTAssertEqual(row["qos"], wireUUID(uuidC))
        // Integers must stay numbers and booleans must stay booleans.
        XCTAssertEqual(row["tag"], .number(100))
        XCTAssertEqual(row["bond_fake_iface"], .boolean(true))
    }

    /// Non-reference string arrays (e.g. logical router port networks, LSP
    /// addresses) must not have their elements rewritten into UUID atoms.
    func testPlainStringSetElementsStayStrings() throws {
        let port = OVNLogicalSwitchPort(name: "lsp-1", addresses: ["router", uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)

        XCTAssertEqual(row["addresses"], wireSet([.string("router"), .string(uuidC)]))
    }

    func testIntegerKeyedUUIDValuedMapEncoding() throws {
        let qos = OVSQoS(qosType: "linux-htb", queues: [0: uuidB])

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovs)

        XCTAssertEqual(row["queues"], wireMap([(.number(0), wireUUID(uuidB))]))
    }

    func testBridgeFlowTablesEncodeIntegerKeys() throws {
        let bridge = OVSBridge(name: "br-0", flow_tables: ["0": uuidB])

        let row = try OVSDBRowEncoder.makeRow(from: bridge, hints: .ovs)

        XCTAssertEqual(row["flow_tables"], wireMap([(.number(0), wireUUID(uuidB))]))
    }

    func testStaticRouteReferenceColumnsEncodeUUIDAtoms() throws {
        let route = OVNLogicalRouterStaticRoute(
            ip_prefix: "10.0.0.0/24",
            nexthop: "192.168.1.1",
            output_port: "lrp0",
            policy: "dst-ip",
            bfd: uuidC
        )

        let row = try OVSDBRowEncoder.makeRow(from: route, hints: .ovn)

        // bfd is the only reference column; output_port is a plain port-name
        // string and nexthop/ip_prefix stay plain strings.
        XCTAssertEqual(row["bfd"], wireUUID(uuidC))
        XCTAssertEqual(row["output_port"], .string("lrp0"))
        XCTAssertEqual(row["nexthop"], .string("192.168.1.1"))
        XCTAssertEqual(row["ip_prefix"], .string("10.0.0.0/24"))
        XCTAssertEqual(row["policy"], .string("dst-ip"))
        XCTAssertNil(row["_uuid"])
    }

    func testStaticRouteRoundTrip() throws {
        let route = OVNLogicalRouterStaticRoute(
            ip_prefix: "0.0.0.0/0",
            nexthop: "10.0.0.1",
            policy: "src-ip",
            route_table: "rt1",
            selection_fields: ["ip_src", "ip_dst"],
            options: ["ecmp_symmetric_reply": "true"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: route, hints: .ovn)
        // selection_fields is a plain string set, not rewritten into UUID atoms.
        XCTAssertEqual(row["selection_fields"], wireSet([.string("ip_src"), .string("ip_dst")]))
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouterStaticRoute.self, from: row)

        XCTAssertEqual(decoded.ip_prefix, route.ip_prefix)
        XCTAssertEqual(decoded.nexthop, route.nexthop)
        XCTAssertEqual(decoded.policy, route.policy)
        XCTAssertEqual(decoded.route_table, route.route_table)
        XCTAssertEqual(decoded.selection_fields, route.selection_fields)
        XCTAssertEqual(decoded.options, route.options)
        XCTAssertEqual(decoded.external_ids, route.external_ids)
    }

    func testGatewayChassisEncodesChassisNameAsStringAndPriorityAsNumber() throws {
        let chassis = OVNGatewayChassis(
            name: "lrp0-hv1",
            chassis_name: "hv1",
            priority: 100,
            options: ["k": "v"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)

        // chassis_name is a plain string (a Chassis *name*), not a UUID atom.
        XCTAssertEqual(row["chassis_name"], .string("hv1"))
        XCTAssertEqual(row["name"], .string("lrp0-hv1"))
        XCTAssertEqual(row["priority"], .number(100))
        XCTAssertNil(row["_uuid"])
    }

    func testGatewayChassisRoundTrip() throws {
        let chassis = OVNGatewayChassis(
            name: "lrp0-hv2",
            chassis_name: "hv2",
            priority: 50,
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNGatewayChassis.self, from: row)

        XCTAssertEqual(decoded.name, chassis.name)
        XCTAssertEqual(decoded.chassis_name, chassis.chassis_name)
        XCTAssertEqual(decoded.priority, chassis.priority)
        XCTAssertEqual(decoded.external_ids, chassis.external_ids)
    }

    func testHAChassisGroupEncodesHAChassisAsUUIDSet() throws {
        let group = OVNHAChassisGroup(
            name: "grp0",
            ha_chassis: [uuidA, uuidB],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: group, hints: .ovn)

        XCTAssertEqual(row["ha_chassis"], wireSet([wireUUID(uuidA), wireUUID(uuidB)]))
        XCTAssertEqual(row["name"], .string("grp0"))
        XCTAssertNil(row["_uuid"])
    }

    func testHAChassisEncodesChassisNameAsStringAndPriorityAsNumber() throws {
        let chassis = OVNHAChassis(
            chassis_name: "hv3",
            priority: 20,
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)

        XCTAssertEqual(row["chassis_name"], .string("hv3"))
        XCTAssertEqual(row["priority"], .number(20))
        XCTAssertNil(row["_uuid"])
    }

    func testHAChassisRoundTrip() throws {
        let chassis = OVNHAChassis(chassis_name: "hv4", priority: 10)

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNHAChassis.self, from: row)

        XCTAssertEqual(decoded.chassis_name, chassis.chassis_name)
        XCTAssertEqual(decoded.priority, chassis.priority)
    }

    func testDHCPOptionsRoundTrip() throws {
        let dhcp = OVNDHCPOptions(
            cidr: "10.0.0.0/24",
            options: ["lease_time": "3600", "server_id": "10.0.0.1"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: dhcp, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNDHCPOptions.self, from: row)

        XCTAssertEqual(decoded.cidr, dhcp.cidr)
        XCTAssertEqual(decoded.options, dhcp.options)
        XCTAssertEqual(decoded.external_ids, dhcp.external_ids)
    }

    func testQoSRoundTrip() throws {
        let qos = OVSQoS(qosType: "linux-htb", queues: [0: uuidB, 1: uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovs)
        let decoded = try OVSDBRowDecoder.decode(OVSQoS.self, from: row)

        XCTAssertEqual(decoded.qosType, qos.qosType)
        XCTAssertEqual(decoded.queues, qos.queues)
    }
}

final class JSONValueWireEncodingTests: XCTestCase {

    /// Integral numbers must serialize as JSON integers: ovsdb-server rejects
    /// "1.0" for integer-typed columns and map keys.
    func testIntegralNumbersSerializeWithoutFraction() throws {
        let encoded = try JSONEncoder().encode(JSONValue.number(5))
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "5")

        let fractional = try JSONEncoder().encode(JSONValue.number(2.5))
        XCTAssertEqual(String(data: fractional, encoding: .utf8), "2.5")
    }
}
