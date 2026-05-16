import Foundation
import SwiftData
import Observation

/// 负责高性能文件系统监控的单例服务
@Observable
final class FileMonitorService {
    static let shared = FileMonitorService()
    
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "com.filesyncmonitor.monitor", qos: .background)
    private var onEventCallback: (([FileEvent]) -> Void)?
    
    /// 存储书签数据的 Key
    private let bookmarksKey = "monitored_directory_bookmarks"

    private let enableDefaultIgnoreRulesKey = "enableDefaultIgnoreRules"
    private let customIgnoredFileNamesKey = "customIgnoredFileNames"
    private let customIgnoredExtensionsKey = "customIgnoredExtensions"
    private let customIgnoredDirectoryNamesKey = "customIgnoredDirectoryNames"
    
    /// 当前正在监控的目录路径
    private(set) var monitoredPaths: [String] = []
    
    /// 追踪已授权的安全作用域 URL 对象
    private var securityScopedURLs: [String: URL] = [:]
    
    private init() {
        loadBookmarks()
        restartMonitoring()
    }
    
    private func loadBookmarks() {
        guard let data = UserDefaults.standard.data(forKey: bookmarksKey),
              let bookmarks = try? JSONDecoder().decode([Data].self, from: data) else {
            return
        }
        
        var paths: [String] = []
        for bookmarkData in bookmarks {
            var isStale = false
            do {
                let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                if url.startAccessingSecurityScopedResource() {
                    paths.append(url.path)
                    securityScopedURLs[url.path] = url
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        self.monitoredPaths = paths
    }
    
    func addDirectory(at url: URL) {
        guard !monitoredPaths.contains(url.path) else { return }
        
        do {
            let bookmarkData = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            
            // 保存书签
            var currentBookmarks: [Data] = []
            if let data = UserDefaults.standard.data(forKey: bookmarksKey),
               let saved = try? JSONDecoder().decode([Data].self, from: data) {
                currentBookmarks = saved
            }
            currentBookmarks.append(bookmarkData)
            
            if let encoded = try? JSONEncoder().encode(currentBookmarks) {
                UserDefaults.standard.set(encoded, forKey: bookmarksKey)
            }
            
            if url.startAccessingSecurityScopedResource() {
                monitoredPaths.append(url.path)
                securityScopedURLs[url.path] = url
                restartMonitoring()
            }
        } catch {
            print("Failed to create bookmark: \(error)")
        }
    }
    
    func removeDirectory(at path: String) {
        if let url = securityScopedURLs.removeValue(forKey: path) {
            url.stopAccessingSecurityScopedResource()
        }
        
        monitoredPaths.removeAll { $0 == path }
        
        // 更新存储
        var remainingBookmarks: [Data] = []
        for p in monitoredPaths {
            if let url = securityScopedURLs[p] {
                if let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                    remainingBookmarks.append(bookmark)
                }
            }
        }
        
        if let encoded = try? JSONEncoder().encode(remainingBookmarks) {
            UserDefaults.standard.set(encoded, forKey: bookmarksKey)
        }
        
        restartMonitoring()
    }
    
    private func restartMonitoring() {
        stopMonitoring()
        guard !monitoredPaths.isEmpty else { return }
        
        startMonitoring(paths: monitoredPaths) { events in
            Task {
                let context = await PersistenceController.shared.makeBackgroundContext()
                for event in events {
                    context.insert(event)
                    // 发送本地通知
                    NotificationManager.shared.sendFileEventNotification(event: event)
                }
                try? context.save()
            }
        }
    }
    
    /// 开始监控指定目录
    func startMonitoring(paths: [String], onEvent: @escaping ([FileEvent]) -> Void) {
        stopMonitoring()
        
        guard !paths.isEmpty else { return }
        self.onEventCallback = onEvent
        
        var context = FSEventStreamContext(version: 0, info: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()), retain: nil, release: nil, copyDescription: nil)
        
        let pathsToWatch = paths as CFArray
        
        // 使用 2.0 秒延迟合并事件，以达到极致性能
        let latency: TimeInterval = 2.0
        
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents | 
            kFSEventStreamCreateFlagUseCFTypes |
            kFSEventStreamCreateFlagIgnoreSelf
        )
        
        stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (streamRef, clientCallBackInfo, numEvents, eventPaths, eventFlags, eventIds) in
                let service = Unmanaged<FileMonitorService>.fromOpaque(clientCallBackInfo!).takeUnretainedValue()
                service.handleEvents(numEvents: numEvents, eventPaths: eventPaths, eventFlags: eventFlags)
            },
            &context,
            pathsToWatch,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        )
        
        FSEventStreamSetDispatchQueue(stream!, queue)
        FSEventStreamStart(stream!)
    }
    
    func stopMonitoring() {
        if let stream = stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }
    
    private func handleEvents(numEvents: Int, eventPaths: UnsafeMutableRawPointer, eventFlags: UnsafePointer<FSEventStreamEventFlags>) {
        let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
        var events: [FileEvent] = []
        
        for i in 0..<numEvents {
            let path = paths[i]
            let flag = eventFlags[i]
            let isDir = flag & UInt32(kFSEventStreamEventFlagItemIsDir) != 0

            guard !shouldIgnoreEvent(path: path, isDirectory: isDir) else {
                continue
            }
            
            // 确定改动类型
            let type: String
            if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                type = "renamed"
            } else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                type = "created"
            } else if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                type = "deleted"
            } else {
                type = "modified"
            }
            
            let event = FileEvent(path: path, type: type, isDirectory: isDir)
            events.append(event)
        }
        
        if !events.isEmpty {
            onEventCallback?(events)
        }
    }

    private func shouldIgnoreEvent(path: String, isDirectory: Bool) -> Bool {
        let rules = IgnoreRules.load(
            userDefaults: .standard,
            enableDefaultKey: enableDefaultIgnoreRulesKey,
            customFileNamesKey: customIgnoredFileNamesKey,
            customExtensionsKey: customIgnoredExtensionsKey,
            customDirectoryNamesKey: customIgnoredDirectoryNamesKey
        )
        return rules.matches(path: path, isDirectory: isDirectory)
    }
}

