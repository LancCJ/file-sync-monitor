import Foundation
import SwiftData

@Model
final class FileEvent {
    @Attribute(.unique) var id: UUID
    var path: String
    var oldPath: String?
    var type: String // created, modified, deleted, renamed
    var timestamp: Date
    var isSynced: Bool
    var hasNotified: Bool
    var isDirectory: Bool
    var remoteId: String? // IMA 远程 ID (media_id 或 doc_id)
    
    // 归档标记，用于树状展示时的逻辑
    var fileName: String {
        URL(fileURLWithPath: path).lastPathComponent
    }
    
    init(id: UUID = UUID(), 
         path: String, 
         oldPath: String? = nil, 
         type: String, 
         timestamp: Date = Date(), 
         isSynced: Bool = false, 
         hasNotified: Bool = false,
         isDirectory: Bool = false,
         remoteId: String? = nil) {
        self.id = id
        self.path = path
        self.oldPath = oldPath
        self.type = type
        self.timestamp = timestamp
        self.isSynced = isSynced
        self.hasNotified = hasNotified
        self.isDirectory = isDirectory
        self.remoteId = remoteId
    }
}
