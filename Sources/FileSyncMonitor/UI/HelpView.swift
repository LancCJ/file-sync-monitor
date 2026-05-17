import SwiftUI

struct HelpView: View {
    private let categories = HelpContent.categories

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 38) {
                HelpHero()

                VStack(alignment: .leading, spacing: 34) {
                    ForEach(categories) { category in
                        HelpCategorySection(category: category)
                    }
                }

                SyncLogicCard()
                    .padding(.top, 4)

                FAQCard()
                    .padding(.top, 4)

                DonationCard()
                    .padding(.top, 4)

                AboutCard()
                    .padding(.top, 4)
                    .padding(.bottom, 84)
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.horizontal, 44)
            .frame(maxWidth: .infinity)
        }
        .background(IMAClientSurfaceBackground())
    }
}

private struct HelpHero: View {
    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(alignment: .leading, spacing: 14) {
                LocalizedText("帮助与关于")
                    .font(.system(size: 42, weight: .black))
                    .foregroundStyle(Color.appInk)

                LocalizedText("按功能场景查看 FileSyncMonitor 的监控、同步、导出与设置能力。")
                    .font(.system(size: 16))
                    .foregroundStyle(Color.appMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 24)

            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color.appSelection,
                                Color.appSurface,
                                Color(red: 245 / 255, green: 252 / 255, blue: 227 / 255)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.appLine.opacity(0.68), lineWidth: 1)
                    )

                HStack(spacing: 18) {
                    AppBrandIcon(size: 74, cornerRadius: 18)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("FileSyncMonitor")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Color.appInk)
                        LocalizedText("清新、轻量、面向日常同步工作流。")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.appMuted)
                        
                        HStack(spacing: 6) {
                            Text("v1.0.0-beta")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(Color.appMint)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.appMint.opacity(0.12))
                                .cornerRadius(4)
                            
                            Link(destination: URL(string: "https://github.com/LancCJ")!) {
                                HStack(spacing: 3) {
                                    Image(systemName: "person.crop.circle.fill")
                                        .font(.system(size: 10))
                                    Text("@LancCJ")
                                        .font(.system(size: 10, weight: .semibold))
                                }
                                .foregroundStyle(Color.appMuted)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 2)
                    }
                }
                .padding(22)
            }
            .frame(width: 360, height: 132)
        }
        .padding(.top, 64)
    }
}

private struct HelpCategorySection: View {
    let category: HelpCategory

    private var columns: [GridItem] {
        [
            GridItem(.flexible(), spacing: 14),
            GridItem(.flexible(), spacing: 14)
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                HelpCategoryMark(symbol: category.symbol, color: category.color)

                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText(category.title)
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    LocalizedText(category.subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(2)
                }

                Spacer()
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 14) {
                ForEach(category.items) { item in
                    HelpFeaturePoint(item: item, color: category.color)
                }
            }
        }
    }
}

private struct HelpCategoryMark: View {
    let symbol: String
    let color: Color

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(color.opacity(0.12))
                .frame(width: 34, height: 34)
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(color)
        }
    }
}

private struct HelpFeaturePoint: View {
    let item: HelpItemModel
    let color: Color
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            HelpMiniIllustration(symbol: item.symbol, color: color, variant: item.variant)

            VStack(alignment: .leading, spacing: 7) {
                LocalizedText(item.title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(2)

                LocalizedText(item.description)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.appSurface.opacity(0.9))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(isHovered ? color.opacity(0.32) : Color.appLine.opacity(0.66), lineWidth: 1)
                )
        )
        .shadow(color: color.opacity(isHovered ? 0.07 : 0.025), radius: isHovered ? 14 : 8, x: 0, y: isHovered ? 8 : 4)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

