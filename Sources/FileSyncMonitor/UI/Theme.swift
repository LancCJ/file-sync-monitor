import SwiftUI

extension Color {
    static let appAccent = Color(red: 34 / 255, green: 36 / 255, blue: 38 / 255)
    static let appAccentSoft = Color(red: 234 / 255, green: 245 / 255, blue: 239 / 255)
    static let appInk = Color(red: 29 / 255, green: 31 / 255, blue: 34 / 255)
    static let appMuted = Color(red: 119 / 255, green: 124 / 255, blue: 132 / 255)
    static let appMint = Color(red: 0 / 255, green: 173 / 255, blue: 111 / 255)
    static let appAmber = Color(red: 233 / 255, green: 146 / 255, blue: 47 / 255)
    static let appRose = Color(red: 219 / 255, green: 78 / 255, blue: 95 / 255)
    static let appViolet = Color(red: 104 / 255, green: 102 / 255, blue: 232 / 255)
    static let appCanvas = Color(red: 247 / 255, green: 247 / 255, blue: 247 / 255)
    static let appCanvasTop = Color(red: 250 / 255, green: 250 / 255, blue: 250 / 255)
    static let appGlowBlue = Color(red: 242 / 255, green: 247 / 255, blue: 247 / 255)
    static let appGlowLime = Color(red: 234 / 255, green: 245 / 255, blue: 239 / 255)
    static let appPanel = Color.white
    static let appSurface = Color(red: 252 / 255, green: 254 / 255, blue: 252 / 255)
    static let appSurfaceSoft = Color(red: 246 / 255, green: 252 / 255, blue: 247 / 255)
    static let appControl = Color(red: 249 / 255, green: 253 / 255, blue: 250 / 255)
    static let appControlPressed = Color(red: 239 / 255, green: 249 / 255, blue: 242 / 255)
    static let appPanelSoft = Color.appSurfaceSoft
    static let appLine = Color(red: 220 / 255, green: 232 / 255, blue: 224 / 255)
    static let appSelection = Color(red: 234 / 255, green: 245 / 255, blue: 239 / 255)

    // Backwards-compatible names used by older views.
    static let tencentBlue = Color.appAccent
    static let tencentLightBlue = Color.appAccentSoft
    static let imaBackground = Color.appCanvas
    static let successGreen = Color.appMint
    static let warningOrange = Color.appAmber
}

enum EventVisuals {
    static func title(for type: String) -> LocalizedStringKey {
        switch type {
        case "created": return "新增"
        case "modified": return "修改"
        case "deleted": return "删除"
        case "renamed": return "重命名"
        default: return "变动"
        }
    }

    static func symbol(for type: String) -> String {
        switch type {
        case "created": return "plus"
        case "modified": return "pencil"
        case "deleted": return "trash"
        case "renamed": return "arrow.left.arrow.right"
        default: return "doc"
        }
    }

    static func color(for type: String) -> Color {
        switch type {
        case "created": return .appMint
        case "modified": return .appInk
        case "deleted": return .appRose
        case "renamed": return .appAmber
        default: return .secondary
        }
    }
}

extension Date {
    var shortActivityTime: String {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = Calendar.current.isDateInToday(self) ? "HH:mm:ss" : "MM/dd HH:mm:ss"
        return formatter.string(from: self)
    }
}

extension View {
    func appBackground() -> some View {
        self.background(IMAWindowBackground())
    }

    func appCard(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.appSurface.opacity(0.9))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.appLine.opacity(0.72), lineWidth: 1)
            )
            .shadow(color: Color.appMint.opacity(0.04), radius: 14, x: 0, y: 8)
            .imaHover()
    }

    func appSection() -> some View {
        self
            .background(Color.appCanvas)
    }

    func imaCard() -> some View {
        appCard()
    }

    func imaHover() -> some View {
        self.modifier(HoverScale())
    }
}

struct IMAWindowBackground: View {
    var body: some View {
        SoftAtmosphereBackground(base: Color(red: 253 / 255, green: 254 / 255, blue: 253 / 255), intensity: 1)
    }
}

struct IMAClientSurfaceBackground: View {
    var body: some View {
        SoftAtmosphereBackground(base: Color.white, intensity: 0.72)
    }
}

private struct SoftAtmosphereBackground: View {
    let base: Color
    let intensity: Double

    var body: some View {
        ZStack {
            base

            LinearGradient(
                colors: [
                    Color(red: 235 / 255, green: 252 / 255, blue: 252 / 255).opacity(0.58 * intensity),
                    Color.white.opacity(0.18),
                    Color(red: 239 / 255, green: 255 / 255, blue: 218 / 255).opacity(0.86 * intensity)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )

            LinearGradient(
                colors: [
                    Color.clear,
                    Color(red: 250 / 255, green: 255 / 255, blue: 231 / 255).opacity(0.72 * intensity),
                    Color(red: 230 / 255, green: 250 / 255, blue: 244 / 255).opacity(0.46 * intensity)
                ],
                startPoint: .center,
                endPoint: .bottom
            )

            LinearGradient(
                colors: [
                    Color.white.opacity(0.86),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .center
            )
        }
    }
}

struct AppIconBadge: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 32

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color == .appAccent ? Color.appInk.opacity(0.08) : color.opacity(0.12))
            Image(systemName: symbol)
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(color)
        }
        .frame(width: size, height: size)
    }
}

