import SwiftUI
import SwiftData
import AppKit
import ServiceManagement

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("notifyOnChanges") private var notifyOnChanges = true
    @AppStorage("retentionDays") private var retentionDays = 365
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "csv"
    @AppStorage("enableDefaultIgnoreRules") private var enableDefaultIgnoreRules = true
    @AppStorage("customIgnoredFileNames") private var customIgnoredFileNames = ""
    @AppStorage("customIgnoredExtensions") private var customIgnoredExtensions = ""
    @AppStorage("customIgnoredDirectoryNames") private var customIgnoredDirectoryNames = ""
    @AppStorage("autoSync") private var autoSync = false
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system

    @AppStorage("imaClientId") private var clientId = ""
    @AppStorage("imaApiKey") private var apiKey = ""

    @State private var isTestingIMA = false
    @State private var imaStatus: IMAStatus = .idle
    @State private var isShowingLogs = false
    @AppStorage("highlightIMAConfig") private var highlightIMAConfig = false
    @State private var highlightPulse = false
    @State private var isShowingIMAHelp = false
    @State private var launchAtLoginEnabled = false
    @State private var launchAtLoginStatusMessage = ""

    enum AppearanceMode: String, CaseIterable {
        case system, light, dark

        var titleKey: String {
            switch self {
            case .system: return "跟随系统"
            case .light: return "浅色"
            case .dark: return "深色"
            }
        }
    }

    enum IMAStatus: Equatable {
        case idle, connected, failed(String)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 32) {
                    LocalizedText("设置")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.appInk)
                        .padding(.top, 64)

                IMASettingsGroup(title: "界面") {
                    IMASettingsRow(title: "语言", subtitle: "手动指定界面语言或跟随系统") {
                        AppDropdownMenu(
                            selection: $appLanguage,
                            options: AppLanguage.allCases.map { ($0, $0.displayTitle) },
                            label: AppMenuValue(text: appLanguage.displayTitle)
                        )
                        .frame(width: 120)
                        .onChange(of: appLanguage) { _, _ in
                            MenuBarManager.shared.refreshMenu()
                        }
                    }

                    IMASettingsRow(title: "外观模式", subtitle: "切换浅色、深色或跟随系统设置") {
                        AppSegmentedControl(
                            options: AppearanceMode.allCases.map { ($0, $0.titleKey) },
                            selection: $appearance
                        )
                        .frame(width: 240)
                    }
                }

                IMASettingsGroup(title: "监控目录") {
                    if FileMonitorService.shared.monitoredPaths.isEmpty {
                        IMASettingsRow(title: "监控文件夹", subtitle: "尚未添加目录") {
                            Button(action: addDirectory) {
                                LocalizedText("添加")
                            }
                            .buttonStyle(PillButtonStyle(isPrimary: true))
                        }
                    } else {
                        ForEach(FileMonitorService.shared.monitoredPaths, id: \.self) { path in
                            MonitoredPathRow(path: path, onRemove: removeDirectory)
                        }
                        IMASettingsRow(title: "添加更多目录", subtitle: "继续监控其他文件夹") {
                            Button(action: addDirectory) {
                                LocalizedText("添加")
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
                            LocalizedText("恢复")
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                }

                IMASettingsGroup(title: "同步") {
                    IMASettingsRow(title: "同步模式", subtitle: autoSync ? "自动同步：文件稳定 30 秒后上传到云端" : "手动同步：点击同步按钮时上传") {
                        AppToggle(isOn: $autoSync)
                    }

                    IMASettingsTextRow(title: "Client ID", subtitle: "IMA OpenAPI Client ID", text: $clientId)
                    IMASettingsTextRow(title: "API Key", subtitle: "IMA OpenAPI API Key", text: $apiKey, isSecure: true)
                    
                    IMASettingsRow(title: "获取凭证帮助", subtitle: "了解如何注册并获取 Tencent IMA 凭证") {
                        Button(action: { isShowingIMAHelp = true }) {
                            HStack(spacing: 4) {
                                LocalizedText("查看帮助")
                                Image(systemName: "questionmark.circle")
                            }
                        }
                        .buttonStyle(QuietButtonStyle())
                    }
                    
                    IMASettingsRow(title: "连接状态", subtitle: imaStatusDetail, isSelectable: true) {
                        HStack(spacing: 12) {
                            StatusPill(text: imaStatusTitle, symbol: imaStatusIcon, color: imaStatusColor)
                            
                            Button(action: { isShowingLogs = true }) {
                                Image(systemName: "list.bullet.rectangle.portrait")
                                    .font(.system(size: 14))
                            }
                            .buttonStyle(QuietButtonStyle())
                            .help("查看请求日志".appLocalized)
                            
                            Button(action: testIMAConnection) {
                                if isTestingIMA {
                                    ProgressView().controlSize(.small)
                                        .transition(.scale.combined(with: .opacity))
                                } else {
                                    LocalizedText("测试连接")
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(clientId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isTestingIMA)
                            .animation(.snappy, value: isTestingIMA)
                        }
                    }
                    .imaHover()
                }
                .id("imaSyncSection")
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.appAmber, lineWidth: highlightPulse ? 2 : 0)
                        .shadow(color: Color.appAmber.opacity(highlightPulse ? 0.6 : 0), radius: 8)
                )
                .animation(.easeInOut(duration: 0.6), value: highlightPulse)

                IMASettingsGroup(title: "通知与导出") {
                    IMASettingsRow(title: "开机自动运行", subtitle: launchAtLoginStatusMessage.isEmpty ? "登录 macOS 后自动启动 FileSyncMonitor 并继续监控目录" : launchAtLoginStatusMessage, isSelectable: !launchAtLoginStatusMessage.isEmpty) {
                        AppToggle(
                            isOn: Binding(
                                get: { launchAtLoginEnabled },
                                set: { setLaunchAtLogin($0) }
                            )
                        )
                        .disabled(!canRegisterLaunchAtLogin)
                        .opacity(canRegisterLaunchAtLogin ? 1 : 0.42)
                    }

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
                        AppDropdownMenu(
                            selection: $retentionDays,
                            options: [
                                (30, "30 天".appLocalized),
                                (90, "90 天".appLocalized),
                                (365, "365 天".appLocalized),
                                (0, "永久".appLocalized)
                            ],
                            label: AppMenuValue(text: retentionText)
                        )
                        .frame(width: 110)
                    }
                }

                IMASettingsGroup(title: "关于与开发") {
                    IMASettingsRow(title: "关于 FileSyncMonitor", subtitle: "版本 v1.0.0-beta • 基于 macOS Sonoma") {
                        Text("FileSyncMonitor")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.appMuted)
                    }
                    
                    IMASettingsRow(title: "开发者", subtitle: "作者: LancCJ (GitHub)") {
                        Link(destination: URL(string: "https://github.com/LancCJ")!) {
                            HStack(spacing: 5) {
                                Image(systemName: "link")
                                    .font(.system(size: 11))
                                Text("@LancCJ")
                                    .font(.system(size: 13, weight: .bold))
                            }
                            .foregroundStyle(Color.appMint)
                        }
                        .buttonStyle(.plain)
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
            .sheet(isPresented: $isShowingIMAHelp) {
                IMAConfigHelpDialog(dismiss: { isShowingIMAHelp = false })
            }
            .onAppear {
                refreshLaunchAtLoginStatus()
                if highlightIMAConfig {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.85)) {
                            proxy.scrollTo("imaSyncSection", anchor: .center)
                        }
                        withAnimation(.easeInOut(duration: 0.6).repeatCount(3, autoreverses: true)) {
                            highlightPulse = true
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                            highlightIMAConfig = false
                            highlightPulse = false
                        }
                    }
                }
            }
            .onChange(of: enableDefaultIgnoreRules) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
            .onChange(of: customIgnoredFileNames) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
            .onChange(of: customIgnoredExtensions) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
            .onChange(of: customIgnoredDirectoryNames) { _, _ in FileMonitorService.shared.refreshIgnoreRules() }
        }
    }

    private var retentionText: String {
        retentionDays == 0 ? "永久" : String(format: "天_format".appLocalized, retentionDays)
    }

    private var defaultIgnoreSummary: String {
        "过滤 .DS_Store、临时文件、系统目录和常见构建缓存"
    }

    private var imaStatusTitle: String {
        switch imaStatus {
        case .idle: return "未测试"
        case .connected: return "连接成功"
        case .failed: return "连接失败"
        }
    }

    private var imaStatusDetail: String {
        switch imaStatus {
        case .idle:
            return "检查当前凭据是否可用"
        case .connected:
            return String(format: "IMA OpenAPI 连接成功，已获取知识库_format".appLocalized, FileMonitorService.shared.availableKnowledgeBases.count)
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

    private func refreshLaunchAtLoginStatus() {
        guard canRegisterLaunchAtLogin else {
            launchAtLoginEnabled = false
            launchAtLoginStatusMessage = "当前是 Xcode/命令行调试运行，不能注册开机自启；请使用 .app 应用包运行后再开启。"
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            return
        }

        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        launchAtLoginStatusMessage = ""
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        guard canRegisterLaunchAtLogin else {
            launchAtLoginEnabled = false
            launchAtLoginStatusMessage = "当前运行的不是 .app 应用包，已阻止注册开机自启，避免重启后打开终端窗口。"
            if SMAppService.mainApp.status == .enabled {
                try? SMAppService.mainApp.unregister()
            }
            return
        }

        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginStatusMessage = enabled ? "已加入 macOS 登录项" : "已从 macOS 登录项移除"
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            launchAtLoginStatusMessage = String(format: "无法更新登录项：%@", error.localizedDescription)
        }
    }

    private var canRegisterLaunchAtLogin: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
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
                LocalizedText("同步至知识库")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.appMuted)
                
                Spacer()
                
                HStack(spacing: 4) {
                    AppDropdownMenu(
                        selection: Binding(
                            get: { FileMonitorService.shared.getKnowledgeBaseId(for: path) },
                            set: { FileMonitorService.shared.setKnowledgeBaseId($0, for: path) }
                        ),
                        options: [("", "默认 (新建笔记)".appLocalized)] + FileMonitorService.shared.availableKnowledgeBases.map { ($0.id, $0.name) },
                        label: AppMenuValue(text: FileMonitorService.shared.availableKnowledgeBases.first { $0.id == FileMonitorService.shared.getKnowledgeBaseId(for: path) }?.name ?? "默认 (新建笔记)".appLocalized),
                        maxHeight: 300
                    )
                    .frame(width: 180)
                    
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
                    .help("刷新云端知识库列表".appLocalized)
                }
                .padding(.leading, 8)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color.appCanvas.opacity(0.42))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(.bottom, 8)
        .imaHover()
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
            LocalizedText(title)
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
                LocalizedText(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)
                
                let text = Text(subtitle.appLocalized)
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
        .background(Color.white.opacity(0.001)) // Make entire row hoverable
        .imaHover()
    }
}

