import SwiftUI
import SwiftData
import QuartzCore
import ServiceManagement

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if CommandLine.arguments.contains("--run-tests") {
            Task {
                await BidirectionalSyncTests.run()
            }
            return
        }
        #endif
        
        cleanupInvalidLaunchAtLoginRegistrationIfNeeded()
        NSApp.setActivationPolicy(.accessory)
        NotificationManager.shared.requestAuthorization()
        MenuBarManager.shared.setupMenuBar()
        _ = FileMonitorService.shared // Trigger initialization and monitoring
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            let mainWindows = NSApp.windows.filter { window in
                return window.canBecomeMain && !window.title.contains("设置") && !window.title.contains("Settings")
            }
            if let window = mainWindows.first {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
        return true
    }

    private func cleanupInvalidLaunchAtLoginRegistrationIfNeeded() {
        let isPackagedApp = Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
        guard !isPackagedApp, SMAppService.mainApp.status == .enabled else { return }
        try? SMAppService.mainApp.unregister()
    }
}

@main
struct FileSyncMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @AppStorage("appearance") private var appearance: SettingsView.AppearanceMode = .system

    private var appLocale: Locale {
        Locale(identifier: appLanguage.effectiveLocaleIdentifier)
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1000, minHeight: 760)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
                .onAppear {
                    applyAppearance(appearance)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1150, height: 820)
        .onChange(of: appearance) { _, newValue in
            applyAppearance(newValue)
        }
        .commands {
            // 清除系统默认注入但对本工具无实际功能的菜单项，保持菜单栏精简专业
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .importExport) {}
            CommandGroup(replacing: .sidebar) {}
            CommandGroup(replacing: .toolbar) {}
        }
        
        Settings {
            SettingsView()
                .frame(minWidth: 700, minHeight: 500)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
        }
    }

    private func applyAppearance(_ mode: SettingsView.AppearanceMode) {
        for window in NSApp.windows {
            if let contentView = window.contentView {
                contentView.wantsLayer = true
                let transition = CATransition()
                transition.duration = 0.32
                transition.timingFunction = CAMediaTimingFunction(name: CAMediaTimingFunctionName.easeInEaseOut)
                transition.type = CATransitionType.fade
                contentView.layer?.add(transition, forKey: "appearanceTransition")
            }
        }

        switch mode {
        case .light:
            NSApp.appearance = NSAppearance(named: .aqua)
        case .dark:
            NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system:
            NSApp.appearance = nil
        }
    }
}
