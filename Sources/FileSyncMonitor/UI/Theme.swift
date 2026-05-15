import SwiftUI

extension Color {
    static let tencentBlue = Color(red: 0.0, green: 82/255, blue: 217/255)
    static let tencentLightBlue = Color(red: 0.0, green: 145/255, blue: 255/255)
    static let imaBackground = Color(nsColor: .windowBackgroundColor)
    static let successGreen = Color(red: 52/255, green: 199/255, blue: 89/255)
    static let warningOrange = Color(red: 255/255, green: 149/255, blue: 0/255)
}

extension View {
    func imaCard() -> some View {
        self.padding()
            .background(.ultraThinMaterial)
            .background(Color.primary.opacity(0.02))
            .cornerRadius(16)
            .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 5)
    }

    func premiumGradient() -> LinearGradient {
        LinearGradient(
            colors: [.tencentBlue, .tencentLightBlue],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

struct PillButtonStyle: ButtonStyle {
    var isPrimary: Bool = true
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(isPrimary ? Color.tencentBlue : Color.primary.opacity(0.05))
            .foregroundColor(isPrimary ? .white : .primary)
            .clipShape(Capsule())
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(), value: configuration.isPressed)
    }
}

// MARK: - Empty State View
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.tencentBlue.opacity(0.08))
                    .frame(width: 100, height: 100)
                Image(systemName: icon)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Color.tencentBlue.opacity(0.6))
            }
            VStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold))
                Text(subtitle)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Animated Counter
struct AnimatedCounter: View {
    let value: Int
    @State private var displayValue: Int = 0

    var body: some View {
        Text("\(displayValue)")
            .font(.system(size: 38, weight: .bold, design: .rounded))
            .onAppear { animate() }
            .onChange(of: value) { _, new in
                withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                    displayValue = new
                }
            }
    }

    private func animate() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
            displayValue = value
        }
    }
}

// MARK: - Glass Badge
struct GlassBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text("\(count)")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule()
                        .fill(Color.tencentBlue)
                        .shadow(color: Color.tencentBlue.opacity(0.4), radius: 4, x: 0, y: 2)
                )
        }
    }
}

// MARK: - Section Header
struct SectionHeader: View {
    let icon: String
    let title: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.tencentBlue)
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Smooth Search Field
struct SmoothSearchField: View {
    @Binding var text: String
    let placeholder: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(isFocused ? Color.tencentBlue : .secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
            if !text.isEmpty {
                Button(action: { text = "" }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.primary.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(isFocused ? Color.tencentBlue.opacity(0.3) : Color.clear, lineWidth: 1.5)
                )
        )
        .animation(.easeInOut(duration: 0.2), value: isFocused)
    }
}

// MARK: - Hover Scale Effect
struct HoverScale: ViewModifier {
    @State private var isHovered = false
    func body(content: Content) -> some View {
        content
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isHovered)
            .onHover { isHovered = $0 }
    }
}
