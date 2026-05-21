import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FileEvent.timestamp, order: .reverse) private var events: [FileEvent]
    
    @State private var credsManager = IMACredentialsManager.shared

    // 观测语言变化，确保切换语言时 body 重新执行，所有 LocalizedText / .appLocalized 使用新语言
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @State private var selectedSidebarItem: SidebarItem = .home
    @State private var selectedEventID: UUID?
    @State private var searchText = ""
    @State private var typeFilter: EventTypeFilter = .all
    @State private var isSyncing = false
    @State private var isShowingQuitConfirmation = false
    @State private var isShowingBatchDeleteConfirmation = false
    @State private var isShowingClearEventsAlert = false
    @State private var isShowingResetAllAlert = false
    @State private var isShowingOnboarding = false
    @State private var onboardingStep = 0
    @State private var showingPullConfirmDialog = false
    @State private var pullConfirmUrls: [URL] = []
    @State private var pullConfirmContinuation: CheckedContinuation<Bool, Never>?

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home, pendingSync, allEvents, reports, settings, help
        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .home: return "首页"
            case .pendingSync: return "待同步"
            case .allEvents: return "全部记录"
            case .reports: return "报告"
            case .settings: return "设置"
            case .help: return "帮助"
            }
        }

        var icon: String {
            switch self {
            case .home: "house"
            case .pendingSync: "exclamationmark.circle"
            case .allEvents: "doc.text"
            case .reports: "chart.bar"
            case .settings: "gearshape"
            case .help: "questionmark.circle"
            }
        }
    }

    enum EventTypeFilter: String, CaseIterable, Identifiable {
        case all = "全部"
        case created = "新增"
        case modified = "修改"
        case deleted = "删除"
        case renamed = "重命名"

        var id: String { rawValue }

        var titleKey: String {
            switch self {
            case .all: return "全部"
            case .created: return "新增"
            case .modified: return "修改"
            case .deleted: return "删除"
            case .renamed: return "重命名"
            }
        }

        var eventType: String? {
            switch self {
            case .all: return nil
            case .created: return "created"
            case .modified: return "modified"
            case .deleted: return "deleted"
            case .renamed: return "renamed"
            }
        }
    }

    private var pendingEvents: [FileEvent] {
        events.filter { !$0.isSynced }
    }

    private var filteredEvents: [FileEvent] {
        var result = selectedSidebarItem == .pendingSync ? pendingEvents : events
        if let eventType = typeFilter.eventType {
            result = result.filter { $0.type == eventType }
        }
        if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }
        return result
    }

    private var selectedEvent: FileEvent? {
        guard let selectedEventID else {
            return nil
        }
        return filteredEvents.first { $0.id == selectedEventID }
    }

    var body: some View {
        GeometryReader { proxy in
            let layout = MainLayoutMetrics(size: proxy.size, safeAreaInsets: proxy.safeAreaInsets)

            ZStack {
                HStack(spacing: 0) {
                    IMARailView(
                        selection: $selectedSidebarItem,
                        pendingCount: pendingEvents.count,
                        layout: layout,
                        requestQuit: { isShowingQuitConfirmation = true }
                    )

                        switch selectedSidebarItem {
                        case .home:
                            FileSyncHomeView(
                                events: events,
                                pendingEvents: pendingEvents,
                                addDirectory: addDirectory,
                                showPending: { 
                                    print("[Debug] Navigating to Pending Sync")
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSidebarItem = .pendingSync 
                                    }
                                },
                                showAllRecords: { 
                                    print("[Debug] Navigating to All Records")
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSidebarItem = .allEvents 
                                    }
                                },
                                showReports: { 
                                    print("[Debug] Navigating to Reports")
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSidebarItem = .reports 
                                    }
                                },
                                showSettings: {
                                    print("[Debug] Navigating to Settings & Highlighting IMA Config")
                                    UserDefaults.standard.set(true, forKey: "highlightIMAConfig")
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSidebarItem = .settings
                                    }
                                },
                                markAllPendingSynced: markAllPendingSynced,
                                syncAllToIMA: syncAllToIMA,
                                deleteEvent: deleteEvent,
                                isSyncing: isSyncing,
                                showHelp: {
                                    print("[Debug] Navigating to Help")
                                    withAnimation(.snappy(duration: 0.22)) {
                                        selectedSidebarItem = .help
                                    }
                                }
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .pendingSync, .allEvents:
                            IMASecondarySidebar(
                                mode: selectedSidebarItem,
                                events: filteredEvents,
                                pendingCount: pendingEvents.count,
                                selectedEventID: $selectedEventID,
                                searchText: $searchText,
                                typeFilter: $typeFilter,
                                markAllPendingSynced: markAllPendingSynced,
                                syncAllToIMA: syncAllToIMA,
                                pullFromRemote: pullFromRemote,
                                deleteAllFilteredEvents: deleteAllFilteredEvents,
                                upload: upload,
                                markSynced: markSynced,
                                deleteEvent: deleteEvent,
                                isSyncing: isSyncing,
                                layout: layout
                            )

                            EventDetailView(
                                event: selectedEvent,
                                mode: selectedSidebarItem,
                                visibleEvents: filteredEvents,
                                isSyncing: isSyncing,
                                showAllRecords: { selectedSidebarItem = .allEvents },
                                addDirectory: addDirectory,
                                markSynced: markSynced,
                                upload: upload,
                                reveal: reveal,
                                deleteEvent: deleteEvent,
                                export: export,
                                layout: layout
                            )
                        case .reports:
                            ReportsView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .settings:
                            SettingsView(
                                requestClearEvents: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        isShowingClearEventsAlert = true
                                    }
                                },
                                requestResetAll: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                        isShowingResetAllAlert = true
                                    }
                                }
                            )
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        case .help:
                            HelpView()
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if isShowingQuitConfirmation {
                    QuitConfirmationOverlay(
                        cancel: { isShowingQuitConfirmation = false },
                        quit: { NSApp.terminate(nil) }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(70)
                }

                if isShowingBatchDeleteConfirmation {
                    BatchDeleteConfirmationOverlay(
                        count: filteredEvents.count,
                        cancel: { isShowingBatchDeleteConfirmation = false },
                        confirm: {
                            performBatchDelete()
                            isShowingBatchDeleteConfirmation = false
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(70)
                }

                if showingPullConfirmDialog {
                    SyncConfirmOverlay(
                        urls: pullConfirmUrls,
                        onConfirm: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                pullConfirmContinuation?.resume(returning: true)
                                pullConfirmContinuation = nil
                                showingPullConfirmDialog = false
                            }
                        },
                        onCancel: {
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                pullConfirmContinuation?.resume(returning: false)
                                pullConfirmContinuation = nil
                                showingPullConfirmDialog = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(80)
                }

                if !credsManager.isLoggedIn {
                    ZStack {
                        Color.black.opacity(0.12)
                        
                        Circle()
                            .fill(Color.appMint.opacity(0.15))
                            .frame(width: 400, height: 400)
                            .blur(radius: 80)
                            .offset(x: -120, y: -80)
                        
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 450, height: 450)
                            .blur(radius: 90)
                            .offset(x: 150, y: 100)
                        
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .opacity(0.55)
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                    
                    IMALoginView(onLoginSuccess: {
                        print("[MainView] WeChat login success, unlocking interface.")
                    })
                    .transition(.scale.combined(with: .opacity))
                    .zIndex(90)
                }
                
                // 全局高端同步进度遮罩卡片
                SyncProgressOverlay()
                    .zIndex(40)

                if isShowingClearEventsAlert {
                    CustomSettingsConfirmationOverlay(
                        title: "确认清除文件记录？",
                        message: "此操作将永久删除本地数据库中的所有文件变动记录和同步日志，但不会删除您的本地物理文件。",
                        confirmTitle: "清除",
                        iconName: "trash.fill",
                        iconColor: Color.appRose,
                        cancel: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                isShowingClearEventsAlert = false
                            }
                        },
                        confirm: {
                            NotificationCenter.default.post(name: Notification.Name("performClearAllEvents"), object: nil)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                isShowingClearEventsAlert = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(70)
                }

                if isShowingResetAllAlert {
                    CustomSettingsConfirmationOverlay(
                        title: "确认彻底重置应用？",
                        message: "此操作将清空所有文件变动记录、停止监控所有文件夹、清除自定义忽略规则、恢复所有偏好设置至出厂默认，并退出您的腾讯 IMA 账号授权。本操作无法撤销。",
                        confirmTitle: "重置",
                        iconName: "exclamationmark.triangle.fill",
                        iconColor: Color.appRose,
                        cancel: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                isShowingResetAllAlert = false
                            }
                        },
                        confirm: {
                            NotificationCenter.default.post(name: Notification.Name("performResetAll"), object: nil)
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                isShowingResetAllAlert = false
                            }
                        }
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
                    .zIndex(70)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IMAWindowBackground())
            .background(MainWindowDelegateConfigurator())
            .tint(.appMint)
            .overlayPreferenceValue(OnboardingTargetPreferenceKey.self) { anchors in
                GeometryReader { proxy in
                    if isShowingOnboarding {
                        OnboardingOverlay(
                            stepIndex: $onboardingStep,
                            layout: layout,
                            targetRects: anchors.mapValues { proxy[$0] },
                            dismiss: {
                                hasCompletedOnboarding = true
                                isShowingOnboarding = false
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                        .zIndex(10)
                    }
                }
            }
            .onChange(of: selectedSidebarItem) { _, _ in
                selectedEventID = nil
                searchText = ""
                typeFilter = .all
            }
            .onAppear {
                if credsManager.isLoggedIn && credsManager.avatarUrl.isEmpty {
                    Task {
                        if let profile = try? await IMASyncService.shared.getUserProfile() {
                            await MainActor.run {
                                credsManager.avatarUrl = profile.avatarUrl
                                credsManager.nickname = profile.nickname
                            }
                        }
                    }
                }
                if !hasCompletedOnboarding {
                    selectedSidebarItem = .home
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                        if !hasCompletedOnboarding {
                            withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                                isShowingOnboarding = true
                            }
                        }
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("ResetOnboarding"))) { _ in
                hasCompletedOnboarding = false
                selectedSidebarItem = .home
                onboardingStep = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.86)) {
                        isShowingOnboarding = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SelectSidebarItem"))) { notification in
                if let rawValue = notification.object as? String,
                   let item = SidebarItem(rawValue: rawValue) {
                    selectedSidebarItem = item
                }
            }
        }
    }

    private func addDirectory() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false

        if panel.runModal() == .OK, let url = panel.url {
            FileMonitorService.shared.addDirectory(at: url)
        }
    }

    private func markAllPendingSynced() {
        for event in pendingEvents {
            event.isSynced = true
        }
        try? modelContext.save()
        selectedEventID = nil
        MenuBarManager.shared.updateBadge(count: 0)
    }

    private func export(events: [FileEvent], format: ExportService.ExportFormat) {
        do {
            let data = try ExportService.shared.export(events: events, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "FileSync_\(Int(Date().timeIntervalSince1970)).\(format == .csv ? "csv" : "json")"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            print("Export failed: \(error)")
        }
    }
}

