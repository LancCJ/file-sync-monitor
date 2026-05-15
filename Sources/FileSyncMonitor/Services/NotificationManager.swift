import Foundation
import UserNotifications

/// 负责发送本地通知的服务
final class NotificationManager {
    static let shared = NotificationManager()
    
    private init() {}
    
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else {
            print("Warning: Skipping notification request because Bundle Identifier is nil. This happens when running as an unbundled executable.")
            return
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            if granted {
                print("Notification permission granted.")
            } else if let error = error {
                print("Notification permission denied: \(error.localizedDescription)")
            }
        }
    }
    
    func sendFileEventNotification(event: FileEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        
        // 如果用户关闭了通知，则不发送
        let content = UNMutableNotificationContent()
        content.title = String(localized: "检测到文件改动")
        
        var typeString: String
        switch event.type {
        case "created": typeString = String(localized: "创建")
        case "modified": typeString = String(localized: "修改")
        case "deleted": typeString = String(localized: "删除")
        case "renamed": typeString = String(localized: "重命名")
        default: typeString = event.type
        }
        
        content.body = "\(typeString): \(event.fileName)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
