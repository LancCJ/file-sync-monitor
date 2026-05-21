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
        let credentials = IMACredentialsManager.shared
        let originalToken = credentials.imaToken
        let originalRefreshToken = credentials.imaRefreshToken
        let originalUid = credentials.imaUid
        let originalGuid = credentials.imaGuid
        credentials.imaToken = "debug-test-token"
        credentials.imaRefreshToken = "debug-test-refresh-token"
        credentials.imaUid = "debug-test-uid"
        credentials.imaGuid = "debug-test-guid"
        defer {
            IMASyncService.shared.session = originalSession
            credentials.imaToken = originalToken
            credentials.imaRefreshToken = originalRefreshToken
            credentials.imaUid = originalUid
            credentials.imaGuid = originalGuid
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

            let folderShapeJSON = """
            {
              "code": 0,
              "msg": "ok",
              "data": {
                "info_list": [
                  {
                    "media_id": "media_root_file_001",
                    "folder_id": "kb_test_123",
                    "title": "root_file.md",
                    "media_type": 7
                  }
                ],
                "folder_list": [
                  {
                    "media_id": "folder_remote_001",
                    "title": "新建文件夹-测试",
                    "media_type": 16,
                    "folder_info": {
                      "folder_id": "folder_remote_001",
                      "name": "新建文件夹-测试",
                      "file_number": 3,
                      "folder_number": 0
                    }
                  }
                ]
              }
            }
            """
            let decodedList = try JSONDecoder().decode(IMAResponse<KnowledgeListPayload>.self, from: Data(folderShapeJSON.utf8))
            guard let directFile = decodedList.data?.knowledgeList.first(where: { $0.displayName == "root_file.md" }),
                  directFile.isFolder == false else {
                throw NSError(domain: "Test", code: 11, userInfo: [NSLocalizedDescriptionKey: "KnowledgeInfo decode regression: root file with folder_id was treated as a folder."])
            }
            guard let folder = decodedList.data?.knowledgeList.first(where: { $0.displayName == "新建文件夹-测试" }),
                  folder.isFolder == true else {
                throw NSError(domain: "Test", code: 12, userInfo: [NSLocalizedDescriptionKey: "KnowledgeInfo decode regression: folder_info item was treated as a file."])
            }
            guard decodedList.data?.knowledgeList.count == 2 else {
                throw NSError(domain: "Test", code: 13, userInfo: [NSLocalizedDescriptionKey: "KnowledgeListPayload regression: folder_list caused info_list root files to be dropped."])
            }
            print("✅ KnowledgeInfo decode regression Passed!")

            // --- SCENARIO 0: Full cloud tree pull (root files, IMA notes, nested folders) ---
            print("\n📁 --- Scenario 0: Pull root files, notes, and nested folders from Cloud ---")

            MockURLProtocol.handler = { request in
                let urlString = request.url?.absoluteString ?? ""
                let bodyObject = request.httpBody
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let folderId = bodyObject["folder_id"] as? String
                let mediaId = bodyObject["media_id"] as? String

                if urlString.contains("get_knowledge_list") {
                    let json: String
                    if folderId == nil || folderId == "kb_test_123" {
                        json = """
                        {
                          "code": 0,
                          "msg": "ok",
                          "data": {
                            "is_end": true,
                            "next_cursor": "",
                            "info_list": [
                              {
                                "media_id": "media_root_manual",
                                "folder_id": "kb_test_123",
                                "title": "root_manual.txt",
                                "media_type": 13
                              },
                              {
                                "media_id": "media_cloud_note",
                                "folder_id": "kb_test_123",
                                "title": "云端笔记",
                                "media_type": 11
                              }
                            ],
                            "folder_list": [
                              {
                                "media_id": "folder_remote_001",
                                "title": "新建文件夹-测试",
                                "media_type": 16,
                                "folder_info": {
                                  "folder_id": "folder_remote_001",
                                  "name": "新建文件夹-测试",
                                  "file_number": 1,
                                  "folder_number": 1
                                }
                              }
                            ]
                          }
                        }
                        """
                    } else if folderId == "folder_remote_001" {
                        json = """
                        {
                          "code": 0,
                          "msg": "ok",
                          "data": {
                            "is_end": true,
                            "next_cursor": "",
                            "info_list": [
                              {
                                "media_id": "media_inside_folder",
                                "folder_id": "folder_remote_001",
                                "title": "inside_A.txt",
                                "media_type": 13
                              }
                            ],
                            "folder_list": [
                              {
                                "media_id": "folder_child_001",
                                "title": "子文件夹",
                                "media_type": 16,
                                "folder_info": {
                                  "folder_id": "folder_child_001",
                                  "name": "子文件夹",
                                  "file_number": 1,
                                  "folder_number": 0
                                }
                              }
                            ]
                          }
                        }
                        """
                    } else {
                        json = """
                        {
                          "code": 0,
                          "msg": "ok",
                          "data": {
                            "is_end": true,
                            "next_cursor": "",
                            "info_list": [
                              {
                                "media_id": "media_deep_file",
                                "folder_id": "folder_child_001",
                                "title": "deep.txt",
                                "media_type": 13
                              }
                            ]
                          }
                        }
                        """
                    }
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, Data(json.utf8))
                } else if urlString.contains("get_knowledge") {
                    let json: String
                    if mediaId == "media_cloud_note" {
                        json = """
                        {
                          "code": 0,
                          "msg": "ok",
                          "data": {
                            "knowledge": {
                              "media_id": "media_cloud_note",
                              "title": "云端笔记",
                              "media_type": 11,
                              "notebook_ext_info": {
                                "notebook_id": "note_001"
                              }
                            }
                          }
                        }
                        """
                    } else {
                        json = """
                        {
                          "code": 0,
                          "msg": "ok",
                          "data": {
                            "knowledge": {
                              "media_id": "\(mediaId ?? "")",
                              "title": "download.txt",
                              "media_type": 13,
                              "url_info": {
                                "url": "https://ima-share-kb.image.myqcloud.com/kb/\(mediaId ?? "file").txt"
                              }
                            }
                          }
                        }
                        """
                    }
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, Data(json.utf8))
                } else if urlString.contains("get_doc_content") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "data": {
                        "content": "Cloud note content"
                      }
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, Data(json.utf8))
                } else if request.httpMethod == "GET" {
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, "Cloud file content".data(using: .utf8)!)
                }

                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }

            await FileMonitorService.shared.pullFromRemote()

            let pulledURLs = [
                tempDir.appendingPathComponent("root_manual.txt"),
                tempDir.appendingPathComponent("云端笔记.md"),
                tempDir.appendingPathComponent("新建文件夹-测试").appendingPathComponent("inside_A.txt"),
                tempDir.appendingPathComponent("新建文件夹-测试").appendingPathComponent("子文件夹").appendingPathComponent("deep.txt")
            ]
            for url in pulledURLs {
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw NSError(domain: "Test", code: 20, userInfo: [NSLocalizedDescriptionKey: "Scenario 0 Failed: \(url.lastPathComponent) was not pulled to local path \(url.path)."])
                }
            }
            let noteContent = try String(contentsOf: tempDir.appendingPathComponent("云端笔记.md"), encoding: .utf8)
            guard noteContent == "Cloud note content" else {
                throw NSError(domain: "Test", code: 21, userInfo: [NSLocalizedDescriptionKey: "Scenario 0 Failed: IMA note content was not exported correctly."])
            }
            print("✅ Scenario 0 Passed: root files, IMA notes, and nested folders were pulled successfully!")

            if let urls = try? FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil) {
                for url in urls {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            if let existing = try? context.fetch(fetchDescriptor) {
                for item in existing {
                    context.delete(item)
                }
                try? context.save()
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
                          "folder_id": "kb_test_123",
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

            let preexistingDeleteEvent = FileEvent(
                path: tempDir.appendingPathComponent("cloud_only_file.txt").path,
                type: "deleted",
                isDirectory: false,
                remoteId: "media_new_file_999"
            )
            preexistingDeleteEvent.isSynced = true
            context.insert(preexistingDeleteEvent)
            try? context.save()
            
            var didRequestRestoreConfirmation = false

            // Pull from remote
            await FileMonitorService.shared.pullFromRemote { urls in
                didRequestRestoreConfirmation = urls.contains(where: { $0.lastPathComponent == "cloud_only_file.txt" })
                return true
            }
            guard didRequestRestoreConfirmation else {
                throw NSError(domain: "Test", code: 100, userInfo: [NSLocalizedDescriptionKey: "Scenario 1 Failed: locally deleted cloud file did not request restore confirmation."])
            }
            
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
                          "folder_id": "kb_test_123",
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
            
            print("✅ Scenario 3 Passed: Cloud version was pulled successfully and conflict was backed up!")
            
            // --- SCENARIO 4: Cloud-to-Local Rename ---
            print("\n📁 --- Scenario 4: File renamed on Cloud ---")
            
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
                          "folder_id": "kb_test_123",
                          "title": "cloud_renamed_file.txt",
                          "media_type": 7,
                          "update_time": "1779094000000"
                        }
                      ]
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                }
                
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            
            await FileMonitorService.shared.pullFromRemote()
            
            let renamedFile = tempDir.appendingPathComponent("cloud_renamed_file.txt")
            guard !FileManager.default.fileExists(atPath: downloadedFile.path) else {
                throw NSError(domain: "Test", code: 401, userInfo: [NSLocalizedDescriptionKey: "Scenario 4 Failed: Old file 'cloud_only_file.txt' still exists."])
            }
            guard FileManager.default.fileExists(atPath: renamedFile.path) else {
                throw NSError(domain: "Test", code: 402, userInfo: [NSLocalizedDescriptionKey: "Scenario 4 Failed: Renamed file 'cloud_renamed_file.txt' does not exist."])
            }
            print("✅ Scenario 4 Passed: File successfully renamed locally!")
            
            // --- SCENARIO 5: Cloud-to-Local Delete ---
            print("\n📁 --- Scenario 5: File deleted on Cloud ---")
            
            MockURLProtocol.handler = { request in
                let urlString = request.url?.absoluteString ?? ""
                
                if urlString.contains("get_knowledge_list") {
                    let json = """
                    {
                      "code": 0,
                      "msg": "ok",
                      "is_end": true,
                      "next_cursor": "",
                      "knowledge_list": []
                    }
                    """
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (response, json.data(using: .utf8)!)
                }
                
                let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            
            await FileMonitorService.shared.pullFromRemote()
            
            guard !FileManager.default.fileExists(atPath: renamedFile.path) else {
                throw NSError(domain: "Test", code: 501, userInfo: [NSLocalizedDescriptionKey: "Scenario 5 Failed: Renamed file 'cloud_renamed_file.txt' was not deleted locally."])
            }
            
            let events5 = try context.fetch(FetchDescriptor<FileEvent>(
                predicate: #Predicate<FileEvent> { $0.path == renamedFile.path }
            ))
            guard events5.contains(where: { $0.type == "deleted" && $0.isSynced }) else {
                throw NSError(domain: "Test", code: 502, userInfo: [NSLocalizedDescriptionKey: "Scenario 5 Failed: Delete event was not recorded in SwiftData."])
            }
            print("✅ Scenario 5 Passed: File successfully deleted locally and recorded in SwiftData!")
            
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