struct MainLayoutMetrics {
    let size: CGSize
    let safeAreaInsets: EdgeInsets

    var railWidth: CGFloat {
        78
    }

    var secondarySidebarWidth: CGFloat {
        min(max(size.width * 0.2, 278), 340)
    }

    var titleBarInset: CGFloat {
        max(safeAreaInsets.top, 28)
    }

    var topContentPadding: CGFloat {
        24
    }

    var sidebarHeaderPadding: CGFloat {
        24
    }

    var detailToolbarHeight: CGFloat {
        54
    }
}

private enum OnboardingTarget: Hashable {
    case rail
    case addDirectory
    case syncMode
    case pending
    case settings
}

private struct OnboardingTargetPreferenceKey: PreferenceKey {
    static var defaultValue: [OnboardingTarget: Anchor<CGRect>] = [:]

    static func reduce(value: inout [OnboardingTarget: Anchor<CGRect>], nextValue: () -> [OnboardingTarget: Anchor<CGRect>]) {
        value.merge(nextValue(), uniquingKeysWith: { _, newValue in newValue })
    }
}

private extension View {
    func onboardingTarget(_ target: OnboardingTarget) -> some View {
        anchorPreference(key: OnboardingTargetPreferenceKey.self, value: .bounds) { anchor in
            [target: anchor]
        }
    }
}

struct IMARailView: View {
    @Binding var selection: MainView.SidebarItem
    let pendingCount: Int
    let layout: MainLayoutMetrics
    let requestQuit: () -> Void
    @Environment(\.colorScheme) var scheme
    @State private var credsManager = IMACredentialsManager.shared

    var body: some View {
        VStack(spacing: 18) {
            AppBrandIcon(size: 38, cornerRadius: 10)
                .padding(.top, layout.titleBarInset + layout.topContentPadding)

            VStack(spacing: 18) {
                ForEach(MainView.SidebarItem.allCases.filter { $0 != .settings && $0 != .help }) { item in
                    IMARailButton(
                        item: item,
                        isSelected: selection == item,
                        badgeCount: item == .pendingSync ? pendingCount : 0
                    ) {
                        selection = item
                    }
                    .modifier(OnboardingTargetMarker(target: item == .pendingSync ? .pending : nil))
                }
            }
            .padding(.top, 22)
            .onboardingTarget(.rail)

            Spacer()

            VStack(spacing: 18) {
                VStack(spacing: 18) {
                    IMARailButton(item: .help, isSelected: selection == .help, badgeCount: 0) {
                        selection = .help
                    }

                    IMARailButton(item: .settings, isSelected: selection == .settings, badgeCount: 0) {
                        selection = .settings
                    }
                }

                VStack(spacing: 18) {
                    IMARailLanguageButton()
                    
                    if credsManager.isLoggedIn {
                        IMARailAvatarButton {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.82)) {
                                credsManager.clear(clearWebView: true)
                            }
                        }
                        .transition(.scale.combined(with: .opacity))
                    }

                    Button(action: requestQuit) {
                        IMARailExitButton()
                    }
                    .buttonStyle(.plain)
                    .help("退出".appLocalized)
                }
            }
            .padding(.bottom, 18)
            .onboardingTarget(.settings)
        }
        .frame(width: layout.railWidth)
        .background(
            LinearGradient(
                colors: [
                    Color(light: Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)),
                    Color(light: Color(red: 230 / 255, green: 238 / 255, blue: 233 / 255), dark: Color(red: 18 / 255, green: 20 / 255, blue: 22 / 255))
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .id(scheme)
    }
}

private struct OnboardingTargetMarker: ViewModifier {
    let target: OnboardingTarget?

    func body(content: Content) -> some View {
        if let target {
            content.onboardingTarget(target)
        } else {
            content
        }
    }
}

struct IMARailExitButton: View {
    @State private var isHovered = false

    var body: some View {
        Image(systemName: "power")
            .font(.system(size: 18, weight: .medium))
            .foregroundStyle(Color.appInk.opacity(0.78))
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.appInk.opacity(0.08) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct IMARailAvatarButton: View {
    @State private var isHovered = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                let avatarUrl = IMACredentialsManager.shared.avatarUrl
                
                Group {
                    if !avatarUrl.isEmpty, let url = URL(string: avatarUrl) {
                        AsyncImage(url: url) { image in
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .clipShape(Circle())
                        } placeholder: {
                            Circle()
                                .fill(Color.appMint.opacity(0.2))
                                .overlay(
                                    ProgressView()
                                        .scaleEffect(0.5)
                                )
                        }
                    } else {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.appMint, Color.appMint.opacity(0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .overlay(
                                Image(systemName: "person.fill")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundColor(.white)
                            )
                    }
                }
                .frame(width: 28, height: 28)
                .shadow(color: Color.appMint.opacity(isHovered ? 0.35 : 0.15), radius: isHovered ? 5 : 2.5, y: 1)
                
                Circle()
                    .fill(Color.green)
                    .frame(width: 8, height: 8)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: 1.5)
                    )
                    .offset(x: 1, y: 1)
            }
            .scaleEffect(isHovered ? 1.06 : 1.0)
            .animation(.snappy(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(IMACredentialsManager.shared.nickname.isEmpty ? "微信已登录 - 点击注销".appLocalized : "\(IMACredentialsManager.shared.nickname) - 点击注销".appLocalized)
    }
}

struct QuitConfirmationOverlay: View {
    let cancel: () -> Void
    let quit: () -> Void

    var body: some View {
        ZStack {
            Color.appInk.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            VStack(spacing: 18) {
                AppBrandIcon(size: 54, cornerRadius: 14)

                VStack(spacing: 8) {
                    LocalizedText("确定退出 FileSyncMonitor？")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.appInk)

                    LocalizedText("退出后将停止监控文件变动和自动同步。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                HStack(spacing: 10) {
                    Button(action: cancel) {
                        LocalizedText("取消")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Button(action: quit) {
                        Label {
                            LocalizedText("退出")
                        } icon: {
                            Image(systemName: "power")
                        }
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    .onboardingTarget(.addDirectory)
                }
            }
            .padding(24)
            .frame(width: 360)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.appSurface.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.appLine.opacity(0.78), lineWidth: 1)
                    )
            )
            .shadow(color: Color.appInk.opacity(0.16), radius: 24, x: 0, y: 16)
        }
    }
}

