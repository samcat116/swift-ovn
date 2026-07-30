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

    /// A container port as ovn-nbctl leaves it: `parent_name` plus the
    /// `tag_request` it makes meaningful, and the `dynamic_addresses` northd
    /// wrote back for `addresses: ["dynamic"]` — the one place the allocated
    /// MAC/IP can be read.
    @Test("A container Logical_Switch_Port with a dynamic address")
    func containerLogicalSwitchPortWithDynamicAddress() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lsp-container"),
            "type": .string(""),
            "parent_name": .string("lsp-vm"),
            "tag_request": .number(42),
            "tag": .number(42),
            "addresses": .string("dynamic"),
            "dynamic_addresses": .string("0a:00:00:00:00:07 10.0.0.7"),
            "peer": emptySet,
            "health_checks": emptySet,
            "mirror_rules": wireUUID(uuidB),
            "ha_chassis_group": emptySet,
        ]

        let port = try OVSDBRowDecoder.decode(OVNLogicalSwitchPort.self, from: row)

        #expect(port.parent_name == "lsp-vm")
        #expect(port.tag_request == 42)
        #expect(port.addresses == ["dynamic"])
        #expect(port.dynamic_addresses == "0a:00:00:00:00:07 10.0.0.7")
        #expect(port.peer == nil)
        #expect(port.health_checks == nil)
        #expect(port.mirror_rules == [uuidB])
        #expect(port.ha_chassis_group == nil)
    }

    /// A port pairing two switches carries the other port's *name* in `peer`,
    /// so a UUID-shaped name must survive as a string.
    @Test("A Logical_Switch_Port's peer decodes as a name")
    func logicalSwitchPortPeerDecodesAsAName() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lsp-pair-a"),
            "peer": .string(uuidB),
        ]

        let port = try OVSDBRowDecoder.decode(OVNLogicalSwitchPort.self, from: row)

        #expect(port.peer == uuidB)
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

    /// The Northbound QoS table's `action` and `bandwidth` are
    /// map<string,integer> — the one map shape no other model exercises, since
    /// every other string-keyed map in the schema has string values.
    @Test("A Northbound QoS row with integer-valued maps")
    func northboundQoSWithIntegerValuedMaps() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "priority": .number(1000),
            "direction": .string("from-lport"),
            "match": .string("inport == \"lsp-1\""),
            "action": wireMap([(.string("dscp"), .number(48))]),
            "bandwidth": wireMap([
                (.string("rate"), .number(10_000)),
                (.string("burst"), .number(2_000)),
            ]),
            "external_ids": wireStringMap(["owner": "test"]),
        ]

        let qos = try OVSDBRowDecoder.decode(OVNQoS.self, from: row)

        #expect(qos.uuid == uuidA)
        #expect(qos.priority == 1000)
        #expect(qos.direction == "from-lport")
        #expect(qos.match == "inport == \"lsp-1\"")
        #expect(qos.action == ["dscp": 48])
        #expect(qos.bandwidth == ["rate": 10_000, "burst": 2_000])
        #expect(qos.external_ids == ["owner": "test"])
    }

    /// `action` and `bandwidth` both have min 0, so a rule that sets neither
    /// has them transmitted as empty maps — which decode to `[:]`, not nil
    /// (only the empty *set* means "no value").
    @Test("A Northbound QoS row with empty maps")
    func northboundQoSWithEmptyMaps() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "priority": .number(0),
            "direction": .string("to-lport"),
            "match": .string("ip4.dst == 10.0.0.0/24"),
            "action": wireMap([]),
            "bandwidth": wireMap([]),
        ]

        let qos = try OVSDBRowDecoder.decode(OVNQoS.self, from: row)

        #expect(qos.action == [:])
        #expect(qos.bandwidth == [:])
    }

    /// A BFD session as ovsdb-server sends it: the optional integer columns are
    /// empty sets when unset and bare numbers when set, and `status` — which
    /// ovn-northd writes, not the client — arrives as a bare string.
    @Test("A BFD session with set and unset optional scalars")
    func bfdSessionWithSetAndUnsetOptionalScalars() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "logical_port": .string("lrp0"),
            "dst_ip": .string("192.168.1.1"),
            "min_tx": .number(250),
            "min_rx": emptySet,
            "detect_mult": .number(5),
            "options": wireMap([]),
            "status": .string("up"),
            "external_ids": wireStringMap(["owner": "test"]),
        ]

        let bfd = try OVSDBRowDecoder.decode(OVNBFD.self, from: row)

        #expect(bfd.uuid == uuidA)
        #expect(bfd.logical_port == "lrp0")
        #expect(bfd.dst_ip == "192.168.1.1")
        #expect(bfd.min_tx == 250)
        #expect(bfd.min_rx == nil)
        #expect(bfd.detect_mult == 5)
        #expect(bfd.status == "up")
        #expect(bfd.external_ids == ["owner": "test"])
    }

    @Test("A DNS row's records decode as a map")
    func dnsRecordsDecodeAsAMap() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "records": wireStringMap(["vm1.ovn.org": "10.0.0.11", "vm2.ovn.org": "10.0.0.12"]),
            "options": wireMap([]),
            "external_ids": wireStringMap(["owner": "test"]),
        ]

        let dns = try OVSDBRowDecoder.decode(OVNDNS.self, from: row)

        #expect(dns.uuid == uuidA)
        #expect(dns.records == ["vm1.ovn.org": "10.0.0.11", "vm2.ovn.org": "10.0.0.12"])
        #expect(dns.external_ids == ["owner": "test"])
    }

    /// A record set created empty and filled later: `records` has min 0, so it
    /// arrives as an empty map and decodes to `[:]` rather than failing the
    /// non-optional property.
    @Test("A DNS row with no records")
    func dnsRowWithNoRecords() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "records": wireMap([]),
            "options": wireMap([]),
            "external_ids": wireMap([]),
        ]

        let dns = try OVSDBRowDecoder.decode(OVNDNS.self, from: row)

        #expect(dns.records == [:])
    }

    /// A meter fresh from `ovn-nbctl meter-add` has exactly one band, so
    /// `bands` arrives as the bare UUID atom, and `fair` — the one optional
    /// column — as the empty set.
    @Test("A Meter with a single band and no fairness setting")
    func meterWithSingleBandAndNoFairness() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("acl-log-meter"),
            "unit": .string("pktps"),
            "bands": wireUUID(uuidB),
            "fair": emptySet,
            "external_ids": wireStringMap(["owner": "test"]),
        ]

        let meter = try OVSDBRowDecoder.decode(OVNMeter.self, from: row)

        #expect(meter.uuid == uuidA)
        #expect(meter.name == "acl-log-meter")
        #expect(meter.unit == "pktps")
        #expect(meter.bands == [uuidB])
        #expect(meter.fair == nil)
        #expect(meter.external_ids == ["owner": "test"])
    }

    @Test("A Meter with several bands and fairness set")
    func meterWithSeveralBandsAndFairnessSet() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("copp-meter"),
            "unit": .string("kbps"),
            "bands": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
            "fair": .boolean(true),
            "external_ids": wireMap([]),
        ]

        let meter = try OVSDBRowDecoder.decode(OVNMeter.self, from: row)

        #expect(meter.bands == [uuidB, uuidC])
        #expect(meter.fair == true)
        #expect(meter.external_ids == [:])
    }

    /// `action`, `rate` and `burst_size` are all required scalars, so a band row
    /// never carries the empty set for them.
    @Test("A Meter_Band row")
    func meterBandRow() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidB),
            "action": .string("drop"),
            "rate": .number(100),
            "burst_size": .number(25),
            "external_ids": wireStringMap(["owner": "test"]),
        ]

        let band = try OVSDBRowDecoder.decode(OVNMeterBand.self, from: row)

        #expect(band.uuid == uuidB)
        #expect(band.action == "drop")
        #expect(band.rate == 100)
        #expect(band.burst_size == 25)
        #expect(band.external_ids == ["owner": "test"])
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

    /// The full column set of the current Southbound schema, including the
    /// `type`/`protocol` columns whose Swift names have to differ.
    @Test("A Service_Monitor row")
    func serviceMonitorRow() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "type": .string("load-balancer"),
            "ip": .string("10.0.0.11"),
            "mac": .string("50:6b:8d:d1:00:01"),
            "protocol": .string("tcp"),
            "port": .number(8080),
            "logical_input_port": .string("lsp-probe"),
            "logical_port": .string("lsp-backend-1"),
            "src_mac": .string("50:6b:8d:d1:00:99"),
            "src_ip": .string("10.0.0.2"),
            "chassis_name": .string("hv-1"),
            "status": .string("online"),
            "ic_learned": .boolean(false),
            "remote": .boolean(false),
            "options": wireStringMap(["interval": "5"]),
            "external_ids": wireStringMap(["lb_id": uuidB]),
        ]

        let monitor = try OVSDBRowDecoder.decode(OVNServiceMonitor.self, from: row)

        #expect(monitor.uuid == uuidA)
        #expect(monitor.monitorType == "load-balancer")
        #expect(monitor.ip == "10.0.0.11")
        #expect(monitor.mac == "50:6b:8d:d1:00:01")
        #expect(monitor.protocolType == "tcp")
        #expect(monitor.port == 8080)
        #expect(monitor.logical_input_port == "lsp-probe")
        #expect(monitor.logical_port == "lsp-backend-1")
        #expect(monitor.src_mac == "50:6b:8d:d1:00:99")
        #expect(monitor.src_ip == "10.0.0.2")
        #expect(monitor.chassis_name == "hv-1")
        #expect(monitor.status == "online")
        #expect(monitor.ic_learned == false)
        #expect(monitor.remote == false)
        #expect(monitor.options == ["interval": "5"])
        #expect(monitor.external_ids == ["lb_id": uuidB])
    }

    /// A Southbound database older than this library sends only the columns
    /// its own schema has: `chassis_name` arrived in 24.03, and `type`, `mac`,
    /// `logical_input_port`, `ic_learned` and `remote` later still. Those
    /// columns are optional precisely so this row still decodes. `status` is
    /// unset until the probing chassis reports an outcome — a backend with no
    /// status is not yet known to be up.
    @Test("A Service_Monitor row from an older schema, before any probe result")
    func serviceMonitorRowFromOlderSchema() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "ip": .string("10.0.0.11"),
            "protocol": .string("tcp"),
            "port": .number(80),
            "logical_port": .string("lsp-backend-1"),
            "src_mac": .string("50:6b:8d:d1:00:99"),
            "src_ip": .string("10.0.0.2"),
            "status": emptySet,
            "options": wireMap([]),
            "external_ids": wireMap([]),
        ]

        let monitor = try OVSDBRowDecoder.decode(OVNServiceMonitor.self, from: row)

        #expect(monitor.ip == "10.0.0.11")
        #expect(monitor.port == 80)
        #expect(monitor.protocolType == "tcp")
        #expect(monitor.monitorType == nil)
        #expect(monitor.mac == nil)
        #expect(monitor.logical_input_port == nil)
        #expect(monitor.chassis_name == nil)
        #expect(monitor.ic_learned == nil)
        #expect(monitor.remote == nil)
        #expect(monitor.status == nil)
    }

    /// A Port_Binding mid-live-migration: `chassis` still holds the source and
    /// `requested_chassis` names the destination, with the multi-chassis
    /// columns carrying the second binding and its tunnel.
    @Test("A Port_Binding during live migration")
    func portBindingDuringLiveMigration() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "logical_port": .string("lsp-vm"),
            "type": .string(""),
            "datapath": wireUUID(uuidB),
            "tunnel_key": .number(3),
            "chassis": wireUUID(uuidB),
            "requested_chassis": wireUUID(uuidC),
            "additional_chassis": wireUUID(uuidC),
            "requested_additional_chassis": wireSet([wireUUID(uuidC)]),
            "encap": wireUUID(uuidA),
            "additional_encap": wireSet([wireUUID(uuidB), wireUUID(uuidC)]),
            "mac": .string("0a:00:00:00:00:03 10.0.0.3"),
            "port_security": emptySet,
            "nat_addresses": emptySet,
            "virtual_parent": emptySet,
            "mirror_port": emptySet,
            "mirror_rules": emptySet,
            "up": .boolean(true),
        ]

        let binding = try OVSDBRowDecoder.decode(OVNPortBinding.self, from: row)

        #expect(binding.chassis == uuidB)
        #expect(binding.requested_chassis == uuidC)
        #expect(binding.additional_chassis == [uuidC])
        #expect(binding.requested_additional_chassis == [uuidC])
        #expect(binding.encap == uuidA)
        #expect(binding.additional_encap == [uuidB, uuidC])
        #expect(binding.port_security == nil)
        #expect(binding.nat_addresses == nil)
        #expect(binding.virtual_parent == nil)
        #expect(binding.mirror_port == nil)
        #expect(binding.mirror_rules == nil)
        #expect(binding.up == true)
    }

    /// A `virtual` port binding and an `l3gateway` one, which is where
    /// `virtual_parent` and `nat_addresses` are actually populated.
    @Test("A Port_Binding with virtual_parent and nat_addresses")
    func portBindingWithVirtualParentAndNATAddresses() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "logical_port": .string("lsp-vip"),
            "type": .string("virtual"),
            "datapath": wireUUID(uuidB),
            "tunnel_key": .number(4),
            "virtual_parent": .string("lsp-vm"),
            "nat_addresses": wireSet([
                .string("80:fa:5b:06:72:b7 158.36.44.22"),
                .string("80:fa:5b:06:72:b7 158.36.44.24"),
            ]),
            "port_security": .string("0a:00:00:00:00:04 10.0.0.4"),
        ]

        let binding = try OVSDBRowDecoder.decode(OVNPortBinding.self, from: row)

        #expect(binding.bindingType == "virtual")
        #expect(binding.virtual_parent == "lsp-vm")
        #expect(binding.nat_addresses == [
            "80:fa:5b:06:72:b7 158.36.44.22",
            "80:fa:5b:06:72:b7 158.36.44.24",
        ])
        #expect(binding.port_security == ["0a:00:00:00:00:04 10.0.0.4"])
    }

    @Test("A Logical_Flow with a description", arguments: [
        (emptySet, nil),
        (JSONValue.string("ingress ACL evaluation"), "ingress ACL evaluation"),
    ] as [(JSONValue, String?)])
    func logicalFlowWithDescription(wire: JSONValue, expected: String?) throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "logical_datapath": wireUUID(uuidB),
            "logical_dp_group": emptySet,
            "pipeline": .string("ingress"),
            "table_id": .number(8),
            "priority": .number(2000),
            "match": .string("ip4 && tcp.dst == 80"),
            "actions": .string("next;"),
            "flow_desc": wire,
        ]

        let flow = try OVSDBRowDecoder.decode(OVNLogicalFlow.self, from: row)

        #expect(flow.flow_desc == expected)
        #expect(flow.table_id == 8)
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

    /// `parent_name` and `peer` are port *names*, so they stay strings even
    /// when they look like UUIDs; `mirror_rules` and `health_checks` are
    /// reference sets and become UUID atoms.
    @Test("A Logical_Switch_Port's names stay strings and its reference sets become atoms")
    func logicalSwitchPortNameAndReferenceColumnsEncode() throws {
        let port = OVNLogicalSwitchPort(
            name: "lsp-container",
            tag_request: 42,
            parent_name: uuidB,
            peer: uuidC,
            health_checks: [uuidA],
            mirror_rules: [uuidB, uuidC],
            ha_chassis_group: uuidA
        )

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)

        #expect(row["parent_name"] == .string(uuidB))
        #expect(row["peer"] == .string(uuidC))
        #expect(row["health_checks"] == wireSet([wireUUID(uuidA)]))
        #expect(row["mirror_rules"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["ha_chassis_group"] == wireUUID(uuidA))
        #expect(row["tag_request"] == .number(42))
        #expect(row["_uuid"] == nil)
    }

    @Test("A Logical_Switch_Port round trips")
    func logicalSwitchPortRoundTrip() throws {
        let port = OVNLogicalSwitchPort(
            name: "lsp-1",
            addresses: ["dynamic"],
            port_security: ["0a:00:00:00:00:01 10.0.0.1"],
            tag_request: 7,
            external_ids: ["owner": "test"],
            parent_name: "lsp-vm",
            dynamic_addresses: "0a:00:00:00:00:01 10.0.0.1",
            peer: "lsp-pair-b",
            health_checks: [uuidA],
            mirror_rules: [uuidB],
            ha_chassis_group: uuidC
        )

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalSwitchPort.self, from: row)

        #expect(decoded.name == port.name)
        #expect(decoded.addresses == port.addresses)
        #expect(decoded.port_security == port.port_security)
        #expect(decoded.tag_request == port.tag_request)
        #expect(decoded.parent_name == port.parent_name)
        #expect(decoded.dynamic_addresses == port.dynamic_addresses)
        #expect(decoded.peer == port.peer)
        #expect(decoded.health_checks == port.health_checks)
        #expect(decoded.mirror_rules == port.mirror_rules)
        #expect(decoded.ha_chassis_group == port.ha_chassis_group)
        #expect(decoded.external_ids == port.external_ids)
    }

    /// `gateway_port` is a `Logical_Router_Port` reference, while `match` and
    /// `priority` are a plain expression and a number.
    @Test("A NAT rule's gateway_port encodes as a UUID atom")
    func natGatewayPortEncodesUUIDAtom() throws {
        let nat = OVNNAT(
            natType: "snat",
            external_ip: "50.1.1.20",
            logical_ip: "10.1.1.0/24",
            allowed_ext_ips: uuidA,
            gateway_port: uuidB,
            match: "ip4.dst == 50.0.0.0/24",
            priority: 100
        )

        let row = try OVSDBRowEncoder.makeRow(from: nat, hints: .ovn)

        #expect(row["gateway_port"] == wireUUID(uuidB))
        #expect(row["allowed_ext_ips"] == wireUUID(uuidA))
        #expect(row["match"] == .string("ip4.dst == 50.0.0.0/24"))
        #expect(row["priority"] == .number(100))
        #expect(row["type"] == .string("snat"))
        #expect(row["_uuid"] == nil)
    }

    @Test("A NAT rule round trips")
    func natRoundTrip() throws {
        let nat = OVNNAT(
            natType: "dnat_and_snat",
            external_ip: "192.0.2.10",
            logical_ip: "10.0.0.10",
            logical_port: "lsp-vm",
            options: ["stateless": "true"],
            external_ids: ["owner": "test"],
            gateway_port: uuidB,
            match: "inport == \"lrp0\"",
            priority: 32767
        )

        let row = try OVSDBRowEncoder.makeRow(from: nat, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNNAT.self, from: row)

        #expect(decoded.natType == nat.natType)
        #expect(decoded.external_ip == nat.external_ip)
        #expect(decoded.logical_ip == nat.logical_ip)
        #expect(decoded.logical_port == nat.logical_port)
        #expect(decoded.gateway_port == nat.gateway_port)
        #expect(decoded.match == nat.match)
        #expect(decoded.priority == nat.priority)
        #expect(decoded.options == nat.options)
        #expect(decoded.external_ids == nat.external_ids)
    }

    /// A NAT rule without a `match` omits both it and `priority`, which is only
    /// consulted when a match is set.
    @Test("A NAT rule without a match omits priority")
    func natWithoutMatchOmitsPriority() throws {
        let row = try OVSDBRowEncoder.makeRow(
            from: OVNNAT(natType: "snat", external_ip: "192.0.2.1", logical_ip: "10.0.0.0/24"),
            hints: .ovn
        )

        #expect(row["match"] == nil)
        #expect(row["priority"] == nil)
        #expect(row["gateway_port"] == nil)
    }

    /// `tier` and `label` are integer columns — they must stay numbers — and
    /// the `sample_*`/`network_function_group` columns are references.
    @Test("An ACL's tier, label and sample references encode")
    func aclTierLabelAndSampleReferencesEncode() throws {
        let acl = OVNACL(
            priority: 1000,
            direction: "from-lport",
            match: "ip4.src == 10.0.0.0/24",
            action: "allow-related",
            log: true,
            tier: 2,
            label: 4_294_967_295,
            network_function_group: uuidA,
            sample_new: uuidB,
            sample_est: uuidC,
            options: ["apply-after-lb": "true"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: acl, hints: .ovn)

        #expect(row["tier"] == .number(2))
        #expect(row["label"] == .number(4_294_967_295))
        #expect(row["network_function_group"] == wireUUID(uuidA))
        #expect(row["sample_new"] == wireUUID(uuidB))
        #expect(row["sample_est"] == wireUUID(uuidC))
        #expect(row["options"] == wireMap([(.string("apply-after-lb"), .string("true"))]))
        #expect(row["log"] == .boolean(true))
        #expect(row["_uuid"] == nil)
    }

    @Test("An ACL round trips")
    func aclRoundTrip() throws {
        let acl = OVNACL(
            priority: 2000,
            direction: "to-lport",
            match: "outport == @pg-web && ip4",
            action: "drop",
            log: true,
            severity: "info",
            meter: "acl-log-meter",
            name: "web-drop",
            external_ids: ["owner": "test"],
            tier: 1,
            label: 42,
            options: ["log-related": "true"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: acl, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNACL.self, from: row)

        #expect(decoded.priority == acl.priority)
        #expect(decoded.direction == acl.direction)
        #expect(decoded.match == acl.match)
        #expect(decoded.action == acl.action)
        #expect(decoded.log == acl.log)
        #expect(decoded.severity == acl.severity)
        #expect(decoded.meter == acl.meter)
        #expect(decoded.name == acl.name)
        #expect(decoded.tier == acl.tier)
        #expect(decoded.label == acl.label)
        #expect(decoded.options == acl.options)
        #expect(decoded.external_ids == acl.external_ids)
    }

    /// An ACL from a server whose schema predates `tier`/`label` omits those
    /// columns entirely, so they must decode as absent rather than failing.
    @Test("An ACL without tier or label decodes")
    func aclWithoutTierOrLabelDecodes() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "priority": .number(100),
            "direction": .string("from-lport"),
            "match": .string("ip"),
            "action": .string("allow"),
            "log": .boolean(false),
        ]

        let acl = try OVSDBRowDecoder.decode(OVNACL.self, from: row)

        #expect(acl.tier == nil)
        #expect(acl.label == nil)
        #expect(acl.options == nil)
        #expect(acl.sample_new == nil)
    }

    /// `ipv6_prefix` is a plain string set and `status` a northd-written map;
    /// `dhcp_relay` is the one reference among the three.
    @Test("A logical router port's prefix, status and dhcp_relay encode")
    func logicalRouterPortPrefixStatusAndDHCPRelayEncode() throws {
        let port = OVNLogicalRouterPort(
            name: "lrp-gw",
            mac: "0a:58:0a:00:00:01",
            networks: ["10.0.0.1/24"],
            ipv6_prefix: ["fd12:3456:789a::/64"],
            dhcp_relay: uuidB,
            status: ["hosting-chassis": "hv1"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)

        #expect(row["ipv6_prefix"] == wireSet([.string("fd12:3456:789a::/64")]))
        #expect(row["dhcp_relay"] == wireUUID(uuidB))
        #expect(row["status"] == wireStringMap(["hosting-chassis": "hv1"]))
    }

    /// The observability read this exists for: a distributed gateway port's
    /// `status:hosting-chassis` names the chassis currently hosting it, and an
    /// unbound port carries the column as an empty map.
    @Test("A logical router port's hosting chassis decodes", arguments: [
        (wireStringMap(["hosting-chassis": "hv2"]), ["hosting-chassis": "hv2"]),
        (wireMap([]), [:]),
    ] as [(JSONValue, [String: String]?)])
    func logicalRouterPortHostingChassisDecodes(
        wire: JSONValue,
        expected: [String: String]?
    ) throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lrp-gw"),
            "mac": .string("0a:58:0a:00:00:01"),
            "networks": .string("10.0.0.1/24"),
            "ipv6_prefix": emptySet,
            "dhcp_relay": emptySet,
            "status": wire,
        ]

        let port = try OVSDBRowDecoder.decode(OVNLogicalRouterPort.self, from: row)

        #expect(port.status == expected)
        #expect(port.ipv6_prefix == nil)
        #expect(port.dhcp_relay == nil)
    }

    @Test("A logical router port round trips with its prefix and status")
    func logicalRouterPortRoundTripWithPrefixAndStatus() throws {
        let port = OVNLogicalRouterPort(
            name: "lrp-gw",
            mac: "0a:58:0a:00:00:01",
            networks: ["10.0.0.1/24"],
            external_ids: ["owner": "test"],
            ipv6_prefix: ["fd12:3456:789a::/64", "fd12:3456:789b::/64"],
            dhcp_relay: uuidC,
            status: ["hosting-chassis": "hv1"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: port, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouterPort.self, from: row)

        #expect(decoded.ipv6_prefix == port.ipv6_prefix)
        #expect(decoded.dhcp_relay == port.dhcp_relay)
        #expect(decoded.status == port.status)
        #expect(decoded.external_ids == port.external_ids)
    }

    @Test("A logical switch's copp and group columns encode as UUID atoms")
    func logicalSwitchCoppAndGroupColumnsEncode() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "ls-1",
            loadBalancer: [uuidA],
            loadBalancerGroup: [uuidB],
            copp: uuidC,
            forwardingGroups: [uuidA, uuidB]
        )

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        #expect(row["load_balancer"] == wireSet([wireUUID(uuidA)]))
        #expect(row["load_balancer_group"] == wireSet([wireUUID(uuidB)]))
        #expect(row["copp"] == wireUUID(uuidC))
        #expect(row["forwarding_groups"] == wireSet([wireUUID(uuidA), wireUUID(uuidB)]))
    }

    @Test("A logical switch round trips with its copp and group columns")
    func logicalSwitchRoundTripWithCoppAndGroupColumns() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "ls-1",
            other_config: ["subnet": "10.0.0.0/24"],
            external_ids: ["owner": "test"],
            loadBalancerGroup: [uuidB],
            copp: uuidC,
            forwardingGroups: [uuidA]
        )

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalSwitch.self, from: row)

        #expect(decoded.loadBalancerGroup == logicalSwitch.loadBalancerGroup)
        #expect(decoded.copp == logicalSwitch.copp)
        #expect(decoded.forwardingGroups == logicalSwitch.forwardingGroups)
        #expect(decoded.other_config == logicalSwitch.other_config)
    }

    @Test("A logical router round trips with its copp and load balancer group")
    func logicalRouterRoundTripWithCoppAndLoadBalancerGroup() throws {
        let router = OVNLogicalRouter(
            name: "lr-1",
            options: ["chassis": "hv1"],
            external_ids: ["owner": "test"],
            load_balancer_group: [uuidA, uuidB],
            copp: uuidC
        )

        let row = try OVSDBRowEncoder.makeRow(from: router, hints: .ovn)
        #expect(row["load_balancer_group"] == wireSet([wireUUID(uuidA), wireUUID(uuidB)]))
        #expect(row["copp"] == wireUUID(uuidC))
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouter.self, from: row)

        #expect(decoded.load_balancer_group == router.load_balancer_group)
        #expect(decoded.copp == router.copp)
        #expect(decoded.options == router.options)
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

    /// `output_port` is a weak `Logical_Router_Port` reference in
    /// `Logical_Router_Policy` and a plain port-name string in
    /// `Logical_Router_Static_Route`, so the hints have to be table-scoped: the
    /// policy's column becomes a UUID atom, the static route's stays a string
    /// even when the same hints are asked for.
    @Test("A router policy's output_port encodes as a UUID atom")
    func routerPolicyOutputPortEncodesUUIDAtom() throws {
        let policy = OVNLogicalRouterPolicy(
            priority: 1000,
            match: "ip4.src == 10.0.0.0/24",
            action: "reroute",
            nexthop: "192.168.1.1",
            output_port: uuidB,
            bfd_sessions: [uuidC]
        )

        let row = try OVSDBRowEncoder.makeRow(
            from: policy,
            hints: .ovn(table: OVNTable.logicalRouterPolicy)
        )

        #expect(row["output_port"] == wireUUID(uuidB))
        #expect(row["bfd_sessions"] == wireSet([wireUUID(uuidC)]))
        #expect(row["nexthop"] == .string("192.168.1.1"))
        #expect(row["match"] == .string("ip4.src == 10.0.0.0/24"))
        #expect(row["action"] == .string("reroute"))
        #expect(row["priority"] == .number(1000))
        #expect(row["_uuid"] == nil)
    }

    /// The other half of that scoping: `output_port` must stay a plain string
    /// under the hints a static route is written with — both the shared `.ovn`
    /// set and the (empty) table-scoped addition for its own table. Only the
    /// policy table opts into the UUID form.
    @Test("A static route's output_port stays a string", arguments: [
        OVSDBRowEncoder.ColumnHints.ovn,
        .ovn(table: OVNTable.logicalRouterStaticRoute),
    ] as [OVSDBRowEncoder.ColumnHints])
    func staticRouteOutputPortStaysAString(hints: OVSDBRowEncoder.ColumnHints) throws {
        let route = OVNLogicalRouterStaticRoute(
            ip_prefix: "10.0.0.0/24",
            nexthop: "192.168.1.1",
            output_port: uuidB  // a port *name* that happens to look like a UUID
        )

        let row = try OVSDBRowEncoder.makeRow(from: route, hints: hints)

        #expect(row["output_port"] == .string(uuidB))
    }

    @Test("A router policy round trips")
    func routerPolicyRoundTrip() throws {
        let policy = OVNLogicalRouterPolicy(
            priority: 32767,
            match: "inport == \"lrp0\" && ip6",
            action: "jump",
            nexthops: ["fd00::1", "fd00::2"],
            output_port: uuidB,
            chain: "main",
            jump_chain: "chain0",
            bfd_sessions: [uuidA, uuidC],
            options: ["pkt_mark": "42"],
            external_ids: ["owner": "test"]
        )

        let hints = OVSDBRowEncoder.ColumnHints.ovn(table: OVNTable.logicalRouterPolicy)
        let row = try OVSDBRowEncoder.makeRow(from: policy, hints: hints)
        // nexthops is a plain string set; bfd_sessions is a reference set.
        #expect(row["nexthops"] == wireSet([.string("fd00::1"), .string("fd00::2")]))
        #expect(row["bfd_sessions"] == wireSet([wireUUID(uuidA), wireUUID(uuidC)]))
        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouterPolicy.self, from: row)

        #expect(decoded.priority == policy.priority)
        #expect(decoded.match == policy.match)
        #expect(decoded.action == policy.action)
        #expect(decoded.nexthop == nil)
        #expect(decoded.nexthops == policy.nexthops)
        #expect(decoded.output_port == policy.output_port)
        #expect(decoded.chain == policy.chain)
        #expect(decoded.jump_chain == policy.jump_chain)
        #expect(decoded.bfd_sessions == policy.bfd_sessions)
        #expect(decoded.options == policy.options)
        #expect(decoded.external_ids == policy.external_ids)
    }

    /// A policy fresh from `ovn-nbctl lr-policy-add` has every optional column
    /// transmitted as the empty set, and a single-element `nexthops` arrives as
    /// the bare atom rather than a one-element set.
    @Test("A Logical_Router_Policy with unset optional columns")
    func routerPolicyWithUnsetOptionalColumns() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "priority": .number(100),
            "match": .string("ip4.dst == 10.0.0.0/8"),
            "action": .string("reroute"),
            "nexthop": emptySet,
            "nexthops": .string("172.16.0.1"),
            "output_port": emptySet,
            "chain": emptySet,
            "jump_chain": emptySet,
            "bfd_sessions": emptySet,
            "options": wireMap([]),
            "external_ids": wireMap([]),
        ]

        let policy = try OVSDBRowDecoder.decode(OVNLogicalRouterPolicy.self, from: row)

        #expect(policy.uuid == uuidA)
        #expect(policy.priority == 100)
        #expect(policy.action == "reroute")
        #expect(policy.nexthop == nil)
        #expect(policy.nexthops == ["172.16.0.1"])
        #expect(policy.output_port == nil)
        #expect(policy.chain == nil)
        #expect(policy.jump_chain == nil)
        #expect(policy.bfd_sessions == nil)
        #expect(policy.options == [:])
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

    /// `Load_Balancer_Group.load_balancer` is a reference set even though the
    /// column holds the members rather than pointing at a parent, so it has to
    /// encode as UUID atoms like any other.
    @Test("A load balancer group's members encode as UUID atoms")
    func loadBalancerGroupMembersEncodeUUIDAtoms() throws {
        let group = OVNLoadBalancerGroup(name: "lbg-web", load_balancer: [uuidB, uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: group, hints: .ovn)

        #expect(row["load_balancer"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["name"] == .string("lbg-web"))
        #expect(row["_uuid"] == nil)
    }

    @Test("A load balancer group round trips")
    func loadBalancerGroupRoundTrip() throws {
        let group = OVNLoadBalancerGroup(name: "lbg-db", load_balancer: [uuidA, uuidB])

        let row = try OVSDBRowEncoder.makeRow(from: group, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNLoadBalancerGroup.self, from: row)

        #expect(decoded.name == group.name)
        #expect(decoded.load_balancer == group.load_balancer)
    }

    /// A group fresh from `ovn-nbctl lb-group-add` has no members, and the
    /// empty set decodes to nil rather than an empty array.
    @Test("A load balancer group with no members")
    func loadBalancerGroupWithNoMembers() throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("lbg-empty"),
            "load_balancer": emptySet,
        ]

        let group = try OVSDBRowDecoder.decode(OVNLoadBalancerGroup.self, from: row)

        #expect(group.uuid == uuidA)
        #expect(group.name == "lbg-empty")
        #expect(group.load_balancer == nil)
    }

    /// `load_balancer_group` is a reference set on both a switch and a router;
    /// `load_balancer` sits beside it on both, and the two must not be
    /// confused for one another.
    @Test("A logical switch's load balancer columns encode as UUID atoms")
    func logicalSwitchLoadBalancerColumnsEncodeUUIDAtoms() throws {
        let logicalSwitch = OVNLogicalSwitch(
            name: "ls0",
            loadBalancer: [uuidA],
            loadBalancerGroup: [uuidB, uuidC]
        )

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        #expect(row["load_balancer"] == wireSet([wireUUID(uuidA)]))
        #expect(row["load_balancer_group"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
    }

    @Test("A logical router's load balancer group round trips")
    func logicalRouterLoadBalancerGroupRoundTrip() throws {
        let router = OVNLogicalRouter(
            name: "lr0",
            load_balancer: [uuidA],
            load_balancer_group: [uuidB]
        )

        let row = try OVSDBRowEncoder.makeRow(from: router, hints: .ovn)
        #expect(row["load_balancer_group"] == wireSet([wireUUID(uuidB)]))

        let decoded = try OVSDBRowDecoder.decode(OVNLogicalRouter.self, from: row)
        #expect(decoded.load_balancer == router.load_balancer)
        #expect(decoded.load_balancer_group == router.load_balancer_group)
    }

    @Test("A load balancer health check round trips")
    func loadBalancerHealthCheckRoundTrip() throws {
        let healthCheck = OVNLoadBalancerHealthCheck(
            vip: "10.0.0.100:80",
            options: ["interval": "5", "timeout": "3", "success_count": "2", "failure_count": "2"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: healthCheck, hints: .ovn)
        // The VIP is a plain string, not a reference, even though it sits next
        // to the reference column that names this row from the load balancer.
        #expect(row["vip"] == .string("10.0.0.100:80"))
        #expect(row["_uuid"] == nil)

        let decoded = try OVSDBRowDecoder.decode(OVNLoadBalancerHealthCheck.self, from: row)
        #expect(decoded.vip == healthCheck.vip)
        #expect(decoded.options == healthCheck.options)
        #expect(decoded.external_ids == healthCheck.external_ids)
    }

    /// The load balancer side of the same pairing: `health_check` is a strong
    /// reference set into `Load_Balancer_Health_Check`, while `vips` and
    /// `ip_port_mappings` beside it stay string maps.
    @Test("A load balancer's health_check encodes as a UUID set")
    func loadBalancerHealthCheckColumnEncodesUUIDSet() throws {
        let loadBalancer = OVNLoadBalancer(
            name: "lb0",
            vips: ["10.0.0.100:80": "10.0.0.11:8080"],
            protocolType: "tcp",
            health_check: [uuidB],
            ip_port_mappings: ["10.0.0.11": "lsp-backend-1:10.0.0.2"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: loadBalancer, hints: .ovn)

        #expect(row["health_check"] == wireSet([wireUUID(uuidB)]))
        #expect(row["vips"] == wireStringMap(["10.0.0.100:80": "10.0.0.11:8080"]))
        #expect(row["ip_port_mappings"] == wireStringMap(["10.0.0.11": "lsp-backend-1:10.0.0.2"]))
        #expect(row["protocol"] == .string("tcp"))
    }

    @Test("An address set's addresses encode as plain strings")
    func addressSetAddressesEncodeAsPlainStrings() throws {
        // `addresses` is a plain string set, so it must not be rewritten into
        // UUID atoms — the NAT columns that *reference* Address_Set rows
        // (allowed_ext_ips, exempted_ext_ips) are the reference-typed ones.
        let addressSet = OVNAddressSet(
            name: "web_tier",
            addresses: ["10.0.0.1", "10.0.1.0/24"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: addressSet, hints: .ovn)

        #expect(row["addresses"] == wireSet([.string("10.0.0.1"), .string("10.0.1.0/24")]))
        #expect(row["name"] == .string("web_tier"))
        #expect(row["_uuid"] == nil)
    }

    /// A UUID-shaped member must survive as a string: an address set can hold
    /// arbitrary strings, and nothing about its shape makes it a reference.
    @Test("An address set round trips")
    func addressSetRoundTrip() throws {
        let addressSet = OVNAddressSet(
            name: "db_tier",
            addresses: [uuidB, "fd12:3456:789a::/64"],
            options: ["k": "v"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: addressSet, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNAddressSet.self, from: row)

        #expect(decoded.name == addressSet.name)
        #expect(decoded.addresses == addressSet.addresses)
        #expect(decoded.options == addressSet.options)
        #expect(decoded.external_ids == addressSet.external_ids)
    }

    /// A fresh address set has `addresses` sent as the empty set and a
    /// single-member one as the bare string atom; both must decode to the
    /// model's array shape.
    @Test("An address set decodes empty and single-member membership",
          arguments: [(emptySet, nil), (JSONValue.string("10.0.0.1"), ["10.0.0.1"])]
            as [(JSONValue, [String]?)])
    func addressSetMembershipShapes(wire: JSONValue, expected: [String]?) throws {
        let row: OVSDBRow = [
            "_uuid": wireUUID(uuidA),
            "name": .string("as0"),
            "addresses": wire,
            "options": wireMap([]),
        ]

        let addressSet = try OVSDBRowDecoder.decode(OVNAddressSet.self, from: row)

        #expect(addressSet.name == "as0")
        #expect(addressSet.addresses == expected)
        #expect(addressSet.options == [:])
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

    /// A string-keyed map with integer values: the keys stay strings (unlike
    /// the integer-keyed `queues`/`flow_tables`) and the values stay numbers.
    @Test("A Northbound QoS rule's integer-valued maps encode")
    func northboundQoSIntegerValuedMapsEncode() throws {
        let qos = OVNQoS(
            priority: 1000,
            direction: "from-lport",
            match: "inport == \"lsp-1\"",
            action: ["dscp": 48],
            bandwidth: ["rate": 10_000]
        )

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovn)

        #expect(row["action"] == wireMap([(.string("dscp"), .number(48))]))
        #expect(row["bandwidth"] == wireMap([(.string("rate"), .number(10_000))]))
        #expect(row["priority"] == .number(1000))
        #expect(row["direction"] == .string("from-lport"))
        #expect(row["match"] == .string("inport == \"lsp-1\""))
        #expect(row["_uuid"] == nil)
    }

    @Test("A Northbound QoS rule round trips")
    func northboundQoSRoundTrip() throws {
        let qos = OVNQoS(
            priority: 200,
            direction: "to-lport",
            match: "outport == \"lsp-2\"",
            action: ["dscp": 8, "mark": 3],
            bandwidth: ["rate": 20_000, "burst": 5_000],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: qos, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNQoS.self, from: row)

        #expect(decoded.priority == qos.priority)
        #expect(decoded.direction == qos.direction)
        #expect(decoded.match == qos.match)
        #expect(decoded.action == qos.action)
        #expect(decoded.bandwidth == qos.bandwidth)
        #expect(decoded.external_ids == qos.external_ids)
    }

    /// `logical_port` is a port *name* in this table, not a reference, and the
    /// interval columns are plain numbers.
    @Test("A BFD session encodes its port name as a string")
    func bfdSessionEncodesPortNameAsAString() throws {
        let bfd = OVNBFD(
            logical_port: uuidB,  // a port name that happens to look like a UUID
            dst_ip: "192.168.1.1",
            min_tx: 250,
            detect_mult: 5
        )

        let row = try OVSDBRowEncoder.makeRow(from: bfd, hints: .ovn)

        #expect(row["logical_port"] == .string(uuidB))
        #expect(row["dst_ip"] == .string("192.168.1.1"))
        #expect(row["min_tx"] == .number(250))
        #expect(row["detect_mult"] == .number(5))
        #expect(row["min_rx"] == nil)
        #expect(row["_uuid"] == nil)
    }

    /// `status` is ovn-northd's to write, so a session built in Swift carries
    /// none and no create or update ever sends the column.
    @Test("A constructed BFD session sends no status")
    func constructedBFDSessionSendsNoStatus() throws {
        let bfd = OVNBFD(logical_port: "lrp0", dst_ip: "192.168.1.1")

        let row = try OVSDBRowEncoder.makeRow(from: bfd, hints: .ovn)

        #expect(bfd.status == nil)
        #expect(row["status"] == nil)
    }

    @Test("A BFD session round trips")
    func bfdSessionRoundTrip() throws {
        let bfd = OVNBFD(
            logical_port: "lrp0",
            dst_ip: "fd00::1",
            min_tx: 100,
            min_rx: 100,
            detect_mult: 3,
            options: ["foo": "bar"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: bfd, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNBFD.self, from: row)

        #expect(decoded.logical_port == bfd.logical_port)
        #expect(decoded.dst_ip == bfd.dst_ip)
        #expect(decoded.min_tx == bfd.min_tx)
        #expect(decoded.min_rx == bfd.min_rx)
        #expect(decoded.detect_mult == bfd.detect_mult)
        #expect(decoded.options == bfd.options)
        #expect(decoded.external_ids == bfd.external_ids)
        #expect(decoded.status == nil)
    }

    @Test("A DNS record set round trips")
    func dnsRecordSetRoundTrip() throws {
        let dns = OVNDNS(
            records: ["vm1.ovn.org": "10.0.0.11"],
            options: ["foo": "bar"],
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: dns, hints: .ovn)
        #expect(row["records"] == wireStringMap(["vm1.ovn.org": "10.0.0.11"]))

        let decoded = try OVSDBRowDecoder.decode(OVNDNS.self, from: row)

        #expect(decoded.records == dns.records)
        #expect(decoded.options == dns.options)
        #expect(decoded.external_ids == dns.external_ids)
    }

    /// `Logical_Switch.dns_records` is a reference set, so a switch written
    /// with DNS rows attached must send UUID atoms — the same treatment
    /// `load_balancer` and `acls` get.
    @Test("A logical switch's dns_records encodes UUID atoms")
    func logicalSwitchDNSRecordsEncodeUUIDAtoms() throws {
        let logicalSwitch = OVNLogicalSwitch(name: "ls0", dnsRecords: [uuidB, uuidC])

        let row = try OVSDBRowEncoder.makeRow(from: logicalSwitch, hints: .ovn)

        #expect(row["dns_records"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["name"] == .string("ls0"))
    }

    /// `bands` is a strong reference set, so its elements become UUID atoms;
    /// `fair` must stay a boolean rather than being coerced into a number.
    @Test("A Meter's bands encode as UUID atoms")
    func meterBandsEncodeAsUUIDAtoms() throws {
        let meter = OVNMeter(
            name: "acl-log-meter",
            unit: "pktps",
            bands: [uuidB, uuidC],
            fair: true,
            external_ids: ["owner": "test"]
        )

        let row = try OVSDBRowEncoder.makeRow(from: meter, hints: .ovn)

        #expect(row["bands"] == wireSet([wireUUID(uuidB), wireUUID(uuidC)]))
        #expect(row["name"] == .string("acl-log-meter"))
        #expect(row["unit"] == .string("pktps"))
        #expect(row["fair"] == .boolean(true))
        #expect(row["_uuid"] == nil)
    }

    /// A meter created band-less carries no `bands` column at all, so the
    /// create's own set of `named-uuid` references is what lands there — the
    /// column has a schema minimum of one and an empty set would be rejected.
    @Test("A Meter without bands omits the column")
    func meterWithoutBandsOmitsTheColumn() throws {
        let row = try OVSDBRowEncoder.makeRow(from: OVNMeter(name: "m0", unit: "kbps"), hints: .ovn)

        #expect(row["bands"] == nil)
        #expect(row["fair"] == nil)
    }

    @Test("A Meter round trips")
    func meterRoundTrip() throws {
        let meter = OVNMeter(name: "m1", unit: "kbps", bands: [uuidB], fair: false, external_ids: ["owner": "test"])

        let row = try OVSDBRowEncoder.makeRow(from: meter, hints: .ovn)
        let decoded = try OVSDBRowDecoder.decode(OVNMeter.self, from: row)

        #expect(decoded.name == meter.name)
        #expect(decoded.unit == meter.unit)
        #expect(decoded.bands == meter.bands)
        #expect(decoded.fair == meter.fair)
        #expect(decoded.external_ids == meter.external_ids)
    }

    /// The band's rates are integer columns: they must stay JSON numbers, and
    /// `action` must stay a plain string (it is an enum, not a reference).
    @Test("A Meter_Band round trips")
    func meterBandRoundTrip() throws {
        let band = OVNMeterBand(rate: 100, burst_size: 25, external_ids: ["owner": "test"])

        let row = try OVSDBRowEncoder.makeRow(from: band, hints: .ovn)
        #expect(row["action"] == .string("drop"))
        #expect(row["rate"] == .number(100))
        #expect(row["burst_size"] == .number(25))
        #expect(row["_uuid"] == nil)

        let decoded = try OVSDBRowDecoder.decode(OVNMeterBand.self, from: row)

        #expect(decoded.action == band.action)
        #expect(decoded.rate == band.rate)
        #expect(decoded.burst_size == band.burst_size)
        #expect(decoded.external_ids == band.external_ids)
    }

    /// `burst_size` is a required column with no OVSDB default of its own, so
    /// the omitted-burst case has to be written explicitly as 0 — the value
    /// `ovn-nbctl meter-add` uses when no burst is given.
    @Test("A Meter_Band defaults burst_size to zero")
    func meterBandDefaultsBurstSizeToZero() throws {
        let row = try OVSDBRowEncoder.makeRow(from: OVNMeterBand(rate: 1), hints: .ovn)

        #expect(row["burst_size"] == .number(0))
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
