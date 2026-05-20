# FileSyncMonitor

[English](README_en.md) | [中文](README.md)
FileSyncMonitor 是一款 macOS 文件变动监控与同步确认工具。它可以监控指定目录的文件变化，记录新增、修改、删除、重命名事件，并通过主窗口、菜单栏角标和系统通知提醒用户处理待同步文件。

当前版本使用 SwiftUI + SwiftData 构建，底层监控基于 macOS FSEvents，支持本地报告导出、手动/自动同步、开机启动、忽略规则、引导式新手教程，以及基于扫码登录的腾讯 IMA 知识库同步。

## 🖥️ 界面预览

### 📊 核心看板与同步流
| 首页 (Dashboard) | 待同步 (Pending Sync) |
| --- | --- |
| ![首页](docs/screenshot/首页.png) | ![待同步](docs/screenshot/待同步.png) |

### 📈 记录明细与统计分析
| 全部记录 (All Records) | 统计报告 (Reports) |
| --- | --- |
| ![全部记录](docs/screenshot/全部记录.png) | ![报告](docs/screenshot/报告.png) |

### ⚙️ 系统设置与同步规则
| 常规设置 (Settings) | 规则与云端配置 (Settings 2) |
| --- | --- |
| ![设置](docs/screenshot/设置.png) | ![设置2](docs/screenshot/设置2.png) |

### ❓ 新手指引与帮助关于
| 帮助与关于 (FAQ & About) | 新手指引 - 第一步 (Onboarding 1) | 新手指引 - 第二步 (Onboarding 2) |
| --- | --- | --- |
| ![帮助与关于](docs/screenshot/帮助与关于.png) | ![引导1](docs/screenshot/引导1.png) | ![引导2](docs/screenshot/引导2.png) |

## 功能特性

- **目录监控**：支持添加多个目录，递归监控文件和文件夹变动，并保留本地相对路径层级。
- **事件记录**：记录路径、类型、时间、同步状态等信息，并持久化到本地 SwiftData。
- **待同步确认**：新事件默认进入待同步状态，可逐条或批量标记完成。
- **手动/自动同步**：默认手动同步；开启自动同步后，稳定等待一段时间再上传，避免正在编辑的文件被重复处理。
- **云端路径映射**：每个监控目录可以绑定一个 IMA 知识库，本地子目录会按层级映射到云端文件夹。
- **云端反向同步**：支持从 IMA 读取创建、更新、删除、重命名等变动，并同步回本地。
- **菜单栏入口**：常驻菜单栏，显示待同步数量，并提供快速打开和退出入口。
- **报告导出**：按时间范围统计记录，支持导出 CSV 和 JSON。
- **IMA 云端集成**：支持微信扫码登录腾讯 IMA，凭据保存到系统 Keychain，可上传到指定知识库。
- **忽略规则**：默认过滤 `.DS_Store`、临时文件、系统目录、构建缓存等噪声文件，也支持在设置页自定义文件名、后缀和目录名。
- **帮助与新手引导**：内置功能说明、同步逻辑表、IMA API Key 获取步骤和一次性新手引导。
- **现代桌面界面**：采用 FileSync 首页、极窄图标栏、二级列表侧栏和浅色氛围背景。

## 系统要求

- macOS 14.0 Sonoma 或更高版本
- Swift 5.9+
- Xcode 15+ 或 Swift Package Manager

## 快速开始

```bash
swift build
swift run
```

运行后：

1. 打开主窗口或菜单栏应用。
2. 在首页或设置页添加需要监控的目录。
3. 按需在设置页登录 IMA，并为监控目录选择知识库。
4. 修改、创建、删除或重命名目录中的文件。
5. 在“待同步”页面确认事件，并按需标记完成、同步到 IMA 或导出记录。

## 开发命令

```bash
# 调试构建
swift build

# 运行应用
swift run

# 运行测试
swift test

# 发布构建
swift build -c release
```

> 当前测试目标已配置，但项目暂未补充自动化测试用例。

## 忽略规则

忽略规则在事件入库前执行。被忽略的文件不会生成记录、不会触发通知，也不会增加菜单栏角标。

默认忽略项包括：

- 文件名：`.DS_Store`、`Icon\r`、`.localized`、`Thumbs.db`、`desktop.ini`
- 临时文件：`~$*`、`.tmp`、`.temp`、`.swp`、`.swo`、`.part`、`.download`、`.crdownload`
- 系统目录：`.Trashes`、`.Spotlight-V100`、`.fseventsd`、`.TemporaryItems`
- 开发目录：`.git`、`.svn`、`.hg`、`node_modules`、`.next`、`.nuxt`、`dist`、`build`、`.build`、`DerivedData`
- IDE 与缓存目录：`.idea`、`.vscode`、`.swiftpm`、`.cache`

可以在“设置 > 忽略规则”中：

- 开启或关闭默认忽略规则。
- 添加自定义忽略文件名，例如 `debug.log`。
- 添加自定义忽略后缀，例如 `.log`、`.tmp`。
- 添加自定义忽略目录名，例如 `node_modules`、`DerivedData`。
- 恢复默认配置。

## IMA 云端同步使用

在“设置 > IMA 云端”中点击**微信登录**，系统会弹出官方登录扫码窗口。扫码登录成功后，应用会把必要登录凭据保存到 macOS Keychain，并在后续同步请求中自动使用。