struct BatchDeleteConfirmationOverlay: View {
    let count: Int
    let cancel: () -> Void
    let confirm: () -> Void

    var body: some View {
        ZStack {
            Color.appInk.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: cancel)

            VStack(spacing: 18) {
                AppBrandIcon(size: 54, cornerRadius: 14)

                VStack(spacing: 8) {
                    LocalizedText("确认批量删除记录？")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.appInk)

                    Text(String(format: "即将删除当前显示的 %d 条记录。该操作不可恢复，且不会影响实际文件。".appLocalized, count))
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .multilineTextAlignment(.center)
                        .lineSpacing(4)
                }

                HStack(spacing: 10) {
                    Button(action: cancel) {
                        LocalizedText("取消")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Button(action: confirm) {
                        Label {
                            LocalizedText("确认删除")
                        } icon: {
                            Image(systemName: "trash")
                        }
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true, color: Color.appRose.opacity(0.92), hoverColor: Color.appRose))
                }
            }
            .padding(24)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.appSurface.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.appLine.opacity(0.78), lineWidth: 1)
                    )
            )
            .shadow(color: Color.appInk.opacity(0.16), radius: 24, x: 0, y: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct OnboardingOverlay: View {
    @Binding var stepIndex: Int
    let layout: MainLayoutMetrics
    let targetRects: [OnboardingTarget: CGRect]
    let dismiss: () -> Void

    private let steps = OnboardingStep.all

    private var step: OnboardingStep {
        steps[min(max(stepIndex, 0), steps.count - 1)]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.appInk.opacity(0.34)
                .ignoresSafeArea()

            highlightLayer

            OnboardingCard(
                step: step,
                stepIndex: stepIndex,
                total: steps.count,
                canGoBack: stepIndex > 0,
                isLast: stepIndex == steps.count - 1,
                back: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        stepIndex = max(0, stepIndex - 1)
                    }
                },
                next: {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                        if stepIndex == steps.count - 1 {
                            dismiss()
                        } else {
                            stepIndex += 1
                        }
                    }
                },
                skip: dismiss
            )
            .frame(width: 360)
            .position(cardPosition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var highlightLayer: some View {
        let rect = targetRect
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: step.cornerRadius, style: .continuous)
                .fill(Color.appSurface.opacity(0.18))
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)
                .shadow(color: Color.appMint.opacity(0.28), radius: 22, x: 0, y: 8)

            RoundedRectangle(cornerRadius: step.cornerRadius, style: .continuous)
                .stroke(Color.appMint, lineWidth: 2)
                .frame(width: rect.width, height: rect.height)
                .position(x: rect.midX, y: rect.midY)

            Image(systemName: step.pointerSymbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.appMint)
                .frame(width: 34, height: 34)
                .background(Circle().fill(Color.appSurface))
                .overlay(Circle().stroke(Color.appMint.opacity(0.28), lineWidth: 1))
                .position(x: pointerPosition.x, y: pointerPosition.y)
        }
    }

    private var targetRect: CGRect {
        if let rect = targetRects[step.kind.target] {
            return rect.insetBy(dx: -8, dy: -8)
        }
        return fallbackTargetRect
    }

    private var fallbackTargetRect: CGRect {
        let titleTop = layout.titleBarInset
        let rail = layout.railWidth
        let width = layout.size.width
        let height = layout.size.height

        switch step.kind {
        case .rail:
            return CGRect(x: 10, y: titleTop + 78, width: max(44, rail - 20), height: 214)
        case .addDirectory:
            return CGRect(x: rail + 46, y: titleTop + 130, width: 138, height: 46)
        case .syncMode:
            return CGRect(x: max(rail + 430, width - 246), y: titleTop + 118, width: 166, height: 66)
        case .pending:
            return CGRect(x: 10, y: titleTop + 116, width: max(44, rail - 20), height: 96)
        case .settings:
            return CGRect(x: 10, y: max(titleTop + 350, height - 280), width: max(44, rail - 20), height: 154)
        }
    }

    private var pointerPosition: CGPoint {
        let rect = targetRect
        switch step.kind {
        case .syncMode:
            return CGPoint(x: rect.minX - 13, y: rect.midY)
        default:
            return CGPoint(x: rect.maxX + 14, y: rect.midY)
        }
    }

    private var cardPosition: CGPoint {
        let rect = targetRect
        let width = layout.size.width
        let height = layout.size.height
        let cardHalfWidth: CGFloat = 180
        let cardHalfHeight: CGFloat = 150

        switch step.kind {
        case .syncMode:
            return CGPoint(
                x: min(max(rect.minX - 212, cardHalfWidth + 20), width - cardHalfWidth - 20),
                y: min(max(rect.midY + 12, cardHalfHeight + layout.titleBarInset), height - cardHalfHeight - 20)
            )
        case .settings:
            return CGPoint(
                x: min(max(rect.maxX + 210, cardHalfWidth + 20), width - cardHalfWidth - 20),
                y: min(max(rect.midY - 22, cardHalfHeight + layout.titleBarInset), height - cardHalfHeight - 20)
            )
        default:
            return CGPoint(
                x: min(max(rect.maxX + 220, cardHalfWidth + 20), width - cardHalfWidth - 20),
                y: min(max(rect.midY + 8, cardHalfHeight + layout.titleBarInset), height - cardHalfHeight - 20)
            )
        }
    }
}

private struct OnboardingCard: View {
    let step: OnboardingStep
    let stepIndex: Int
    let total: Int
    let canGoBack: Bool
    let isLast: Bool
    let back: () -> Void
    let next: () -> Void
    let skip: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                AppIconBadge(symbol: step.symbol, color: .appMint, size: 38)

                VStack(alignment: .leading, spacing: 3) {
                    Text(String(format: "引导进度_format".appLocalized, stepIndex + 1, total))
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.appMint)
                    LocalizedText(step.title)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(Color.appInk)
                }

                Spacer()
            }

            LocalizedText(step.message)
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index == stepIndex ? Color.appMint : Color.appLine)
                        .frame(width: index == stepIndex ? 20 : 7, height: 7)
                }
            }

            HStack(spacing: 10) {
                Button(action: skip) {
                    LocalizedText("跳过")
                }
                .buttonStyle(QuietButtonStyle())

                Spacer()

                if canGoBack {
                    Button(action: back) {
                        LocalizedText("上一步")
                    }
                    .buttonStyle(QuietButtonStyle())
                }

                Button(action: next) {
                    Label {
                        LocalizedText(isLast ? "完成" : "下一步")
                    } icon: {
                        Image(systemName: isLast ? "checkmark" : "arrow.right")
                    }
                }
                .buttonStyle(PillButtonStyle(isPrimary: true))
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.98))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.appLine.opacity(0.78), lineWidth: 1)
                )
        )
        .shadow(color: Color.appInk.opacity(0.2), radius: 24, x: 0, y: 16)
    }
}

private struct OnboardingStep {
    enum Kind {
        case rail
        case addDirectory
        case syncMode
        case pending
        case settings

        var target: OnboardingTarget {
            switch self {
            case .rail: return .rail
            case .addDirectory: return .addDirectory
            case .syncMode: return .syncMode
            case .pending: return .pending
            case .settings: return .settings
            }
        }
    }

    let kind: Kind
    let title: String
    let message: String
    let symbol: String
    let pointerSymbol: String
    let cornerRadius: CGFloat

    static let all: [OnboardingStep] = [
        OnboardingStep(
            kind: .rail,
            title: "先认识左侧导航",
            message: "左侧图标栏是主要入口：首页、待同步、全部记录、报告、帮助和设置都在这里切换。",
            symbol: "sidebar.left",
            pointerSymbol: "arrow.left",
            cornerRadius: 14
        ),
        OnboardingStep(
            kind: .addDirectory,
            title: "第一步：添加监控目录",
            message: "点击“添加目录”选择你要关注的文件夹。授权后，文件新增、修改、删除和重命名都会被自动记录。",
            symbol: "folder.badge.plus",
            pointerSymbol: "arrow.left",
            cornerRadius: 10
        ),
        OnboardingStep(
            kind: .syncMode,
            title: "选择手动或自动同步",
            message: "默认是手动同步。开启自动同步后，文件稳定 30 秒会自动上传到 IMA，适合持续写作或频繁保存的目录。",
            symbol: "arrow.triangle.2.circlepath",
            pointerSymbol: "arrow.right",
            cornerRadius: 12
        ),
        OnboardingStep(
            kind: .pending,
            title: "处理待同步与历史记录",
            message: "第二个图标查看待同步队列，第三个图标查看全部记录。你可以搜索、筛选、切换树状视图、同步或清理记录。",
            symbol: "doc.text.magnifyingglass",
            pointerSymbol: "arrow.left",
            cornerRadius: 14
        ),
        OnboardingStep(
            kind: .settings,
            title: "最后配置云端和偏好",
            message: "底部区域可以进入帮助、设置、切换语言和退出。建议先进行腾讯 IMA 账户扫码登录，并按需配置忽略规则。",
            symbol: "gearshape",
            pointerSymbol: "arrow.left",
            cornerRadius: 14
        )
    ]
}

