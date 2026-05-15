import SwiftUI
import SwiftData

struct MainView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \FileEvent.timestamp, order: .reverse) private var events: [FileEvent]

    @State private var selectedSidebarItem: SidebarItem? = .allEvents
    @State private var viewMode: ViewMode = .list
    @State private var searchText: String = ""

    enum SidebarItem: String, CaseIterable, Identifiable {
        case allEvents, pendingSync, reports, settings
        var id: String { self.rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .allEvents: "所有记录"
            case .pendingSync: "待同步"
            case .reports: "报告中心"
            case .settings: "设置"
            }
        }

        var icon: String {
            switch self {
            case .allEvents: "clock"
            case .pendingSync: "arrow.triangle.2.circlepath"
            case .reports: "chart.bar"
            case .settings: "gearshape"
            }
        }
    }

    enum ViewMode {
        case list, tree
    }

    var filteredEvents: [FileEvent] {
        var result = events

        if selectedSidebarItem == .pendingSync {
            result = result.filter { !$0.isSynced }
        }

        if !searchText.isEmpty {
            result = result.filter { $0.path.localizedCaseInsensitiveContains(searchText) }
        }

        return result
    }

    var pendingCount: Int {
        events.filter { !$0.isSynced }.count
    }

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selectedItem: $selectedSidebarItem,
                pendingCount: pendingCount
            )
        } detail: {
            ZStack {
                Color(nsColor: .windowBackgroundColor).ignoresSafeArea()

                Group {
                    switch selectedSidebarItem {
                    case .allEvents, .pendingSync:
                        EventManagementView(
                            title: selectedSidebarItem?.title ?? "所有记录",
                            events: filteredEvents,
                            viewMode: $viewMode,
                            searchText: $searchText
                        )
                    case .reports:
                        ReportsView()
                    case .settings:
                        SettingsView()
                    case .none:
                        EmptyStateView(
                            icon: "arrowshape.left.fill",
                            title: "选择一个项目",
                            subtitle: "从左侧边栏选择一个选项以开始"
                        )
                    }
                }
            }
        }
    }
}

// MARK: - Sidebar
struct SidebarView: View {
    @Binding var selectedItem: MainView.SidebarItem?
    let pendingCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // App Logo & Header
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(
                            LinearGradient(
                                colors: [.tencentBlue, .tencentLightBlue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 40, height: 40)
                        .shadow(color: .tencentBlue.opacity(0.3), radius: 8, x: 0, y: 4)

                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("FileSyncMonitor")
                        .font(.system(size: 15, weight: .bold))
                    Text("文件同步监控")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 20)

            Divider()
                .padding(.horizontal, 16)

            // Sidebar Items
            List(MainView.SidebarItem.allCases, selection: $selectedItem) { item in
                SidebarItemRow(
                    item: item,
                    isSelected: selectedItem == item,
                    badgeCount: item == .pendingSync ? pendingCount : 0
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        selectedItem = item
                    }
                }
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)

            Spacer()

            // Footer
            HStack {
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("v1.0 · 运行中")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .background(.ultraThinMaterial)
        .navigationSplitViewColumnWidth(min: 220, ideal: 240)
    }
}

struct SidebarItemRow: View {
    let item: MainView.SidebarItem
    let isSelected: Bool
    let badgeCount: Int
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.icon)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 24)
                .foregroundStyle(isSelected ? .white : .primary)

            Text(item.title)
                .font(.system(size: 14, weight: isSelected ? .semibold : .medium))

            Spacer()

            if badgeCount > 0 {
                Text("\(badgeCount)")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isSelected ? Color.tencentBlue : .white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(
                        Capsule()
                            .fill(isSelected ? Color.white : Color.tencentBlue)
                    )
            }

            if isSelected {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected
                    ? Color.tencentBlue
                    : (isHovered ? Color.primary.opacity(0.06) : Color.clear)
                )
        )
        .foregroundStyle(isSelected ? .white : .primary)
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.15), value: isSelected)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
    }
}

