import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 40) {
                // Hero Header
                VStack(alignment: .leading, spacing: 16) {
                    LocalizedText("帮助与关于")
                        .font(.system(size: 44, weight: .black))
                        .foregroundStyle(Color.appInk)
                    
                    LocalizedText("解锁 FileSyncMonitor 的全部潜力，让您的工作流与 IMA 云端无缝合一。")
                        .font(.system(size: 18))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.top, 64)
                .padding(.horizontal, 40)

                // Bento Grid Layout
                HStack(alignment: .top, spacing: 24) {
                    // Left Column
                    VStack(spacing: 24) {
                        FeatureCard(
                            title: "实时智能监控", 
                            icon: "bolt.shield.fill", 
                            color: .appAmber, 
                            imageName: "help-monitoring",
                            items: [
                                ("全天候变动捕获", "利用高性能 FSEvents 技术，秒级感知任何文件的新增、修改或重命名。"),
                                ("智能过滤引擎", "内置专业级忽略规则，自动屏蔽缓存与系统杂质，让您的监控列表始终保持纯净。")
                            ]
                        )
                        
                        FeatureCard(
                            title: "精品化交互体验", 
                            icon: "sparkles", 
                            color: .appMint, 
                            imageName: "help-experience",
                            items: [
                                ("极致视觉反馈", "每一处按钮与卡片都经过精心调校，支持细腻的悬停动效与平滑的状态转换。"),
                                ("秒级记录分析", "支持秒级精度的时间轴回溯，并提供专业级 CSV/JSON 报表导出。")
                            ]
                        )
                    }
                    
                    // Right Column
                    VStack(spacing: 24) {
                        FeatureCard(
                            title: "IMA 双向同步", 
                            icon: "arrow.left.arrow.right.circle.fill", 
                            color: .appViolet, 
                            imageName: "help-sync",
                            items: [
                                ("双向拉取与删除决策", "点击「从云端拉取更新」以合并云端更改。若本地已被删除的文件仍存于云端，会弹框提示您选择重新拉回或保持本地删除。"),
                                ("自动推送与删除同步", "开启自动同步后 30 秒自动完成云端备份。对于本地删除事件，应用会自动标记同步成功，并指引您手动清理云端以实现双向一致。"),
                                ("智能状态合并", "系统会自动合并同一文件的多次连续操作。例如「新建后编辑」仍记为新建，「多次编辑」仅保留最新修改，从而大幅减少同步冗余。")
                            ]
                        )
                    }
                }
                .padding(.horizontal, 40)

                // About Section
                AboutCard()
                    .padding(.horizontal, 40)
                    .padding(.bottom, 80)
            }
            .frame(maxWidth: 1100, alignment: .center)
            .frame(maxWidth: .infinity)
        }
        .background(IMAClientSurfaceBackground())
    }
}

// MARK: - Components

struct FeatureCard: View {
    let title: String
    let icon: String
    let color: Color
    let imageName: String
    let items: [(title: String, desc: String)]
    
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Image Banner
            if let nsImage = loadImage() {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 180)
                    .clipped()
            } else {
                Rectangle()
                    .fill(LinearGradient(colors: [color.opacity(0.8), color.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(height: 180)
                    .overlay(
                        Image(systemName: icon)
                            .font(.system(size: 60))
                            .foregroundStyle(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                    )
            }

            // Content Area
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(color.opacity(0.15))
                            .frame(width: 40, height: 40)
                        Image(systemName: icon)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(color)
                    }
                    LocalizedText(title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.appInk)
                }

                VStack(alignment: .leading, spacing: 20) {
                    ForEach(items, id: \.title) { item in
                        HelpItem(title: item.title, description: item.desc)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.appSurface)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.appLine.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 24 : 12, x: 0, y: isHovered ? 12 : 4)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
    }

    private func loadImage() -> NSImage? {
        let resourceURL = Bundle.module.url(forResource: imageName, withExtension: "png")
            ?? Bundle.module.url(
                forResource: URL(fileURLWithPath: imageName).lastPathComponent,
                withExtension: "png"
            )

        guard let url = resourceURL else { return nil }
        return NSImage(contentsOf: url)
    }
}

struct HelpItem: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LocalizedText(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appInk)
            LocalizedText(description)
                .font(.system(size: 14))
                .foregroundStyle(Color.appMuted)
                .lineSpacing(6)
        }
    }
}

struct AboutCard: View {
    @State private var isHovered = false
    
    var body: some View {
        HStack(spacing: 32) {
            AppBrandIcon(size: 90, cornerRadius: 20)
                .shadow(color: Color.appMint.opacity(0.2), radius: 15, x: 0, y: 8)
            
            VStack(alignment: .leading, spacing: 10) {
                Text("FileSyncMonitor")
                    .font(.system(size: 32, weight: .heavy))
                    .foregroundStyle(Color.appInk)
                
                HStack(spacing: 12) {
                    Text("Version 1.2.0 Professional")
                        .font(.system(size: 13, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.appMint.opacity(0.12))
                        .foregroundStyle(Color.appMint)
                        .clipShape(Capsule())
                    
                    Text("Build 20260517.Release")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.appMuted)
                }
                
                HStack(spacing: 4) {
                    Text("© 2026 Antigravity & IMA Design Sync.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                    
                    Text("•")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted.opacity(0.5))
                        .padding(.horizontal, 4)
                        
                    LocalizedText("作者：")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                    Link("LancCJ", destination: URL(string: "https://github.com/LancCJ")!)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.appMint)
                }
                .padding(.top, 8)
            }
            Spacer()
        }
        .padding(36)
        .background(Color.appSurface)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.appLine.opacity(0.6), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 24 : 12, x: 0, y: isHovered ? 12 : 4)
        .scaleEffect(isHovered ? 1.01 : 1.0)
        .onHover { isHovered = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: isHovered)
    }
}