struct IMARailButton: View {
    let item: MainView.SidebarItem
    let isSelected: Bool
    let badgeCount: Int
    let action: () -> Void
    
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .topTrailing) {
                Image(systemName: item.icon)
                    .font(.system(size: 18, weight: isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Color.appInk : Color.appMuted.opacity(0.8))
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.appSurface.opacity(0.95) : (isHovered ? Color.appInk.opacity(0.08) : Color.clear))
                    )

                if badgeCount > 0 {
                    Text("\(badgeCount)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .frame(height: 14)
                        .background(Capsule().fill(Color.appRose))
                        .offset(x: 2, y: -2)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(item.titleKey.appLocalized)
    }
}

struct FileSyncHomeView: View {
    @AppStorage("autoSync") private var autoSync = false
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @AppStorage("imaKnowledgeBaseId") private var knowledgeBaseId = ""
    @AppStorage("showAppWelcomeBanner") private var showAppWelcomeBanner = true

    let events: [FileEvent]
    let pendingEvents: [FileEvent]
    let addDirectory: () -> Void
    let showPending: () -> Void
    let showAllRecords: () -> Void
    let showReports: () -> Void
    let showSettings: () -> Void
    let markAllPendingSynced: () -> Void
    let syncAllToIMA: () -> Void
    let deleteEvent: (FileEvent) -> Void
    let isSyncing: Bool
    let showHelp: () -> Void

    private var monitoredCount: Int {
        FileMonitorService.shared.monitoredPaths.count
    }

    private var recentEvents: [FileEvent] {
        Array(events.prefix(5))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. Header Area: 固定在顶部，提供品牌状态与全局操作
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 6) {
                        LocalizedText("欢迎使用")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.appMint)
                        
                        LocalizedText(homeMessage)
                            .font(.system(size: 26, weight: .bold))
                            .foregroundStyle(Color.appInk)
                    }
                    
                    Spacer()
                    
                    StatusPill(
                        text: pendingEvents.isEmpty ? "已同步" : String(format: "个待处理_format".appLocalized, pendingEvents.count),
                        symbol: pendingEvents.isEmpty ? "checkmark" : "clock",
                        color: pendingEvents.isEmpty ? .appMint : .appAmber
                    )
                }
                
                HStack(spacing: 12) {
                    Button(action: addDirectory) {
                        HStack(spacing: 8) {
                            Image(systemName: "plus")
                            LocalizedText("添加目录")
                        }
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    
                    Button(action: syncAllToIMA) {
                        HStack(spacing: 8) {
                            if isSyncing {
                                ProgressView()
                                    .controlSize(.small)
                                    .brightness(0.5)
                            } else {
                                Image(systemName: pendingEvents.isEmpty ? "cloud.badge.checkmark" : "cloud.fill")
                            }
                            LocalizedText(pendingEvents.isEmpty ? "暂无可同步" : "全部同步")
                        }
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: !pendingEvents.isEmpty))
                    .disabled(pendingEvents.isEmpty || isSyncing)
                    
                    Spacer()
                    
                    HomeSyncModeControl(isAutoSync: $autoSync)
                        .onboardingTarget(.syncMode)
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 48)
            .padding(.bottom, 32)

            if showAppWelcomeBanner {
                WelcomeIntroBanner(
                    dismiss: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            showAppWelcomeBanner = false
                        }
                    },
                    startOnboarding: {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) {
                            showAppWelcomeBanner = false
                        }
                        NotificationCenter.default.post(name: NSNotification.Name("ResetOnboarding"), object: nil)
                    },
                    showHelp: showHelp
                )
                .padding(.horizontal, 48)
                .padding(.bottom, 28)
                .transition(.asymmetric(insertion: .opacity.combined(with: .move(edge: .top)), removal: .opacity.combined(with: .scale(scale: 0.95))))
            }

            // 2. Main Content Area: 左右分栏，核心展示区
            HStack(alignment: .top, spacing: 28) {
                // 左栏：变动流
                VStack(alignment: .leading, spacing: 24) {
                    SimplePanel(title: "最近记录", subtitle: events.isEmpty ? "添加监控目录后，文件变动会显示在这里。" : "最近捕获到的文件变动。") {
                        Group {
                            if recentEvents.isEmpty {
                                EmptyStateView(icon: "tray", title: "暂无记录", subtitle: "开始监控后，这里会显示最新文件变动。")
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ScrollView {
                                    VStack(spacing: 0) {
                                        ForEach(recentEvents) { event in
                                            HomeRecentEventRow(event: event, deleteAction: { deleteEvent(event) })
                                            if event.id != recentEvents.last?.id {
                                                Divider()
                                            }
                                        }
                                    }
                                    .animation(.snappy(duration: 0.28), value: recentEvents)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity) // 撑开中间区域
                    
                    // 底部快速跳转
                    HStack(spacing: 12) {
                        Button(action: showPending) {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                LocalizedText("处理待同步")
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        
                        Button(action: showAllRecords) {
                            HStack(spacing: 6) {
                                Image(systemName: "doc.text")
                                LocalizedText("查看全部记录")
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                        
                        Button(action: showReports) {
                            HStack(spacing: 6) {
                                Image(systemName: "chart.bar")
                                LocalizedText("查看报告")
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }

                // 右栏：统计看板
                VStack(spacing: 20) {
                    VStack(spacing: 12) {
                        HomeMetricCard(title: "待同步", value: pendingEvents.count, icon: "clock", color: pendingEvents.isEmpty ? .appMint : .appAmber)
                        HomeMetricCard(title: "全部记录", value: events.count, icon: "doc.text", color: .appInk)
                        HomeMetricCard(title: "监控目录", value: monitoredCount, icon: "folder", color: .appMint)
                    }
                    
                    SimplePanel(title: "状态摘要", subtitle: nil) {
                        VStack(spacing: 0) {
                            HomeStatusRow(title: "同步队列", value: pendingEvents.isEmpty ? "空" : "个文件_count:\(pendingEvents.count)", color: pendingEvents.isEmpty ? .appMint : .appAmber)
                            HomeStatusRow(title: "当前模式", value: autoSync ? "自动" : "手动", color: autoSync ? .appMint : .appInk)
                            HomeStatusRow(title: "监控路径", value: "个_count:\(monitoredCount)")
                        }
                    }
                }
                .frame(width: 270) // 适中的宽度
            }
            .padding(.horizontal, 48)
            .padding(.bottom, 32) // 减小底部边距
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IMAClientSurfaceBackground())
    }

    private var homeMessage: String {
        if monitoredCount == 0 {
            return "添加一个目录后，文件变动会自动记录并提醒你处理。"
        }
        if pendingEvents.isEmpty {
            return "所有文件变动都已处理完成。"
        }
        return "有新的文件变动等待确认同步。"
    }
}

struct HomeMetricCard: View {
    let title: String
    let value: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            AppIconBadge(symbol: icon, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                LocalizedText(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .appCard(padding: 15)
    }
}

struct HomeSyncModeControl: View {
    @Binding var isAutoSync: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Image(systemName: isAutoSync ? "bolt.circle.fill" : "hand.tap")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isAutoSync ? Color.appMint : Color.appMuted)

                LocalizedText(isAutoSync ? "自动同步" : "手动同步")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .frame(width: 56, alignment: .leading)

                AppToggle(isOn: $isAutoSync)
            }

            LocalizedText(isAutoSync ? "稳定 30 秒后上传" : "点击按钮时上传")
                .font(.system(size: 10))
                .foregroundStyle(Color.appMuted)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appSurface.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isAutoSync ? Color.appMint.opacity(0.34) : Color.appLine.opacity(0.72), lineWidth: 1)
                )
        )
        .help((isAutoSync ? "当前为自动同步：文件变动 30 秒后自动同步至云端" : "当前为手动同步：需要点击全部同步或单条上传").appLocalized)
    }
}

struct HomeRecentEventRow: View {
    let event: FileEvent
    var deleteAction: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            AppIconBadge(symbol: EventVisuals.symbol(for: event.type), color: EventVisuals.color(for: event.type), size: 28)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(event.fileName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.appInk)
                Text(event.path)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(event.timestamp.shortActivityTime)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.appMuted)
            SyncStatusChip(isSynced: event.isSynced)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.appSelection.opacity(0.5) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .imaHover()
    }
}