// MARK: - Event Management View
struct EventManagementView: View {
    let title: LocalizedStringKey
    let events: [FileEvent]
    @Binding var viewMode: MainView.ViewMode
    @Binding var searchText: String

    var body: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 22, weight: .bold))
                    Text("\(events.count) 条记录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                // View Toggle
                HStack(spacing: 0) {
                    Button(action: { viewMode = .list }) {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 13, weight: viewMode == .list ? .bold : .regular))
                            .foregroundStyle(viewMode == .list ? .white : .primary)
                            .frame(width: 36, height: 28)
                            .background(viewMode == .list ? Color.tencentBlue : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)

                    Button(action: { viewMode = .tree }) {
                        Image(systemName: "list.bullet.indent")
                            .font(.system(size: 13, weight: viewMode == .tree ? .bold : .regular))
                            .foregroundStyle(viewMode == .tree ? .white : .primary)
                            .frame(width: 36, height: 28)
                            .background(viewMode == .tree ? Color.tencentBlue : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                }
                .padding(2)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 9))

                // Search
                SmoothSearchField(text: $searchText, placeholder: "搜索事件...")
                    .frame(width: 220)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)

            Divider()
                .padding(.horizontal, 32)

            if viewMode == .list {
                EventCardListView(events: events)
            } else {
                EventTreeView(events: events)
            }
        }
    }
}

// MARK: - Card List View
struct EventCardListView: View {
    let events: [FileEvent]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                if events.isEmpty {
                    EmptyStateView(
                        icon: "tray",
                        title: "暂无记录",
                        subtitle: "添加监控目录后，文件改动将自动显示在这里"
                    )
                    .padding(.top, 80)
                } else {
                    ForEach(events) { event in
                        EventRowCard(event: event)
                    }
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 20)
        }
    }
}

// MARK: - Event Row Card
struct EventRowCard: View {
    let event: FileEvent
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 14) {
            // Type Icon with background
            ZStack {
                Circle()
                    .fill(eventTypeColor.opacity(0.12))
                    .frame(width: 36, height: 36)

                TypeIcon(type: event.type)
                    .font(.system(size: 16))
            }

            // File info
            VStack(alignment: .leading, spacing: 3) {
                Text(event.fileName)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)

                Text(event.path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Timestamp
            Text(event.timestamp, style: .time)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)

            // Status
            SyncStatusChip(isSynced: event.isSynced)

            // Sync action
            Button(action: { syncToIMA(event) }) {
                Image(systemName: event.isSynced ? "checkmark" : "icloud.and.arrow.up")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(event.isSynced ? .secondary : Color.tencentBlue)
                    .frame(width: 28, height: 28)
                    .background(isHovered && !event.isSynced ? Color.tencentBlue.opacity(0.1) : Color.clear)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(event.isSynced)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.primary.opacity(isHovered ? 0.03 : 0.01))
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(isHovered ? Color.tencentBlue.opacity(0.15) : Color.primary.opacity(0.04), lineWidth: 1)
                )
        )
        .onHover { isHovered = $0 }
        .animation(.easeInOut(duration: 0.2), value: isHovered)
    }

    private var eventTypeColor: Color {
        switch event.type {
        case "created": return .green
        case "modified": return .blue
        case "deleted": return .red
        case "renamed": return .orange
        default: return .gray
        }
    }

    private func syncToIMA(_ event: FileEvent) {
        Task {
            do {
                let url = URL(fileURLWithPath: event.path)
                _ = try await IMASyncService.shared.importDoc(fileURL: url, knowledgeBaseId: "default")
                event.isSynced = true
            } catch {
                print("IMA Sync failed: \(error)")
            }
        }
    }
}

// MARK: - Sync Status Chip
struct SyncStatusChip: View {
    let isSynced: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: isSynced ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 10))
            Text(isSynced ? "已同步" : "待同步")
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSynced ? Color.successGreen.opacity(0.12) : Color.warningOrange.opacity(0.12))
        .foregroundStyle(isSynced ? Color.successGreen : Color.warningOrange)
        .clipShape(Capsule())
    }
}

