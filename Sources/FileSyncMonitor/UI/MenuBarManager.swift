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
        if let url = AppResourceLoader.url(forResource: "AppMenuBarIcon", withExtension: "png"),
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

        // 1. 状态头部展示 (包含待同步计数)
        let headerItem = NSMenuItem()
        let unsyncedCount = getUnsyncedCount()
        let statusText = unsyncedCount > 0 
            ? "FileSyncMonitor (\(String(format: "条待同步_format".appLocalized, unsyncedCount)))"
            : "FileSyncMonitor (\("已全部同步".appLocalized))"
        
        headerItem.attributedTitle = NSAttributedString(
            string: statusText,
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .bold),
                .foregroundColor: unsyncedCount > 0 ? NSColor.systemOrange : NSColor.secondaryLabelColor
            ]
        )
        headerItem.image = makeStatusBarImage()
        headerItem.isEnabled = false
        menu.addItem(headerItem)

        menu.addItem(NSMenuItem.separator())

        // 2. 打开主界面
        let openItem = NSMenuItem(
            title: "打开主界面".appLocalized,
            action: #selector(openMainWindow),
            keyEquivalent: "o"
        )
        openItem.target = self
        openItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(openItem)

        // 3. 系统设置
        let settingsItem = NSMenuItem(
            title: "设置...".appLocalized,
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // 4. 退出程序
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
        
        // 过滤获得主界面窗口（排除设置窗口和气泡窗口）
        let mainWindows = NSApp.windows.filter { window in
            return window.canBecomeMain && !window.title.contains("设置") && !window.title.contains("Settings")
        }
        
        if let window = mainWindows.first {
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else {
            // 如果窗口由于被用户关闭而彻底不存在，则向 AppDelegate 发送 reopen 消息，让 SwiftUI WindowGroup 自动拉起新窗口
            if let delegate = NSApp.delegate as? AppDelegate {
                _ = delegate.applicationShouldHandleReopen(NSApp, hasVisibleWindows: false)
            }
        }
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        // 兼容现代 macOS Sonoma (showSettingsWindow:) 和早期 macOS (showPreferencesWindow:)
        if #available(macOS 13.0, *) {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
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

    private func getUnsyncedCount() -> Int {
        let context = PersistenceController.shared.makeBackgroundContext()
        let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })
        return (try? context.fetchCount(descriptor)) ?? 0
    }
}