struct IgnoreRules {
    static let defaultFileNames = [
        ".DS_Store",
        "Icon\r",
        ".localized",
        "Thumbs.db",
        "desktop.ini"
    ]

    static let defaultExtensions = [
        ".tmp",
        ".temp",
        ".swp",
        ".swo",
        ".part",
        ".download",
        ".crdownload"
    ]

    static let defaultDirectoryNames = [
        ".Trashes",
        ".Spotlight-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".git",
        ".svn",
        ".hg",
        "node_modules",
        ".next",
        ".nuxt",
        "dist",
        "build",
        ".build",
        "DerivedData",
        ".idea",
        ".vscode",
        ".swiftpm",
        ".cache"
    ]

    private static let defaultFileNamePrefixes = ["~$"]

    let enableDefaultRules: Bool
    let customFileNames: [String]
    let customExtensions: [String]
    let customDirectoryNames: [String]

    static func load(
        userDefaults: UserDefaults,
        enableDefaultKey: String,
        customFileNamesKey: String,
        customExtensionsKey: String,
        customDirectoryNamesKey: String
    ) -> IgnoreRules {
        let hasDefaultPreference = userDefaults.object(forKey: enableDefaultKey) != nil
        return IgnoreRules(
            enableDefaultRules: hasDefaultPreference ? userDefaults.bool(forKey: enableDefaultKey) : true,
            customFileNames: parseList(userDefaults.string(forKey: customFileNamesKey) ?? ""),
            customExtensions: parseList(userDefaults.string(forKey: customExtensionsKey) ?? "").map(normalizeExtension),
            customDirectoryNames: parseList(userDefaults.string(forKey: customDirectoryNamesKey) ?? "")
        )
    }

    func matches(path: String, isDirectory: Bool) -> Bool {
        let url = URL(fileURLWithPath: path)
        let fileName = url.lastPathComponent
        let loweredFileName = fileName.lowercased()
        let loweredComponents = pathComponents(path).map { $0.lowercased() }

        if containsAnyDirectoryName(in: loweredComponents) {
            return true
        }

        let fileNames = normalizedFileNames
        if fileNames.contains(loweredFileName) {
            return true
        }

        if enableDefaultRules && Self.defaultFileNamePrefixes.contains(where: { fileName.hasPrefix($0) }) {
            return true
        }

        if !isDirectory {
            let loweredPath = path.lowercased()
            if normalizedExtensions.contains(where: { loweredPath.hasSuffix($0) }) {
                return true
            }
        }

        return false
    }

    private var normalizedFileNames: Set<String> {
        var names = Set(customFileNames.map { $0.lowercased() })
        if enableDefaultRules {
            names.formUnion(Self.defaultFileNames.map { $0.lowercased() })
        }
        return names
    }

    private var normalizedExtensions: Set<String> {
        var extensions = Set(customExtensions.map(Self.normalizeExtension))
        if enableDefaultRules {
            extensions.formUnion(Self.defaultExtensions.map(Self.normalizeExtension))
        }
        return extensions
    }

    private var normalizedDirectoryNames: Set<String> {
        var names = Set(customDirectoryNames.map { $0.lowercased() })
        if enableDefaultRules {
            names.formUnion(Self.defaultDirectoryNames.map { $0.lowercased() })
        }
        return names
    }

    private func containsAnyDirectoryName(in pathComponents: [String]) -> Bool {
        let directoryNames = normalizedDirectoryNames
        return pathComponents.contains { directoryNames.contains($0) }
    }

    private func pathComponents(_ path: String) -> [String] {
        URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" }
    }

    private static func parseList(_ value: String) -> [String] {
        value
            .split { character in
                character == "\n" || character == "," || character == ";"
            }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizeExtension(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return trimmed }
        return trimmed.hasPrefix(".") ? trimmed : ".\(trimmed)"
    }
}