private struct HelpMiniIllustration: View {
    let symbol: String
    let color: Color
    let variant: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(0.18),
                            Color.appSelection.opacity(0.72),
                            Color.appSurface.opacity(0.94)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.72), lineWidth: 1)
                )

            decorativeLayer

            Image(systemName: symbol)
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(color)
                .shadow(color: Color.white.opacity(0.8), radius: 3, x: 0, y: 1)
        }
        .frame(width: 72, height: 72)
    }

    @ViewBuilder
    private var decorativeLayer: some View {
        switch variant % 4 {
        case 0:
            VStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(color.opacity(index == 0 ? 0.22 : 0.12))
                        .frame(width: CGFloat(42 - index * 7), height: 5)
                        .offset(x: CGFloat(index * 5 - 6))
                }
            }
            .offset(y: 21)
        case 1:
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(color.opacity(0.16 + Double(index) * 0.04))
                        .frame(width: CGFloat(10 + index * 5), height: CGFloat(10 + index * 5))
                }
            }
            .offset(x: -2, y: 22)
        case 2:
            ZStack {
                Circle()
                    .stroke(color.opacity(0.16), lineWidth: 8)
                    .frame(width: 48, height: 48)
                Circle()
                    .fill(Color.white.opacity(0.74))
                    .frame(width: 12, height: 12)
                    .offset(x: 18, y: -16)
            }
        default:
            VStack(alignment: .leading, spacing: 5) {
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 4) {
                        Circle()
                            .fill(color.opacity(0.24))
                            .frame(width: 5, height: 5)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(0.12))
                            .frame(width: CGFloat(28 + index * 6), height: 4)
                    }
                }
            }
            .offset(y: 22)
        }
    }
}

private struct AboutCard: View {
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 28) {
            AppBrandIcon(size: 86, cornerRadius: 20)

            VStack(alignment: .leading, spacing: 10) {
                Text("FileSyncMonitor")
                    .font(.system(size: 30, weight: .heavy))
                    .foregroundStyle(Color.appInk)

                HStack(spacing: 10) {
                    Text("Version 1.2.0 Open Source")
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

                LocalizedText("本工具用于监控本地文件变动，并辅助同步到 IMA 云端。")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.appMuted)

                HStack(spacing: 6) {
                    Text("© 2026 Antigravity")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted.opacity(0.82))
                    Text("·")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.appMuted.opacity(0.55))
                    Link("LancCJ", destination: URL(string: "https://github.com/LancCJ")!)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.appMint)
                }
            }

            Spacer()
        }
        .padding(28)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.appLine.opacity(0.68), lineWidth: 1)
                )
        )
        .shadow(color: Color.appMint.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 18 : 10, x: 0, y: isHovered ? 10 : 5)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

private struct SyncLogicCard: View {
    private let rows = HelpContent.syncLogicRows
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                HelpCategoryMark(symbol: "arrow.triangle.2.circlepath.circle", color: .appMint)

                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("本地操作同步逻辑")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    LocalizedText("理解每种文件操作会如何进入待同步列表、自动同步和历史记录。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(3)
                }

                Spacer()
            }

            VStack(spacing: 0) {
                SyncLogicHeaderRow()

                ForEach(rows) { row in
                    SyncLogicRowView(row: row)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.appSurface.opacity(0.92))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.appLine.opacity(0.62), lineWidth: 1)
                    )
            )

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.appMint)
                    .padding(.top, 1)
                LocalizedText("忽略规则会先于记录入库执行；被忽略的文件不会产生记录、通知、角标或同步任务。")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.appMuted)
                    .lineSpacing(4)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isHovered ? Color.appMint.opacity(0.32) : Color.appLine.opacity(0.68), lineWidth: 1)
                )
        )
        .shadow(color: Color.appMint.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 18 : 10, x: 0, y: isHovered ? 10 : 5)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

private struct SyncLogicHeaderRow: View {
    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            SyncLogicHeaderCell("本地操作", width: 156)
            SyncLogicHeaderCell("记录类型", width: 112)
            SyncLogicHeaderCell("同步处理", minWidth: 250)
            SyncLogicHeaderCell("用户需要知道", minWidth: 230)
        }
        .padding(.vertical, 12)
        .background(Color.appSelection.opacity(0.5))
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14))
    }
}

private struct SyncLogicHeaderCell: View {
    let title: String
    let width: CGFloat?
    let minWidth: CGFloat?

    init(_ title: String, width: CGFloat? = nil, minWidth: CGFloat? = nil) {
        self.title = title
        self.width = width
        self.minWidth = minWidth
    }

    var body: some View {
        if let width {
            headerText
                .frame(width: width, alignment: .leading)
                .padding(.horizontal, 14)
        } else {
            headerText
                .frame(minWidth: minWidth, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }
    }

    private var headerText: some View {
        LocalizedText(title)
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(Color.appMuted)
    }
}

private struct SyncLogicRowView: View {
    let row: SyncLogicRow

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(row.color.opacity(0.12))
                        .frame(width: 30, height: 30)
                    Image(systemName: row.symbol)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(row.color)
                }

