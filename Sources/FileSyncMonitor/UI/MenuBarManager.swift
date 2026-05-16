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
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "FileSyncMonitor")
            button.imagePosition = .imageLeft
            updateBadge(count: 0)
        }

        setupMenu()
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
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        let statusMenuItem = NSMenuItem()
        let unsyncedCount = getUnsyncedCount()
        statusMenuItem.attributedTitle = NSAttributedString(
            string: unsyncedCount > 0 ? "\(unsyncedCount) 条待同步" : "没有待同步文件",
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
            title: "打开待同步文件",
            action: #selector(openMainWindow),
            keyEquivalent: "m"
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        menu.addItem(NSMenuItem.separator())

        let syncItem = NSMenuItem(
            title: "全部完成",
            action: #selector(syncAll),
            keyEquivalent: "s"
        )
        syncItem.target = self
        syncItem.image = NSImage(systemSymbolName: "checkmark.circle", accessibilityDescription: nil)
        menu.addItem(syncItem)

        let exportMenu = NSMenu(title: "导出")
        let csvItem = NSMenuItem(title: "导出 CSV...", action: #selector(exportCSV), keyEquivalent: "")
        csvItem.target = self
        csvItem.image = NSImage(systemSymbolName: "tablecells", accessibilityDescription: nil)
        exportMenu.addItem(csvItem)

        let jsonItem = NSMenuItem(title: "导出 JSON...", action: #selector(exportJSON), keyEquivalent: "")
        jsonItem.target = self
        jsonItem.image = NSImage(systemSymbolName: "curlybraces", accessibilityDescription: nil)
        exportMenu.addItem(jsonItem)

        let exportItem = NSMenuItem(title: "导出", action: nil, keyEquivalent: "")
        exportItem.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
        exportItem.submenu = exportMenu
        menu.addItem(exportItem)

        menu.addItem(NSMenuItem.separator())

        let settingsItem = NSMenuItem(
            title: "设置...",
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
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

    @objc private func exportCSV() {
        export(format: .csv)
    }

    @objc private func exportJSON() {
        export(format: .json)
    }

    private func export(format: ExportService.ExportFormat) {
        let context = PersistenceController.shared.makeBackgroundContext()
        let descriptor = FetchDescriptor<FileEvent>(sortBy: [SortDescriptor(\.timestamp, order: .reverse)])
        guard let events = try? context.fetch(descriptor) else { return }

        do {
            let data = try ExportService.shared.export(events: events, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "Export_\(Int(Date().timeIntervalSince1970)).\(format == .csv ? "csv" : "json")"

            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            print("Export failed: \(error)")
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
        case "created": return "新增"
        case "modified": return "修改"
        case "deleted": return "删除"
        case "renamed": return "重命名"
        default: return "变动"
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
