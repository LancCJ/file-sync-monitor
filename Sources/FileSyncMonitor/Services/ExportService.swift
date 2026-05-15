import Foundation

/// 负责导出改动记录的服务
final class ExportService {
    static let shared = ExportService()
    
    private init() {}
    
    enum ExportFormat {
        case csv
        case json
    }
    
    func export(events: [FileEvent], format: ExportFormat) throws -> Data {
        switch format {
        case .csv:
            return try generateCSV(events: events)
        case .json:
            return try generateJSON(events: events)
        }
    }
    
    private func generateCSV(events: [FileEvent]) throws -> Data {
        var csvString = "ID,Timestamp,Type,Path,IsSynced\n"
        
        let formatter = ISO8601DateFormatter()
        
        for event in events {
            let line = "\(event.id.uuidString),\(formatter.string(from: event.timestamp)),\(event.type),\"\(event.path)\",\(event.isSynced)\n"
            csvString.append(line)
        }
        
        return csvString.data(using: .utf8) ?? Data()
    }
    
    private func generateJSON(events: [FileEvent]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .prettyPrinted
        
        // 转换成简单的 Codable 结构体进行导出
        let exportableEvents = events.map { ExportableFileEvent(event: $0) }
        return try encoder.encode(exportableEvents)
    }
}

private struct ExportableFileEvent: Codable {
    let id: UUID
    let timestamp: Date
    let type: String
    let path: String
    let isSynced: Bool
    
    init(event: FileEvent) {
        self.id = event.id
        self.timestamp = event.timestamp
        self.type = event.type
        self.path = event.path
        self.isSynced = event.isSynced
    }
}
