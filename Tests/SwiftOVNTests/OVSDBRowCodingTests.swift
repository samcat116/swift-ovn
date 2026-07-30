import Foundation
import Testing
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

/// Sorts the pairs of a `["map", [[k, v], ...]]` value, leaving anything else
/// untouched. RFC 7047 maps are unordered and both the encoder and
/// `wireStringMap` derive their pair order from `Dictionary` iteration, which
/// varies between processes — so multi-entry maps must be compared
/// order-insensitively or the comparison flakes.
private func normalizingMapOrder(_ value: JSONValue?) -> JSONValue? {
    guard let value else { return nil }
    guard case .array(let tagged) = value, tagged.count == 2,
        case .string("map") = tagged[0],
        case .array(let pairs) = tagged[1]
    else { return value }
    return .array([.string("map"), .array(pairs.sorted { String(describing: $0) < String(describing: $1) })])
}

private let uuidA = "0d53b52f-7f4c-4c8f-9b1e-1a2b3c4d5e6f"
private let uuidB = "550e8400-e29b-41d4-a716-446655440000"
private let uuidC = "9a3e11a4-9f7a-4d0a-8f5e-0123456789ab"

@Suite("OVSDB row decoding")
struct OVSDBRowDecoderTests {

    // MARK: OVN Northbound

    /// The headline regression: a Logical_Switch_Port fresh from ovn-nbctl has
    /// every optional scalar column transmitted as the empty set ["set",[]],
    /// and its single address as a bare string atom.
    @Test("A Logical_Switch_Port with unset optional scalars")
    func logicalSwitchPortWithUnsetOptionalScalars() throws {
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

        #expect(port.uuid == uuidA)
        #expect(port.name == "lsp-1")
        #expect(port.addresses == ["50:6b:8d:d1:00:01 10.0.0.11"])
        #expect(port.port_security == nil)
        #expect(port.tag == nil)
        #expect(port.tag_request == nil)
        #expect(port.up == nil)
        #expect(port.enabled == nil)
        #expect(port.dhcpv4_options == nil)
        #expect(port.dhcpv6_options == nil)
        #expect(port.options == [:])
        #expect(port.external_ids == ["neutron:port_id": uuidB])
    }

    @Test("A Logical_Switch_Port with populated optional scalars")
    func logicalSwitchPortWithPopulatedOptionalScalars() throws {
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

        #expect(port.tag == 100)
        #expect(port.up == true)
        #expect(port.enabled == false)
        #expect(port.dhcpv4_options == uuidC)
        #expect(port.addresses == ["dynamic", "unknown"])
    }

