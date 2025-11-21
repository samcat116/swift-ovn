import Foundation

public struct OVSDBMonitorRequest: Codable, Sendable {
    public let columns: [String]?
    public let select: OVSDBMonitorSelect?
    
    public init(columns: [String]? = nil, select: OVSDBMonitorSelect? = nil) {
        self.columns = columns
        self.select = select
    }
}