# FileSyncMonitor

[English](README_en.md) | [中文](README.md)

FileSyncMonitor 是一款跨平台桌面文件变动监控与同步确认工具。当前版本已经从早期 SwiftUI 单端实现升级为 **Tauri 2 + Rust 后端 + 原生 HTML/CSS/JS 前端** 的双端架构，可面向 macOS 与 Windows 扩展。

它可以监控指定目录的新增、修改、删除、重命名事件，将记录保存到本地 SQLite，并通过主窗口、系统托盘和同步任务提醒用户处理待同步文件。应用还集成了基于扫码登录的腾讯 IMA 知识库同步能力，支持本地到云端、云端到本地以及双向同步。

## 界面预览

### 核心看板与同步流

| 初始化界面 | 微信扫码 |
| --- | --- |
| ![初始化界面](docs/screenshot/初始化界面.png) | ![微信扫码](docs/screenshot/微信扫码.png) |

| 首页 | 待同步 |
| --- | --- |
| ![首页](docs/screenshot/首页.png) | ![待同步](docs/screenshot/待同步界面.png) |

### 记录明细与统计分析

| 全部记录 (同步历史) | 报告 (深色风格) |
| --- | --- |
| ![全部记录](docs/screenshot/同步历史界面.png) | ![报告](docs/screenshot/深色风格.png) |

### 系统设置与同步规则

| 设置 | 规则与云端配置 |
| --- | --- |
| ![设置](docs/screenshot/设置界面.png) | ![设置2](docs/screenshot/配置监听目录.png) |

### 新手指引与帮助关于

| 帮助与关于 | 新手指引 | 功能指南 |
| --- | --- | --- |
| ![帮助与关于](docs/screenshot/帮助与关于.png) | ![引导1](docs/screenshot/新手指引.png) | ![引导2](docs/screenshot/功能指南.png) |

## 功能特性

- **跨平台桌面架构**：Tauri 2 负责桌面壳、系统托盘、窗口、打包与前后端 IPC。
- **Rust 文件监控核心**：使用 `notify` 递归监控目录，支持 2 秒防抖与事件合并。
- **本地 SQLite 存储**：文件事件和应用配置写入本机 SQLite 数据库。
- **事件记录**：记录路径、旧路径、事件类型、时间、同步状态、目录标记和远端 ID。
- **待同步处理**：新变动默认进入待同步，可逐条、按目录或批量标记完成/同步。
- **手动/自动同步**：手动同步由用户触发；自动同步在检测到变动后尝试执行绑定目录同步。
- **IMA 知识库同步**：支持微信扫码登录、知识库列表、目录绑定、文件上传、云端拉取、文件夹创建、重命名和删除接口适配。
- **云端路径映射**：本地监控目录可绑定到指定 IMA 知识库，本地子目录会映射到云端文件夹。
- **忽略规则**：默认过滤系统文件、临时文件、构建目录、缓存目录，并支持自定义文件名、后缀和目录名。
- **系统托盘**：提供打开主窗口、立即同步所有目录、退出应用入口。
- **请求日志**：最近 IMA HTTP 请求和响应保存在内存中，便于排查接口、凭据和网络问题。
- **CSV/JSON 导出**：前端可将已同步历史记录导出为 CSV 或 JSON。
- **双语界面**：内置简体中文和英文界面文案。

## 技术架构

```text
                    ┌──────────────────────────────────────┐
                    │ desktop-portal Web UI                │
                    │ HTML / CSS / Vanilla JS              │
                    │ state, rendering, settings, i18n     │
                    └──────────────────┬───────────────────┘
                                       │ Tauri invoke/listen
                    ┌──────────────────▼───────────────────┐
                    │ sync-kernel Rust Backend              │
                    │ commands, SQLite, notify, tray, IMA   │
                    └──────┬────────────┬────────────┬──────┘
                           │            │            │
                     SQLite DB     OS file events   IMA Web APIs
```

### 前端

- `desktop-portal/index.html`：单页应用结构。
- `desktop-portal/main.js`：应用状态、Tauri command 调用、事件监听、渲染逻辑。
- `desktop-portal/styles.css`：桌面 UI 样式、主题变量和布局。
- `desktop-portal/i18n.js`：英文翻译字典。

### 后端

- `sync-kernel/src/lib.rs`：Tauri 初始化、命令注册、同步编排、登录窗口、静默刷新。
- `sync-kernel/src/db.rs`：SQLite 表结构、事件和配置 CRUD。
- `sync-kernel/src/monitor.rs`：目录监听、忽略规则、2 秒防抖合并、事件入库。
- `sync-kernel/src/ima_sync.rs`：IMA 接口客户端、知识库、上传下载、文件夹、删除、重命名。
- `sync-kernel/src/credentials.rs`：IMA 凭据读取、保存和清除。
- `sync-kernel/src/tray.rs`：系统托盘菜单和点击行为。

## 快速开始

### 环境要求

- Node.js 18+
- Rust stable
- Tauri 2 支持的桌面环境
- macOS 或 Windows

### 安装依赖

```bash
npm install
```

### 开发运行

```bash
npm run dev
```

该命令会进入 `sync-kernel` 并启动 `tauri dev`。

### 构建应用

```bash
npm run build
```

### 检查 Rust 后端

```bash
cd sync-kernel
cargo check
```

## GitHub 自动化打包

仓库内置 GitHub Actions workflow：

```text
.github/workflows/release-tauri.yml
```

触发方式：

- 推送版本 tag，例如 `v1.2.0`。
- 在 GitHub Actions 页面手动运行 `Release Tauri App`。

构建目标：

- macOS Apple Silicon：`aarch64-apple-darwin`
- macOS Intel：`x86_64-apple-darwin`
- Windows x64

