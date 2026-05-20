import Foundation
import SwiftUI

@Observable
class IMALogService {
    static let shared = IMALogService()
    
    struct LogEntry: Identifiable {
        var id = UUID()
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
    
    private func appendToLogFile(_ message: String) {
        let fileManager = FileManager.default
        let paths = [
            URL(fileURLWithPath: "/Users/chenjian/Documents/codes/file-sync-monitor/sync_debug.log"),
            fileManager.temporaryDirectory.appendingPathComponent("sync_debug.log"),
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent("sync_debug.log")
        ].compactMap { $0 }
        
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .medium)
        let formattedMessage = "[\(timestamp)] \(message)"
        
        for path in paths {
            do {
                if !fileManager.fileExists(atPath: path.path) {
                    try "".write(to: path, atomically: true, encoding: .utf8)
                }
                if let fileHandle = try? FileHandle(forWritingTo: path) {
                    fileHandle.seekToEndOfFile()
                    if let data = (formattedMessage + "\n").data(using: .utf8) {
                        fileHandle.write(data)
                    }
                    fileHandle.closeFile()
                }
            } catch {
                // ignore
            }
        }
    }

    func logRequest(method: String, url: String, headers: [String: String]? = nil, body: String?) -> UUID {
        let id = UUID()
        let headerString = headers?.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        
        appendToLogFile("REQUEST [\(id.uuidString)] \(method) \(url)\nHeaders: \(headerString ?? "nil")\nBody: \(body ?? "nil")")
        
        Task { @MainActor in
            let entry = LogEntry(id: id, method: method, url: url, requestHeaders: headerString, requestBody: body, responseCode: nil, responseBody: nil, requestId: nil, error: nil)
            self.logs.insert(entry, at: 0)
            if self.logs.count > maxLogs {
                self.logs.removeLast()
            }
        }
        
        return id
    }
    
    func logResponse(id: UUID, code: Int, body: String?, requestId: String?) {
        appendToLogFile("RESPONSE [\(id.uuidString)] HTTP \(code)\nRequestId: \(requestId ?? "nil")\nBody: \(body ?? "nil")")
        
        Task { @MainActor in
            if let index = self.logs.firstIndex(where: { $0.id == id }) {
                let old = self.logs[index]
                self.logs[index] = LogEntry(
                    id: old.id,
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
    }
    
    func logError(id: UUID, code: Int?, error: String, requestId: String?) {
        appendToLogFile("ERROR [\(id.uuidString)] (Code: \(code?.description ?? "nil")) \(error)\nRequestId: \(requestId ?? "nil")")
        
        Task { @MainActor in
            if let index = self.logs.firstIndex(where: { $0.id == id }) {
                let old = self.logs[index]
                self.logs[index] = LogEntry(
                    id: old.id,
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
    }
    
    @MainActor
    func clear() {
        logs.removeAll()
    }
}
