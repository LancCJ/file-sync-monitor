import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import AppKit

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FileEvent.timestamp, order: .reverse) private var events: [FileEvent]

    @State private var selectedSidebarItem: SidebarItem = .home
    @State private var selectedEventID: UUID?
    @State private var searchText = ""
    @State private var typeFilter: EventTypeFilter = .all
    @State private var isSyncing = false

    enum SidebarItem: String, CaseIterable, Identifiable {
        case home, pendingSync, allEvents, reports, settings, help
        var id: String { rawValue }

        var title: String {
            switch self {
            case .home: "首页"
            case .pendingSync: "待同步"
            case .allEvents: "全部记录"
            case .reports: "报告"
            case .settings: "设置"
            case .help: "帮助"
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

            VStack(spacing: 0) {
                Color.clear
                    .frame(height: layout.titleBarInset)

                HStack(spacing: 0) {
                    IMARailView(
                        selection: $selectedSidebarItem,
                        pendingCount: pendingEvents.count,
                        layout: layout
                    )

                    switch selectedSidebarItem {
                    case .home:
                        FileSyncHomeView(
                            events: events,
                            pendingEvents: pendingEvents,
                            addDirectory: addDirectory,
                            showPending: { selectedSidebarItem = .pendingSync },
                            showAllRecords: { selectedSidebarItem = .allEvents },
                            showReports: { selectedSidebarItem = .reports },
                            markAllPendingSynced: markAllPendingSynced,
                            syncAllToIMA: syncAllToIMA
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
                            export: export,
                            layout: layout
                        )
                    case .reports:
                        ReportsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .settings:
                        SettingsView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    case .help:
                        HelpView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(IMAWindowBackground())
            .tint(.appMint)
            .onChange(of: selectedSidebarItem) { _, _ in
                selectedEventID = nil
                searchText = ""
                typeFilter = .all
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
        min(max(size.width * 0.045, 64), 72)
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

struct IMARailView: View {
    @Binding var selection: MainView.SidebarItem
    let pendingCount: Int
    let layout: MainLayoutMetrics

    var body: some View {
        VStack(spacing: 18) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appSelection)
                .frame(width: 34, height: 34)
                .overlay {
                    Text("FSM")
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(Color.appInk)
                }
                .padding(.top, layout.topContentPadding)

            VStack(spacing: 18) {
                ForEach(MainView.SidebarItem.allCases.filter { $0 != .settings && $0 != .help }) { item in
                    IMARailButton(
                        item: item,
                        isSelected: selection == item,
                        badgeCount: item == .pendingSync ? pendingCount : 0
                    ) {
                        selection = item
                    }
                }
            }
            .padding(.top, 22)

            Spacer()

            VStack(spacing: 18) {
                IMARailButton(item: .help, isSelected: selection == .help, badgeCount: 0) {
                    selection = .help
                }
                
                IMARailButton(item: .settings, isSelected: selection == .settings, badgeCount: 0) {
                    selection = .settings
                }
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                IMARailExitButton()
            }
            .buttonStyle(.plain)
            .help("退出")
            .padding(.bottom, 18)
        }
        .frame(width: layout.railWidth)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 238 / 255, green: 244 / 255, blue: 240 / 255),
                    Color(red: 230 / 255, green: 238 / 255, blue: 233 / 255)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
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
                    .fill(isHovered ? Color.appSurface.opacity(0.9) : Color.clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
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
                    .foregroundStyle(Color.appInk)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(isSelected ? Color.appSurface.opacity(0.95) : (isHovered ? Color.appSurface.opacity(0.5) : Color.clear))
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
        .help(item.title)
    }
}

struct FileSyncHomeView: View {
    let events: [FileEvent]
    let pendingEvents: [FileEvent]
    let addDirectory: () -> Void
    let showPending: () -> Void
    let showAllRecords: () -> Void
    let showReports: () -> Void
    let markAllPendingSynced: () -> Void
    let syncAllToIMA: () -> Void

    private var monitoredCount: Int {
        FileMonitorService.shared.monitoredPaths.count
    }

    private var recentEvents: [FileEvent] {
        Array(events.prefix(5))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("FileSync")
                            .font(.system(size: 44, weight: .black))
                            .foregroundStyle(Color.appInk)
                        Text("monitor")
                            .font(.system(size: 12, weight: .medium))
                            .tracking(8)
                            .foregroundStyle(Color.appInk.opacity(0.68))
                        Text(homeMessage)
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appMuted)
                            .padding(.top, 4)
                    }

                    Spacer()

                    StatusPill(
                        text: pendingEvents.isEmpty ? "已同步" : "\(pendingEvents.count) 个待处理",
                        symbol: pendingEvents.isEmpty ? "checkmark" : "clock",
                        color: pendingEvents.isEmpty ? .appMint : .appAmber
                    )
                    .padding(.top, 8)
                }

                HStack(spacing: 12) {
                    HomeMetricCard(title: "待同步", value: pendingEvents.count, icon: "clock", color: pendingEvents.isEmpty ? .appMint : .appAmber)
                    HomeMetricCard(title: "全部记录", value: events.count, icon: "doc.text", color: .appInk)
                    HomeMetricCard(title: "监控目录", value: monitoredCount, icon: "folder", color: .appMint)
                }

                HStack(spacing: 10) {
                    Button(action: addDirectory) {
                        Label("添加目录", systemImage: "plus")
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: true))

                    Button(action: showPending) {
                        Label("处理待同步", systemImage: "clock")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(pendingEvents.isEmpty)

                    Button(action: showAllRecords) {
                        Label("查看全部记录", systemImage: "doc.text")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Button(action: showReports) {
                        Label("查看报告", systemImage: "chart.bar")
                    }
                    .buttonStyle(QuietButtonStyle())

                    Spacer()

                    Button(action: syncAllToIMA) {
                        Label("全部同步", systemImage: "cloud.fill")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(pendingEvents.isEmpty)

                    Button(action: markAllPendingSynced) {
                        Label("全部完成", systemImage: "checkmark")
                    }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(pendingEvents.isEmpty)
                }

                HStack(alignment: .top, spacing: 18) {
                    SimplePanel(title: "最近记录", subtitle: events.isEmpty ? "添加监控目录后，文件变动会显示在这里。" : "最近捕获到的文件变动。") {
                        if recentEvents.isEmpty {
                            EmptyStateView(icon: "tray", title: "暂无记录", subtitle: "开始监控后，这里会显示最新文件变动。")
                                .frame(height: 170)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(recentEvents) { event in
                                    HomeRecentEventRow(event: event)
                                    if event.id != recentEvents.last?.id {
                                        Divider()
                                    }
                                }
                            }
                        }
                    }

                    SimplePanel(title: "当前状态", subtitle: "快速了解监控与同步状态。") {
                        VStack(spacing: 0) {
                            HomeStatusRow(title: "同步队列", value: pendingEvents.isEmpty ? "没有待同步文件" : "\(pendingEvents.count) 个文件待处理", color: pendingEvents.isEmpty ? .appMint : .appAmber)
                            HomeStatusRow(title: "监控目录", value: monitoredCount == 0 ? "尚未添加" : "\(monitoredCount) 个目录")
                            HomeStatusRow(title: "记录总数", value: "\(events.count) 条")
                        }
                    }
                    .frame(width: 280)
                }
            }
            .frame(maxWidth: 980, alignment: .leading)
            .padding(.horizontal, 64)
            .padding(.vertical, 58)
            .frame(maxWidth: .infinity)
        }
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
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.appMuted)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .appCard(padding: 15)
    }
}

