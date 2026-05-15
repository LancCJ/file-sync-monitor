import SwiftUI
import SwiftData

struct SettingsView: View {
    @AppStorage("appearance") private var appearance: AppearanceMode = .system
    @AppStorage("language") private var language: String = "zh-Hans"
    @AppStorage("clientId") private var clientId: String = ""
    @AppStorage("apiKey") private var apiKey: String = ""

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

    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("常规", systemImage: "gearshape") }

            IMACloudSettingsView()
                .tabItem { Label("IMA 云端", systemImage: "cloud") }

            ProUpgradeView()
                .tabItem { Label("高级版", systemImage: "star") }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General Settings
struct GeneralSettingsView: View {
    @AppStorage("appearance") private var appearance: SettingsView.AppearanceMode = .system

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // Appearance Section
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "paintpalette", title: "外观")

                    VStack(spacing: 16) {
                        HStack {
                            Image(systemName: "sun.max.fill")
                                .foregroundStyle(Color.warningOrange)
                                .frame(width: 24)
                            Text("主题模式")
                                .font(.system(size: 14))
                            Spacer()
                            Picker("", selection: $appearance) {
                                ForEach(SettingsView.AppearanceMode.allCases, id: \.self) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(width: 140)
                        }
                    }
                    .imaCard()
                }

                // Monitor Section
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "folder.badge.gear", title: "监控目录")

                    MonitoredDirectoriesCard()
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }
}

struct MonitoredDirectoriesCard: View {
    var body: some View {
        VStack(spacing: 0) {
            if FileMonitorService.shared.monitoredPaths.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(Color.tencentBlue.opacity(0.5))
                    VStack(alignment: .leading, spacing: 4) {
                        Text("尚未添加监控目录")
                            .font(.system(size: 14, weight: .medium))
                        Text("点击下方按钮添加需要监控的文件夹")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(16)
            } else {
                VStack(spacing: 0) {
                    ForEach(FileMonitorService.shared.monitoredPaths, id: \.self) { path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder")
                                .foregroundStyle(Color.tencentBlue)
                                .frame(width: 20)
                            Text(path)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button(role: .destructive) {
                                FileMonitorService.shared.removeDirectory(at: path)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .font(.system(size: 16))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)

                        if path != FileMonitorService.shared.monitoredPaths.last {
                            Divider()
                                .padding(.leading, 46)
                        }
                    }
                }
            }

            Divider()

            Button(action: addDirectory) {
                HStack(spacing: 6) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14))
                    Text("添加监控目录")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.tencentBlue)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .background(.ultraThinMaterial)
        .background(Color.primary.opacity(0.02))
        .cornerRadius(16)
        .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
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
}

// MARK: - IMA Cloud Settings
struct IMACloudSettingsView: View {
    @AppStorage("imaClientId") private var clientId: String = ""
    @AppStorage("imaApiKey") private var apiKey: String = ""
    @State private var isTesting = false
    @State private var testResult: TestResult? = nil

    enum TestResult: Equatable {
        case connected, failed(String)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                // API Config Section
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "key.horizontal", title: "API 配置")