    /// Every wire shape a reference-set column can arrive in: the empty set
    /// (which decodes to nil, not `[]`), a single element sent as the bare atom
    /// rather than a one-element set, and the tagged multi-element form.
    @Test("A reference set column decodes from every wire shape", arguments: [
        (emptySet, nil),
        (wireUUID(uuidB), [uuidB]),
        (wireSet([wireUUID(uuidB), wireUUID(uuidC)]), [uuidB, uuidC]),
    ] as [(JSONValue, [String]?)])
    func referenceSetColumnDecodes(wire: JSONValue, expected: [String]?) throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("ls-1"),
            "ports": wire,
            "acls": emptySet,
            "external_ids": wireMap([]),
        ]

        let logicalSwitch = try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: row)

        #expect(logicalSwitch.ports == expected)
        #expect(logicalSwitch.acls == nil)
    }

    @Test("A Chassis with a non-optional string set")
    func chassisWithNonOptionalStringSet() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("chassis-1"),
            "hostname": .string("node-1"),
            "encaps": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
            "nb_cfg": .number(7),
            "transport_zones": emptySet,
        ]

        let chassis = try OVSDBRowDecoder.decode(OVNChassis.self, from: row)

        #expect(chassis.encaps == [uuidB, uuidC])
        #expect(chassis.nb_cfg == 7)
        #expect(chassis.transport_zones == nil)
    }

    @Test("An Advertised_Route row")
    func advertisedRouteRow() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "datapath": wireUUID(uuidB),
            "logical_port": wireUUID(uuidC),
            "ip_prefix": .string("192.0.2.10/32"),
            "tracked_port": emptySet,
            "external_ids": wireStringMap(["owner": "northd"]),
        ]

        let route = try OVSDBRowDecoder.decode(OVNAdvertisedRoute.self, from: row)

        #expect(route.uuid == uuidA)
        #expect(route.datapath == uuidB)
        #expect(route.logical_port == uuidC)
        #expect(route.ip_prefix == "192.0.2.10/32")
        #expect(route.tracked_port == nil)
        #expect(route.external_ids == ["owner": "northd"])
    }

    /// `tracked_port` is an optional scalar reference: unset it is the empty
    /// set, set it is the bare UUID atom.
    @Test("An Advertised_Route's optional scalar reference decodes from both wire shapes",
          arguments: [(emptySet, nil), (wireUUID(uuidC), uuidC)] as [(JSONValue, String?)])
    func advertisedRouteTrackedPort(wire: JSONValue, expected: String?) throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "datapath": wireUUID(uuidB),
            "logical_port": wireUUID(uuidC),
            "ip_prefix": .string("10.0.0.0/24"),
            "tracked_port": wire,
        ]

        let route = try OVSDBRowDecoder.decode(OVNAdvertisedRoute.self, from: row)

        #expect(route.tracked_port == expected)
    }

    @Test("A Learned_Route row")
    func learnedRouteRow() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "datapath": wireUUID(uuidB),
            "logical_port": wireUUID(uuidC),
            "ip_prefix": .string("203.0.113.0/24"),
            "nexthop": .string("192.0.2.254"),
            "external_ids": wireMap([]),
        ]

        let route = try OVSDBRowDecoder.decode(OVNLearnedRoute.self, from: row)

        #expect(route.uuid == uuidA)
        #expect(route.datapath == uuidB)
        #expect(route.logical_port == uuidC)
        #expect(route.ip_prefix == "203.0.113.0/24")
        #expect(route.nexthop == "192.0.2.254")
        #expect(route.external_ids == [:])
    }

    // MARK: Open_vSwitch

    @Test("An Interface with unset and bare scalars")
    func interfaceWithUnsetAndBareScalars() throws {
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

        #expect(interface.mtu == 1500)
        #expect(interface.ifindex == 2)
        #expect(interface.mac == nil)
        #expect(interface.mac_in_use == "aa:bb:cc:dd:ee:ff")
        #expect(interface.link_state == "up")
        #expect(interface.link_speed == nil)
        #expect(interface.statistics == ["rx_packets": 1024, "tx_packets": 2048])
        #expect(interface.status == ["driver_name": "veth"])
    }

    @Test("A Port with a single interface and unset optionals")
    func portWithSingleInterfaceAndUnsetOptionals() throws {
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

        #expect(port.interfaces == [uuidB])
        #expect(port.tag == nil)
        #expect(port.trunks == [10, 20])
        #expect(port.qos == nil)
        #expect(port.mac == nil)
    }

    @Test("A Bridge row")
    func bridgeRow() throws {
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

        #expect(bridge.uuid == uuidA)
        #expect(bridge.ports == [uuidB, uuidC])
        #expect(bridge.mirrors == nil)
        #expect(bridge.netflow == uuidC)
        #expect(bridge.sflow == nil)
        #expect(bridge.controller == [uuidB])
        #expect(bridge.protocols == ["OpenFlow13", "OpenFlow15"])
        #expect(bridge.fail_mode == "secure")
        #expect(bridge.flood_vlans == [42])
        #expect(bridge.flow_tables == ["0": uuidC])
        #expect(bridge.stp_enable == false)
        #expect(bridge.external_ids == ["system-id": uuidB])
    }

    /// QoS.queues is a map<integer,uuid>: integer keys and UUID-atom values.
    @Test("QoS with integer-keyed queues")
    func qoSWithIntegerKeyedQueues() throws {
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

        #expect(qos.qosType == "linux-htb")
        #expect(qos.queues == [0: uuidB, 1: uuidC])
        #expect(qos.other_config == ["max-rate": "1000000"])
    }

    /// One bad row must not sink the whole getter: all rows in a realistic
    /// select response decode.
    @Test("Every row of a mixed select response decodes")
    func mixedRowsAllDecode() throws {
        let rows: [OVSDBRow] = [
            ["_uuid": wireUUID(uuidA), "name": .string("ls-a"), "ports": emptySet],
            ["_uuid": wireUUID(uuidB), "name": .string("ls-b"), "ports": wireUUID(uuidC)],
            ["_uuid": wireUUID(uuidC), "name": .string("ls-c"), "ports": wireSet([wireUUID(uuidA), wireUUID(uuidB)])],
        ]

        let switches = try rows.map { try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: $0) }

        #expect(switches[0].ports == nil)
        #expect(switches[1].ports == [uuidC])
        #expect(switches[2].ports?.count == 2)
    }
}