struct HomeRecentEventRow: View {
    let event: FileEvent

    var body: some View {
        HStack(spacing: 10) {
            AppIconBadge(symbol: EventVisuals.symbol(for: event.type), color: EventVisuals.color(for: event.type), size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)
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
        .padding(.vertical, 9)
    }
}

struct HomeStatusRow: View {
    let title: String
    let value: String
    var color: Color = .appInk

    var body: some View {
        HStack(spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appMuted)
            Spacer()
            Text(value)
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
    let isSyncing: Bool
    let layout: MainLayoutMetrics

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(mode == .pendingSync ? "待同步" : "全部记录")
                        .font(.system(size: 16, weight: .bold))
                    Spacer()
                    Text("\(events.count)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }

                SmoothSearchField(text: $searchText, placeholder: "搜索文件或路径")

                AppSegmentedControl(
                    options: MainView.EventTypeFilter.allCases.map { ($0, $0.rawValue) },
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
                                Text("全部同步至 IMA")
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PillButtonStyle(isPrimary: true))
                        .disabled(pendingCount == 0 || isSyncing)

                        Button(action: markAllPendingSynced) {
                            Label("全部标记完成", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(QuietButtonStyle())
                        .disabled(pendingCount == 0 || isSyncing)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, layout.sidebarHeaderPadding)
            .padding(.bottom, 14)
            .clipped()

            Divider()

            if events.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: mode == .pendingSync ? "checkmark.circle" : "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Color.appMuted)
                    Text(mode == .pendingSync ? "没有待同步文件" : "暂无记录")
                        .font(.system(size: 13, weight: .semibold))
                    Text(mode == .pendingSync ? "所有变动都处理完成了。" : "添加目录后记录会显示在这里。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(events) { event in
                            IMAEventListRow(
                                event: event,
                                isSelected: selectedEventID == event.id
                            ) {
                                selectedEventID = event.id
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(width: layout.secondarySidebarWidth)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 250 / 255, green: 253 / 255, blue: 251 / 255),
                    Color(red: 244 / 255, green: 251 / 255, blue: 247 / 255)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }
}

struct IMAEventListRow: View {
    let event: FileEvent
    let isSelected: Bool
    let action: () -> Void

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
                            Circle()
                                .fill(Color.appAmber)
                                .frame(width: 6, height: 6)
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
                    .fill(isSelected ? Color.appSelection : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}

struct EventDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let event: FileEvent?
    let mode: MainView.SidebarItem
    let visibleEvents: [FileEvent]
    let isSyncing: Bool
    
    let showAllRecords: () -> Void
    let addDirectory: () -> Void
    let markSynced: (FileEvent) -> Void
    let upload: (FileEvent) -> Void
    let reveal: (FileEvent) -> Void
    let export: (ExportService.ExportFormat) -> Void
    let layout: MainLayoutMetrics

    var body: some View {
        ZStack {
            IMAClientSurfaceBackground()

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
                                EventInfoRow(title: "记录时间", value: event.timestamp.formatted(date: .abbreviated, time: .shortened))
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
                                Button(action: { markSynced(event) }) {
                                    Label(event.isSynced ? "重新标记待同步" : "标记完成", systemImage: event.isSynced ? "arrow.uturn.backward" : "checkmark")
                                }
                                .buttonStyle(PillButtonStyle(isPrimary: true))

                                Button(action: { upload(event) }) {
                                    if isSyncing {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Label("上传到 IMA", systemImage: "icloud.and.arrow.up")
                                    }
                                }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(event.isSynced || isSyncing)

                                Button(action: { reveal(event) }) {
                                    Label("在 Finder 中显示", systemImage: "folder")
                                }
                                .buttonStyle(QuietButtonStyle())

                                Spacer()
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
            defer { isSyncing = false }
            do {
                let kbId = FileMonitorService.shared.getKnowledgeBaseId(for: event.path)
                try await IMASyncService.shared.syncFile(fileURL: URL(fileURLWithPath: event.path), knowledgeBaseId: kbId)
                
                await MainActor.run {
                    event.isSynced = true
                    try? modelContext.save()
                    MenuBarManager.shared.updateBadge(count: currentUnsyncedCount())
                }
            } catch {
                print("IMA Sync failed: \(error)")
            }
        }
    }

    private func syncAllToIMA() {
        let targets = pendingEvents
        guard !targets.isEmpty else { return }
        
        isSyncing = true
        Task {
            defer { isSyncing = false }
            for event in targets {
                do {
                    let kbId = FileMonitorService.shared.getKnowledgeBaseId(for: event.path)
                    try await IMASyncService.shared.syncFile(fileURL: URL(fileURLWithPath: event.path), knowledgeBaseId: kbId)
                    
                    await MainActor.run {
                        event.isSynced = true
                        try? modelContext.save()
                        MenuBarManager.shared.updateBadge(count: currentUnsyncedCount())
                    }
                } catch {
                    print("Batch sync failed for \(event.fileName): \(error)")
                }
            }
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
            .help("导出 CSV")

            Button(action: { export(.json) }) {
                Image(systemName: "curlybraces")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .help("导出 JSON")
        }
        .font(.system(size: 13, weight: .medium))
        .foregroundStyle(Color.appInk)
        .padding(.horizontal, 28)
        .frame(height: layout.detailToolbarHeight)
        .background(Color.white.opacity(0.82))
    }
}

struct EventInfoRow: View {
    let title: String
    let value: String
    var color: Color = .appInk

    var body: some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appInk)
                .frame(width: 92, alignment: .leading)

            Text(value)
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
                Text("FileSync")
                    .font(.system(size: 58, weight: .black))
                    .foregroundStyle(Color.appInk)
                Text("monitor")
                    .font(.system(size: 12, weight: .medium))
                    .tracking(8)
                    .foregroundStyle(Color.appInk.opacity(0.7))
            }

            VStack(spacing: 8) {
                Text(isPendingMode ? "所有文件都已同步" : "还没有文件记录")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Text(isPendingMode ? "新的文件变动会自动出现在左侧列表。" : "添加监控目录后，文件变动会被自动记录。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
            }

            HStack(spacing: 10) {
                Button(action: addDirectory) {
                    Label("添加目录", systemImage: "plus")
                }
                .buttonStyle(PillButtonStyle(isPrimary: true))

                Button(action: showAllRecords) {
                    Label("查看全部记录", systemImage: "doc.text")
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
                Text("选择一条记录")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Text("从左侧列表中选择文件变动后，可查看路径、状态并执行同步操作。")
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
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
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
            Text(label)
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