struct HomeStatusRow: View {
    let title: String
    let value: String
    var color: Color = .appInk
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    var body: some View {
        HStack(spacing: 12) {
            LocalizedText(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            Spacer()
            Text(localizedValue)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appLine.opacity(0.64))
                .frame(height: 1)
        }
    }

    private var localizedValue: String {
        if value.contains("_count:") {
            let parts = value.components(separatedBy: "_count:")
            if parts.count == 2, let count = Int(parts[1]) {
                let key = parts[0] + "_format"
                return String(format: key.appLocalized, count)
            }
        }
        return value.appLocalized
    }
}

struct IMASecondarySidebar: View {
    let mode: MainView.SidebarItem
    let events: [FileEvent]
    let pendingCount: Int
    @Binding var selectedEventID: UUID?
    @Binding var searchText: String
    @Binding var typeFilter: MainView.EventTypeFilter
    let markAllPendingSynced: () -> Void
    let syncAllToIMA: () -> Void
    let pullFromRemote: () -> Void
    let deleteAllFilteredEvents: () -> Void
    let upload: (FileEvent) -> Void
    let markSynced: (FileEvent) -> Void
    let deleteEvent: (FileEvent) -> Void
    let isSyncing: Bool
    let layout: MainLayoutMetrics
    @Environment(\.colorScheme) var scheme

    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @State private var viewMode: EventListViewMode = .list

    enum EventListViewMode: String, CaseIterable {
        case list = "列表"
        case tree = "树状"
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    LocalizedText(mode.titleKey)
                        .font(.system(size: 16, weight: .bold))
                    
                    Text("\(events.count)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .background(Capsule().fill(Color.appMuted.opacity(0.1)))

                    Spacer()
                    
                    // 视图模式切换
                    HStack(spacing: 2) {
                        ForEach([EventListViewMode.list, .tree], id: \.self) { m in
                            Button {
                                withAnimation(.snappy(duration: 0.18)) { viewMode = m }
                            } label: {
                                Image(systemName: m == .list ? "list.bullet" : "folder.badge.gearshape")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 26, height: 26)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                                            .fill(viewMode == m ? Color.appInk : Color.clear)
                                    )
                                    .foregroundStyle(viewMode == m ? Color.appCanvas : Color.appMuted)
                            }
                            .buttonStyle(.plain)
                            .help(m.rawValue.appLocalized)
                        }
                    }
                    .padding(3)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.appSurface.opacity(0.82))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.appLine.opacity(0.72), lineWidth: 1)
                            )
                    )
                    
                    if !events.isEmpty {
                        Button(action: deleteAllFilteredEvents) {
                            Image(systemName: "trash")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Color.appRose)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.appRose.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                        .help("批量删除当前视图记录".appLocalized)
                    }
                }

                SmoothSearchField(text: $searchText, placeholder: "搜索文件或路径")

                AppSegmentedControl(
                    options: MainView.EventTypeFilter.allCases.map { ($0, $0.titleKey) },
                    selection: $typeFilter
                )
                .frame(maxWidth: .infinity)

                if mode == .pendingSync {
                    VStack(spacing: 8) {
                        Button(action: syncAllToIMA) {
                            HStack {
                                if isSyncing {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "cloud.fill")
                                }
                                LocalizedText("全部同步至 IMA")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(isPrimary: true))
                        .disabled(pendingCount == 0 || isSyncing)

                        Button(action: pullFromRemote) {
                            HStack {
                                if FileMonitorService.shared.isPulling {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.down.circle.fill")
                                }
                                LocalizedText("从云端拉取更新")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(isPrimary: false))
                        .disabled(FileMonitorService.shared.isPulling)

                        Button(action: markAllPendingSynced) {
                            Label {
                                LocalizedText("全部标记完成")
                            } icon: {
                                Image(systemName: "checkmark")
                            }
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(pendingCount == 0 || isSyncing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, layout.titleBarInset + layout.sidebarHeaderPadding)
            .padding(.bottom, 14)
            .clipped()

            Divider()

            if events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: mode == .pendingSync ? "checkmark.circle" : "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.appMuted)
                    LocalizedText(mode == .pendingSync ? "没有待同步文件" : "暂无记录")
                        .font(.system(size: 13, weight: .semibold))
                    LocalizedText(mode == .pendingSync ? "所有变动都处理完成了。" : "添加目录后记录会显示在这里。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewMode == .list {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(events) { event in
                            IMAEventListRow(
                                event: event,
                                isSelected: selectedEventID == event.id,
                                action: { selectedEventID = event.id },
                                deleteAction: { deleteEvent(event) },
                                markSyncedAction: { markSynced(event) },
                                uploadAction: { upload(event) }
                            )
                        }
                    }
                    .padding(8)
                    .animation(.snappy(duration: 0.28), value: events)
                }
            } else {
                EventTreeView(
                    events: events,
                    selectedEventID: $selectedEventID
                )
            }
        }
        .frame(width: layout.secondarySidebarWidth)
        .background(
            GeometryReader { geo in
                let h = max(geo.size.height, 1)
                let titleEnd = layout.titleBarInset / h
                let blendEnd = min((layout.titleBarInset + 50) / h, 1.0)
                LinearGradient(
                    stops: [
                        .init(color: Color(light: Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)), location: 0),
                        .init(color: Color(light: Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)), location: titleEnd),
                        .init(color: Color(light: Color(red: 250 / 255, green: 253 / 255, blue: 251 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)), location: blendEnd),
                        .init(color: Color(light: Color(red: 244 / 255, green: 251 / 255, blue: 247 / 255), dark: Color(red: 18 / 255, green: 20 / 255, blue: 22 / 255)), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        )
        .id(scheme)
    }
}

struct IMAEventListRow: View {
    let event: FileEvent
    let isSelected: Bool
    let action: () -> Void
    var deleteAction: (() -> Void)? = nil
    var markSyncedAction: (() -> Void)? = nil
    var uploadAction: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: EventVisuals.symbol(for: event.type))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(EventVisuals.color(for: event.type))
                    .frame(width: 20, height: 20)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(EventVisuals.color(for: event.type).opacity(0.1))
                    )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(event.fileName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.appInk)
                            .lineLimit(1)
                        Spacer()
                        if !event.isSynced {
                            HStack(spacing: 4) {
                                Text(EventVisuals.title(for: event.type))
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(EventVisuals.color(for: event.type).opacity(0.15))
                                    .foregroundStyle(EventVisuals.color(for: event.type))
                                    .clipShape(RoundedRectangle(cornerRadius: 3))
                                
                                Circle()
                                    .fill(Color.appAmber)
                                    .frame(width: 6, height: 6)
                            }
                        }
                    }

                    Text(event.path)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(2)
                        .truncationMode(.middle)

                    Text(event.timestamp.shortActivityTime)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.appMuted.opacity(0.85))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.appSelection : (isHovered ? Color.appSelection.opacity(0.4) : Color.clear))
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.15), value: isHovered)
            .imaHover()
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !event.isSynced {
                Button {
                    uploadAction?()
                } label: {
                    Label("同步到 IMA".appLocalized, systemImage: "icloud.and.arrow.up")
                }
            }
            
            Button {
                markSyncedAction?()
            } label: {
                Label(event.isSynced ? "重新标记待同步".appLocalized : "标记为已完成".appLocalized, 
                      systemImage: event.isSynced ? "arrow.uturn.backward" : "checkmark.circle")
            }
            
            Divider()
            
            Button(role: .destructive) {
                deleteAction?()
            } label: {
                Label("删除记录".appLocalized, systemImage: "trash")
            }
        }
    }
}

