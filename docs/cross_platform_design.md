# FileSyncMonitor 跨平台（Windows & macOS）重构设计白皮书

本设计白皮书旨在为 `FileSyncMonitor` 从单端 macOS 纯 Swift 应用改造为 **Windows & macOS 双端跨平台桌面应用**提供高精度的技术重构蓝图。

本方案选择 **Tauri 2.0 (Rust Backend + Vanilla HTML/JS/CSS Premium Frontend)** 作为核心架构，以确保最小的系统开销（30~50MB 内存占用）以及极致的系统托盘交互体验。

---

## 目录
1. [系统总体架构](#1-系统总体架构)
2. [数据库与存储层重构（SwiftData -> SQLite）](#2-数据库与存储层重构)
3. [高性能双端文件监控引擎（FSEvents -> Rust Notify）](#3-高性能双端文件监控引擎)
4. [系统托盘与全局状态（NSStatusItem -> Tauri Tray）](#4-系统托盘与全局状态)
5. [IMA 云端接口与安全存储（Keychain -> Keyring）](#5-ima-云端接口与安全存储)
6. [前端视觉与交互复刻（SwiftUI -> Glassmorphism Web UI）](#6-前端视觉与交互复刻)
7. [双端自动化打包与分发管道](#7-双端自动化打包与分发管道)

---

## 1. 系统总体架构

重构后的系统分为**安全沙盒前端（UI）**与**高性能 Rust 核心（后端）**。两端通过 Tauri 的安全 IPC 机制（Commands & Events）进行异步双向通信。

```
                    +--------------------------------------------+
                    |           Web UI Frontend (TypeScript)     |
                    |   - Sidebar & Navigation (HTML5)           |
                    |   - Event List Tree (Canvas/DOM)           |
                    |   - Settings & Custom Glassmorphism Alerts |
                    +----------------------+---------------------+
                                           ^
                                           |  Tauri IPC (Commands & Events)
                                           v
  +----------------------------------------+---------------------------------------+
  |                               Rust Core Backend                                |
  |                                                                                |
  |  +--------------------+  +--------------------+  +--------------------------+  |
  |  |  System Tray Mgr   |  |   IMA Sync Agent   |  |   File Watcher (notify)  |  |
  |  |  - Custom Icons    |  |   - reqwest        |  |   - Thread-safe Debouncer|  |
  |  |  - Dynamic Badges  |  |   - Chunk Upload   |  |   - Coalescing (2.0s)    |  |
  |  +---------+----------+  +---------+----------+  +------------+-------------+  |
  |            |                       |                          |                |
  +------------v-----------------------v--------------------------v----------------+
               |                       |                          |
  +------------v-----------------------v--------------------------v----------------+
  |                               OS Native Layer                                  |
  |  +--------------------+  +--------------------+  +--------------------------+  |
  |  |      System        |  |  Secure Storage    |  |      OS File Events      |  |
  |  |  - macOS MenuBar   |  |  - macOS Keychain  |  |  - macOS FSEvents        |  |
  |  |  - Windows Tray    |  |  - Win Credential  |  |  - Win ReadDirectory     |  |
  |  +--------------------+  +--------------------+  +--------------------------+  |
  +--------------------------------------------------------------------------------+
```

---

## 2. 数据库与存储层重构

将基于 `@Model` 的 SwiftData ORM 彻底重构为跨平台的轻量级 **SQLite3** 引擎（在 Rust 中使用 `sqlx` 或 `rusqlite`）。

### 2.1 数据库结构 (Schema)
在 Rust 中创建表结构定义，保持事件核心记录完全与原有系统对齐：

```sql
-- 文件变更事件表
CREATE TABLE IF NOT EXISTS file_events (
    id TEXT PRIMARY KEY NOT NULL,
    path TEXT NOT NULL,
    old_path TEXT,
    type TEXT NOT NULL,            -- 'created' | 'modified' | 'deleted' | 'renamed'
    timestamp REAL NOT NULL,        -- Unix 时间戳 (秒)
    is_synced INTEGER NOT NULL DEFAULT 0,
    has_notified INTEGER NOT NULL DEFAULT 0
);

-- 应用配置表（代替 UserDefaults）
CREATE TABLE IF NOT EXISTS app_config (
    key TEXT PRIMARY KEY NOT NULL,
    value TEXT NOT NULL
);
```

### 2.2 Rust 数据结构与映射
```rust
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FileEvent {
    pub id: String,
    pub path: String,
    pub old_path: Option<String>,
    pub r#type: String, // created, modified, deleted, renamed
    pub timestamp: f64,
    pub is_synced: bool,
    pub has_notified: bool,
}
```

---

## 3. 高性能双端文件监控引擎

将基于 macOS 专用 C API `FSEventStream` 的 `FileMonitorService.swift`，使用 Rust 的跨平台 **`notify`** 库进行全面重写。

### 3.1 核心特点
1. **跨平台适配**：在 macOS 上自动使用底层 `FSEvents` API，在 Windows 上自动使用 `ReadDirectoryChangesW` 异步系统调用，保证无缝兼容。
2. **2.0s 延迟防抖合并 (Coalescing & Debouncing)**：
   使用 Rust 的 `notify-debouncer-mini` 或者在后台线程通过 `tokio` 的异步信道（Channels）进行多事件缓冲与去重。

### 3.2 Rust 监控实现框架 (文件监控后台服务)
```rust
use notify_debouncer_mini::{new_debouncer, notify::*, Debouncer, DebouncedEvent};
use std::{sync::mpsc::channel, time::Duration, path::Path};

pub struct CrossPlatformFileMonitor {
    debouncer: Option<Debouncer<RecommendedWatcher>>,
}

impl CrossPlatformFileMonitor {
    pub fn new() -> Self {
        Self { debouncer: None }
    }

    pub fn start_monitoring<P: AsRef<Path>>(&mut self, paths: Vec<P>, on_events: impl Fn(Vec<DebouncedEvent>) + Send + 'static) {
        // 创建一个 2.0 秒的防抖通道
        let (tx, rx) = channel();
        
        let mut debouncer = new_debouncer(Duration::from_millis(2000), tx)
            .expect("Failed to create debouncer");

        for path in paths {
            debouncer.watcher()
                .watch(path.as_ref(), RecursiveMode::Recursive)
                .unwrap_or_else(|e| println!("Error watching path: {:?}", e));
        }

        // 后台线程监听 debouncer 输出
        std::thread::spawn(move || {
            for result in rx {
                match result {
                    Ok(events) => {
                        // 执行忽略规则过滤
                        let filtered_events: Vec<DebouncedEvent> = events
                            .into_iter()
                            .filter(|e| !should_ignore(&e.path))
                            .collect();
                        
                        if !filtered_events.is_empty() {
                            on_events(filtered_events);
                        }
                    }
                    Err(errors) => errors.iter().for_each(|err| println!("Monitor error: {:?}", err)),
                }
            }
        });

        self.debouncer = Some(debouncer);
    }
}
```

---

## 4. 系统托盘与全局状态

在 macOS 上保留完美的顶部状态栏气泡菜单及 Badge 计数，在 Windows 上自适应显示为右下角任务栏系统托盘。

```rust
use tauri::{
    menu::{Menu, MenuItem},
    tray::{TrayIconBuilder, TrayIconEvent},
    Runtime,
};

pub fn setup_system_tray<R: Runtime>(app: &tauri::AppHandle<R>) -> Result<(), tauri::Error> {
    let show_item = MenuItem::with_id(app, "show", "打开主窗口", true, None::<&str>)?;
    let sync_item = MenuItem::with_id(app, "sync_all", "立即同步所有目录", true, None::<&str>)?;
    let quit_item = MenuItem::with_id(app, "quit", "退出应用", true, None::<&str>)?;
    
    let menu = Menu::with_items(app, &[&show_item, &sync_item, &quit_item])?;

    let tray = TrayIconBuilder::new()
        .tooltip("FileSyncMonitor")
        // 使用多平台图标适配
        .icon(app.default_window_icon().unwrap().clone())
        .menu(&menu)
        .on_tray_icon_event(|tray, event| {
            if let TrayIconEvent::Click { id: _, .. } = event {
                // 点击托盘图标直接唤起或隐藏主窗口
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    if window.is_visible().unwrap_or(false) {
                        let _ = window.hide();
                    } else {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
            }
        })
        .build(app)?;

    Ok(())
}
```

### 4.1 macOS Badge 动态渲染
在 macOS 上，可以通过读取待同步事件总数，利用 Rust 动态绘制或组合出带数字的菜单栏图标（使用 `cocoa` 或 `core-graphics` 绑定，或者利用 PNG 帧），从而复刻 SwiftUI 中的：
```swift
button.title = pendingCount > 0 ? "󰓦 \(pendingCount)" : ""
```

---

## 5. IMA 云端接口与安全存储

原系统中的网络请求库（基于 `URLSession`）和安全凭证（基于 `Keychain`）需进行双端跨平台替换。

### 5.1 网络库 (reqwest + tokio)
网络层采用 Rust 业界最高性能的异步 HTTP 客户端 `reqwest`，实现对腾讯 IMA 接口的高并发、异步多线程操作。
* **分块多流上传**：使用 `tokio::fs::File` 将大文件以多流异步分块（Chunked Multipart）形式高效上传。
* **文件指纹**：使用 Rust `md5` 和 `sha2` 库计算高精度文件校验值，以匹配腾讯云端去重策略。

### 5.2 跨平台安全凭证存储 (keyring)
用跨平台 **`keyring`** 库替换 macOS 独占的 `KeychainHelper.swift`。
* **macOS 平台**：自动存取至系统的安全密钥串服务 (System Keychain)。
* **Windows 平台**：自动调用 Windows 凭据管理器 (Windows Credential Manager) 的安全存储 API。

```rust
use keyring::Entry;

pub fn save_secure_token(token_key: &str, token_value: &str) -> Result<(), keyring::Error> {
    let entry = Entry::new("com.filesyncmonitor.app", token_key)?;
    entry.set_secret(token_value.as_bytes())?;
    Ok(())
}

pub fn get_secure_token(token_key: &str) -> Result<String, keyring::Error> {
    let entry = Entry::new("com.filesyncmonitor.app", token_key)?;
    let secret = entry.get_secret()?;
    Ok(String::from_utf8(secret).unwrap_or_default())
}
```

---

## 6. 前端视觉与交互复刻

原系统最出彩的亮点在于**极富空气感、毛玻璃感、现代化渐变与微动效**的 UI 设计。我们在跨平台 Web 前端将严格复刻这些设计：

### 6.1 精准 CSS 设计令牌映射 (Design Tokens)
将 `Theme.swift` 中的色彩设计系统 100% 映射为 CSS 变量：

```css
:root {
  /* Harmony Palette */
  --app-mint: #00D2A0;          /* 极富生命力的青绿 */
  --app-mint-dark: #00B086;
  --app-ink: #1D1D2C;           /* 典雅的深墨绿背景色 */
  --app-ink-sub: #2A2A3C;
  --app-rose: #FF5E7E;          /* 温暖柔和的警告红 */
  --app-gold: #FFB340;          /* 活力阳光的橙黄 */
  
  /* Modern Neutral Grays */
  --app-surface: #FCFCFF;       /* 主背景板 */
  --app-control: #F0F2F6;       /* 交互控件背景 */
  --app-selection: #E5E9F0;
  --app-line: rgba(29, 29, 44, 0.08); /* 柔和分割线 */
  --app-muted: #8E8EA2;         /* 辅助阅读灰 */
  
  /* Glassmorphism Configuration */
  --glass-bg: rgba(252, 252, 255, 0.72);
  --glass-border: rgba(255, 255, 255, 0.48);
  --glass-blur: blur(24px) saturate(180%);
}

/* 深色模式自适应 */
@media (prefers-color-scheme: dark) {
  :root {
    --app-surface: #14141E;
    --app-control: #20202F;
    --app-selection: #2D2D42;
    --app-line: rgba(255, 255, 255, 0.06);
    --app-muted: #727288;
    --glass-bg: rgba(20, 20, 30, 0.76);
  }
}
```

### 6.2 经典三栏自适应布局 (`NavigationSplitView`)
利用 HTML5 与 Flexbox 完美重建原主视图界面：

```html
<div class="app-container">
  <!-- 第一栏：极窄主快捷导航栏 -->
  <aside class="app-rail">
    <div class="brand-logo">
      <img src="logo.svg" alt="Logo" class="logo-spark" />
    </div>
    <nav class="rail-links">
      <button class="rail-btn active" id="btn-events"><i class="icon-pulse"></i></button>
      <button class="rail-btn" id="btn-reports"><i class="icon-chart"></i></button>
      <button class="rail-btn" id="btn-settings"><i class="icon-gear"></i></button>
      <button class="rail-btn" id="btn-help"><i class="icon-info"></i></button>
    </nav>
  </aside>

  <!-- 第二栏：待同步/已同步事件列表 -->
  <section class="app-sidebar-second">
    <div class="sidebar-header">
      <h2>事件记录</h2>
      <div class="search-box">
        <input type="text" placeholder="搜索文件事件..." />
      </div>
    </div>
    <div class="event-tree-list">
      <!-- 动态事件渲染树 -->
    </div>
  </section>

  <!-- 第三栏：事件详细预览与同步控制台 -->
  <main class="app-main-content">
    <div class="toolbar">
      <button class="pill-btn primary" id="btn-sync-now">立即同步</button>
    </div>
    <div class="detail-card">
      <!-- 卡片详细信息 -->
    </div>
  </main>
</div>
```

---

## 7. 双端自动化打包与分发管道

通过部署一套完善的 **GitHub Actions** 构建矩阵（Matrix Build），自动输出原生平台安装包：

### 7.1 打包目标格式 (Bundled Formats)
* **Windows**：输出 `.msi` (基于 WiX 编译的静默安装程序) 与便携版 `.exe` 可执行包，包含对 Edge WebView2 运行时依赖的静默检查。
* **macOS**：输出带数字签名的 `.dmg` (磁盘映像) 以及纯苹果应用包 `.app`，兼容 Intel (`x64`) 以及 Apple Silicon (`aarch64`) 架构。

### 7.2 GitHub Actions 自动编译管道配置简述
在 `.github/workflows/build.yml` 中：
```yaml
name: Release Tauri Apps
on:
  push:
    tags:
      - 'v*'

jobs:
  publish:
    strategy:
      fail-fast: false
      matrix:
        platform: [macos-latest, windows-latest]
    runs-on: ${{ matrix.platform }}
    steps:
      - uses: actions/checkout@v4
      - name: Setup Node.js
        uses: actions/setup-node@v4
        with:
          node-version: 20
      - name: Install Rust
        uses: dtolnay/rust-toolchain@stable
      - name: Install Dependencies (macOS)
        if: matrix.platform == 'macos-latest'
        run: echo "No extra libs needed"
      - name: Build and Pack
        uses: tauri-apps/tauri-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        with:
          tagName: ${{ github.ref_name }}
          releaseName: 'FileSyncMonitor ${{ github.ref_name }}'
          releaseDraft: false
          prerelease: true
```
