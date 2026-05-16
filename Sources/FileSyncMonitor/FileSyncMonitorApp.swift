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
        Locale(identifier: appLanguage.effectiveLocaleIdentifier)
    }

    var body: some Scene {
        WindowGroup {
            MainView()
                .frame(minWidth: 1000, minHeight: 650)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1100, height: 720)
        
        Settings {
            SettingsView()
                .frame(minWidth: 700, minHeight: 500)
                .modelContainer(PersistenceController.shared.container)
                .environment(\.locale, appLocale)
        }
    }
}