// MARK: - Tree View
struct EventTreeView: View {
    let events: [FileEvent]

    var rootNodes: [FileNode] {
        var roots: [FileNode] = []
        for event in events {
            let components = URL(fileURLWithPath: event.path).pathComponents.filter { $0 != "/" }
            insert(components: components, event: event, into: &roots, currentPath: "")
        }
        return roots
    }

    func insert(components: [String], event: FileEvent, into nodes: inout [FileNode], currentPath: String) {
        guard let first = components.first else { return }
        let newPath = (currentPath as NSString).appendingPathComponent(first)

        if components.count == 1 {
            nodes.append(FileNode(name: first, fullPath: newPath, children: nil, event: event))
        } else {
            if let index = nodes.firstIndex(where: { $0.name == first }) {
                var children = nodes[index].children ?? []
                insert(components: Array(components.dropFirst()), event: event, into: &children, currentPath: newPath)
                nodes[index].children = children
            } else {
                var children: [FileNode] = []
                insert(components: Array(components.dropFirst()), event: event, into: &children, currentPath: newPath)
                nodes.append(FileNode(name: first, fullPath: newPath, children: children, event: nil))
            }
        }
    }

    var body: some View {
        ScrollView {
            if events.isEmpty {
                EmptyStateView(
                    icon: "folder.badge.questionmark",
                    title: "暂无树状数据",
                    subtitle: "添加监控目录后，文件层级结构将在此展示"
                )
                .padding(.top, 80)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rootNodes) { node in
                        TreeNodeView(node: node, depth: 0)
                    }
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 20)
            }
        }
    }
}

struct TreeNodeView: View {
    let node: FileNode
    let depth: Int
    @State private var isExpanded = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 0) {
                    ForEach(0..<depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 1)
                            .padding(.leading, 12)
                    }
                }

                if node.children != nil {
                    Button(action: { withAnimation(.spring(response: 0.3)) { isExpanded.toggle() } }) {
                        Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                } else {
                    Spacer()
                        .frame(width: 16)
                }

                if let event = node.event {
                    TypeIcon(type: event.type)
                        .font(.system(size: 13))
                } else {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.tencentBlue.opacity(0.7))
                }

                Text(node.name)
                    .font(.system(size: 13, weight: node.children != nil ? .semibold : .regular))

                if let event = node.event {
                    Spacer()
                    Text(event.timestamp, style: .time)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    SyncStatusChip(isSynced: event.isSynced)
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.01))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            if let children = node.children, isExpanded {
                ForEach(children) { child in
                    TreeNodeView(node: child, depth: depth + 1)
                }
            }
        }
    }
}

// MARK: - File Node
struct FileNode: Identifiable {
    let id = UUID()
    let name: String
    let fullPath: String
    var children: [FileNode]?
    var event: FileEvent?
}

// MARK: - Type Icon
struct TypeIcon: View {
    let type: String

    var systemImageName: String {
        switch type {
        case "created": return "plus.circle.fill"
        case "modified": return "pencil.circle.fill"
        case "deleted": return "trash.circle.fill"
        case "renamed": return "arrow.right.circle.fill"
        default: return "questionmark.circle"
        }
    }

    var iconColor: Color {
        switch type {
        case "created": return .green
        case "modified": return .blue
        case "deleted": return .red
        case "renamed": return .orange
        default: return .gray
        }
    }

    var body: some View {
        Image(systemName: systemImageName)
            .foregroundColor(iconColor)
    }
}

// MARK: - Sync Status View (legacy, used in table if needed)
struct SyncStatusView: View {
    let isSynced: Bool
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isSynced ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            Text(isSynced ? "已同步" : "待同步")
        }
        .font(.caption.bold())
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isSynced ? Color.successGreen.opacity(0.15) : Color.warningOrange.opacity(0.15))
        .foregroundColor(isSynced ? Color.successGreen : Color.warningOrange)
        .cornerRadius(6)
    }
}