struct EventDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    let event: FileEvent?
    let mode: MainView.SidebarItem
    let visibleEvents: [FileEvent]
    let isSyncing: Bool
    
    let showAllRecords: () -> Void
    let addDirectory: () -> Void
    let markSynced: (FileEvent) -> Void
    let upload: (FileEvent) -> Void
    let reveal: (FileEvent) -> Void
    let deleteEvent: (FileEvent) -> Void
    let export: (ExportService.ExportFormat) -> Void
    let layout: MainLayoutMetrics

    var body: some View {
        ZStack {
            IMAClientSurfaceBackground()

            // 标题栏区域背景统一渐变：从左侧栏同色灰绿平滑过渡至透明
            VStack(spacing: 0) {
                LinearGradient(
                    colors: [
                        Color(light: Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)),
                        Color(light: Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255), dark: Color(red: 24 / 255, green: 26 / 255, blue: 28 / 255)).opacity(0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: layout.titleBarInset + 50)
                Spacer()
            }
            .allowsHitTesting(false)

            if let event {
                VStack(spacing: 0) {
                    EventDetailToolbar(
                        event: event,
                        visibleEvents: visibleEvents,
                        export: export,
                        layout: layout
                    )

                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            VStack(alignment: .leading, spacing: 12) {
                                StatusPill(
                                    text: EventVisuals.title(for: event.type),
                                    symbol: EventVisuals.symbol(for: event.type),
                                    color: EventVisuals.color(for: event.type)
                                )

                                Text(event.fileName)
                                    .font(.system(size: 30, weight: .bold))
                                    .foregroundStyle(Color.appInk)
                                    .lineLimit(2)

                                Text(event.path)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.appMuted)
                                    .textSelection(.enabled)
                            }

                            VStack(spacing: 0) {
                                EventInfoRow(title: "同步状态", value: event.isSynced ? "已同步" : "待同步", color: event.isSynced ? .appMint : .appAmber)
                                EventInfoRow(title: "记录时间", value: event.timestamp.shortActivityTime)
                                EventInfoRow(title: "是否目录", value: event.isDirectory ? "目录" : "文件")
                                if let oldPath = event.oldPath, !oldPath.isEmpty {
                                    EventInfoRow(title: "原路径", value: oldPath)
                                }
                            }
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.appSurfaceSoft.opacity(0.88))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                                            .stroke(Color.appLine.opacity(0.66), lineWidth: 1)
                                    )
                            )

                            HStack(spacing: 10) {
                                Button(action: { upload(event) }) {
                                    if isSyncing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label {
                                            LocalizedText(event.isSynced ? "已同步到 IMA" : "同步到 IMA")
                                        } icon: {
                                            Image(systemName: event.isSynced ? "checkmark.icloud" : "icloud.and.arrow.up")
                                        }
                                    }
                                }
                                .buttonStyle(PillButtonStyle(isPrimary: true))
                                .disabled(event.isSynced || isSyncing)

                                Button(action: { markSynced(event) }) {
                                    Label {
                                        LocalizedText(event.isSynced ? "重新标记待同步" : "仅标记完成")
                                    } icon: {
                                        Image(systemName: event.isSynced ? "arrow.uturn.backward" : "checkmark")
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())

                                Button(action: { reveal(event) }) {
                                    Label {
                                        LocalizedText("在 Finder 中显示")
                                    } icon: {
                                        Image(systemName: "folder")
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())

                                Spacer()

                                Button(role: .destructive, action: { deleteEvent(event) }) {
                                    HStack(spacing: 6) {
                                        Image(systemName: "trash")
                                        LocalizedText("删除记录")
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())
                                .tint(.appRose)
                            }
                        }
                        .frame(maxWidth: 720, alignment: .leading)
                        .padding(.horizontal, 80)
                        .padding(.top, 72)
                    }
                }
            } else if visibleEvents.isEmpty {
                IMAEmptyHomeState(
                    isPendingMode: mode == .pendingSync,
                    addDirectory: addDirectory,
                    showAllRecords: showAllRecords
                )
            } else {
                IMASelectEventState()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension MainView {
    private func markSynced(_ event: FileEvent) {
        event.isSynced.toggle()
        try? modelContext.save()
        MenuBarManager.shared.updateBadge(count: currentUnsyncedCount())
    }

    private func upload(_ event: FileEvent) {
        isSyncing = true
        Task {
            FileMonitorService.shared.startSyncProgress(title: "正在同步到云端...".appLocalized)
            defer { isSyncing = false }
            
            do {
                try await FileMonitorService.shared.syncEventToIMA(event, in: modelContext)
                FileMonitorService.shared.finishSyncProgressSuccess(status: event.type == "deleted" ? "已自动从云端移除".appLocalized : "同步完成".appLocalized)
            } catch {
                print("IMA Sync failed: \(error)")
                FileMonitorService.shared.finishSyncProgressError(message: error.localizedDescription)
            }
        }
    }

    private func syncAllToIMA() {
        print("[Debug] syncAllToIMA called. Pending count: \(pendingEvents.count)")
        let targets = pendingEvents
        guard !targets.isEmpty else { return }
        
        isSyncing = true
        Task {
            FileMonitorService.shared.startSyncProgress(title: "正在同步到云端...".appLocalized)
            defer { isSyncing = false }
            var failedMessages: [String] = []
            
            for event in targets {
                do {
                    try await FileMonitorService.shared.syncEventToIMA(event, in: modelContext)
                } catch {
                    print("Batch sync failed for \(event.fileName): \(error)")
                    failedMessages.append("\(event.fileName)：\(error.localizedDescription)")
                }
            }
            
            if !failedMessages.isEmpty {
                FileMonitorService.shared.finishSyncProgressError(message: failedMessages.joined(separator: "\n\n"))
            } else {
                FileMonitorService.shared.finishSyncProgressSuccess(status: "全部同步完成".appLocalized)
            }
        }
    }

    @MainActor
    private func showSyncFailureAlert(message: String) {
        let alert = NSAlert()
        alert.messageText = "同步失败".appLocalized
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "我知道了".appLocalized)
        alert.runModal()
    }

    private func deleteEvent(_ event: FileEvent) {
        let alert = NSAlert()
        alert.messageText = "确认删除记录？".appLocalized
        alert.informativeText = "该操作不可恢复，仅删除 App 内的变动记录，不会影响实际文件。".appLocalized
        alert.alertStyle = .warning
        alert.addButton(withTitle: "删除".appLocalized)
        alert.addButton(withTitle: "取消".appLocalized)
        
        if alert.runModal() == .alertFirstButtonReturn {
            modelContext.delete(event)
            try? modelContext.save()
            selectedEventID = nil
            MenuBarManager.shared.updateBadge(count: currentUnsyncedCount())
        }
    }

    private func reveal(_ event: FileEvent) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: event.path)])
    }

    private func export(format: ExportService.ExportFormat) {
        // 使用 filteredEvents 进行导出
        do {
            let data = try ExportService.shared.export(events: filteredEvents, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "FileSync_\(Int(Date().timeIntervalSince1970)).\(format == .csv ? "csv" : "json")"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            print("Export failed: \(error)")
        }
    }

    private func currentUnsyncedCount() -> Int {
        let descriptor = FetchDescriptor<FileEvent>(predicate: #Predicate<FileEvent> { $0.isSynced == false })
        return (try? modelContext.fetchCount(descriptor)) ?? 0
    }

    private func pullFromRemote() {
        Task {
            FileMonitorService.shared.startSyncProgress(title: "正在从云端拉取更新...".appLocalized)
            await FileMonitorService.shared.pullFromRemote(confirmDownloadForDeleted: { urls in
                await MainActor.run {
                    self.pullConfirmUrls = urls
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        self.showingPullConfirmDialog = true
                    }
                }
                return await withCheckedContinuation { continuation in
                    self.pullConfirmContinuation = continuation
                }
            })
            FileMonitorService.shared.finishSyncProgressSuccess(status: "已完成从云端同步".appLocalized)
        }
    }

    private func deleteAllFilteredEvents() {
        guard !filteredEvents.isEmpty else { return }
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) {
            isShowingBatchDeleteConfirmation = true
        }
    }

    private func performBatchDelete() {
        for event in filteredEvents {
            modelContext.delete(event)
        }
        try? modelContext.save()
        selectedEventID = nil
        MenuBarManager.shared.updateBadge(count: currentUnsyncedCount())
    }
}

struct EventDetailToolbar: View {
    let event: FileEvent
    let visibleEvents: [FileEvent]
    let export: (ExportService.ExportFormat) -> Void
    let layout: MainLayoutMetrics

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "chevron.left")
                .foregroundStyle(Color.appMuted)
            Image(systemName: "chevron.right")
                .foregroundStyle(Color.appMuted.opacity(0.45))

            Text(event.fileName)
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)

            Spacer()

            Button(action: { export(.csv) }) {
                Image(systemName: "tablecells")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("导出 CSV".appLocalized)

            Button(action: { export(.json) }) {
                Image(systemName: "curlybraces")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("导出 JSON".appLocalized)
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.appInk)
        .padding(.horizontal, 28)
        .padding(.top, layout.titleBarInset)
        .frame(height: layout.detailToolbarHeight + layout.titleBarInset)
        .background(
            VStack(spacing: 0) {
                Color.clear
                    .frame(height: layout.titleBarInset)
                Color.white.opacity(0.82)
            }
        )
    }
}

