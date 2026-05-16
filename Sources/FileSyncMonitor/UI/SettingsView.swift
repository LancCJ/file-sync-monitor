import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("notifyOnChanges") private var notifyOnChanges = true
    @AppStorage("retentionDays") private var retentionDays = 365
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "csv"
    @AppStorage("enableDefaultIgnoreRules") private var enableDefaultIgnoreRules = true
    @AppStorage("customIgnoredFileNames") private var customIgnoredFileNames = ""
    @AppStorage("customIgnoredExtensions") private var customIgnoredExtensions = ""
    @AppStorage("customIgnoredDirectoryNames") private var customIgnoredDirectoryNames = ""

    @AppStorage("imaClientId") private var clientId = ""
    @AppStorage("imaApiKey") private var apiKey = ""

    @State private var isTestingIMA = false
    @State private var imaStatus: IMAStatus = .idle
    @State private var isShowingLogs = false

    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var title: LocalizedStringKey {
            switch self {
            case .system: "跟随系统"
            case .light: "浅色"
            case .dark: "深色"
            }
        }
    }

    enum IMAStatus: Equatable {
        case idle, connected, failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                Text("设置")
                    .font(.system(size: 28, weight: .bold))
                    .foregroundStyle(Color.appInk)
                    .padding(.top, 64)

                IMASettingsGroup(title: "监控目录") {
                    if FileMonitorService.shared.monitoredPaths.isEmpty {
                        IMASettingsRow(title: "监控文件夹", subtitle: "尚未添加目录") {
                            Button(action: addDirectory) {
                                Text("添加")
                            }
                            .buttonStyle(PillButtonStyle(isPrimary: true))
                        }
                    } else {
                        ForEach(FileMonitorService.shared.monitoredPaths, id: \.self) { path in
                            MonitoredPathRow(path: path, onRemove: removeDirectory)
                        }
                        IMASettingsRow(title: "添加更多目录", subtitle: "继续监控其他文件夹") {
                            Button(action: addDirectory) {
                                Text("添加")
                            }
                            .buttonStyle(QuietButtonStyle())
                        }
                    }
                }

                IMASettingsGroup(title: "忽略规则") {
                    IMASettingsRow(title: "启用默认忽略规则", subtitle: defaultIgnoreSummary) {
                        AppToggle(isOn: $enableDefaultIgnoreRules)
                    }

                    IMASettingsTextRow(
                        title: "忽略文件名",
                        subtitle: "用逗号、分号或换行分隔，例如 .DS_Store, debug.log",
                        text: $customIgnoredFileNames,
                        placeholder: ".DS_Store, debug.log"
                    )

                    IMASettingsTextRow(
                        title: "忽略后缀",
                        subtitle: "用逗号、分号或换行分隔，例如 .log, .tmp",
                        text: $customIgnoredExtensions,
                        placeholder: ".log, .tmp"
                    )

                    IMASettingsTextRow(
                        title: "忽略目录名",
                        subtitle: "用逗号、分号或换行分隔，例如 node_modules, DerivedData",
                        text: $customIgnoredDirectoryNames,
                        placeholder: "node_modules, DerivedData"
                    )

                    IMASettingsRow(title: "恢复默认", subtitle: "清空自定义规则，并重新启用默认忽略规则") {
                        Button(action: resetIgnoreRules) {
                            Text("恢复")
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }

                IMASettingsGroup(title: "IMA 云端") {
                    IMASettingsTextRow(title: "Client ID", subtitle: "IMA OpenAPI Client ID", text: $clientId)
                    IMASettingsTextRow(title: "API Key", subtitle: "IMA OpenAPI API Key", text: $apiKey, isSecure: true)
                    IMASettingsRow(title: "连接状态", subtitle: imaStatusDetail, isSelectable: true) {
                        HStack(spacing: 12) {
                            StatusPill(text: imaStatusTitle, symbol: imaStatusIcon, color: imaStatusColor)
                            
                            Button(action: { isShowingLogs = true }) {
                                Image(systemName: "list.bullet.rectangle.portrait")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(QuietButtonStyle())
                            .help("查看请求日志")
                            
                            Button(action: testIMAConnection) {
                                if isTestingIMA {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("测试")
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingIMA)
                        }
                    }
                }

                IMASettingsGroup(title: "通知与导出") {
                    IMASettingsRow(title: "允许消息通知", subtitle: "新文件变动时发送系统通知") {
                        AppToggle(isOn: $notifyOnChanges)
                    }

                    IMASettingsRow(title: "默认导出格式", subtitle: "报告与记录导出的默认格式") {
                        AppSegmentedControl(
                            options: [("csv", "CSV"), ("json", "JSON")],
                            selection: $defaultExportFormat
                        )
                        .frame(width: 112)
                    }

                    IMASettingsRow(title: "已同步记录保留", subtitle: "未同步记录不会自动清理") {
                        Menu {
                            Button("30 天") { retentionDays = 30 }
                            Button("90 天") { retentionDays = 90 }
                            Button("365 天") { retentionDays = 365 }
                            Button("永久") { retentionDays = 0 }
                        } label: {
                            AppMenuValue(text: retentionText)
                        }
                        .buttonStyle(.plain)
                    }
                }

                IMASettingsGroup(title: "高级版") {
                    IMASettingsRow(
                        title: StoreManager.shared.isPro ? "高级版已激活" : "升级到高级版",
                        subtitle: StoreManager.shared.isPro ? "所有高级功能已经可用" : "解锁无限监控、自动同步和高级报告"
                    ) {
                        if StoreManager.shared.isPro {
                            StatusPill(text: "已激活", symbol: "checkmark", color: .appMint)
                        } else {
                            Button {
                                Task { try? await StoreManager.shared.purchase() }
                            } label: {
                                Label("¥9.9", systemImage: "bag")
                            }
                            .buttonStyle(PillButtonStyle(isPrimary: true))
                        }
                    }
                }
            }
            .frame(width: 760, alignment: .leading)
            .padding(.bottom, 80)
            .frame(maxWidth: .infinity)
        }
        .background(IMAClientSurfaceBackground())
        .background(WindowFocusActivator())
        .sheet(isPresented: $isShowingLogs) {
            IMALogView()
        }
        .onAppear {
            // 已自动通过 AppStorage 加载
        }
        .onChange(of: enableDefaultIgnoreRules) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
        .onChange(of: customIgnoredFileNames) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
        .onChange(of: customIgnoredExtensions) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
        .onChange(of: customIgnoredDirectoryNames) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
    }

    private var retentionText: String {
        retentionDays == 0 ? "永久" : "\(retentionDays) 天"
    }

    private var defaultIgnoreSummary: String {
        "过滤 .DS_Store、临时文件、系统目录和常见构建缓存"
    }

    private var imaStatusTitle: String {
        switch imaStatus {
        case .idle: return "未测试"
        case .connected: return "可用"
        case .failed: return "失败"
        }
    }

    private var imaStatusDetail: String {
        switch imaStatus {
        case .idle:
            return "检查当前凭据是否可用"
        case .connected:
            return "IMA OpenAPI 连接成功"
        case .failed(let message):
            return message
        }
    }

    private var imaStatusIcon: String {
        switch imaStatus {
        case .idle: return "circle"
        case .connected: return "checkmark"
        case .failed: return "xmark"
        }
    }

    private var imaStatusColor: Color {
        switch imaStatus {
        case .idle: return .secondary
        case .connected: return .appMint
        case .failed: return .appRose
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

    private func removeDirectory(_ path: String) {
        FileMonitorService.shared.removeDirectory(at: path)
    }

    private func testIMAConnection() {
        isTestingIMA = true
        imaStatus = .idle
        Task {
            do {
                let kbs = try await IMASyncService.shared.getKnowledgeBases()
                await MainActor.run {
                    FileMonitorService.shared.availableKnowledgeBases = kbs
                    imaStatus = .connected
                    isTestingIMA = false
                }
            } catch {
                await MainActor.run {
                    imaStatus = .failed(error.localizedDescription)
                    isTestingIMA = false
                }
            }
        }
    }

    private func resetIgnoreRules() {
        enableDefaultIgnoreRules = true
        customIgnoredFileNames = ""
        customIgnoredExtensions = ""
        customIgnoredDirectoryNames = ""
    }
}

struct MonitoredPathRow: View {
    let path: String
    let onRemove: (String) -> Void
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            IMASettingsRow(title: URL(fileURLWithPath: path).lastPathComponent, subtitle: path) {
                Button(action: { onRemove(path) }) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            
            // 知识库绑定 Picker & 刷新按钮
            HStack(spacing: 8) {
                Text("同步至知识库")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                
                Spacer()
                
                HStack(spacing: 4) {
                    Picker("", selection: Binding(
                        get: { FileMonitorService.shared.getKnowledgeBaseId(for: path) ?? "" },
                        set: { FileMonitorService.shared.setKnowledgeBaseId($0, for: path) }
                    )) {
                        Text("默认 (新建笔记)").tag("")
                        ForEach(FileMonitorService.shared.availableKnowledgeBases) { kb in
                            Text(kb.name).tag(kb.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(width: 130)
                    .labelsHidden()
                    
                    Button(action: {
                        Task {
                            await FileMonitorService.shared.fetchKnowledgeBases()
                        }
                    }) {
                        Image(systemName: "arrow.clockwise.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.appAccent)
                    }
                    .buttonStyle(.plain)
                    .help("刷新云端知识库列表")
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.appCanvas.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.bottom, 8)
    }
}

struct WindowFocusActivator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.makeKeyAndOrderFront(nil)
        }
    }
}

struct IMASettingsGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appMuted)

            VStack(spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appSurface.opacity(0.86))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.appLine.opacity(0.62), lineWidth: 1)
                    )
            )
            .shadow(color: Color.appMint.opacity(0.035), radius: 14, x: 0, y: 8)
        }
    }
}

