import Foundation

/// Builds OVSDB wire-format rows (RFC 7047) from `Codable` models.
///
/// The wire format is not derivable from a value's JSON shape alone: whether
/// a string is a plain string or a `["uuid", ...]` reference atom, and
/// whether a map's keys are strings or integers, depends on the column's
/// schema type. `ColumnHints` carries that schema knowledge, so a switch
/// literally named "550e8400-..." stays a string while `ports` entries
/// become UUID atoms.
enum OVSDBRowEncoder {
    struct ColumnHints: Sendable {
        /// Columns whose atoms (scalar or set elements) are UUID references
        /// and must be sent as `["uuid", ...]`.
        var uuidReferenceColumns: Set<String>
        /// Map columns whose *values* are UUID references.
        var uuidValuedMapColumns: Set<String>
        /// Map columns whose *keys* are integers and must be sent as JSON
        /// numbers, not strings.
        var integerKeyedMapColumns: Set<String>

        init(
            uuidReferenceColumns: Set<String> = [],
            uuidValuedMapColumns: Set<String> = [],
            integerKeyedMapColumns: Set<String> = []
        ) {
            self.uuidReferenceColumns = uuidReferenceColumns
            self.uuidValuedMapColumns = uuidValuedMapColumns
            self.integerKeyedMapColumns = integerKeyedMapColumns
        }

        /// Reference-typed columns across the OVN Northbound/Southbound
        /// tables this package writes. Column names are unambiguous across
        /// those tables (no string-typed column shares a name with a
        /// reference-typed one).
        static let ovn = ColumnHints(
            uuidReferenceColumns: [
                // Logical_Switch
                "ports", "acls", "qos_rules", "dns_records", "load_balancer",
                // Logical_Switch_Port
                "dhcpv4_options", "dhcpv6_options",
                // Logical_Router
                "static_routes", "policies", "nat",
                // Logical_Router_Static_Route (output_port is a plain
                // port-name string, not a reference)
                "bfd",
                // Logical_Router_Port
                "gateway_chassis", "ha_chassis_group",
                // Load_Balancer
                "health_check",
                // NAT (weak references to Address_Set)
                "allowed_ext_ips", "exempted_ext_ips",
            ]
        )

        /// Reference-typed columns across the Open_vSwitch tables this
        /// package writes. `QoS.queues` and `Bridge.flow_tables` are
        /// integer-keyed maps whose values are references.
        static let ovs = ColumnHints(
            uuidReferenceColumns: [
                // Bridge
                "ports", "mirrors", "netflow", "sflow", "ipfix", "controller",
                // Port
                "interfaces", "qos",
                // Mirror
                "select_src_port", "select_dst_port", "output_port",
            ],
            uuidValuedMapColumns: ["queues", "flow_tables"],
            integerKeyedMapColumns: ["queues", "flow_tables"]
        )
    }

    /// Encodes the model to a row of wire-format column values. The `_uuid`
    /// column is omitted (it is server-assigned and immutable).
    static func makeRow<T: Encodable>(from object: T, hints: ColumnHints) throws -> OVSDBRow {
        let data = try JSONEncoder().encode(object)
        let jsonObject = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]

        var row: OVSDBRow = [:]
        for (column, value) in jsonObject where column != "_uuid" {
            row[column] = try columnValue(value, column: column, hints: hints)
        }
        return row
    }

    private static func columnValue(_ value: Any, column: String, hints: ColumnHints) throws -> JSONValue {
        let isUUIDRef = hints.uuidReferenceColumns.contains(column)

        if let dictionary = value as? [String: Any] {
            let integerKeys = hints.integerKeyedMapColumns.contains(column)
            let uuidValues = hints.uuidValuedMapColumns.contains(column)
            var pairs: [JSONValue] = []
            for (key, mapValue) in dictionary {
                let keyJSON: JSONValue
                if integerKeys, let integerKey = Int64(key) {
                    keyJSON = .number(Double(integerKey))
                } else {
                    keyJSON = .string(key)
                }
                let valueJSON: JSONValue
                if uuidValues, let uuid = mapValue as? String {
                    valueJSON = .array([.string("uuid"), .string(uuid)])
                } else {
                    valueJSON = try atomValue(mapValue, isUUIDRef: false)
                }
                pairs.append(.array([keyJSON, valueJSON]))
            }
            return .array([.string("map"), .array(pairs)])
        }

        if let array = value as? [Any] {
            let items = try array.map { try atomValue($0, isUUIDRef: isUUIDRef) }
            return .array([.string("set"), .array(items)])
        }

        return try atomValue(value, isUUIDRef: isUUIDRef)
    }

    private static func atomValue(_ value: Any, isUUIDRef: Bool) throws -> JSONValue {
        if value is NSNull {
            return .null
        }
        if let number = value as? NSNumber {
            if isBoolean(number) {
                return .boolean(number.boolValue)
            }
            return .number(number.doubleValue)
        }
        if let bool = value as? Bool {
            return .boolean(bool)
        }
        if let string = value as? String {
            if isUUIDRef {
                return .array([.string("uuid"), .string(string)])
            }
            return .string(string)
        }
        throw OVNManagerError.encodingError(
            NSError(domain: "OVSDBRowEncoder", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Unsupported atom for OVSDB wire conversion: \(type(of: value))",
            ])
        )
    }

    /// Distinguishes JSON booleans from numbers: `NSNumber(value: true)` is
    /// also castable to integer types, so `as? Bool`-style checks would turn
    /// integer columns holding 0/1 into booleans (which ovsdb-server
    /// rejects for integer-typed columns).
    private static func isBoolean(_ number: NSNumber) -> Bool {
        #if canImport(ObjectiveC)
        return CFGetTypeID(number) == CFBooleanGetTypeID()
        #else
        return String(cString: number.objCType) == "c"
        #endif
    }
}