                    VStack(spacing: 0) {
                        IconTextField(
                            icon: "person.text.rectangle",
                            iconColor: Color.tencentBlue,
                            title: "Client ID",
                            text: $clientId,
                            prompt: "输入 Client ID"
                        )

                        Divider()
                            .padding(.leading, 44)

                        IconTextField(
                            icon: "lock.shield",
                            iconColor: Color.warningOrange,
                            title: "API Key",
                            text: $apiKey,
                            prompt: "输入 API Key",
                            isSecure: true
                        )
                    }
                    .imaCard()
                }

                // Connection Test
                VStack(alignment: .leading, spacing: 12) {
                    SectionHeader(icon: "antenna.radiowaves.left.and.right", title: "连接测试")

                    Button(action: testConnection) {
                        HStack(spacing: 8) {
                            if isTesting {
                                ProgressView()
                                    .controlSize(.small)
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: testResultIcon)
                                    .font(.system(size: 14))
                            }
                            Text(buttonTitle)
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    }
                    .buttonStyle(PillButtonStyle(isPrimary: testResult == nil))
                    .disabled(clientId.isEmpty || apiKey.isEmpty || isTesting)

                    if let result = testResult {
                        HStack(spacing: 8) {
                            Image(systemName: result == .connected ? "checkmark.circle.fill" : "xmark.circle.fill")
                            Text(resultMessage(for: result))
                                .font(.system(size: 13))
                            Spacer()
                        }
                        .foregroundStyle(result == .connected ? Color.successGreen : .red)
                        .padding(.horizontal, 4)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }

                Spacer(minLength: 20)
            }
            .padding(24)
        }
    }

    private var buttonTitle: String {
        if isTesting { return "测试中..." }
        switch testResult {
        case .connected: return "连接成功"
        case .failed: return "重试连接"
        case .none: return "测试连接"
        }
    }

    private var testResultIcon: String {
        switch testResult {
        case .connected: return "checkmark.circle.fill"
        case .failed: return "arrow.clockwise"
        case .none: return "bolt.fill"
        }
    }

    private func resultMessage(for result: TestResult) -> String {
        switch result {
        case .connected: return "API 连接正常，可以正常使用同步功能"
        case .failed(let msg): return msg
        }
    }

    func testConnection() {
        isTesting = true
        testResult = nil
        Task {
            IMASyncService.shared.clientId = clientId
            IMASyncService.shared.apiKey = apiKey
            do {
                _ = try await IMASyncService.shared.getKnowledgeBases()
                withAnimation {
                    testResult = .connected
                }
            } catch {
                withAnimation {
                    testResult = .failed("连接失败：请检查 Client ID 和 API Key 是否正确")
                }
            }
            isTesting = false
        }
    }
}

// MARK: - Icon Text Field
struct IconTextField: View {
    let icon: String
    let iconColor: Color
    let title: String
    @Binding var text: String
    let prompt: String
    var isSecure: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(iconColor)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if isSecure {
                    SecureField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFocused)
                        .frame(maxWidth: .infinity, minHeight: 18)
                } else {
                    TextField(prompt, text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($isFocused)
                        .frame(maxWidth: .infinity, minHeight: 18)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(isFocused ? Color.tencentBlue.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Pro Upgrade
struct ProUpgradeView: View {
    let store = StoreManager.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 0.15, green: 0.25, blue: 0.55),
                                    Color(red: 0.08, green: 0.12, blue: 0.35)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    VStack(spacing: 20) {
                        ZStack {
                            Circle()
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 80, height: 80)
                            Image(systemName: "crown.fill")
                                .font(.system(size: 36))
                                .foregroundStyle(
                                    LinearGradient(
                                        colors: [.yellow, .orange],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                                .shadow(color: .orange.opacity(0.4), radius: 10, x: 0, y: 4)
                        }

                        if store.isPro {
                            VStack(spacing: 8) {
                                Text("您已是专业版用户")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("感谢您的支持，所有高级功能已解锁")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)

                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.system(size: 14))
                                    Text("已激活")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                .foregroundStyle(.green)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 6)
                                .background(Color.green.opacity(0.15))
                                .clipShape(Capsule())
                                .padding(.top, 8)
                            }
                        } else {
                            VStack(spacing: 8) {
                                Text("升级到专业版")
                                    .font(.system(size: 20, weight: .bold))
                                    .foregroundStyle(.white)
                                Text("一次性解锁无限监控、自动同步等高级功能")
                                    .font(.system(size: 13))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .multilineTextAlignment(.center)
                            }

                            // Features
                            VStack(alignment: .leading, spacing: 10) {
                                FeatureRow(icon: "infinity", text: "无限监控目录")
                                FeatureRow(icon: "arrow.triangle.2.circlepath", text: "自动云端同步")
                                FeatureRow(icon: "bell.badge", text: "实时推送通知")
                                FeatureRow(icon: "chart.line.uptrend.xyaxis", text: "高级数据报表")
                            }
                            .padding(.vertical, 8)

                            Button(action: {
                                Task { try? await store.purchase() }
                            }) {
                                HStack(spacing: 8) {
                                    Image(systemName: "bag.fill")
                                    Text("立即购买 - ¥9.9")
                                        .font(.system(size: 15, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                            }
                            .buttonStyle(PillButtonStyle(isPrimary: true))
                            .padding(.horizontal, 20)
                        }
                    }
                    .padding(28)
                }
                .padding(24)

                Spacer(minLength: 20)
            }
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 20)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
    }
}