struct IMASettingsTextRow: View {
    @Environment(\.locale) var locale
    let title: String
    let subtitle: String
    @Binding var text: String
    var placeholder: String = "未填写"
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
                    isFocused: $isFocused,
                    locale: locale
                )
                .id(locale)
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
    let locale: Locale

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
        field.placeholderString = placeholder.appLocalized
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
        field.placeholderString = placeholder.appLocalized
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
        .help(help.appLocalized)
    }
}

struct IMAConfigHelpDialog: View {
    let dismiss: () -> Void
    @State private var isCloseHovered = false
    
    var body: some View {
        VStack(spacing: 24) {
            // Header
            HStack {
                LocalizedText("如何获取 Tencent IMA 凭证")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Spacer()
                Button(action: dismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(isCloseHovered ? Color.red : Color.appMuted)
                }
                .buttonStyle(.plain)
                .onHover { isCloseHovered = $0 }
                .animation(.snappy(duration: 0.15), value: isCloseHovered)
            }
            .padding(.bottom, 8)
            
            Divider()
            
            // Steps
            VStack(alignment: .leading, spacing: 18) {
                HelpStepRow(
                    number: "1",
                    title: "登录并进入控制台".appLocalized,
                    desc: "登录您的腾讯云账号，访问 Tencent IMA (腾讯云智能知识库) 平台并进入管理控制台。".appLocalized
                )
                
                HelpStepRow(
                    number: "2",
                    title: "获取 API 密钥".appLocalized,
                    desc: "在「API 密钥」或「安全凭证」管理页面，生成并获取您的 Client ID (客户端标识) 和 API Key (接口密钥)。".appLocalized
                )
                
                HelpStepRow(
                    number: "3",
                    title: "获取知识库 ID".appLocalized,
                    desc: "在「知识库管理」中，选择或创建目标知识库，复制其知识库 ID 并填入同步目录设置中。".appLocalized
                )
            }
            
            Spacer()
            
            // Action
            Button(action: dismiss) {
                LocalizedText("我知道了")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .background(Color.appMint)
                    .foregroundStyle(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(32)
        .frame(width: 480, height: 400)
        .background(IMAWindowBackground())
    }
}

struct HelpStepRow: View {
    let number: String
    let title: String
    let desc: String
    
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.appMint.opacity(0.12))
                    .frame(width: 24, height: 24)
                Text(number)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.appMint)
            }
            .padding(.top, 2)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appInk)
                Text(desc)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appInk.opacity(0.6))
                    .lineSpacing(4)
            }
        }
    }
}
