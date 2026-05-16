import Foundation
import SwiftUI

@Observable
class IMALogService {
    static let shared = IMALogService()
    
    struct LogEntry: Identifiable {
        let id = UUID()
        let timestamp = Date()
        let method: String
        let url: String
        let requestHeaders: String?
        let requestBody: String?
        let responseCode: Int?
        let responseBody: String?
        let requestId: String?
        let error: String?
        var isExpanded: Bool = false
    }
    
    var logs: [LogEntry] = []
    private let maxLogs = 100
    
    func logRequest(method: String, url: String, headers: [String: String]? = nil, body: String?) -> UUID {
        let headerString = headers?.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        let entry = LogEntry(method: method, url: url, requestHeaders: headerString, requestBody: body, responseCode: nil, responseBody: nil, requestId: nil, error: nil)
        logs.insert(entry, at: 0)
        if logs.count > maxLogs {
            logs.removeLast()
        }
        return entry.id
    }
    
    func logResponse(id: UUID, code: Int, body: String?, requestId: String?) {
        if let index = logs.firstIndex(where: { $0.id == id }) {
            let old = logs[index]
            logs[index] = LogEntry(
                method: old.method,
                url: old.url,
                requestHeaders: old.requestHeaders,
                requestBody: old.requestBody,
                responseCode: code,
                responseBody: body,
                requestId: requestId,
                error: nil
            )
        }
    }
    
    func logError(id: UUID, code: Int?, error: String, requestId: String?) {
        if let index = logs.firstIndex(where: { $0.id == id }) {
            let old = logs[index]
            logs[index] = LogEntry(
                method: old.method,
                url: old.url,
                requestHeaders: old.requestHeaders,
                requestBody: old.requestBody,
                responseCode: code,
                responseBody: nil,
                requestId: requestId,
                error: error
            )
        }
    }
    
    func clear() {
        logs.removeAll()
    }
}