                LocalizedText(row.operation)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.appInk)
                    .lineLimit(2)
            }
            .frame(width: 156, alignment: .leading)
            .padding(.horizontal, 14)

            Text(row.recordType)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.color)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(row.color.opacity(0.1), in: Capsule())
                .frame(width: 112, alignment: .leading)
                .padding(.horizontal, 14)

            LocalizedText(row.syncBehavior)
                .font(.system(size: 13))
                .foregroundStyle(Color.appInk.opacity(0.86))
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 250, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)

            LocalizedText(row.userNote)
                .font(.system(size: 12))
                .foregroundStyle(Color.appMuted)
                .lineSpacing(4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minWidth: 230, maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
        }
        .padding(.vertical, 14)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.appLine.opacity(0.58))
                .frame(height: 1)
                .padding(.leading, 14)
        }
    }
}

private struct DonationCard: View {
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HelpCategoryMark(symbol: "heart.circle", color: .appRose)

                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("支持开源项目")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    LocalizedText("FileSyncMonitor 将以开源方式提供。如果它帮你节省了时间，欢迎扫码捐赠支持后续维护。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .lineLimit(3)
                }

                Spacer()
            }

            HStack(spacing: 18) {
                DonationQRCode(title: "微信捐赠", resourceName: "donation-wechat")
                DonationQRCode(title: "支付宝捐赠", resourceName: "donation-alipay")

                VStack(alignment: .leading, spacing: 10) {
                    LocalizedText("捐赠说明")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    LocalizedText("捐赠完全自愿，不影响任何功能使用。感谢每一份支持，它会用于持续适配 macOS、维护 IMA 同步能力和完善文档。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                        .lineSpacing(5)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 4)

                Spacer(minLength: 0)
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isHovered ? Color.appRose.opacity(0.32) : Color.appLine.opacity(0.68), lineWidth: 1)
                )
        )
        .shadow(color: Color.appRose.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 18 : 10, x: 0, y: isHovered ? 10 : 5)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

private struct DonationQRCode: View {
    let title: String
    let resourceName: String

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.appLine.opacity(0.72), lineWidth: 1)
                    )

                if let image = loadImage() {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "qrcode")
                        .font(.system(size: 54, weight: .medium))
                        .foregroundStyle(Color.appMuted)
                }
            }
            .frame(width: 156, height: 156)

            LocalizedText(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.appInk)
        }
        .frame(width: 176)
    }

    private func loadImage() -> NSImage? {
        guard let url = Bundle.module.url(forResource: resourceName, withExtension: "jpg") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }
}

private enum HelpContent {
    static let syncLogicRows: [SyncLogicRow] = [
        SyncLogicRow(
            operation: "新增文件",
            recordType: "created",
            syncBehavior: "生成一条待同步记录；手动模式等待点击同步，自动模式在文件稳定 30 秒后上传。",
            userNote: "如果新建后又立即删除，应用会抵消这次短暂变动，不再产生待同步事项。",
            symbol: "plus.square",
            color: .appMint
        ),
        SyncLogicRow(
            operation: "修改文件",
            recordType: "modified",
            syncBehavior: "同一路径已有未同步记录时只更新时间，避免反复保存产生多条记录。",
            userNote: "自动同步会在最后一次修改后重新等待 30 秒。",
            symbol: "square.and.pencil",
            color: .appAccent
        ),
        SyncLogicRow(
            operation: "删除文件",
            recordType: "deleted",
            syncBehavior: "删除会生成删除记录；同步时仅在本地标记完成。",
            userNote: "当前 IMA 未开放云端删除接口，云端已有文档需要用户按需手动清理。",
            symbol: "trash",
            color: .appRose
        ),
        SyncLogicRow(
            operation: "重命名文件",
            recordType: "renamed",
            syncBehavior: "已存在文件重命名会生成重命名记录，并在详情里保留原路径。",
            userNote: "如果是刚新建的文件又重命名，应用会合并为最终路径的一条新增记录。",
            symbol: "arrow.left.arrow.right.square",
            color: .appViolet
        ),
        SyncLogicRow(
            operation: "快速新建后删除",
            recordType: "none",
            syncBehavior: "未同步前创建又删除会被视为一次无效临时变动。",
            userNote: "适合过滤编辑器临时文件和误操作，不会增加角标或通知。",
            symbol: "xmark.circle",
            color: .appMuted
        ),
        SyncLogicRow(
            operation: "手动同步",
            recordType: "manual",
            syncBehavior: "点击单条“同步到 IMA”或首页“全部同步”后才上传。",
            userNote: "这是默认模式，适合确认后再同步。",
            symbol: "hand.tap",
            color: .appInk
        ),
        SyncLogicRow(
            operation: "自动同步",
            recordType: "auto",
            syncBehavior: "开启后，文件变动稳定 30 秒再上传到绑定知识库。",
            userNote: "频繁保存会重置等待时间，避免上传半成品。",
            symbol: "bolt.circle",
            color: .appAmber
        )
    ]

