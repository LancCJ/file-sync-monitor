import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct ReportsView: View {
    @Query(sort: \FileEvent.timestamp, order: .reverse) private var events: [FileEvent]
    @State private var timeRange: TimeRange = .week

    enum TimeRange: String, CaseIterable, Identifiable {
        case today = "今天"
        case week = "近 7 天"
        case month = "近 30 天"
        case all = "全部"

        var id: String { rawValue }

        var startDate: Date {
            let calendar = Calendar.current
            switch self {
            case .today:
                return calendar.startOfDay(for: .now)
            case .week:
                return calendar.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
            case .month:
                return calendar.date(byAdding: .day, value: -30, to: .now) ?? .distantPast
            case .all:
                return .distantPast
            }
        }
    }

    private var scopedEvents: [FileEvent] {
        events.filter { $0.timestamp >= timeRange.startDate }
    }

    private var stats: SimpleReportStats {
        SimpleReportStats(events: scopedEvents)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("file.sync")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.appMint)
                        Text("报告")
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(Color.appInk)
                    }
                    Text("低频查看统计和导出记录。日常处理请回到待同步。")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                AppSegmentedControl(
                    options: TimeRange.allCases.map { ($0, $0.rawValue) },
                    selection: $timeRange
                )
                .frame(width: 280)
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 22)

            Divider()

            ScrollView {
                VStack(spacing: 18) {
                    HStack(spacing: 12) {
                        SimpleReportCard(title: "记录", value: stats.total, icon: "list.bullet.rectangle", color: .appAccent)
                        SimpleReportCard(title: "待同步", value: stats.pending, icon: "clock", color: stats.pending == 0 ? .appMint : .appAmber)
                        SimpleReportCard(title: "已完成", value: stats.synced, icon: "checkmark", color: .appMint)
                    }

                    HStack(alignment: .top, spacing: 18) {
                        ReportBreakdown(stats: stats)
                        ReportExportPanel(events: scopedEvents)
                    }

                    RecentReportEvents(events: Array(scopedEvents.prefix(6)))
                }
                .padding(30)
            }
        }
        .background(IMAClientSurfaceBackground())
    }
}

private struct SimpleReportStats {
    let total: Int
    let pending: Int
    let synced: Int
    let created: Int
    let modified: Int
    let deleted: Int
    let renamed: Int

    init(events: [FileEvent]) {
        total = events.count
        pending = events.filter { !$0.isSynced }.count
        synced = events.filter { $0.isSynced }.count
        created = events.filter { $0.type == "created" }.count
        modified = events.filter { $0.type == "modified" }.count
        deleted = events.filter { $0.type == "deleted" }.count
        renamed = events.filter { $0.type == "renamed" }.count
    }
}

private struct SimpleReportCard: View {
    let title: String
    let value: Int
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            AppIconBadge(symbol: icon, color: color, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .appCard()
    }
}

private struct ReportBreakdown: View {
    let stats: SimpleReportStats

    private var rows: [(String, String, Int, Color)] {
        [
            ("新增", "created", stats.created, .appMint),
            ("修改", "modified", stats.modified, .appAccent),
            ("删除", "deleted", stats.deleted, .appRose),
            ("重命名", "renamed", stats.renamed, .appAmber)
        ]
    }

    var body: some View {
        SimplePanel(title: "类型分布", subtitle: "按文件变动类型统计。") {
            VStack(spacing: 12) {
                ForEach(rows, id: \.0) { row in
                    HStack(spacing: 10) {
                        AppIconBadge(symbol: EventVisuals.symbol(for: row.1), color: row.3, size: 28)
                        Text(row.0)
                            .font(.system(size: 13, weight: .medium))
                        Spacer()
                        Text("\(row.2)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                    }
                }
            }
        }
    }
}

private struct ReportExportPanel: View {
    let events: [FileEvent]

    var body: some View {
        SimplePanel(title: "导出", subtitle: "导出当前时间范围内的记录。") {
            VStack(spacing: 8) {
                Button {
                    export(format: .csv)
                } label: {
                    Label("导出 CSV", systemImage: "tablecells")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle())

                Button {
                    export(format: .json)
                } label: {
                    Label("导出 JSON", systemImage: "curlybraces")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(QuietButtonStyle())
            }
        }
        .frame(width: 280)
    }

    private func export(format: ExportService.ExportFormat) {
        do {
            let data = try ExportService.shared.export(events: events, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "FileSync_Report_\(Int(Date().timeIntervalSince1970)).\(format == .csv ? "csv" : "json")"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            print("Export failed: \(error)")
        }
    }
}

private struct RecentReportEvents: View {
    let events: [FileEvent]

    var body: some View {
        SimplePanel(title: "最近记录", subtitle: "当前范围内最新的文件变动。") {
            if events.isEmpty {
                EmptyStateView(icon: "tray", title: "暂无记录", subtitle: "这个时间范围还没有文件变动。")
                    .frame(height: 150)
            } else {
                VStack(spacing: 0) {
                    ForEach(events) { event in
                        HStack(spacing: 10) {
                            AppIconBadge(symbol: EventVisuals.symbol(for: event.type), color: EventVisuals.color(for: event.type), size: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(event.fileName)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Text(event.path)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(event.timestamp.shortActivityTime)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            SyncStatusChip(isSynced: event.isSynced)
                        }
                        .padding(.vertical, 9)

                        if event.id != events.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}