struct EventInfoRow: View {
    let title: String
    let value: String
    var color: Color = .appInk

    var body: some View {
        HStack(alignment: .top) {
            LocalizedText(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appInk)
                .frame(width: 92, alignment: .leading)

            Text(value.appLocalized)
                .font(.system(size: 13))
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appLine)
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }
}

struct IMAEmptyHomeState: View {
    let isPendingMode: Bool
    let addDirectory: () -> Void
    let showAllRecords: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                AppBrandIcon(size: 74, cornerRadius: 18)
                    .padding(.bottom, 4)

                Text("FileSync")
                    .font(.system(size: 58, weight: .black))
                    .foregroundStyle(Color.appInk)
                Text("monitor")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(8)
                    .foregroundStyle(Color.appInk.opacity(0.7))
            }

            VStack(spacing: 8) {
                LocalizedText(isPendingMode ? "所有文件都已同步" : "还没有文件记录")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appInk)
                LocalizedText(isPendingMode ? "新的文件变动会自动出现在左侧列表。" : "添加监控目录后，文件变动会被自动记录。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
            }

            HStack(spacing: 10) {
                Button(action: addDirectory) {
                    Label {
                        LocalizedText("添加目录")
                    } icon: {
                        Image(systemName: "plus")
                    }
                }
                .buttonStyle(PillButtonStyle(isPrimary: true))

                Button(action: showAllRecords) {
                    Label {
                        LocalizedText("查看全部记录")
                    } icon: {
                        Image(systemName: "doc.text")
                    }
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IMAClientSurfaceBackground())
    }
}

struct IMASelectEventState: View {
    var body: some View {
        VStack(spacing: 18) {
            AppIconBadge(symbol: "cursorarrow.click", color: .appMint, size: 54)

            VStack(spacing: 7) {
                LocalizedText("选择一条记录")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appInk)
                LocalizedText("从左侧列表中选择文件变动后，可查看路径、状态并执行同步操作。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IMAClientSurfaceBackground())
    }
}

struct SimplePanel<Content: View>: View {
    let title: String
    let subtitle: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                LocalizedText(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appInk)
                
                if let subtitle {
                    LocalizedText(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                }
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .appCard(padding: 15)
    }
}

struct MetricLine: View {
    let value: Int
    let label: String
    let color: Color

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(value)")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundStyle(color)
            LocalizedText(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
    }
}

struct SyncStatusChip: View {
    let isSynced: Bool

    var body: some View {
        StatusPill(
            text: isSynced ? "已同步" : "待同步",
            symbol: isSynced ? "checkmark" : "clock",
            color: isSynced ? .appMint : .appAmber
        )
    }
}

struct TypeIcon: View {
    let type: String

    var body: some View {
        Image(systemName: EventVisuals.symbol(for: type))
            .foregroundStyle(EventVisuals.color(for: type))
    }
}

struct SyncStatusView: View {
    let isSynced: Bool

    var body: some View {
        SyncStatusChip(isSynced: isSynced)
    }
}

struct IMARailLanguageButton: View {
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @State private var isHovered = false

    var body: some View {
        AppDropdownMenu(
            selection: $appLanguage,
            options: AppLanguage.allCases.map { ($0, $0.displayTitle) },
            label: VStack(spacing: 1) {
                Image(systemName: "globe")
                    .font(.system(size: 17, weight: .medium))
                Text(appLanguage == .en ? "EN" : (appLanguage == .zhHant ? "繁" : "简"))
                    .font(.system(size: 8, weight: .bold))
            }
            .foregroundStyle(Color.appInk.opacity(0.78))
            .frame(width: 40, height: 40)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isHovered ? Color.appInk.opacity(0.08) : Color.clear)
            ),
            arrowEdge: .trailing,
            localizeOptions: false
        )
        .onHover { isHovered = $0 }
        .help("切换语言".appLocalized)
        .id(appLanguage)
        .onChange(of: appLanguage) { _, _ in
            MenuBarManager.shared.refreshMenu()
        }
    }
}

// MARK: - Tree View

/// 树节点：可以是虚拟目录节点，也可以是叶子文件事件节点
final class EventTreeNode: Identifiable {
    let id: String            // 完整路径，作为唯一标识
    let name: String          // 目录名 或 文件名
    let path: String          // 完整路径
    var children: [EventTreeNode] = []
    var events: [FileEvent] = []  // 该节点直接持有的事件（叶子节点）

    init(path: String, name: String) {
        self.id = path
        self.path = path
        self.name = name
    }

    /// 该节点（含所有子孙）下的待同步事件数
    var pendingCount: Int {
        events.filter { !$0.isSynced }.count
            + children.reduce(0) { $0 + $1.pendingCount }
    }

    /// 该节点（含所有子孙）下的总事件数
    var totalCount: Int {
        events.count + children.reduce(0) { $0 + $1.totalCount }
    }
}

/// 把 [FileEvent] 按路径层级构建成前缀树
struct EventTreeBuilder {
    /// 将事件列表构建为以监控根目录为根的树节点数组
    static func build(events: [FileEvent], monitoredPaths: [String]) -> [EventTreeNode] {
        // 先建一个虚拟全局根，方便操作
        let globalRoot = EventTreeNode(path: "__root__", name: "root")

        for event in events {
            // 找到该事件所属的最深监控根目录
            let sortedMonitoredPaths = monitoredPaths.sorted { $0.count > $1.count }
            let rootPath = sortedMonitoredPaths.first { event.path.hasPrefix($0) }

            if let rootPath {
                // 拆分出相对路径片段
                let relativePath = String(event.path.dropFirst(rootPath.count))
                let segments = relativePath
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)

                // 确保根目录节点存在
                let rootNode = findOrCreate(child: URL(fileURLWithPath: rootPath).lastPathComponent,
                                            fullPath: rootPath,
                                            in: globalRoot)

                // 逐层插入中间目录节点
                var currentNode = rootNode
                var accumulatedPath = rootPath
                for (index, segment) in segments.enumerated() {
                    accumulatedPath += "/" + segment
                    let isLast = index == segments.count - 1
                    if isLast {
                        // 叶节点直接挂 event，不再创建子目录节点
                        currentNode.events.append(event)
                    } else {
                        currentNode = findOrCreate(child: segment,
                                                   fullPath: accumulatedPath,
                                                   in: currentNode)
                    }
                }
            } else {
                // 无法匹配任何监控根目录，放到"其他"节点
                let other = findOrCreate(child: "其他", fullPath: "__other__", in: globalRoot)
                other.events.append(event)
            }
        }

        // 剪枝：移除空子树，并对子节点按名称排序
        prune(globalRoot)
        return globalRoot.children
    }

    @discardableResult
    private static func findOrCreate(child name: String, fullPath: String, in parent: EventTreeNode) -> EventTreeNode {
        if let existing = parent.children.first(where: { $0.path == fullPath }) {
            return existing
        }
        let node = EventTreeNode(path: fullPath, name: name)
        parent.children.append(node)
        return node
    }

    @discardableResult
    private static func prune(_ node: EventTreeNode) -> Bool {
        node.children = node.children.filter { prune($0) }
        node.children.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        return node.totalCount > 0
    }
}

/// 树状视图容器
struct EventTreeView: View {
    let events: [FileEvent]
    @Binding var selectedEventID: UUID?

    // 已展开的节点路径集合
    @State private var expandedPaths: Set<String> = []
    @State private var roots: [EventTreeNode] = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(roots) { node in
                    TreeNodeView(
                        node: node,
                        depth: 0,
                        expandedPaths: $expandedPaths,
                        selectedEventID: $selectedEventID
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .onAppear { rebuildTree() }
        .onChange(of: events.map(\.id)) { _, _ in rebuildTree() }
        .onChange(of: events.map(\.isSynced)) { _, _ in rebuildTree() }
    }

    private func rebuildTree() {
        let monitoredPaths = FileMonitorService.shared.monitoredPaths
        let newRoots = EventTreeBuilder.build(events: events, monitoredPaths: monitoredPaths)
        roots = newRoots

        // 默认展开所有根节点（第一层）
        let rootPaths = Set(newRoots.map(\.path))
        expandedPaths = expandedPaths.union(rootPaths)
    }
}

/// 递归渲染单个节点（目录节点 + 其子节点 / 叶子事件行）
struct TreeNodeView: View {
    let node: EventTreeNode
    let depth: Int
    @Binding var expandedPaths: Set<String>
    @Binding var selectedEventID: UUID?

