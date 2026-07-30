#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A value that cannot be expressed in OVSDB's wire format.
///
/// `EncodingError` does not fit: nothing here is a `Codable` container failure —
/// the value encoded fine, it just has no RFC 7047 spelling. This is what
/// `OVNManagerError.encodingError` carries in that case.
struct OVSDBRowEncodingError: Error, CustomStringConvertible, LocalizedError {
    let description: String

    var errorDescription: String? { description }
}

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
        /// those tables with one exception: `output_port` is a plain port-name
        /// string in `Logical_Router_Static_Route` and a `Logical_Router_Port`
        /// reference in `Logical_Router_Policy`, so it is table-scoped instead
        /// — see `ovn(table:)`.
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
                // Logical_Router_Policy (weak references to BFD)
                "bfd_sessions",
                // Logical_Router_Port
                "gateway_chassis", "ha_chassis_group",
                // HA_Chassis_Group (chassis_name in Gateway_Chassis/HA_Chassis
                // is a plain chassis-name string, not a reference)
                "ha_chassis",
                // Load_Balancer
                "health_check",
                // Meter
                "bands",
                // NAT (weak references to Address_Set)
                "allowed_ext_ips", "exempted_ext_ips",
            ]
        )

        /// Reference-typed columns that hold only inside one table, because the
        /// same column name is *not* reference-typed elsewhere in the database
        /// and the name-keyed hints above cannot tell the two apart.
        private static let ovnTableScopedReferenceColumns: [String: Set<String>] = [
            OVNTable.logicalRouterPolicy: ["output_port"],
        ]

        /// `ovn`, plus the reference columns that only apply within `table`.
        /// Callers that write a table listed in
        /// `ovnTableScopedReferenceColumns` must use this instead of `ovn`.
        static func ovn(table: String) -> ColumnHints {
            var hints = ovn
            hints.uuidReferenceColumns.formUnion(ovnTableScopedReferenceColumns[table] ?? [])
            return hints
        }

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
    ///
    /// This is the boundary between `JSONValueEncoder` — a general `Encoder`,
    /// so it throws `EncodingError` — and the typed-throws API above, hence the
    /// blanket wrap into `encodingError`.
    static func makeRow<T: Encodable>(from object: T, hints: ColumnHints) throws(OVNManagerError) -> OVSDBRow {
        do {
            let encoded = try JSONValueEncoder.encode(object)
            guard case .object(let columns) = encoded else {
                throw OVNManagerError.encodingError(
                    OVSDBRowEncodingError(description: "A row must encode to a JSON object, got \(encoded)")
                )
            }

            var row: OVSDBRow = [:]
            for (column, value) in columns where column != "_uuid" {
                row[column] = try columnValue(value, column: column, hints: hints)
            }
            return row
        } catch {
            throw OVNManagerError.wrapping(error) { .encodingError($0) }
        }
    }

    private static func columnValue(_ value: JSONValue, column: String, hints: ColumnHints) throws -> JSONValue {
        let isUUIDRef = hints.uuidReferenceColumns.contains(column)

        switch value {
        case .object(let dictionary):
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
                if uuidValues, case .string(let uuid) = mapValue {
                    valueJSON = .array([.string("uuid"), .string(uuid)])
                } else {
                    valueJSON = try atomValue(mapValue, isUUIDRef: false)
                }
                pairs.append(.array([keyJSON, valueJSON]))
            }
            return .array([.string("map"), .array(pairs)])

        case .array(let array):
            let items = try array.map { try atomValue($0, isUUIDRef: isUUIDRef) }
            return .array([.string("set"), .array(items)])

        default:
            return try atomValue(value, isUUIDRef: isUUIDRef)
        }
    }

    private static func atomValue(_ value: JSONValue, isUUIDRef: Bool) throws -> JSONValue {
        switch value {
        case .null, .boolean, .number:
            // Booleans and numbers are already distinct here — nothing in this
            // path turns one into the other.
            return value
        case .string(let string):
            return isUUIDRef ? .array([.string("uuid"), .string(string)]) : value
        case .array, .object:
            throw OVNManagerError.encodingError(
                OVSDBRowEncodingError(description: "Unsupported atom for OVSDB wire conversion: \(value)")
            )
        }
    }
}