struct IMASettingsRow<Accessory: View>: View {
    let title: String
    let subtitle: String
    var isSelectable: Bool = false
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    let text = Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(isSelectable ? 4 : 1)
                        .truncationMode(.middle)
                    
                    if isSelectable {
                        text.textSelection(.enabled)
                    } else {
                        text.textSelection(.disabled)
                    }
                }
            }
            Spacer()
            accessory
        }
        .padding(.horizontal, 18)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appLine.opacity(0.64))
                .frame(height: 1)
                .padding(.leading, 18)
        }
    }
}

struct IMASettingsTextRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    var placeholder = "未填写"
    var isSecure = false
    @State private var isRevealed = false
    @State private var isFocused = false

    var body: some View {
        IMASettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 6) {
                AppKitSingleLineTextField(
                    text: $text,
                    placeholder: placeholder,
                    isSecure: isSecure && !isRevealed,
                    isFocused: $isFocused
                )
                .frame(maxWidth: .infinity)
                .frame(height: 24)

                if isSecure {
                    CredentialToolButton(
                        icon: isRevealed ? "eye.slash" : "eye",
                        help: isRevealed ? "隐藏" : "显示"
                    ) {
                        isRevealed.toggle()
                    }
                }

                CredentialToolButton(icon: "doc.on.doc", help: "复制") {
                    copyToPasteboard()
                }
                .disabled(text.isEmpty)

                CredentialToolButton(icon: "doc.on.clipboard", help: "粘贴") {
                    pasteFromPasteboard()
                }
            }
            .padding(.horizontal, 12)
            .frame(width: 380, height: 36)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.appControl.opacity(0.94))
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isFocused ? Color.appMint.opacity(0.65) : Color.appLine.opacity(0.72), lineWidth: 1)
                    )
            )
        }
    }

    private func copyToPasteboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func pasteFromPasteboard() {
        if let value = NSPasteboard.general.string(forType: .string) {
            text = value
        }
    }
}

struct AppKitSingleLineTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isSecure: Bool
    @Binding var isFocused: Bool

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        installField(in: container, context: context)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        let field = nsView.subviews.first as? NSTextField
        if field == nil || ((field is NSSecureTextField) != isSecure) {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            installField(in: nsView, context: context)
        }

        guard let field = nsView.subviews.first as? NSTextField else { return }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    private func installField(in container: NSView, context: Context) {
        let field = makeField()
        field.delegate = context.coordinator
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    private func makeField() -> NSTextField {
        let field: NSTextField = isSecure ? FocusableSecureTextField() : FocusableTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = .labelColor
        field.lineBreakMode = .byTruncatingMiddle
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        return field
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isFocused = true
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isFocused = false
            if let field = obj.object as? NSTextField {
                text = field.stringValue
            }
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                text = field.stringValue
            }
        }
    }
}

private final class FocusableTextField: NSTextField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

private final class FocusableSecureTextField: NSSecureTextField {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

struct CredentialToolButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.appMuted)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.appControlPressed.opacity(0.9))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