struct AppSectionHeader: View {
    let title: String
    var subtitle: String?
    var icon: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appAccent)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

struct SectionHeader: View {
    let icon: String
    let title: String

    var body: some View {
        AppSectionHeader(title: title, icon: icon)
    }
}

struct PillButtonStyle: ButtonStyle {
    var isPrimary: Bool = true

    func makeBody(configuration: Configuration) -> some View {
        PillButtonContent(configuration: configuration, isPrimary: isPrimary)
    }

    private struct PillButtonContent: View {
        let configuration: Configuration
        let isPrimary: Bool
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(stroke, lineWidth: 1)
                        )
                )
                .foregroundStyle(isPrimary ? .white : Color.appInk)
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.02 : 1))
                .onHover { isHovered = $0 }
                .animation(.snappy(duration: 0.15), value: isHovered)
                .animation(.snappy(duration: 0.1), value: configuration.isPressed)
        }

        private var background: Color {
            if isPrimary {
                return configuration.isPressed ? Color.appInk.opacity(0.8) : (isHovered ? Color.appInk.opacity(0.92) : Color.appInk)
            } else {
                return configuration.isPressed ? Color.appControlPressed : (isHovered ? Color.appSelection.opacity(0.4) : Color.appControl)
            }
        }

        private var stroke: Color {
            isPrimary ? Color.appInk : (isHovered ? Color.appMint.opacity(0.3) : Color.appLine.opacity(0.72))
        }
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonContent(configuration: configuration)
    }

    private struct QuietButtonContent: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(background)
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .stroke(Color.appLine.opacity(isHovered ? 0.9 : 0.72), lineWidth: 1)
                        )
                )
                .foregroundStyle(isHovered ? Color.appInk : Color.appInk.opacity(0.85))
                .scaleEffect(configuration.isPressed ? 0.97 : (isHovered ? 1.02 : 1))
                .onHover { isHovered = $0 }
                .animation(.snappy(duration: 0.15), value: isHovered)
        }

        private var background: Color {
            configuration.isPressed ? Color.appControlPressed : (isHovered ? Color.appSelection.opacity(0.5) : Color.appControl.opacity(0.92))
        }
    }
}

struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 14) {
            AppIconBadge(symbol: icon, color: .appAccent, size: 52)
            VStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}

struct SmoothSearchField: View {
    @Binding var text: String
    let placeholder: LocalizedStringKey
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isFocused ? Color.appMint : .secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.appControl.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isFocused ? Color.appMint.opacity(0.58) : Color.appLine.opacity(0.72), lineWidth: 1)
                )
        )
    }
}

struct StatusPill: View {
    let text: LocalizedStringKey
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
            Text(text)
                .font(.system(size: 11, weight: .semibold))
        }
        .padding(.horizontal, 8)
        .frame(height: 22)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(color.opacity(0.12))
        )
        .foregroundStyle(color)
    }
}

struct AppToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                isOn.toggle()
            }
        } label: {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isOn ? Color.appMint : Color(red: 224 / 255, green: 235 / 255, blue: 227 / 255))
                .frame(width: 40, height: 22)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 16, height: 16)
                        .padding(3)
                        .shadow(color: Color.appInk.opacity(0.12), radius: 3, x: 0, y: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

struct AppMenuValue: View {
    let text: LocalizedStringKey

    var body: some View {
        HStack(spacing: 6) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.appControl.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color.appLine.opacity(0.72), lineWidth: 1)
                )
        )
        .foregroundStyle(Color.appInk)
    }
}

struct AppSegmentedControl<Value: Hashable>: View {
    let options: [(Value, LocalizedStringKey)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { option in
                Button {
                    withAnimation(.snappy(duration: 0.18)) {
                        selection = option.0
                    }
                } label: {
                    Text(option.1)
                        .font(.system(size: 12, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .frame(maxWidth: .infinity)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(selection == option.0 ? Color.appInk : Color.clear)
                        )
                        .foregroundStyle(selection == option.0 ? .white : Color.appMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.appSurface.opacity(0.82))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.appLine.opacity(0.72), lineWidth: 1)
                )
        )
    }
}

struct AnimatedCounter: View {
    let value: Int
    @State private var displayValue = 0

    var body: some View {
        Text("\(displayValue)")
            .font(.system(size: 30, weight: .bold, design: .rounded))
            .contentTransition(.numericText())
            .onAppear { displayValue = value }
            .onChange(of: value) { _, newValue in
                withAnimation(.snappy(duration: 0.25)) {
                    displayValue = newValue
                }
            }
    }
}

struct GlassBadge: View {
    let count: Int

    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.appRose)
                )
        }
    }
}

struct HoverScale: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.012 : 1)
            .shadow(color: isHovered ? Color.appMint.opacity(0.08) : Color.clear, radius: isHovered ? 12 : 0, x: 0, y: 6)
            .onHover { isHovered = $0 }
            .animation(.snappy(duration: 0.22), value: isHovered)
    }
}

enum AppLanguage: String, CaseIterable {
    case system, en, zhHans, zhHant

    var title: LocalizedStringKey {
        switch self {
        case .system: "跟随系统"
        case .en: "English"
        case .zhHans: "简体中文"
        case .zhHant: "繁体中文"
        }
    }

    var localeIdentifier: String? {
        switch self {
        case .system: return nil
        case .en: return "en"
        case .zhHans: return "zh-Hans"
        case .zhHant: return "zh-Hant"
        }
    }
}