@Suite("OVSDB row encoding")
struct OVSDBRowEncoderTests {

    /// A UUID-shaped string in a string-typed column (a switch literally named
    /// like a UUID, or a UUID stored in external_ids) must stay a plain string.
    @Test("UUID-shaped strings in string columns stay strings")
    func uuidShapedStringsInStringColumnsStayStrings() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: uuidB,
            external_ids: ["vm-id": uuidC]
        )

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        #expect(row["name"] == .string(uuidB))
        #expect(row["external_ids"] == wireMap([(.string("vm-id"), .string(uuidC))]))
    }

    @Test("A reference set column encodes UUID atoms")
    func referenceSetColumnEncodesUUIDAtoms() throws {
        let logicalSwitch = OVNLogicalSwitch(name: "ls-1", ports: [uuidB, uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        #expect(row["ports"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["_uuid"] == nil)
    }

    @Test("A scalar reference column encodes a UUID atom")
    func scalarReferenceColumnEncodesUUIDAtom() throws {
        let port = OVSPort(name: "port-1", interfaces: [uuidB], tag: 100, qos: uuidC, bond_fake_iface: true)

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovs)

        #expect(row["interfaces"] == wireSet([wireUUID(uuidB)]))
        #expect(row["qos"] == wireUUID(uuidC))
        // Integers must stay numbers and booleans must stay booleans.
        #expect(row["tag"] == .number(100))
        #expect(row["bond_fake_iface"] == .boolean(true))
    }

    /// Non-reference string arrays (e.g. logical router port networks, LSP
    /// addresses) must not have their elements rewritten into UUID atoms.
    @Test("Plain string set elements stay strings")
    func plainStringSetElementsStayStrings() throws {
        let port = OVNLogicalSwitchPort(name: "lsp-1", addresses: ["router", uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)

        #expect(row["addresses"] == wireSet([.string("router"), .string(uuidC)]))
    }

    @Test("An integer-keyed, UUID-valued map encodes")
    func integerKeyedUUIDValuedMapEncoding() throws {
        let qos = OVSQoS(qosType: "linux-htb", queues: [0: uuidB])

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovs)

        #expect(row["queues"] == wireMap([(.number(0), wireUUID(uuidB))]))
    }

    @Test("A Bridge's flow_tables encodes integer keys")
    func bridgeFlowTablesEncodeIntegerKeys() throws {
        let bridge = OVSBridge(name: "br-0", flow_tables: ["0": uuidB])

        let row = try OVSDBRowEncoder.makeRow(from: bridge, hints: .ovs)

        #expect(row["flow_tables"] == wireMap([(.number(0), wireUUID(uuidB))]))
    }

    @Test("A static route's reference columns encode UUID atoms")
    func staticRouteReferenceColumnsEncodeUUIDAtoms() throws {
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
        #expect(row["bfd"] == wireUUID(uuidC))
        #expect(row["output_port"] == .string("lrp0"))
        #expect(row["nexthop"] == .string("192.168.1.1"))
        #expect(row["ip_prefix"] == .string("10.0.0.0/24"))
        #expect(row["policy"] == .string("dst-ip"))
        #expect(row["_uuid"] == nil)
    }

    @Test("A static route round trips")
    func staticRouteRoundTrip() throws {
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
        #expect(row["selection_fields"] == wireSet([.string("ip_src"), .string("ip_dst")]))
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouterStaticRoute.self, from: row)

        #expect(decoded.ip_prefix == route.ip_prefix)
        #expect(decoded.nexthop == route.nexthop)
        #expect(decoded.policy == route.policy)
        #expect(decoded.route_table == route.route_table)
        #expect(decoded.selection_fields == route.selection_fields)
        #expect(decoded.options == route.options)
        #expect(decoded.external_ids == route.external_ids)
    }

    @Test("A logical router port round trips with IPv6 RA configs")
    func logicalRouterPortRoundTripWithIPv6RAConfigs() throws {
        let port = OVNLogicalRouterPort(
            name: "lrp-net0",
            mac: "0a:58:0a:00:00:01",
            networks: ["10.0.0.1/24", "fd12:3456:789a::1/64"],
            ipv6_ra_configs: ["address_mode": "dhcpv6_stateful", "send_periodic": "true"],
            options: ["gateway_mtu": "1500"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)
        #expect(
            normalizingMapOrder(row["ipv6_ra_configs"])
                == normalizingMapOrder(
                    wireStringMap(["address_mode": "dhcpv6_stateful", "send_periodic": "true"]))
        )
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouterPort.self, from: row)

        #expect(decoded.name == port.name)
        #expect(decoded.mac == port.mac)
        #expect(decoded.networks == port.networks)
        #expect(decoded.ipv6_ra_configs == port.ipv6_ra_configs)
        #expect(decoded.options == port.options)
        #expect(decoded.external_ids == port.external_ids)
    }

    /// A router port fresh from ovn-nbctl carries ipv6_ra_configs as an empty
    /// map; rows from peers that predate the column omit it entirely. Both
    /// must decode.
    @Test("A logical router port decodes without IPv6 RA configs",
          arguments: [(nil, nil), (wireMap([]), [:])] as [(JSONValue?, [String: String]?)])
    func logicalRouterPortWithoutIPv6RAConfigs(
        wire: JSONValue?,
        expected: [String: String]?
    ) throws {
        var row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lrp-bare"),
            "mac": .string("0a:58:0a:00:00:01"),
            "networks": .string("10.0.0.1/24"),
        ]
        row["ipv6_ra_configs"] = wire

        let port = try OVSDBRowDecoder.decode(OVNLogicalRouterPort.self, from: row)

        #expect(port.ipv6_ra_configs == expected)
    }

    @Test("A port group's reference columns encode UUID atoms")
    func portGroupReferenceColumnsEncodeUUIDAtoms() throws {
        let portGroup = OVNPortGroup(
            name: "pg-web",
            ports: [uuidB, uuidC],
            acls: [uuidA],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: portGroup, hints: .ovn)

        // ports and acls are reference sets rewritten into UUID atoms; the
        // encoder always emits the tagged ["set", ...] form, even for one item.
        #expect(row["ports"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["acls"] == wireSet([wireUUID(uuidA)]))
        #expect(row["name"] == .string("pg-web"))
        #expect(row["_uuid"] == nil)
    }

    @Test("A port group round trips")
    func portGroupRoundTrip() throws {
        let portGroup = OVNPortGroup(
            name: "pg-db",
            ports: [uuidB, uuidC],
            acls: [uuidA],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: portGroup, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNPortGroup.self, from: row)

        #expect(decoded.name == portGroup.name)
        #expect(decoded.ports == portGroup.ports)
        #expect(decoded.acls == portGroup.acls)
        #expect(decoded.external_ids == portGroup.external_ids)
    }

    /// A fresh, empty port group has its reference sets sent as the empty set,
    /// which decodes to nil rather than an empty array.
    @Test("A port group with empty membership")
    func portGroupWithEmptyMembership() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("pg-empty"),
            "ports": emptySet,
            "acls": emptySet,
        ]

        let portGroup = try OVSDBRowDecoder.decode(OVNPortGroup.self, from: row)

        #expect(portGroup.name == "pg-empty")
        #expect(portGroup.ports == nil)
        #expect(portGroup.acls == nil)
    }

    @Test("A Gateway_Chassis encodes chassis_name as a string and priority as a number")
    func gatewayChassisEncodesChassisNameAsStringAndPriorityAsNumber() throws {
        let chassis = OVNGatewayChassis(
            name: "lrp0-hv1",
            chassis_name: "hv1",
            priority: 100,
            options: ["k": "v"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)

        // chassis_name is a plain string (a Chassis *name*), not a UUID atom.
        #expect(row["chassis_name"] == .string("hv1"))
        #expect(row["name"] == .string("lrp0-hv1"))
        #expect(row["priority"] == .number(100))
        #expect(row["_uuid"] == nil)
    }

    @Test("A Gateway_Chassis round trips")
    func gatewayChassisRoundTrip() throws {
        let chassis = OVNGatewayChassis(
            name: "lrp0-hv2",
            chassis_name: "hv2",
            priority: 50,
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNGatewayChassis.self, from: row)

        #expect(decoded.name == chassis.name)
        #expect(decoded.chassis_name == chassis.chassis_name)
        #expect(decoded.priority == chassis.priority)
        #expect(decoded.external_ids == chassis.external_ids)
    }

    @Test("An HA_Chassis_Group encodes ha_chassis as a UUID set")
    func haChassisGroupEncodesHAChassisAsUUIDSet() throws {
        let group = OVNHAChassisGroup(
            name: "grp0",
            ha_chassis: [uuidA, uuidB],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: group, hints: .ovn)

        #expect(row["ha_chassis"] == wireSet([wireUUID(uuidA), wireUUID(uuidB)]))
        #expect(row["name"] == .string("grp0"))
        #expect(row["_uuid"] == nil)
    }

    @Test("An HA_Chassis encodes chassis_name as a string and priority as a number")
    func haChassisEncodesChassisNameAsStringAndPriorityAsNumber() throws {
        let chassis = OVNHAChassis(
            chassis_name: "hv3",
            priority: 20,
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)

        #expect(row["chassis_name"] == .string("hv3"))
        #expect(row["priority"] == .number(20))
        #expect(row["_uuid"] == nil)
    }

    @Test("An HA_Chassis round trips")
    func haChassisRoundTrip() throws {
        let chassis = OVNHAChassis(chassis_name: "hv4", priority: 10)

        let row = try OVSDBRowEncoder.makeRow(from: chassis, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNHAChassis.self, from: row)

        #expect(decoded.chassis_name == chassis.chassis_name)
        #expect(decoded.priority == chassis.priority)
    }

    @Test("DHCP_Options round trips")
    func dhcpOptionsRoundTrip() throws {
        let dhcp = OVNDHCPOptions(
            cidr: "10.0.0.0/24",
            options: ["lease_time": "3600", "server_id": "10.0.0.1"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: dhcp, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNDHCPOptions.self, from: row)

        #expect(decoded.cidr == dhcp.cidr)
        #expect(decoded.options == dhcp.options)
        #expect(decoded.external_ids == dhcp.external_ids)
    }

    @Test("QoS round trips")
    func qoSRoundTrip() throws {
        let qos = OVSQoS(qosType: "linux-htb", queues: [0: uuidB, 1: uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovs)
        let decoded = try OVSDBRowDecoder.decode(OVSQoS.self, from: row)

        #expect(decoded.qosType == qos.qosType)
        #expect(decoded.queues == qos.queues)
    }
}

@Suite("JSONValue wire encoding")
struct JSONValueWireEncodingTests {

    /// Integral numbers must serialize as JSON integers: ovsdb-server rejects
    /// "1.0" for integer-typed columns and map keys.
    @Test("Numbers serialize with a fractional part only when they have one",
          arguments: [(JSONValue.number(5), "5"), (JSONValue.number(2.5), "2.5")])
    func numbersSerializeWithoutSpuriousFraction(value: JSONValue, expected: String) throws {
        let encoded = try JSONEncoder().encode(value)

        #expect(String(decoding: encoded, as: UTF8.self) == expected)
    }
}