    static let categories: [HelpCategory] = [
        HelpCategory(
            title: "监控与过滤",
            subtitle: "从选择目录到过滤噪声文件，保证记录列表干净可用。",
            symbol: "folder.badge.gearshape",
            color: .appMint,
            items: [
                HelpItemModel(title: "添加监控目录", description: "在首页或设置中添加文件夹，应用会保存授权并在下次启动后继续监控。", symbol: "folder.badge.plus", variant: 0),
                HelpItemModel(title: "实时捕获变动", description: "通过 macOS FSEvents 捕获新增、修改、删除和重命名，变动会自动进入记录列表。", symbol: "bolt.shield", variant: 1),
                HelpItemModel(title: "默认忽略规则", description: "默认过滤 .DS_Store、临时文件、系统目录、构建产物和常见缓存目录。", symbol: "line.3.horizontal.decrease.circle", variant: 2),
                HelpItemModel(title: "自定义忽略项", description: "可在设置中维护忽略文件名、后缀和目录名，让监控范围更贴合你的项目。", symbol: "slider.horizontal.3", variant: 3)
            ]
        ),
        HelpCategory(
            title: "记录处理",
            subtitle: "围绕待同步和全部记录进行查看、筛选、确认与清理。",
            symbol: "doc.text.magnifyingglass",
            color: .appAmber,
            items: [
                HelpItemModel(title: "待同步队列", description: "左侧第二个入口集中展示未处理变动，可搜索路径、按类型筛选并批量处理。", symbol: "clock.badge.exclamationmark", variant: 0),
                HelpItemModel(title: "全部记录视图", description: "保留所有已同步和未同步记录，适合回溯历史、查找文件变动轨迹。", symbol: "doc.text", variant: 1),
                HelpItemModel(title: "列表与树状模式", description: "二级侧栏支持列表和树状视图切换，既能快速扫列表，也能按目录结构定位。", symbol: "list.bullet.rectangle", variant: 2),
                HelpItemModel(title: "详情与快捷操作", description: "选中记录后可查看路径、时间、状态，并执行同步、标记完成、Finder 显示或删除记录。", symbol: "cursorarrow.click.2", variant: 3),
                HelpItemModel(title: "批量删除记录", description: "在待同步或全部记录页可清理当前筛选结果，只删除应用内记录，不影响真实文件。", symbol: "trash", variant: 0)
            ]
        ),
        HelpCategory(
            title: "IMA 云端同步",
            subtitle: "支持手动上传、自动上传、知识库绑定和云端拉取。",
            symbol: "icloud.and.arrow.up",
            color: .appViolet,
            items: [
                HelpItemModel(title: "手动同步", description: "默认采用手动模式，点击单条“同步到 IMA”或首页“全部同步”后再上传。", symbol: "hand.tap", variant: 1),
                HelpItemModel(title: "自动同步", description: "开启后，文件稳定 30 秒会自动上传，减少频繁保存造成的重复同步。", symbol: "bolt.circle", variant: 2),
                HelpItemModel(title: "目录绑定知识库", description: "每个监控目录都可以绑定不同 IMA 知识库；不绑定时默认导入为新笔记。", symbol: "books.vertical", variant: 3),
                HelpItemModel(title: "从云端拉取更新", description: "待同步页可从 IMA 拉取云端新增内容，并下载到对应本地目录。", symbol: "arrow.down.circle", variant: 0),
                HelpItemModel(title: "删除事件同步提示", description: "本地删除会在应用内标记已同步；由于 IMA 未开放云端删除 API，云端文档需手动清理。", symbol: "exclamationmark.triangle", variant: 1),
                HelpItemModel(title: "请求日志排查", description: "连接测试和同步请求会记录在 IMA 请求日志中，方便排查凭据、接口和网络问题。", symbol: "list.bullet.rectangle.portrait", variant: 2)
            ]
        ),
        HelpCategory(
            title: "获取 IMA API 凭据",
            subtitle: "完成 Client ID 和 API Key 配置后，才能测试连接、同步文件和读取知识库。",
            symbol: "key.horizontal",
            color: .appMint,
            items: [
                HelpItemModel(title: "打开凭据页面", description: "在浏览器访问 ima.qq.com/agent-interface，并使用你的腾讯 IMA 账号登录。", symbol: "safari", variant: 0),
                HelpItemModel(title: "复制 Client ID", description: "在页面中找到 Client ID，复制后回到本应用的“设置 > 同步”区域粘贴到 Client ID 输入框。", symbol: "number.square", variant: 1),
                HelpItemModel(title: "复制 API Key", description: "继续复制 API Key，粘贴到 API Key 输入框。API Key 属于敏感凭据，请不要发给他人或提交到代码仓库。", symbol: "key", variant: 2),
                HelpItemModel(title: "测试连接", description: "点击“测试连接”。如果连接成功，应用会获取 IMA 知识库列表，并允许你给监控目录绑定目标知识库。", symbol: "checkmark.seal", variant: 3),
                HelpItemModel(title: "凭据失效时重新生成", description: "如果测试失败，请确认账号是否登录正确、凭据是否完整；必要时回到 IMA 页面重新生成或复制新的凭据。", symbol: "arrow.clockwise.circle", variant: 0)
            ]
        ),
        HelpCategory(
            title: "报告、通知与菜单栏",
            subtitle: "把同步状态从主窗口延伸到菜单栏、通知和导出文件。",
            symbol: "chart.bar.doc.horizontal",
            color: .appAccent,
            items: [
                HelpItemModel(title: "统计报告", description: "报告页按今天、近 7 天、近 30 天或全部范围统计记录、待同步和已完成数量。", symbol: "chart.bar", variant: 3),
                HelpItemModel(title: "CSV / JSON 导出", description: "可导出当前记录或报告范围，便于留档、分析或给其他工具继续处理。", symbol: "square.and.arrow.up", variant: 0),
                HelpItemModel(title: "系统通知提醒", description: "新文件变动出现时可发送 macOS 通知，避免待同步事项被遗忘。", symbol: "bell.badge", variant: 1),
                HelpItemModel(title: "菜单栏状态", description: "菜单栏图标会显示待同步数量，可快速打开窗口、标记完成或退出应用。", symbol: "menubar.rectangle", variant: 2)
            ]
        ),
        HelpCategory(
            title: "设置与体验",
            subtitle: "让界面语言、外观与凭据配置保持可控。",
            symbol: "gearshape",
            color: .appRose,
            items: [
                HelpItemModel(title: "多语言界面", description: "支持跟随系统、English、简体中文和繁体中文，切换后主界面和菜单栏同步刷新。", symbol: "globe", variant: 0),
                HelpItemModel(title: "浅色与深色模式", description: "可跟随系统，也可手动选择浅色或深色，整体保持清新简约风格。", symbol: "circle.lefthalf.filled", variant: 1),
                HelpItemModel(title: "凭据输入与复制粘贴", description: "Client ID 和 API Key 支持键盘输入、复制、粘贴与隐藏显示。", symbol: "key", variant: 2)
            ]
        )
    ]
}

