import Foundation

public struct OVSDBOperation: Codable, Sendable {
    public let op: String
    public let table: String
    public let whereConditions: [OVSDBCondition]?
    public let columns: [String]?
    public let rows: [OVSDBRow]?
    public let row: OVSDBRow?
    public let mutations: [OVSDBMutation]?
    public let uuidName: String?
    public let until: String?
    public let timeout: Int?

    private enum CodingKeys: String, CodingKey {
        case op, table, columns, rows, row, mutations, until, timeout
        case whereConditions = "where"
        case uuidName = "uuid-name"
    }

    public init(op: String, table: String, whereConditions: [OVSDBCondition]? = nil, columns: [String]? = nil, rows: [OVSDBRow]? = nil, row: OVSDBRow? = nil, mutations: [OVSDBMutation]? = nil, uuidName: String? = nil, until: String? = nil, timeout: Int? = nil) {
        self.op = op
        self.table = table
        self.whereConditions = whereConditions
        self.columns = columns
        self.rows = rows
        self.row = row
        self.mutations = mutations
        self.uuidName = uuidName
        self.until = until
        self.timeout = timeout
    }
}