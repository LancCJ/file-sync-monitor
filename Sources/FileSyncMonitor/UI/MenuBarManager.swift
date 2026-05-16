import SwiftUI
import AppKit
import SwiftData

/// 负责菜单栏图标及其下拉菜单的管理
@MainActor
final class MenuBarManager: NSObject {
    static let shared = MenuBarManager()

    private var statusItem: NSStatusItem?

    func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.image = makeStatusBarImage()
            button.imagePosition = .imageLeft
            updateBadge(count: 0)
        }

        setupMenu()
    }

    private func makeStatusBarImage() -> NSImage? {
        if let url = Bundle.module.url(forResource: "AppMenuBarIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 18, height: 18)
            image.isTemplate = false
            image.accessibilityDescription = "FileSyncMonitor"
            return image
        }

        return NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FileSyncMonitor")
    }

    func updateBadge(count: Int) {
        guard let button = statusItem?.button else { return }
        if count > 0 {
            let attrString = NSAttributedString(
                string: " \(count)",
                attributes: [
                    .font: NSFont.systemFont(ofSize: 11, weight: .bold),
                    .foregroundColor: NSColor.systemRed
                ]
            )
            button.attributedTitle = attrString
        } else {
            button.attributedTitle = NSAttributedString(string: "")
        }
    }

    func refreshMenu() {
        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        let headerItem = NSMenuItem()
        headerItem.attributedTitle = NSAttributedString(
            string: "FileSyncMonitor",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .bold),
                .foregroundColor: NSColor.labelColor
            ]
        )
        headerItem.image = makeStatusBarImage()
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let statusMenuItem = NSMenuItem()
        let unsyncedCount = getUnsyncedCount()
        statusMenuItem.attributedTitle = NSAttributedString(
            string: unsyncedCount > 0 ? String(format: "条待同步_format".appLocalized, unsyncedCount) : "没有待同步文件".appLocalized,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(NSMenuItem.separator())

        for event in getRecentUnsyncedEvents() {
            let item = NSMenuItem(
            title: "\(eventTypeLabel(event.type)) · \(event.fileName)",
                action: #selector(markMenuEventSynced(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = event.id.uuidString
            item.image = NSImage(systemSymbolName: eventTypeSymbol(event.type), accessibilityDescription: nil)
            menu.addItem(item)
        }

        if unsyncedCount > 0 {
            menu.addItem(NSMenuItem.separator())
        }

        let openItem = NSMenuItem(
            title: "打开待同步文件".appLocalized,
            action: #selector(openMainWindow),
            keyEquivalent: "m"
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let syncItem = NSMenuItem(
            title: "全部标记完成".appLocalized,
            action: #selector(syncAll),
            keyEquivalent: "s"
        )
        syncItem.target = self
        syncItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        menu.addItem(syncItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "设置...".appLocalized,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "退出".appLocalized,
            action: #selector(confirmQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        self.statusItem?.menu = menu
    }

    @objc private func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    @objc private func syncAll() {
        Task { @MainActor in
            let context = PersistenceController.shared.makeBackgroundContext()
            let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })

            if let unsyncedEvents = try? context.fetch(descriptor) {
                for event in unsyncedEvents {
                    event.isSynced = true
                }
                try? context.save()
                updateBadge(count: 0)
                setupMenu()
            }
        }
    }

    @objc private func confirmQuit() {
        let alert = NSAlert()
        alert.messageText = "确定退出 FileSyncMonitor？".appLocalized
        alert.informativeText = "退出后将停止监控文件变动和自动同步。".appLocalized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "退出".appLocalized)
        alert.addButton(withTitle: "取消".appLocalized)

        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    @objc private func markMenuEventSynced(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let id = UUID(uuidString: idString) else { return }

        Task { @MainActor in
            let context = PersistenceController.shared.makeBackgroundContext()
            let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.id == id })
            if let event = try? context.fetch(descriptor).first {
                event.isSynced = true
                try? context.save()
            }
            let count = getUnsyncedCount()
            updateBadge(count: count)
            setupMenu()
        }
    }

    private func getUnsyncedCount() -> Int {
        let context = PersistenceController.shared.makeBackgroundContext()
        let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })
        return (try? context.fetchCount(descriptor)) ?? 0
    }

    private func getRecentUnsyncedEvents() -> [FileEvent] {
        let context = PersistenceController.shared.makeBackgroundContext()
        var descriptor = FetchDescriptor<FileEvent>(
            predicate: #Predicate<FileEvent> { $0.isSynced == false },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 5
        return (try? context.fetch(descriptor)) ?? []
    }

    private func eventTypeLabel(_ type: String) -> String {
        switch type {
        case "created": return "新增".appLocalized
        case "modified": return "修改".appLocalized
        case "deleted": return "删除".appLocalized
        case "renamed": return "重命名".appLocalized
        default: return "变动".appLocalized
        }
    }

    private func eventTypeSymbol(_ type: String) -> String {
        switch type {
        case "created": return "plus.circle"
        case "modified": return "pencil.circle"
        case "deleted": return "trash.circle"
        case "renamed": return "arrow.left.arrow.right.circle"
        default: return "doc"
        }
    }
}