workflow 会使用 Tauri 官方 `tauri-apps/tauri-action` 构建安装包，并创建/更新 GitHub Release 草稿。发布前可在 GitHub Release 页面检查产物和说明后再正式发布。

示例：

```bash
git tag v1.2.0
git push origin v1.2.0
```

## 数据与配置

- 文件事件保存在 Tauri app data 目录下的 SQLite 数据库 `file_sync_monitor.db`。
- 配置写入 SQLite `app_config` 表，部分前端偏好也会镜像在 `localStorage`。
- IMA 凭据当前保存为 Tauri app data 目录下的 `ima_credentials.json`，并会尝试迁移旧版临时目录凭据文件。
- HTTP 请求日志只保存在内存中，最多保留最近 100 条。
- 导出文件由浏览器前端生成下载。

## 事件处理流程

1. 前端读取已保存的监控目录。
2. 前端调用 `start_file_monitor`。
3. Rust 后端使用 `notify` 递归监听目录。
4. 原始事件先经过忽略规则过滤。
5. 事件进入 2 秒防抖合并窗口。
6. 合并后的事件写入 SQLite。
7. 后端通过 `file-change-events` 通知前端刷新。
8. 前端更新首页、待同步、全部记录和详情面板。

## 同步处理流程

1. 用户为监控目录绑定 IMA 知识库。
2. 用户触发手动同步，或自动同步条件满足。
3. 后端暂停文件监听，避免同步写入触发反馈循环。
4. 拉取阶段读取云端知识库文件树，创建本地目录并下载文件。
5. 上传阶段扫描本地待同步事件，创建云端文件夹或上传文件。
6. 成功后记录 `remote_id` 并标记为已同步。
7. 后端恢复文件监听并通知前端同步进度。

## 忽略规则

默认忽略项包括：

- 文件名：`.DS_Store`、`Icon\r`、`.localized`、`Thumbs.db`、`desktop.ini`
- 临时文件前缀：`~$`、`._`、`~wrl`、`~df`、`~rf`
- 临时后缀：`asd`、`lck`、`lock`、`tmp`、`temp`、`swp`、`swo`、`part`、`download`、`crdownload`
- 系统目录：`.Trashes`、`.Spotlight-V100`、`.fseventsd`、`.TemporaryItems`
- 开发目录：`.git`、`.svn`、`.hg`、`node_modules`、`.next`、`.nuxt`、`dist`、`build`、`.build`、`DerivedData`
- IDE 与缓存目录：`.idea`、`.vscode`、`.swiftpm`、`.cache`

设置页可以开启/关闭默认规则，并自定义忽略文件名、扩展名和目录名。

## IMA 云端同步

应用通过内嵌 Tauri WebView 打开腾讯 IMA 登录页，并注入登录响应捕获逻辑来保存必要凭据。同步接口基于 IMA Web/H5 请求适配，支持：

- 获取用户信息和空间容量。
- 获取知识库列表。
- 获取知识库文件树。
- 创建云端文件夹。
- 上传本地文件到知识库目录。
- 下载云端文件或笔记内容到本地。
- 尝试远端重命名和删除。
- Token 失效时尝试静默刷新。

> IMA 云端功能依赖非官方接口，接口参数和行为可能随服务端变化而失效。抓包资料整理见 [docs/IMA抓包接口总结.md](docs/IMA抓包接口总结.md)。

## 项目结构

```text
.
├── package.json
├── package-lock.json
├── desktop-portal/
│   ├── index.html
│   ├── main.js
│   ├── styles.css
│   ├── i18n.js
│   └── assets/
├── sync-kernel/
│   ├── Cargo.toml
│   ├── Cargo.lock
│   ├── tauri.conf.json
│   ├── build.rs
│   ├── capabilities/
│   ├── permissions/
│   ├── icons/
│   └── src/
│       ├── main.rs
│       ├── lib.rs
│       ├── db.rs
│       ├── monitor.rs
│       ├── ima_sync.rs
│       ├── credentials.rs
│       └── tray.rs
├── docs/
└── scripts/
```

## 已知限制

- 当前没有自动化测试覆盖，发布前建议结合真实目录和真实知识库手动验证。
- IMA 同步基于非官方接口，稳定性取决于腾讯服务端行为。
- 凭据当前为本地 JSON 文件保存，尚未切换到跨平台 Keyring/系统凭据管理器。
- 系统托盘暂未显示动态待同步数字角标。
- 事件只记录文件系统变动，不做文件内容 diff。
- `notify` 和底层系统事件可能合并高频变动，最终事件粒度受系统行为影响。
- 已入库的历史记录不会因后续新增忽略规则而自动删除。

## 捐赠与支持

FileSyncMonitor 是一款开源工具。如果它为你节省了时间，欢迎通过扫码捐赠支持后续维护。

| 微信捐赠 | 支付宝捐赠 |
| --- | --- |
| <img src="docs/pay/wechat.jpg" width="260" alt="微信" /> | <img src="docs/pay/alipay.jpg" width="260" alt="支付宝" /> |

捐赠完全自愿，不影响任何功能使用。

## 免责声明

本软件及源码仅供学习、研究和个人技术交流使用。腾讯 IMA 云端同步功能基于非官方接口适配，软件作者与腾讯控股有限公司或其关联公司无任何关联。接口可能随时失效，使用者需自行承担账号、数据、接口变化和法律合规风险。

软件按“原样”提供，不承诺任何明示或暗示担保。因使用本软件或云端功能产生的任何直接或间接损失，作者不承担责任。

## 开源协议

本项目采用 [GPL-3.0](LICENSE) 协议开源。
