import SwiftUI

struct IMALogView: View {
    @Environment(\.dismiss) private var dismiss
    private let logService = IMALogService.shared
    
    var body: some View {
        NavigationStack {
            List {
                if logService.logs.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("暂无日志记录")
                            .font(.headline)
                        Text("所有的 IMA 接口请求和响应详情都会记录在这里")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 300)
                    .listRowBackground(Color.clear)
                } else {
                    ForEach(logService.logs) { entry in
                        LogEntryRow(entry: entry)
                    }
                }
            }
            .navigationTitle("IMA 请求日志")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("清空") { logService.clear() }
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }
}

struct LogEntryRow: View {
    let entry: IMALogService.LogEntry
    @State private var isExpanded = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                StatusIndicator(code: entry.responseCode, error: entry.error)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(entry.method) \(entry.url)")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                    Text(entry.url)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                
                Spacer()
                
                if let rid = entry.requestId {
                    Text("ID: \(rid.suffix(8))")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.1))
                        .clipShape(Capsule())
                }
                
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.snappy) {
                    isExpanded.toggle()
                }
            }
            
            if isExpanded {
                VStack(alignment: .leading, spacing: 12) {
                    LogSection(title: "Full URL", content: entry.url, color: .secondary)
                    
                    if let headers = entry.requestHeaders {
                        LogSection(title: "Request Headers", content: headers, color: .secondary)
                    }
                    
                    if let body = entry.requestBody {
                        LogSection(title: "Request Body", content: body, color: Color.appInk)
                    }
                    
                    if let body = entry.responseBody {
                        LogSection(title: "Response Body", content: body)
                    }
                    
                    if let error = entry.error {
                        LogSection(title: "Error Detail", content: error, color: .red)
                    }
                    
                    Button(action: { copyFullLog(entry) }) {
                        Label("复制完整日志详情", systemImage: "doc.on.doc")
                            .font(.system(size: 11, weight: .medium))
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(.appAccent)
                }
                .padding(.leading, 24)
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
    
    private func copyFullLog(_ entry: IMALogService.LogEntry) {
        var text = "【IMA 请求日志】\n"
        text += "时间: \(entry.timestamp)\n"
        text += "方法: \(entry.method)\n"
        text += "全路径: \(entry.url)\n"
        if let headers = entry.requestHeaders { text += "\n[Request Headers]\n\(headers)\n" }
        if let rid = entry.requestId { text += "RequestID: \(rid)\n" }
        if let code = entry.responseCode { text += "HTTP 状态: \(code)\n" }
        if let req = entry.requestBody { text += "\n[Request Body]\n\(req)\n" }
        if let res = entry.responseBody { text += "\n[Response Body]\n\(res)\n" }
        if let err = entry.error { text += "\n[Error]\n\(err)\n" }
        
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct StatusIndicator: View {
    let code: Int?
    let error: String?
    
    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
    }
    
    private var color: Color {
        if error != nil { return .red }
        guard let code = code else { return .gray }
        return (200...299).contains(code) ? .green : .orange
    }
}

struct LogSection: View {
    let title: String
    let content: String
    var color: Color = .primary
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                }) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.appAccent)
                }
                .buttonStyle(.plain)
                .help("复制此段内容")
            }
            
            Text(content)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(color)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .textSelection(.enabled)
        }
    }
}
