import SwiftUI
import SwiftData

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NotificationManager.shared.requestAuthorization()
        MenuBarManager.shared.setupMenuBar()
        _ = FileMonitorService.shared // Trigger initialization and monitoring
    }
}

@main
struct FileSyncMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    private var appLocale: Locale {
        if let identifier = appLanguage.localeIdentifier {
            return Locale(identifier: identifier)
        }
        
        // If system, check if it's one of the supported ones
        let supported = ["en", "zh-Hans", "zh-Hant"]
        let current = Locale.current.identifier
        if supported.contains(where: { current.hasPrefix($0) }) {
            return .current
        }
        
        // Default to English if not supported
        return Locale(identifier: "en")
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1000, minHeight: 650)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
                .id(appLanguage)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        
        Settings {
            SettingsView()
                .frame(minWidth: 700, minHeight: 500)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
                .id(appLanguage)
        }
    }
}