- 测试云端连接与存储配额。
- 在设置页中为各个监控目录关联指定 IMA 知识库。
- 手动同步时，用户在详情页或首页主动触发上传。
- 自动同步时，应用会等待文件稳定后再上传，减少 Word、Excel 等应用产生的临时文件干扰。
- 新增或修改文件会上传到对应云端目录；遇到同名文件时，使用带时间戳的文件名保留历史版本。
- 云端删除、重命名和文件夹层级变动会在拉取同步时映射回本地。

> IMA 云端功能依赖非官方接口，接口参数和行为可能随服务端变化而失效。项目中的抓包资料已经整理为脱敏文档：[docs/IMA抓包接口总结.md](docs/IMA抓包接口总结.md)，原始请求响应文件不再提交到仓库。

## 项目结构

```text
.
├── Package.swift
├── Sources/FileSyncMonitor
│   ├── FileSyncMonitorApp.swift
│   ├── Models
│   │   └── FileEvent.swift
│   ├── Services
│   │   ├── FileMonitorService.swift
│   │   ├── PersistenceController.swift
│   │   ├── NotificationManager.swift
│   │   ├── ExportService.swift
│   │   ├── IMASyncService.swift
│   │   ├── IMACredentialsManager.swift
│   │   ├── IMALogService.swift
│   │   └── KeychainHelper.swift
│   ├── UI
│   │   ├── MainView.swift
│   │   ├── SettingsView.swift
│   │   ├── ReportsView.swift
│   │   ├── HelpView.swift
│   │   ├── IMALoginWebView.swift
│   │   ├── MenuBarManager.swift
│   │   └── Theme.swift
│   └── Resources
│       └── Localizable.xcstrings
├── Tests
└── docs
```

## 数据与隐私

- 文件事件记录保存在本机 SwiftData/SQLite 数据库中。
- IMA 登录凭据保存在系统 Keychain；本仓库不保存真实 token、cookie、用户 ID 或抓包原文。
- 应用不会自动同步文件内容，除非用户主动触发同步或开启自动同步。
- 导出文件由用户通过保存面板选择位置。
- 监控目录权限通过 Security-Scoped Bookmarks 持久化。
- 原始抓包目录、临时日志、`.DS_Store`、调试脚本等已加入 `.gitignore`，避免误提交无关文件或敏感材料。

## 已知限制

- 当前不做文件内容 diff，只记录文件系统事件。
- FSEvents 会合并短时间内的高频事件，事件粒度取决于系统回调。
- 已入库的历史记录不会因后续新增忽略规则而自动删除。
- IMA 云端同步基于非官方接口，若服务端接口调整，需要重新适配。
- 当前自动化测试覆盖有限，发布前仍建议结合真实目录和 IMA 知识库做手动验证。

## 💖 捐赠与支持

FileSyncMonitor 是一款完全开源且自愿使用的工具。如果它为您节省了时间，提升了工作效率，欢迎通过扫码进行捐赠支持，您的支持将是维护本项目持续更新的最佳动力！

**⚠️ 捐赠前必读（免责声明补充）：**
- 捐赠完全基于无偿赞助和自愿赠予性质，用于支持作者学习和进行开源软件维护。
- **捐赠行为不构成任何买卖、雇佣、代理或服务契约关系**。
- 请在充分理解下方 [⚠️ 免责声明](#-免责声明) 的前提下进行捐赠。即使您进行了捐赠，也无法免除您使用非官方接口时自身所需承担的法律与封号风险。

| 微信捐赠 (WeChat Pay) | 支付宝捐赠 (Alipay) |
| --- | --- |
| <img src="docs/pay/wechat.jpg" width="260" alt="微信" /> | <img src="docs/pay/alipay.jpg" width="260" alt="支付宝" /> |

> 💡 捐赠完全自愿，所有功能均无限制提供。感谢您的支持！

## ⚠️ 免责声明 (Disclaimer)

**请仔细阅读以下条款，使用本软件即代表您同意并接受本声明的所有内容：**

1. **学习与交流用途**：本软件（FileSyncMonitor）及其全部源代码仅供**学术研究与个人技术学习交流**之用，严禁将本软件用于任何商业用途或非法活动。
2. **非官方接口声明**：本软件集成的腾讯 IMA 云端同步功能，其底层接口是通过**非官方抓包/反向工程**分析而来的。软件作者与腾讯控股有限公司（或其任何关联公司）无任何关联。接口可能会因为服务提供商的更新调整而随时失效或报错。
3. **法律风险与责任自负**：
   - 抓包接口的使用存在一定的法律和封号风险。用户在使用云端同步服务时，需自行承担由于使用非官方接口可能导致的账号封禁、数据丢失、网络拥堵等一切后果。
   - 软件作者不为因使用本软件或其云端功能而导致的任何直接、间接、附带或惩罚性损害（包括但不限于商业利润损失、数据丢失、商誉损害等）承担任何法律责任。
4. **关于捐赠**：
   - 本软件提供的“捐赠与支持”通道完全属于**无偿赞助和赠予性质**，用于支持作者学习和进行开源软件维护。
   - **捐赠行为不构成任何买卖、雇佣、代理或服务契约关系**。即使进行了捐赠，也绝对无法免除用户自身的法律风险，亦不代表作者会对由于本软件接口引起的任何法律纠纷、知识产权问题或数据纠纷承担连带责任。
5. **无担保声明**：本软件按“原样”（AS IS）提供，不提供任何明示或暗示的担保，包括但不限于对适销性、特定用途适用性和非侵权性的担保。

## 📄 开源协议 (License)

本项目采用 [GPL-3.0](LICENSE) 协议开源。详细内容请参阅 `LICENSE` 文件。
