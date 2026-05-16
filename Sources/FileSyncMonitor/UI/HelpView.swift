import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 48) {
                // Hero Header
                VStack(alignment: .leading, spacing: 16) {
                    Text("帮助与关于")
                        .font(.system(size: 40, weight: .black))
                        .foregroundStyle(Color.appInk)
                    
                    Text("解锁 FileSyncMonitor 的全部潜力，让您的工作流与 IMA 云端无缝合一。")
                        .font(.system(size: 16))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.top, 72)

                // 1. Intelligent Monitoring
                VStack(alignment: .leading, spacing: 24) {
                    HelpImageCard(imagePath: "/Users/chenjian/.gemini/antigravity/brain/7a7dc5fc-3d78-42bb-8607-24d828caf4b4/monitor_concept_1778914952955.png")
                    
                    HelpSection(title: "实时智能监控", icon: "bolt.shield.fill", color: .appAmber) {
                        HelpItem(title: "全天候变动捕获", description: "利用高性能 FSEvents 技术，秒级感知任何文件的新增、修改或重命名。")
                        HelpItem(title: "智能过滤引擎", description: "内置专业级忽略规则，自动屏蔽缓存与系统杂质，让您的监控列表始终保持纯净。")
                    }
                }

                // 2. Bidirectional Cloud Sync
                VStack(alignment: .leading, spacing: 24) {
                    HelpImageCard(imagePath: "/Users/chenjian/.gemini/antigravity/brain/7a7dc5fc-3d78-42bb-8607-24d828caf4b4/sync_concept_1778914940343.png")
                    
                    HelpSection(title: "IMA 双向同步", icon: "arrow.left.arrow.right.circle.fill", color: .appViolet) {
                        HelpItem(title: "双向拉取尝试", description: "点击「从云端拉取更新」，即可智能识别并下载知识库中的新文件到本地。")
                        HelpItem(title: "自动化推送流程", description: "开启自动同步后，应用会在您保存文件 30 秒后自动完成云端备份。")
                    }
                }

                // 3. Interaction Design
                VStack(alignment: .leading, spacing: 24) {
                    HelpImageCard(imagePath: "/Users/chenjian/.gemini/antigravity/brain/7a7dc5fc-3d78-42bb-8607-24d828caf4b4/ux_concept_1778914967694.png")
                    
                    HelpSection(title: "精品化交互体验", icon: "sparkles", color: .appMint) {
                        HelpItem(title: "极致视觉反馈", description: "每一处按钮与卡片都经过精心调校，支持细腻的悬停动效与平滑的状态转换。")
                        HelpItem(title: "秒级记录分析", description: "支持秒级精度的时间轴回溯，并提供专业级 CSV/JSON 报表导出。")
                    }
                }

                // About Section
                VStack(spacing: 32) {
                    Divider()
                    
                    HStack(spacing: 24) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(LinearGradient(colors: [.appMint, .appAccent], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 100, height: 100)
                                .shadow(color: Color.appMint.opacity(0.3), radius: 20, x: 0, y: 10)
                            
                            Text("FSM")
                                .font(.system(size: 32, weight: .black))
                                .foregroundStyle(.white)
                        }
                        
                        VStack(alignment: .leading, spacing: 6) {
                            Text("FileSyncMonitor")
                                .font(.system(size: 24, weight: .bold))
                                .foregroundStyle(Color.appInk)
                            
                            Text("Version 1.1.0 Professional")
                                .font(.system(size: 14, weight: .medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.appMint.opacity(0.1))
                                .foregroundStyle(Color.appMint)
                                .clipShape(Capsule())
                            
                            Text("Build 20260516.Release")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appMuted)
                            
                            Text("© 2026 Antigravity & IMA Design Sync.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appMuted.opacity(0.8))
                        }
                        Spacer()
                    }
                }
                .padding(.top, 24)
            }
            .frame(width: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.bottom, 120)
            .frame(maxWidth: .infinity)
        }
        .background(IMAClientSurfaceBackground())
    }
}

struct HelpImageCard: View {
    let imagePath: String
    @State private var isHovered = false
    
    var body: some View {
        Group {
            if let nsImage = NSImage(contentsOfFile: imagePath) {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .stroke(Color.appLine.opacity(0.5), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(isHovered ? 0.15 : 0.08), radius: isHovered ? 30 : 20, x: 0, y: 15)
                    .scaleEffect(isHovered ? 1.01 : 1)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color.appControl)
                    .frame(height: 320)
            }
        }
        .onHover { isHovered = $0 }
        .animation(.snappy, value: isHovered)
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.12))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(color)
                }
                Text(title)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Color.appInk)
            }
            
            VStack(alignment: .leading, spacing: 24) {
                content
            }
            .padding(.leading, 44)
        }
    }
}

struct HelpItem: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(Color.appInk)
            Text(description)
                .font(.system(size: 14))
                .foregroundStyle(Color.appMuted)
                .lineSpacing(6)
        }
    }
}
