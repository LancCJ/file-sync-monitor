import Foundation
import SwiftData

#if DEBUG
final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?
    
    override class func canInit(with request: URLRequest) -> Bool {
        return true
    }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        return request
    }
    
    override func startLoading() {
        guard let handler = MockURLProtocol.handler else {
            client?.urlProtocol(self, didFailWithError: NSError(domain: "MockURLProtocol", code: 0, userInfo: [NSLocalizedDescriptionKey: "No handler set"]))
            return
        }
        
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    
    override func stopLoading() {}
}

@MainActor
class BidirectionalSyncTests {
    static func run() async {
        print("==============================================================")
        print("🚀 Starting Bidirectional Sync Test Suite (Debug Mode)")
        print("==============================================================")
        
        // 1. Setup mock session Configuration
        let config = URLSessionConfiguration.default
        config.protocolClasses = [MockURLProtocol.self]
        let mockSession = URLSession(configuration: config)
        
        let originalSession = IMASyncService.shared.session
        IMASyncService.shared.session = mockSession
        defer {
            IMASyncService.shared.session = originalSession
        }
        
        // 2. Setup SwiftData database context
        let context = PersistenceController.shared.container.mainContext
        
        do {
            // 清理旧事件记录
            let fetchDescriptor = FetchDescriptor<FileEvent>()
            if let existing = try? context.fetch(fetchDescriptor) {
                for item in existing {
                    context.delete(item)
                }
                try? context.save()
            }
            
            // 3. Setup temporary local monitored directory
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(at: tempDir)
            }
            
            let monitoredPath = tempDir.path
            print("Sync Test: Temporary monitored path: \(monitoredPath)")
            
            // Inject temp path to monitoredPaths and mapping
            let originalPaths = FileMonitorService.shared.monitoredPaths
            let originalMapping = FileMonitorService.shared.pathKnowledgeBaseMapping
            
            FileMonitorService.shared.monitoredPaths = [monitoredPath]
            FileMonitorService.shared.pathKnowledgeBaseMapping = [monitoredPath: "kb_test_123"]
            
            defer {
                FileMonitorService.shared.monitoredPaths = originalPaths
                FileMonitorService.shared.pathKnowledgeBaseMapping = originalMapping
            }
            
            // --- SCENARIO 1: Cloud -> Local Pull (New File) ---
            print("\n📁 --- Scenario 1: New file exists on Cloud but not Local ---")
            
            // Mock get_knowledge_list response
            MockURLProtocol.handler = { request in
                let urlString = request.url?.absoluteString ?? ""
                
                if urlString.contains("get_knowledge_list") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "is_end": true,
                      "next_cursor": "",
                      "knowledge_list": [
                        {
                          "media_id": "media_new_file_999",
                          "title": "cloud_only_file.txt",
                          "media_type": 7,
                          "update_time": "1779092588127"
                        }
                      ]
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                } else if urlString.contains("download") || urlString.contains("cos_download") || urlString.contains("cos") || urlString.contains("myqcloud.com") || urlString.contains("downloadFile") || request.httpMethod == "GET" {
                    // This is a download request, return file contents
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, "Hello from the Cloud!".data(using: .utf8)!)
                } else if urlString.contains("get_knowledge") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "knowledge": {
                        "media_id": "media_new_file_999",
                        "title": "cloud_only_file.txt",
                        "media_type": 7,
                        "jump_url": "https://ima-share-kb.image.myqcloud.com/kb/cloud_only_file.txt"
                      }
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                }
                
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            
            // Pull from remote
            await FileMonitorService.shared.pullFromRemote()
            
            // Verify new file downloaded
            let downloadedFile = tempDir.appendingPathComponent("cloud_only_file.txt")
            guard FileManager.default.fileExists(atPath: downloadedFile.path) else {
                throw NSError(domain: "Test", code: 101, userInfo: [NSLocalizedDescriptionKey: "Scenario 1 Failed: 'cloud_only_file.txt' was not downloaded."])
            }
            
            let contents1 = try String(contentsOf: downloadedFile, encoding: .utf8)
            guard contents1 == "Hello from the Cloud!" else {
                throw NSError(domain: "Test", code: 102, userInfo: [NSLocalizedDescriptionKey: "Scenario 1 Failed: File content mismatch: '\(contents1)'"])
            }
            print("✅ Scenario 1 Passed: 'cloud_only_file.txt' successfully pulled and downloaded from Cloud!")
            
            // Verify SwiftData event recorded
            let events1 = try context.fetch(FetchDescriptor<FileEvent>())
            guard events1.contains(where: { $0.path == downloadedFile.path && $0.remoteId == "media_new_file_999" && $0.isSynced }) else {
                throw NSError(domain: "Test", code: 103, userInfo: [NSLocalizedDescriptionKey: "Scenario 1 Failed: SwiftData event was not correctly recorded."])
            }
            print("✅ Scenario 1 SwiftData verification Passed!")
            
            // --- SCENARIO 2: Local & Cloud Identical (Skip Pull) ---
            print("\n📁 --- Scenario 2: File exists on both Local & Cloud with matching mediaId ---")
            // No new file should be created or updated. We will use the same mock handler.
            let fileModTimeBefore = try FileManager.default.attributesOfItem(atPath: downloadedFile.path)[.modificationDate] as? Date ?? Date()
            
            await FileMonitorService.shared.pullFromRemote()
            
            let fileModTimeAfter = try FileManager.default.attributesOfItem(atPath: downloadedFile.path)[.modificationDate] as? Date ?? Date()
            guard fileModTimeBefore == fileModTimeAfter else {
                throw NSError(domain: "Test", code: 201, userInfo: [NSLocalizedDescriptionKey: "Scenario 2 Failed: File was overwritten unnecessarily."])
            }
            print("✅ Scenario 2 Passed: Matching file was skipped cleanly!")
            
            // --- SCENARIO 3: Conflict Detection & Auto Backup ---
            print("\n📁 --- Scenario 3: Conflict detected (Cloud has new version, Local has unsynced changes) ---")
            
            // Mark local file as unsynced
            let descriptor = FetchDescriptor<FileEvent>(
                predicate: #Predicate<FileEvent> { $0.path == downloadedFile.path }
            )
            if let event = try? context.fetch(descriptor).first {
                event.isSynced = false
                try? context.save()
            }
            
            // Modify local content to simulate unsynced local changes
            try "Local modifications".write(to: downloadedFile, atomically: true, encoding: .utf8)
            
            // Mock get_knowledge_list response to return a new media_id (indicating cloud update)
            MockURLProtocol.handler = { request in
                let urlString = request.url?.absoluteString ?? ""
                
                if urlString.contains("get_knowledge_list") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "is_end": true,
                      "next_cursor": "",
                      "knowledge_list": [
                        {
                          "media_id": "media_updated_file_888",
                          "title": "cloud_only_file.txt",
                          "media_type": 7,
                          "update_time": "1779093000000"
                        }
                      ]
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                } else if urlString.contains("download") || urlString.contains("cos_download") || urlString.contains("cos") || urlString.contains("myqcloud.com") || urlString.contains("downloadFile") || request.httpMethod == "GET" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, "Brand new Cloud content!".data(using: .utf8)!)
                } else if urlString.contains("get_knowledge") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "knowledge": {
                        "media_id": "media_updated_file_888",
                        "title": "cloud_only_file.txt",
                        "media_type": 7,
                        "jump_url": "https://ima-share-kb.image.myqcloud.com/kb/cloud_only_file.txt"
                      }
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                }
                
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            
            // Pull from remote (should trigger conflict resolution)
            await FileMonitorService.shared.pullFromRemote()
            
            // Verify Local backup created
            let contentsInLocalNow = try String(contentsOf: downloadedFile, encoding: .utf8)
            guard contentsInLocalNow == "Brand new Cloud content!" else {
                throw NSError(domain: "Test", code: 301, userInfo: [NSLocalizedDescriptionKey: "Scenario 3 Failed: Cloud version was not pulled successfully."])
            }
            
            // Verify backup file exists
            let files = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            let backupFiles = files.filter { $0.lastPathComponent.contains("cloud_only_file_local_backup") }
            guard !backupFiles.isEmpty else {
                throw NSError(domain: "Test", code: 302, userInfo: [NSLocalizedDescriptionKey: "Scenario 3 Failed: Local backup file was not created."])
            }
            
            let backupFile = backupFiles[0]
            let backupContents = try String(contentsOf: backupFile, encoding: .utf8)
            guard backupContents == "Local modifications" else {
                throw NSError(domain: "Test", code: 303, userInfo: [NSLocalizedDescriptionKey: "Scenario 3 Failed: Local modifications backup content mismatch: '\(backupContents)'"])
            }
            
            print("✅ Scenario 3 Passed: Conflict resolved perfectly with local backup and safe pull!")
            
            print("\n==============================================================")
            print("🎉 ALL Bidirectional Sync Tests Completed Flawlessly! 100% OK")
            print("==============================================================")
            
        } catch {
            print("\n❌ Bidirectional Sync Test Failed: \(error.localizedDescription)")
        }
        
        exit(0)
    }
}
#endif