private struct HelpCategory: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String
    let symbol: String
    let color: Color
    let items: [HelpItemModel]
}

private struct HelpItemModel: Identifiable {
    let id = UUID()
    let title: String
    let description: String
    let symbol: String
    let variant: Int
}

private struct SyncLogicRow: Identifiable {
    let id = UUID()
    let operation: String
    let recordType: String
    let syncBehavior: String
    let userNote: String
    let symbol: String
    let color: Color
}

private struct FAQCard: View {
    @State private var isHovered = false
    @State private var expandedItem: Int? = 0 // 默认展开第一项（Gatekeeper 安装报错）
    
    private let faqs: [FAQItem] = [
        FAQItem(
            question: "打开时提示“Apple无法验证是否包含恶意软件”如何解决？",
            answer: "这是 macOS 针对非 App Store 或未签名开发者程序的 Gatekeeper 安全防护机制。请使用以下任一方式解锁：\n\n1. 【右键打开 - 最常用】：在「应用程序」文件夹中找到 FileSyncMonitor，按住 Control 键点按（或右键点按）应用图标，选择「打开」，在弹出的对话框中点击「仍要打开」。此操作只需进行一次，以后双击便可秒开。\n2. 【系统设置放行】：前往「系统设置 -> 隐私与安全 -> 安全性」，点击底部的「仍要打开」并输入系统开机密码放行。\n3. 【终端指令秒解】：打开「终端」执行 `xattr -cr /Applications/FileSyncMonitor.app` 即可彻底抹除系统内置的隔离标志，双击无感秒开。",
            symbol: "shield.dashed",
            color: .appRose
        ),
        FAQItem(
            question: "为什么本地删除的文件无法同步删除 IMA 云端的知识库？",
            answer: "目前腾讯 IMA OpenAPI 尚未开放「云端移出或删除 Wiki」的接口。为了不阻塞你的工作流，应用在检测到本地删除后会生成 deleted 类型的记录，并在同步时仅在本地标记为「已同步」。云端已导入的对应文档需要你手动登录 IMA 客户端进行清理。",
            symbol: "trash.slash",
            color: .appViolet
        ),
        FAQItem(
            question: "自动同步是如何实现防抖并避免频繁重复上传的？",
            answer: "本应用内置了「延迟稳定捕获」机制。为了防止你的编辑器在频繁保存或自动保存时产生大量冗余的上传任务，变动发生后应用会开始 30 秒的稳定静默计时。若你在 30 秒内再次修改该文件，计时将自动重置，直到文件连续 30 秒不再变动时才发起安全上传。",
            symbol: "clock.arrow.circlepath",
            color: .appMint
        ),
        FAQItem(
            question: "忽略规则可以支持哪些过滤方式？怎么写？",
            answer: "忽略规则会先于记录入库前执行。你可以在「设置 -> 忽略规则」中添加三种过滤对象：\n1. 【全名过滤】：输入特定文件名（例如 config.json），完全匹配时自动跳过监控。\n2. 【后缀过滤】：输入以点开头的扩展名（例如 .tmp），所有临时文件均会被自动丢弃。\n3. 【目录过滤】：输入路径子项（例如 node_modules 或 build），匹配该文件夹名下的所有变动均被直接屏蔽。",
            symbol: "line.3.horizontal.decrease.circle",
            color: .appAmber
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                HelpCategoryMark(symbol: "questionmark.circle", color: .appAccent)

                VStack(alignment: .leading, spacing: 4) {
                    LocalizedText("常见问题与解答 (FAQ)")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.appInk)
                    LocalizedText("解决安装警告、了解删除同步限制与自动稳定同步细节。")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appMuted)
                }

