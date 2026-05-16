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

    var body: some Scene {
        WindowGroup {
            MainView()
                .modelContainer(PersistenceController.shared.container)
        }
        .windowStyle(.hiddenTitleBar)
        
        Settings {
            SettingsView()
                .modelContainer(PersistenceController.shared.container)
        }
    }
}
