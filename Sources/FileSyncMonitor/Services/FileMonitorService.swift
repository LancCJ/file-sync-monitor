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
    private var syncTimers: [String: Timer] = [:]
    
    /// 存储书签数据的 Key
    private let bookmarksKey = "monitored_directory_bookmarks"

    private let enableDefaultIgnoreRulesKey = "enableDefaultIgnoreRules"
    private let customIgnoredFileNamesKey = "customIgnoredFileNames"
    private let customIgnoredExtensionsKey = "customIgnoredExtensions"
    private let customIgnoredDirectoryNamesKey = "customIgnoredDirectoryNames"
    
    /// 当前正在监控的目录路径
    var monitoredPaths: [String] = []
    
    /// 是否正在从云端同步
    var isPulling: Bool = false
    
    // 同步弹窗状态管理
    var isShowingSyncSheet = false
    var syncSheetTitle = ""
    var syncSheetStatus = ""
    var syncSheetProgress: Double? = nil
    var syncSheetError: String? = nil
    var isSyncSheetFinished = false
    
    @MainActor
    func startSyncProgress(title: String) {
        isShowingSyncSheet = true
        syncSheetTitle = title
        syncSheetStatus = "初始化同步...".appLocalized
        syncSheetError = nil
        isSyncSheetFinished = false
        syncSheetProgress = nil
    }

    @MainActor
    func updateSyncProgress(status: String, progress: Double? = nil) {
        syncSheetStatus = status
        if let progress {
            syncSheetProgress = progress
        }
    }

    @MainActor
    func finishSyncProgressSuccess(status: String) {
        syncSheetStatus = status
        isSyncSheetFinished = true
        syncSheetProgress = 1.0
        
        // 自动延时 1.5s 后关闭
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                if self.isSyncSheetFinished && self.syncSheetError == nil {
                    self.isShowingSyncSheet = false
                }
            }
        }
    }

    @MainActor
    func finishSyncProgressError(message: String) {
        syncSheetError = message
        isSyncSheetFinished = true
    }
    
    private let mappingKey = "pathKnowledgeBaseMapping"
    private let availableKBsKey = "availableKnowledgeBases"
    
    /// 追踪已授权的安全作用域 URL 对象
    private var securityScopedURLs: [String: URL] = [:]
    
    /// 缓存的忽略规则
    private var cachedIgnoreRules: IgnoreRules?
    
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
                var resolvedUrl: URL? = nil
                do {
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale)
                    if url.startAccessingSecurityScopedResource() {
                        securityScopedURLs[url.path] = url
                        resolvedUrl = url
                    }
                } catch {}
                
                if resolvedUrl == nil {
                    // 非沙盒或命令行测试环境，回退使用标准书签解析
                    let url = try URL(resolvingBookmarkData: bookmarkData, options: [], relativeTo: nil, bookmarkDataIsStale: &isStale)
                    resolvedUrl = url
                }
                
                if let url = resolvedUrl {
                    paths.append(url.path)
                }
            } catch {
                print("Failed to resolve bookmark: \(error)")
            }
        }
        self.monitoredPaths = paths
        print("Resolved monitoredPaths: \(paths)")
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
                var paths = monitoredPaths
                paths.append(url.path)
                monitoredPaths = paths
                securityScopedURLs[url.path] = url
                restartMonitoring()
            }
        } catch {
            print("Failed to create bookmark: \(error)")
        }
    }
    
    func removeDirectory(at path: String) {
        var paths = monitoredPaths
        paths.removeAll { $0 == path }
        monitoredPaths = paths
        
        // 同时移除映射关系
        var mapping = pathKnowledgeBaseMapping
        mapping.removeValue(forKey: path)
        pathKnowledgeBaseMapping = mapping
        
        stopMonitoring()
        securityScopedURLs[path]?.stopAccessingSecurityScopedResource()
        securityScopedURLs.removeValue(forKey: path)
        
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
                    let path = event.path
                    
                    // 1. 查找是否存在该路径的“未同步”记录
                    var descriptor = FetchDescriptor<FileEvent>(
                        predicate: #Predicate<FileEvent> { $0.path == path && $0.isSynced == false }
                    )
                    descriptor.fetchLimit = 1
                    
                    if let existing = try? context.fetch(descriptor).first {
                        // --- 核心状态合并逻辑 ---
                        let oldType = existing.type
                        let newType = event.type
                        
                        var shouldDelete = false
                        if oldType == "created" {
                            if newType == "deleted" {
                                shouldDelete = true
                            } else {
                                existing.timestamp = event.timestamp
                            }
                        } else if oldType == "modified" {
                            if newType == "deleted" {
                                existing.type = "deleted"
                                existing.timestamp = event.timestamp
                            } else {
                                existing.timestamp = event.timestamp
                            }
                        } else if oldType == "deleted" {
                            if newType == "created" || newType == "renamed" {
                                // 用户删除了文件后又重新添加了同名文件，在 UI 上应重新显示为新增
                                existing.type = "created"
                                existing.timestamp = event.timestamp
                            } else {
                                existing.timestamp = event.timestamp
                            }
                        } else if oldType == "renamed" {
                            if newType == "deleted" {
                                existing.type = "deleted"
                                existing.timestamp = event.timestamp
                            } else {
                                // 忽略后续的 modified 或 created，保留 renamed 状态
                                existing.timestamp = event.timestamp
                            }
                        } else {
                            existing.type = newType
                            existing.timestamp = event.timestamp
                        }
                        
                        if shouldDelete {
                            context.delete(existing)
                            continue
                        }
                        
                        // 触发自动同步计时器
                        self.resetSyncTimer(for: existing)
                    } else {
                        if event.type == "renamed" {
                            if let mergedEvent = self.mergeRecentCreatedEventIntoRename(event, context: context) {
                                self.resetSyncTimer(for: mergedEvent)
                                continue
                            } else {
                                // 找不到对应的待处理源文件，说明是从监控目录外部拖入/拷贝的全新文件，本质上是新增
                                event.type = "created"
                            }
                        }

                        // 2. 如果是新记录，尝试从最近一次“已同步”的记录中继承 remoteId
                        var syncedDescriptor = FetchDescriptor<FileEvent>(
                            predicate: #Predicate<FileEvent> { $0.path == path && $0.isSynced == true }
                        )
                        syncedDescriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
                        syncedDescriptor.fetchLimit = 1
                        
                        if let lastSynced = try? context.fetch(syncedDescriptor).first {
                            event.remoteId = lastSynced.remoteId
                        } else {
                            // 核心兜底：如果这个文件在数据库中从未有过“已同步”记录，
                            // 那么无论底层抛出的是 modified 还是其他属性变更，对于云端而言它就是纯粹的“新增”
                            if event.type != "deleted" {
                                event.type = "created"
                            }
                        }
                        
                        context.insert(event)
                        // 仅对新产生的变动发送通知
                        NotificationManager.shared.sendFileEventNotification(event: event)
                        // 触发自动同步计时器
                        self.resetSyncTimer(for: event)
                    }
                }
                try? context.save()
            }
        }
    }

    private func mergeRecentCreatedEventIntoRename(_ event: FileEvent, context: ModelContext) -> FileEvent? {
        let newURL = URL(fileURLWithPath: event.path)
        let directoryPath = newURL.deletingLastPathComponent().path
        let cutoff = event.timestamp.addingTimeInterval(-30)

        var descriptor = FetchDescriptor<FileEvent>(
            predicate: #Predicate<FileEvent> {
                ($0.type == "created" || $0.type == "deleted") &&
                $0.isSynced == false &&
                $0.timestamp >= cutoff
            },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 20

        guard let candidates = try? context.fetch(descriptor) else {
            return nil
        }

        guard let staleCreated = candidates.first(where: { candidate in
            let candidateURL = URL(fileURLWithPath: candidate.path)
            return candidateURL.deletingLastPathComponent().path == directoryPath &&
                candidate.path != event.path &&
                !FileManager.default.fileExists(atPath: candidate.path)
        }) else {
            return nil
        }

        staleCreated.oldPath = staleCreated.path
        staleCreated.path = event.path
        if staleCreated.type == "deleted" {
            // 原本已同步的文件被重命名（先产生 deleted，再产生 renamed）
            staleCreated.type = "renamed"
        } else {
            // 原本未同步的新建文件被重命名（保持 created）
            staleCreated.type = "created"
        }
        staleCreated.timestamp = event.timestamp
        staleCreated.isDirectory = event.isDirectory
        return staleCreated
    }
    
    var pathKnowledgeBaseMapping: [String: String] {
        get {
            guard let data = UserDefaults.standard.data(forKey: mappingKey) else { return [:] }
            return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                UserDefaults.standard.set(data, forKey: mappingKey)
            }
        }
    }
    
    var availableKnowledgeBases: [KnowledgeBase] = {
        guard let data = UserDefaults.standard.data(forKey: "availableKnowledgeBases") else { return [] }
        return (try? JSONDecoder().decode([KnowledgeBase].self, from: data)) ?? []
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(availableKnowledgeBases) {
                UserDefaults.standard.set(data, forKey: "availableKnowledgeBases")
            }
        }
    }
    
    @MainActor
    func fetchKnowledgeBases() async {
        do {
            let kbs = try await IMASyncService.shared.getKnowledgeBases()
            self.availableKnowledgeBases = kbs
        } catch {
            print("Failed to fetch knowledge bases: \(error)")
        }
    }

    func setKnowledgeBaseId(_ id: String, for path: String) {
        var mapping = pathKnowledgeBaseMapping
        if id.isEmpty || id == "default" {
            mapping.removeValue(forKey: path)
        } else {
            mapping[path] = id
        }
        pathKnowledgeBaseMapping = mapping
    }
    
    func getKnowledgeBaseId(for filePath: String) -> String {
        getKnowledgeBaseTarget(for: filePath).knowledgeBaseId
    }

    private func isSubpath(filePath: String, of rootPath: String) -> Bool {
        let resolvedFile = URL(fileURLWithPath: filePath).resolvingSymlinksInPath().path
        let resolvedRoot = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        
        if resolvedFile == resolvedRoot {
            return true
        }
        
        let rootWithSlash = resolvedRoot.hasSuffix("/") ? resolvedRoot : resolvedRoot + "/"
        return resolvedFile.hasPrefix(rootWithSlash)
    }

    func getKnowledgeBaseTarget(for filePath: String) -> (knowledgeBaseId: String, relativeFolderPath: String?) {
        let mapping = pathKnowledgeBaseMapping
        
        // 寻找最长匹配的监控目录（即所属的最深层监控根目录）
        let sortedPaths = monitoredPaths.sorted { $0.count > $1.count }
        for rootPath in sortedPaths {
            if isSubpath(filePath: filePath, of: rootPath) {
                return (mapping[rootPath] ?? "default", relativeFolderPath(filePath: filePath, rootPath: rootPath))
            }
        }
        
        return ("default", nil)
    }

    func getFolderTarget(for folderPath: String) -> (knowledgeBaseId: String, folderName: String, relativeParentFolderPath: String?) {
        let mapping = pathKnowledgeBaseMapping
        
        let sortedPaths = monitoredPaths.sorted { $0.count > $1.count }
        for rootPath in sortedPaths {
            if isSubpath(filePath: folderPath, of: rootPath) {
                let kbId = mapping[rootPath] ?? "default"
                let fileURL = URL(fileURLWithPath: folderPath).resolvingSymlinksInPath()
                let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
                let folderName = fileURL.lastPathComponent
                
                let parentURL = fileURL.deletingLastPathComponent()
                let rootComponents = rootURL.pathComponents
                let parentComponents = parentURL.pathComponents
                
                if parentComponents.count > rootComponents.count,
                   parentComponents.starts(with: rootComponents) {
                    let relativeParent = parentComponents
                        .dropFirst(rootComponents.count)
                        .joined(separator: "/")
                    return (kbId, folderName, relativeParent.isEmpty ? nil : relativeParent)
                }
                return (kbId, folderName, nil)
            }
        }
        
        let folderName = URL(fileURLWithPath: folderPath).lastPathComponent
        return ("default", folderName, nil)
    }

    private func relativeFolderPath(filePath: String, rootPath: String) -> String? {
        let fileURL = URL(fileURLWithPath: filePath).resolvingSymlinksInPath()
        let rootURL = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath()
        let parentURL = fileURL.deletingLastPathComponent()

        let rootComponents = rootURL.pathComponents
        let parentComponents = parentURL.pathComponents
        guard parentComponents.count > rootComponents.count,
              parentComponents.starts(with: rootComponents) else {
            return nil
        }

        let relativePath = parentComponents
            .dropFirst(rootComponents.count)
            .joined(separator: "/")

        return relativePath.isEmpty ? nil : relativePath
    }

    /// 从云端拉取更新（双向同步核心尝试）
    @MainActor
    func pullFromRemote(confirmDownloadForDeleted: (([URL]) async -> Bool)? = nil) async {
        guard !isPulling else { return }
        isPulling = true
        defer { isPulling = false }
        
        let context = PersistenceController.shared.container.mainContext
        
        func getLatestSyncedEvent(for path: String) -> FileEvent? {
            var descriptor = FetchDescriptor<FileEvent>(
                predicate: #Predicate<FileEvent> { $0.path == path && $0.remoteId != nil }
            )
            descriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
            descriptor.fetchLimit = 1
            return try? context.fetch(descriptor).first
        }
        
        func hasUnsyncedLocalChanges(for path: String) -> Bool {
            let descriptor = FetchDescriptor<FileEvent>(
                predicate: #Predicate<FileEvent> { $0.path == path && $0.isSynced == false }
            )
            let count = (try? context.fetchCount(descriptor)) ?? 0
            return count > 0
        }
        
        func hasLocalDeletionRecord(for path: String) -> Bool {
            let descriptor = FetchDescriptor<FileEvent>(
                predicate: #Predicate<FileEvent> { $0.path == path && $0.type == "deleted" }
            )
            let count = (try? context.fetchCount(descriptor)) ?? 0
            return count > 0
        }
        
        var deletedFilesToPull: [(url: URL, mediaId: String, kbId: String)] = []
        let mapping = pathKnowledgeBaseMapping
        
        for (localPath, kbId) in mapping {
            guard !kbId.isEmpty && kbId != "default" else { continue }
            
            do {
                // 1. 获取云端列表
                let (items, _, _) = try await IMASyncService.shared.getKnowledgeList(knowledgeBaseId: kbId)
                
                let localURL = URL(fileURLWithPath: localPath)
                for item in items {
                    guard !item.isFolder else {
                        // 对于文件夹，我们只需确保本地目录存在，然后跳过内容下载
                        let folderURL = localURL.appendingPathComponent(item.title)
                        try? FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
                        print("Sync: Ensured local directory exists for folder: \(item.title)")
                        continue
                    }
                    
                    let fileURL = localURL.appendingPathComponent(item.title)
                    let filePath = fileURL.path
                    
                    // 2. 检查本地是否存在
                    if !FileManager.default.fileExists(atPath: filePath) {
                        // 3. 检查是否有本地删除记录
                        if hasLocalDeletionRecord(for: filePath) {
                            // 暂存，稍后统一确认
                            deletedFilesToPull.append((fileURL, item.mediaId, kbId))
                            print("Sync: Found locally deleted file still on cloud (pending choice): \(item.title)")
                        } else {
                            // 无删除记录，安全直接下载
                            print("Sync: Downloading new file from cloud: \(item.title)")
                            try await IMASyncService.shared.downloadFile(mediaId: item.mediaId, knowledgeBaseId: kbId, to: fileURL)
                            
                            let event = FileEvent(path: filePath, type: "created", isDirectory: false, remoteId: item.mediaId)
                            event.isSynced = true
                            context.insert(event)
                            try? context.save()
                        }
                    } else {
                        // 本地存在该文件，比对状态
                        let latestSynced = getLatestSyncedEvent(for: filePath)
                        let hasUnsynced = hasUnsyncedLocalChanges(for: filePath)
                        
                        if let lastRemoteId = latestSynced?.remoteId {
                            if item.mediaId == lastRemoteId {
                                print("Sync: File identical (mediaId matches): \(item.title)")
                            } else {
                                if hasUnsynced {
                                    print("Sync: CONFLICT detected for \(item.title). Cloud changed and local has unsynced changes.")
                                    
                                    let ext = fileURL.pathExtension
                                    let baseName = fileURL.deletingPathExtension().lastPathComponent
                                    let timestamp = Int(Date().timeIntervalSince1970)
                                    let backupName = "\(baseName)_local_backup_\(timestamp)\(ext.isEmpty ? "" : ".\(ext)")"
                                    let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
                                    
                                    try? FileManager.default.moveItem(at: fileURL, to: backupURL)
                                    
                                    let backupEvent = FileEvent(path: backupURL.path, type: "created", isDirectory: false)
                                    backupEvent.isSynced = true
                                    context.insert(backupEvent)
                                    
                                    try await IMASyncService.shared.downloadFile(mediaId: item.mediaId, knowledgeBaseId: kbId, to: fileURL)
                                    
                                    let event = FileEvent(path: filePath, type: "modified", isDirectory: false, remoteId: item.mediaId)
                                    event.isSynced = true
                                    context.insert(event)
                                    try? context.save()
                                } else {
                                    print("Sync: Safe pull (cloud updated, local untouched) for \(item.title)")
                                    try await IMASyncService.shared.downloadFile(mediaId: item.mediaId, knowledgeBaseId: kbId, to: fileURL)
                                    
                                    let event = FileEvent(path: filePath, type: "modified", isDirectory: false, remoteId: item.mediaId)
                                    event.isSynced = true
                                    context.insert(event)
                                    try? context.save()
                                }
                            }
                        } else {
                            print("Sync: File exists locally but has no remoteId record. Treating as conflict.")
                            let ext = fileURL.pathExtension
                            let baseName = fileURL.deletingPathExtension().lastPathComponent
                            let timestamp = Int(Date().timeIntervalSince1970)
                            let backupName = "\(baseName)_local_backup_\(timestamp)\(ext.isEmpty ? "" : ".\(ext)")"
                            let backupURL = fileURL.deletingLastPathComponent().appendingPathComponent(backupName)
                            
                            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
                            
                            let backupEvent = FileEvent(path: backupURL.path, type: "created", isDirectory: false)
                            backupEvent.isSynced = true
                            context.insert(backupEvent)
                            
                            try await IMASyncService.shared.downloadFile(mediaId: item.mediaId, knowledgeBaseId: kbId, to: fileURL)
                            
                            let event = FileEvent(path: filePath, type: "created", isDirectory: false, remoteId: item.mediaId)
                            event.isSynced = true
                            context.insert(event)
                            try? context.save()
                        }
                    }
                }
            } catch {
                print("Pull from remote failed for \(localPath): \(error)")
            }
        }
        
        // 3. 统一处理本地已删除的云端文件确认
        if !deletedFilesToPull.isEmpty {
            var shouldDownload = false
            if let confirmCallback = confirmDownloadForDeleted {
                shouldDownload = await confirmCallback(deletedFilesToPull.map { $0.url })
            } else {
                // 无回调（如背景/自动拉取）则静默跳过，保留本地删除状态
                shouldDownload = false
            }
            
            if shouldDownload {
                for item in deletedFilesToPull {
                    do {
                        print("Sync: Re-downloading locally deleted file: \(item.url.lastPathComponent)")
                        try await IMASyncService.shared.downloadFile(mediaId: item.mediaId, knowledgeBaseId: item.kbId, to: item.url)
                        
                        let event = FileEvent(path: item.url.path, type: "created", isDirectory: false, remoteId: item.mediaId)
                        event.isSynced = true
                        context.insert(event)
                    } catch {
                        print("Failed to re-download \(item.url.lastPathComponent): \(error)")
                    }
                }
                try? context.save()
            } else {
                print("Sync: User or system chose to keep local deletion. Skipped pulling \(deletedFilesToPull.count) files.")
            }
        }
        
        // 更新菜单栏 Badge
        let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })
        let unsyncedCount = (try? context.fetchCount(descriptor)) ?? 0
        MenuBarManager.shared.updateBadge(count: unsyncedCount)
    }

    // MARK: - Auto Sync Logic
    
    private func resetSyncTimer(for event: FileEvent) {
        guard UserDefaults.standard.bool(forKey: "autoSync") else { return }
        
        let path = event.path
        let eventId = event.id
        
        DispatchQueue.main.async {
            self.syncTimers[path]?.invalidate()
            self.syncTimers[path] = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                self.syncTimers.removeValue(forKey: path)
                
                // 触发同步回调
                Task {
                    let context = await PersistenceController.shared.makeBackgroundContext()
                    let descriptor = FetchDescriptor<FileEvent>(
                        predicate: #Predicate<FileEvent> { $0.id == eventId && $0.isSynced == false }
                    )
                    if let freshEvent = try? context.fetch(descriptor).first {
                        do {
                            try await self.syncEventToIMA(freshEvent, in: context)
                        } catch {
                            print("Auto sync failed for \(freshEvent.fileName): \(error)")
                        }
                    }
                }
            }
        }
    }

    @MainActor
    func syncEventToIMA(_ event: FileEvent, in context: ModelContext) async throws {
        print("Attempting to sync event: \(event.path) (type: \(event.type))")
        if event.isDirectory {
            let folderTarget = getFolderTarget(for: event.path)
            if !folderTarget.knowledgeBaseId.isEmpty && folderTarget.knowledgeBaseId != "default" {
                if event.type == "deleted" {
                    if let remoteId = event.remoteId ?? getLatestRemoteId(for: event.path, in: context) {
                        do {
                            try await IMASyncService.shared.deleteKnowledgeByWebAPI(mediaIds: [remoteId], knowledgeBaseId: folderTarget.knowledgeBaseId)
                            print("Sync: Successfully deleted remote folder \(remoteId) for \(event.path)")
                        } catch {
                            print("Sync: Failed to delete remote folder \(remoteId) for \(event.path): \(error)")
                        }
                    }
                } else {
                    do {
                        let parentFolderId = try await IMASyncService.shared.resolveFolderIdIfNeeded(
                            knowledgeBaseId: folderTarget.knowledgeBaseId,
                            relativeFolderPath: folderTarget.relativeParentFolderPath
                        )
                        
                        let children = try await IMASyncService.shared.fetchAllKnowledgeItems(
                            knowledgeBaseId: folderTarget.knowledgeBaseId,
                            folderId: parentFolderId
                        )
                        
                        let folderId: String
                        if let existing = children.first(where: { $0.isFolder && $0.displayName == folderTarget.folderName }) {
                            folderId = existing.folderIdentifier ?? existing.mediaId
                            print("Sync: Folder \(folderTarget.folderName) already exists on cloud with ID \(folderId)")
                        } else {
                            folderId = try await IMASyncService.shared.createFolder(
                                title: folderTarget.folderName,
                                knowledgeBaseId: folderTarget.knowledgeBaseId,
                                parentFolderId: parentFolderId
                            )
                            print("Sync: Created folder \(folderTarget.folderName) on cloud with ID \(folderId)")
                        }
                        event.remoteId = folderId
                    } catch {
                        print("Sync: Failed to handle directory sync for \(event.path): \(error)")
                        throw error
                    }
                }
            }
            event.isSynced = true
            try? context.save()
            MenuBarManager.shared.updateBadge(count: unsyncedCount(in: context))
            return
        }

        if event.type == "deleted" {
            let target = getKnowledgeBaseTarget(for: event.path)
            if !target.knowledgeBaseId.isEmpty && target.knowledgeBaseId != "default" {
                if let remoteId = event.remoteId ?? getLatestRemoteId(for: event.path, in: context) {
                    do {
                        try await IMASyncService.shared.deleteKnowledgeByWebAPI(mediaIds: [remoteId], knowledgeBaseId: target.knowledgeBaseId)
                        print("Sync: Successfully deleted remote knowledge doc \(remoteId) for \(event.path)")
                    } catch {
                        print("Sync: Failed to delete remote knowledge doc \(remoteId) for \(event.path): \(error)")
                    }
                }
            }
            event.isSynced = true
            try? context.save()
            MenuBarManager.shared.updateBadge(count: unsyncedCount(in: context))
            return
        }

        let target = getKnowledgeBaseTarget(for: event.path)
        
        // 寻找包含此文件路径的已授权根目录安全 scoped URL
        let sortedPaths = monitoredPaths.sorted { $0.count > $1.count }
        var rootUrl: URL? = nil
        for rootPath in sortedPaths {
            if isSubpath(filePath: event.path, of: rootPath) {
                rootUrl = securityScopedURLs[rootPath]
                break
            }
        }
        
        // 显式开启沙盒内该父目录的读取权限（防 fileSize 因沙盒限制返回 0 / code 51）
        let didAccess = rootUrl?.startAccessingSecurityScopedResource() ?? false
        defer {
            if didAccess {
                rootUrl?.stopAccessingSecurityScopedResource()
            }
        }

        let remoteId = try await IMASyncService.shared.syncFile(
            fileURL: URL(fileURLWithPath: event.path),
            knowledgeBaseId: target.knowledgeBaseId,
            relativeFolderPath: target.relativeFolderPath,
            existingRemoteId: event.remoteId,
            duplicateStrategy: duplicateFileStrategy
        )
        event.isSynced = true
        event.remoteId = remoteId
        try? context.save()
        MenuBarManager.shared.updateBadge(count: unsyncedCount(in: context))
    }

    @MainActor
    private func unsyncedCount(in context: ModelContext) -> Int {
        let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    @MainActor
    private func getLatestRemoteId(for path: String, in context: ModelContext) -> String? {
        let descriptor = FetchDescriptor<FileEvent>(
            predicate: #Predicate<FileEvent> { $0.path == path && $0.remoteId != nil }
        )
        var sortedDescriptor = descriptor
        sortedDescriptor.sortBy = [SortDescriptor(\.timestamp, order: .reverse)]
        sortedDescriptor.fetchLimit = 1
        return (try? context.fetch(sortedDescriptor))?.first?.remoteId
    }

    private var duplicateFileStrategy: IMADuplicateFileStrategy {
        let rawValue = UserDefaults.standard.string(forKey: "imaDuplicateFileStrategy") ?? IMADuplicateFileStrategy.renameWithTimestamp.rawValue
        return IMADuplicateFileStrategy(rawValue: rawValue) ?? .renameWithTimestamp
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
            if flag & UInt32(kFSEventStreamEventFlagItemRemoved) != 0 {
                type = "deleted"
            } else if flag & UInt32(kFSEventStreamEventFlagItemRenamed) != 0 {
                // 对于重命名标志，我们需要区分是真正的重命名（目标文件存在）还是删除/移到废纸篓（文件不存在）
                // 必须通过 Security-Scoped Bookmarks 获取沙盒读取授权，否则 fileExists 将无权访问并错误返回 false
                let sortedPaths = self.monitoredPaths.sorted { $0.count > $1.count }
                var rootUrl: URL? = nil
                for rootPath in sortedPaths {
                    if self.isSubpath(filePath: path, of: rootPath) {
                        rootUrl = self.securityScopedURLs[rootPath]
                        break
                    }
                }
                
                let didAccess = rootUrl?.startAccessingSecurityScopedResource() ?? false
                let exists = FileManager.default.fileExists(atPath: path)
                if didAccess {
                    rootUrl?.stopAccessingSecurityScopedResource()
                }
                
                if !exists {
                    type = "deleted"
                } else {
                    type = "renamed"
                }
            } else if flag & UInt32(kFSEventStreamEventFlagItemCreated) != 0 {
                type = "created"
            } else {
                type = "modified"
            }
            
            let event = FileEvent(path: path, type: type, isDirectory: isDir)
            events.append(event)
        }
        
        if !events.isEmpty {
            print("FSEvents received events: \(events.map { "\($0.path) [\($0.type)]" })")
            onEventCallback?(events)
        }
    }

    func refreshIgnoreRules() {
        cachedIgnoreRules = IgnoreRules.load(
            userDefaults: .standard,
            enableDefaultKey: enableDefaultIgnoreRulesKey,
            customFileNamesKey: customIgnoredFileNamesKey,
            customExtensionsKey: customIgnoredExtensionsKey,
            customDirectoryNamesKey: customIgnoredDirectoryNamesKey
        )
    }

    private func shouldIgnoreEvent(path: String, isDirectory: Bool) -> Bool {
        if cachedIgnoreRules == nil {
            refreshIgnoreRules()
        }
        return cachedIgnoreRules?.matches(path: path, isDirectory: isDirectory) ?? false
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
        ".asd",
        ".lck",
        ".lock",
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

    private static let defaultFileNamePrefixes = [
        "~$",
        ".~$",
        "._",
        ".~lock.",
        "~WRL",
        "~DF",
        "~RF"
    ]

    private static let defaultFileNameSuffixes = [
        "#"
    ]

    let enableDefaultRules: Bool
    let customFileNames: [String]
    let customExtensions: [String]
    let customDirectoryNames: [String]

    let normalizedFileNames: Set<String>
    let normalizedExtensions: Set<String>
    let normalizedDirectoryNames: Set<String>

    init(enableDefaultRules: Bool, customFileNames: [String], customExtensions: [String], customDirectoryNames: [String]) {
        self.enableDefaultRules = enableDefaultRules
        self.customFileNames = customFileNames
        self.customExtensions = customExtensions
        self.customDirectoryNames = customDirectoryNames
        
        var fileNamesSet = Set(customFileNames.map { $0.lowercased() })
        if enableDefaultRules {
            fileNamesSet.formUnion(Self.defaultFileNames.map { $0.lowercased() })
        }
        self.normalizedFileNames = fileNamesSet
        
        var extensionsSet = Set(customExtensions.map(Self.normalizeExtension))
        if enableDefaultRules {
            extensionsSet.formUnion(Self.defaultExtensions.map(Self.normalizeExtension))
        }
        self.normalizedExtensions = extensionsSet
        
        var dirNamesSet = Set(customDirectoryNames.map { $0.lowercased() })
        if enableDefaultRules {
            dirNamesSet.formUnion(Self.defaultDirectoryNames.map { $0.lowercased() })
        }
        self.normalizedDirectoryNames = dirNamesSet
    }

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
        let nsPath = path as NSString
        let fileName = nsPath.lastPathComponent
        let loweredFileName = fileName.lowercased()
        let loweredComponents = pathComponents(path).map { $0.lowercased() }

        if containsAnyDirectoryName(in: loweredComponents) {
            return true
        }

        if normalizedFileNames.contains(loweredFileName) {
            return true
        }

        if enableDefaultRules {
            if Self.defaultFileNamePrefixes.contains(where: { fileName.hasPrefix($0) }) {
                return true
            }

            if Self.defaultFileNamePrefixes.contains(where: { loweredFileName.hasPrefix($0.lowercased()) }) {
                return true
            }

            if Self.defaultFileNameSuffixes.contains(where: { fileName.hasSuffix($0) }) {
                return true
            }
        }

        if !isDirectory {
            let loweredPath = path.lowercased()
            if normalizedExtensions.contains(where: { loweredPath.hasSuffix($0) }) {
                return true
            }
        }

        return false
    }

    private func containsAnyDirectoryName(in pathComponents: [String]) -> Bool {
        return pathComponents.contains { normalizedDirectoryNames.contains($0) }
    }

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map { String($0) }
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