                Spacer()
            }

            VStack(spacing: 12) {
                ForEach(0..<faqs.count, id: \.self) { index in
                    let item = faqs[index]
                    FAQRowView(
                        item: item,
                        isExpanded: expandedItem == index,
                        onTap: {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                expandedItem = expandedItem == index ? nil : index
                            }
                        }
                    )
                }
            }
        }
        .padding(22)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.appSurface.opacity(0.94))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(isHovered ? Color.appAccent.opacity(0.32) : Color.appLine.opacity(0.68), lineWidth: 1)
                )
        )
        .shadow(color: Color.appAccent.opacity(isHovered ? 0.08 : 0.03), radius: isHovered ? 18 : 10, x: 0, y: isHovered ? 10 : 5)
        .onHover { isHovered = $0 }
        .animation(.snappy(duration: 0.18), value: isHovered)
    }
}

private struct FAQItem {
    let question: String
    let answer: String
    let symbol: String
    let color: Color
}

private struct FAQRowView: View {
    let item: FAQItem
    let isExpanded: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(item.color.opacity(0.1))
                            .frame(width: 28, height: 28)
                        Image(systemName: item.symbol)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(item.color)
                    }

                    LocalizedText(item.question)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.appInk)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    Spacer()

                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.appMuted.opacity(0.8))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                        .background(Color.appLine.opacity(0.5))
                        .padding(.horizontal, 16)
                    
                    LocalizedText(item.answer)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.appInk.opacity(0.8))
                        .lineSpacing(6)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                        .background(Color.appSelection.opacity(0.12))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovered ? Color.appSelection.opacity(0.24) : Color.appSurface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isExpanded ? item.color.opacity(0.22) : Color.appLine.opacity(0.48), lineWidth: 1)
        )
    }
}
