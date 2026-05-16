import SwiftUI
import SwiftData
import AppKit

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("notifyOnChanges") private var notifyOnChanges = true
    @AppStorage("retentionDays") private var retentionDays = 365
    @AppStorage("defaultExportFormat") private var defaultExportFormat = "csv"
    @AppStorage("imaClientId") private var clientId = ""
    @AppStorage("imaApiKey") private var apiKey = ""
    @AppStorage("enableDefaultIgnoreRules") private var enableDefaultIgnoreRules = true
    @AppStorage("customIgnoredFileNames") private var customIgnoredFileNames = ""
    @AppStorage("customIgnoredExtensions") private var customIgnoredExtensions = ""
    @AppStorage("customIgnoredDirectoryNames") private var customIgnoredDirectoryNames = ""

    @State private var isTestingIMA = false
    @State private var imaStatus: IMAStatus = .idle

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
        case idle, connected, failed
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
                            IMASettingsRow(title: URL(fileURLWithPath: path).lastPathComponent, subtitle: path) {
                                Button(role: .destructive) {
                                    FileMonitorService.shared.removeDirectory(at: path)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                            }
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

                    IMASettingsEditorRow(
                        title: "忽略文件名",
                        subtitle: "每行一个文件名，例如 .DS_Store 或 debug.log",
                        text: $customIgnoredFileNames,
                        placeholder: ".DS_Store\ndebug.log"
                    )

                    IMASettingsEditorRow(
                        title: "忽略后缀",
                        subtitle: "每行一个后缀，例如 .log、.tmp",
                        text: $customIgnoredExtensions,
                        placeholder: ".log\n.tmp"
                    )

                    IMASettingsEditorRow(
                        title: "忽略目录名",
                        subtitle: "每行一个目录名，例如 node_modules 或 DerivedData",
                        text: $customIgnoredDirectoryNames,
                        placeholder: "node_modules\nDerivedData"
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
                    IMASettingsRow(title: "连接测试", subtitle: "检查当前凭据是否可用") {
                        HStack(spacing: 10) {
                            StatusPill(text: imaStatusTitle, symbol: imaStatusIcon, color: imaStatusColor)
                            Button(action: testIMAConnection) {
                                if isTestingIMA {
                                    ProgressView().controlSize(.small)
                                } else {
                                    Text("测试")
                                }
                            }
                            .buttonStyle(QuietButtonStyle())
                            .disabled(clientId.isEmpty || apiKey.isEmpty || isTestingIMA)
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

    private func testIMAConnection() {
        isTestingIMA = true
        imaStatus = .idle
        Task {
            IMASyncService.shared.clientId = clientId
            IMASyncService.shared.apiKey = apiKey
            do {
                _ = try await IMASyncService.shared.getKnowledgeBases()
                imaStatus = .connected
            } catch {
                imaStatus = .failed
            }
            isTestingIMA = false
        }
    }

    private func resetIgnoreRules() {
        enableDefaultIgnoreRules = true
        customIgnoredFileNames = ""
        customIgnoredExtensions = ""
        customIgnoredDirectoryNames = ""
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
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
    var isSecure = false
    @State private var isRevealed = false
    @State private var isFocused = false

    var body: some View {
        IMASettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 6) {
                AppKitCredentialField(
                    text: $text,
                    placeholder: "未填写",
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
            text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct IMASettingsEditorRow: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        IMASettingsRow(title: title, subtitle: subtitle) {
            ZStack(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted.opacity(0.55))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color.appInk)
                    .scrollContentBackground(.hidden)
                    .focused($isFocused)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
            }
            .frame(width: 380, height: 74)
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
}

struct AppKitCredentialField: NSViewRepresentable {
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
        let currentField = nsView.subviews.first as? NSTextField
        if currentField == nil || ((currentField is NSSecureTextField) != isSecure) {
            nsView.subviews.forEach { $0.removeFromSuperview() }
            installField(in: nsView, context: context)
        }

        guard let field = nsView.subviews.first as? NSTextField else { return }
        if field.stringValue != text {
            field.stringValue = text
        }
        field.placeholderString = placeholder
    }

    private func installField(in container: NSView, context: Context) {
        let field = makeField()
        field.delegate = context.coordinator
        field.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        if let height = field.cell?.cellSize.height {
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: height).isActive = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    private func makeField() -> NSTextField {
        let field: NSTextField = isSecure ? NSSecureTextField() : NSTextField()
        field.stringValue = text
        field.placeholderString = placeholder
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.isEditable = true
        field.isSelectable = true
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.textColor = NSColor.labelColor
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
