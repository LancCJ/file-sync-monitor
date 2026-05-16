import SwiftUI

struct HelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                // Header
                VStack(alignment: .leading, spacing: 12) {
                    Text("帮助与关于")
                        .font(.system(size: 34, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    
                    Text("了解如何高效使用 FileSyncMonitor 监控您的工作流。")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.appMuted)
                }
                .padding(.top, 64)

                // Quick Start Section
                HelpSection(title: "快速上手", icon: "bolt.fill", color: .appAmber) {
                    HelpItem(title: "1. 添加监控目录", description: "在首页或设置中点击「添加目录」，选择您需要监控的文件夹。应用会自动申请必要的访问权限。")
                    HelpItem(title: "2. 捕获变动", description: "当监控目录内的文件发生创建、修改、删除或重命名时，应用会即时记录并发送系统通知。")
                    HelpItem(title: "3. 确认与同步", description: "进入「待同步」页面，查看所有未处理的变动。您可以手动标记为已完成，或一键同步到 IMA 云端。")
                }

                // IMA Cloud Section
                HelpSection(title: "IMA 云端同步", icon: "icloud.fill", color: .appViolet) {
                    HelpItem(title: "配置凭据", description: "在设置中填写您的 IMA Client ID 和 API Key。您可以点击「测试」按钮验证连接是否正常。")
                    HelpItem(title: "一键导入", description: "在记录详情页点击「上传到 IMA」，应用会将文件内容自动同步到您的 IMA 知识库中。")
                }

                // Advanced Features
                HelpSection(title: "高级功能", icon: "sparkles", color: .appMint) {
                    HelpItem(title: "忽略规则", description: "您可以自定义忽略特定的文件后缀、文件名或子目录（如 node_modules），保持记录的纯净。")
                    HelpItem(title: "数据导出", description: "支持将捕获到的记录导出为 CSV 或 JSON 格式，方便进行二次数据分析。")
                }

                // About Section
                VStack(alignment: .leading, spacing: 20) {
                    Divider()
                    
                    HStack(spacing: 20) {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.appSelection)
                            .frame(width: 80, height: 80)
                            .overlay {
                                Text("FSM")
                                    .font(.system(size: 24, weight: .black))
                                    .foregroundStyle(Color.appInk)
                            }
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text("FileSyncMonitor")
                                .font(.system(size: 20, weight: .bold))
                            Text("版本 1.0.0 (Build 100)")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.appMuted)
                            Text("© 2026 Antigravity. All Rights Reserved.")
                                .font(.system(size: 12))
                                .foregroundStyle(Color.appMuted.opacity(0.8))
                        }
                    }
                    .padding(.vertical, 10)
                }
            }
            .frame(width: 720, alignment: .leading)
            .padding(.bottom, 100)
            .frame(maxWidth: .infinity)
        }
        .background(IMAClientSurfaceBackground())
    }
}

struct HelpSection<Content: View>: View {
    let title: String
    let icon: String
    let color: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(color)
                Text(title)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.appInk)
            }
            
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .padding(.leading, 26)
        }
    }
}

struct HelpItem: View {
    let title: String
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.appInk)
            Text(description)
                .font(.system(size: 13))
                .foregroundStyle(Color.appMuted)
                .lineSpacing(4)
        }
    }
}