    private var isExpanded: Bool { expandedPaths.contains(node.path) }
    private let indentUnit: CGFloat = 16

    var body: some View {
        VStack(spacing: 2) {
            // 目录节点行
            TreeDirectoryRow(
                node: node,
                isExpanded: isExpanded,
                depth: depth
            ) {
                withAnimation(.snappy(duration: 0.22)) {
                    if isExpanded {
                        expandedPaths.remove(node.path)
                    } else {
                        expandedPaths.insert(node.path)
                    }
                }
            }

            // 展开时显示：子目录 + 叶子事件
            if isExpanded {
                // 子目录
                ForEach(node.children) { child in
                    TreeNodeView(
                        node: child,
                        depth: depth + 1,
                        expandedPaths: $expandedPaths,
                        selectedEventID: $selectedEventID
                    )
                }

                // 该节点直接持有的事件（叶节点）
                ForEach(node.events) { event in
                    TreeFileEventRow(
                        event: event,
                        depth: depth + 1,
                        isSelected: selectedEventID == event.id
                    ) {
                        selectedEventID = event.id
                    }
                }
            }
        }
    }
}

/// 目录节点行
struct TreeDirectoryRow: View {
    let node: EventTreeNode
    let isExpanded: Bool
    let depth: Int
    let onTap: () -> Void

    @State private var isHovered = false
    private let indentUnit: CGFloat = 16

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                // 缩进占位
                Color.clear.frame(width: CGFloat(depth) * indentUnit, height: 1)

                // 展开箭头
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Color.appMuted)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .animation(.snappy(duration: 0.2), value: isExpanded)
                    .frame(width: 14)

                // 目录图标
                Image(systemName: isExpanded ? "folder.open.fill" : "folder.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appAmber)
                    .frame(width: 18)

                // 目录名
                Text(node.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)

                Spacer()

                // 待同步 badge
                if node.pendingCount > 0 {
                    Text("\(node.pendingCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(Color.appRose)
                        )
                }

                // 总事件数（如果全已同步时换成绿色）
                let syncedAll = node.pendingCount == 0
                Text("\(node.totalCount)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(syncedAll ? Color.appMint : Color.appMuted)
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(syncedAll ? Color.appMint.opacity(0.12) : Color.appMuted.opacity(0.1))
                    )
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isHovered ? Color.appSelection.opacity(0.6) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
    }
}

/// 文件事件叶子节点行（带缩进）
struct TreeFileEventRow: View {
    let event: FileEvent
    let depth: Int
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false
    private let indentUnit: CGFloat = 16

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                // 缩进
                Color.clear.frame(width: CGFloat(depth) * indentUnit + 14 + 8, height: 1)

                // 事件类型图标
                Image(systemName: EventVisuals.symbol(for: event.type))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(EventVisuals.color(for: event.type))
                    .frame(width: 18, height: 18)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(EventVisuals.color(for: event.type).opacity(0.1))
                    )

                // 文件名
                VStack(alignment: .leading, spacing: 1) {
                    Text(event.fileName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Color.appInk)
                        .lineLimit(1)

                    Text(event.timestamp.shortActivityTime)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.appMuted.opacity(0.85))
                }

                Spacer()

                // 同步状态指示
                if !event.isSynced {
                    Text(EventVisuals.title(for: event.type))
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(EventVisuals.color(for: event.type).opacity(0.15))
                        .foregroundStyle(EventVisuals.color(for: event.type))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    Circle()
                        .fill(Color.appAmber)
                        .frame(width: 6, height: 6)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMint.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.appSelection : (isHovered ? Color.appSelection.opacity(0.4) : Color.clear))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.15), value: isHovered)
        .animation(.snappy(duration: 0.15), value: isSelected)
    }
}

struct MainWindowDelegateConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                window.delegate = MainWindowDelegate.shared
                // 彻底移除系统标题栏的半透明灰色材质叠加层
                window.titlebarAppearsTransparent = true
            }
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

final class MainWindowDelegate: NSObject, NSWindowDelegate {
    static let shared = MainWindowDelegate()

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil) // 隐藏窗口而非销毁
        return false // 阻止默认的销毁行为
    }
}


struct SyncConfirmOverlay: View {
    let urls: [URL]
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.appInk.opacity(0.16)
                .ignoresSafeArea()
                .onTapGesture(perform: onCancel)

            VStack(spacing: 18) {
                Image(systemName: "arrow.clockwise.icloud.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

                VStack(spacing: 8) {
                    LocalizedText("检测到本地已删除的云端文件")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Color.appInk)

                    LocalizedText("以下文件已被本地删除，但云端仍然存在：")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.appInk)
                        .multilineTextAlignment(.center)
                    
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(urls, id: \.self) { url in
                                HStack(spacing: 6) {
                                    Image(systemName: "doc.text")
                                        .font(.system(size: 11))
                                        .foregroundStyle(Color.appMuted)
                                    Text(url.lastPathComponent)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.appMuted)
                                        .lineLimit(1)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.appLine.opacity(0.3))
                                .cornerRadius(6)
                            }
                        }
                        .padding(4)
                    }
                    .frame(maxHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.appLine.opacity(0.5), lineWidth: 1)
                    )

                    LocalizedText("是否重新下载拉回到本地目录？")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .multilineTextAlignment(.center)
                        .padding(.top, 4)
                }

                HStack(spacing: 10) {
                    Button(action: onCancel) {
                        LocalizedText("保持本地删除")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Button(action: onConfirm) {
                        LocalizedText("重新拉回本地")
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                }
            }
            .padding(24)
            .frame(width: 380)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.appSurface.opacity(0.98))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.appLine.opacity(0.78), lineWidth: 1)
                    )
            )
            .shadow(color: Color.appInk.opacity(0.16), radius: 24, x: 0, y: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeIntroBanner: View {
    let dismiss: () -> Void
    let startOnboarding: () -> Void
    let showHelp: () -> Void

    @State private var isHoveringClose = false
    @State private var animateIcon = false

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            // 左侧闪亮和循环同步图标组合，表示智能监控与自动同步
            ZStack {
                Circle()
                    .fill(Color.appMint.opacity(0.12))
                    .frame(width: 44, height: 44)
                
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appMint)
                    .rotationEffect(.degrees(animateIcon ? 360 : 0))
                
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.appAmber)
                    .offset(x: 12, y: -12)
            }
            .padding(.top, 2)
            .onAppear {
                withAnimation(.linear(duration: 4.5).repeatForever(autoreverses: false)) {
                    animateIcon = true
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 4) {
                        LocalizedText("关于 FileSyncMonitor")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Color.appInk)
                        
                        Text("FileSyncMonitor 是一款面向 macOS 用户的轻量化文件夹自动监控与同步工具。")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.appMint)
                    }
                    
                    Spacer()
                    
                    // 关闭按钮
                    Button(action: dismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(isHoveringClose ? Color.appInk : Color.appMuted)
                            .frame(width: 20, height: 20)
                            .background(isHoveringClose ? Color.appLine.opacity(0.42) : Color.clear)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .onHover { isHoveringClose = $0 }
                    .help("隐藏此功能说明".appLocalized)
                }

                // 核心说明文本
                Text("它能够静默监控您指定的本地文件夹，捕获任何新建、修改、删除和重命名等文件变动事件，并能够安全地自动或手动同步到腾讯 IMA 个人知识库。在这里，我们将帮助您在本地常用编辑器与云端平台之间，架起一座可靠的双向同步桥梁。")
                    .font(.system(size: 12.5))
                    .lineSpacing(4)
                    .foregroundStyle(Color.appMuted)
                    .fixedSize(horizontal: false, vertical: true)

                // 引导按钮行
                HStack(spacing: 12) {
                    Button(action: startOnboarding) {
                        HStack(spacing: 6) {
                            Image(systemName: "hand.point.up.left.fill")
                                .font(.system(size: 11))
                            LocalizedText("新手使用向导")
                        }
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))
                    
                    Button(action: showHelp) {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.plaintext.fill")
                                .font(.system(size: 11))
                            LocalizedText("查看帮助文档")
                        }
                    }
                    .buttonStyle(QuietButtonStyle())
                    
                    Button(action: dismiss) {
                        LocalizedText("不再显示")
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.appMuted)
                    .padding(.leading, 8)
                }
                .padding(.top, 4)
            }
        }
        .padding(20)
        .background(
            LinearGradient(
                colors: [
                    Color.appSurface,
                    Color.appSelection.opacity(0.32)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.appLine.opacity(0.68), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: Color.appInk.opacity(0.035), radius: 10, x: 0, y: 5)
    }
}
