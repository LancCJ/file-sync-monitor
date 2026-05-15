import SwiftUI
import SwiftData

struct ReportsView: View {
    @Query(sort: \FileEvent.timestamp, order: .reverse) private var events: [FileEvent]
    @State private var timeRange: TimeRange = .today
    
    enum TimeRange: String, CaseIterable {
        case today = "今天", week = "本周", month = "本月"
        var date: Date {
            let cal = Calendar.current
            switch self {
            case .today: return cal.startOfDay(for: .now)
            case .week: return cal.date(byAdding: .day, value: -7, to: .now)!
            case .month: return cal.date(byAdding: .month, value: -1, to: .now)!
            }
        }
    }
    
    var stats: (created: Int, modified: Int, deleted: Int) {
        let e = events.filter { $0.timestamp >= timeRange.date }
        return (
            e.filter { $0.type == "created" }.count,
            e.filter { $0.type == "modified" }.count,
            e.filter { $0.type == "deleted" }.count
        )
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("报告中心")
                    .font(.system(size: 28, weight: .bold))
                Spacer()
                Picker("", selection: $timeRange) {
                    ForEach(TimeRange.allCases, id: \.self) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            
            ScrollView {
                VStack(spacing: 40) {
                    // 核心数据卡片 (IMA 风格)
                    HStack(spacing: 24) {
                        StatCard(title: "新增文件", count: stats.created, color: .green, icon: "plus.viewfinder")
                        StatCard(title: "修改文件", count: stats.modified, color: .tencentBlue, icon: "doc.text.magnifyingglass")
                        StatCard(title: "删除文件", count: stats.deleted, color: .red, icon: "trash.slash.fill")
                    }
                    
                    // 导出区域
                    VStack(alignment: .leading, spacing: 24) {
                        HStack {
                            Image(systemName: "square.and.arrow.up.fill")
                                .foregroundStyle(Color.tencentBlue)
                            Text("导出数据报表")
                                .font(.system(size: 18, weight: .bold))
                        }
                        
                        Text("将监控到的改动记录导出为结构化文档，方便离线分析或备份。建议定期导出重要改动以供查阅。")
                            .font(.system(size: 14))
                            .lineSpacing(4)
                            .foregroundStyle(.secondary)
                        
                        HStack(spacing: 20) {
                            ExportButton(title: "导出 CSV", icon: "tablecells", format: .csv, events: events)
                            ExportButton(title: "导出 JSON", icon: "curlybraces", format: .json, events: events)
                        }
                    }
                    .padding(32)
                    .background(Color.primary.opacity(0.02))
                    .cornerRadius(24)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(Color.primary.opacity(0.05), lineWidth: 1))
                }
                .padding(.horizontal, 40)
                .padding(.bottom, 60)
            }
        }
    }
}

struct StatCard: View {
    let title: String
    let count: Int
    let color: Color
    let icon: String
    @State private var isHovered = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(colors: [color, color.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
            }
            .shadow(color: color.opacity(0.2), radius: 8, x: 0, y: 4)
        
            VStack(alignment: .leading, spacing: 6) {
                AnimatedCounter(value: count)
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial)
        .background(color.opacity(isHovered ? 0.08 : 0.03))
        .cornerRadius(24)
        .shadow(color: Color.black.opacity(isHovered ? 0.1 : 0.05), radius: isHovered ? 20 : 10, x: 0, y: 10)
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(color.opacity(isHovered ? 0.3 : 0.1), lineWidth: 1))
        .scaleEffect(isHovered ? 1.02 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
        .onHover { h in isHovered = h }
    }
}

struct ExportButton: View {
    let title: String
    let icon: String
    let format: ExportService.ExportFormat
    let events: [FileEvent]
    
    var body: some View {
        Button(action: { export() }) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 14, weight: .bold))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PillButtonStyle(isPrimary: false))
    }
    
    private func export() {
        do {
            let data = try ExportService.shared.export(events: events, format: format)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [format == .csv ? .commaSeparatedText : .json]
            panel.nameFieldStringValue = "Export_\(Int(Date().timeIntervalSince1970)).\(format == .csv ? "csv" : "json")"
            
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url)
            }
        } catch {
            print("Export failed: \(error)")
        }
    }
}
