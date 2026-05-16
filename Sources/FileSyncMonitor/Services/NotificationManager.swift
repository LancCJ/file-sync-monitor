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
        content.title = "检测到文件改动".appLocalized
        
        var typeString: String
        switch event.type {
        case "created": typeString = "创建".appLocalized
        case "modified": typeString = "修改".appLocalized
        case "deleted": typeString = "删除".appLocalized
        case "renamed": typeString = "重命名".appLocalized
        default: typeString = event.type
        }
        
        content.body = "\(typeString): \(event.fileName)"
        content.sound = .default
        
        let request = UNNotificationRequest(identifier: event.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
