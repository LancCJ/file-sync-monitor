import SwiftUI
import SwiftData
import QuartzCore

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
