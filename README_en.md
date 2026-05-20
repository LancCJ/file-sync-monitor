# FileSyncMonitor

[English](README_en.md) | [中文](README.md)

FileSyncMonitor is a macOS file change monitoring and sync confirmation tool. It monitors file changes in specified directories, records create, modify, delete, and rename events, and reminds users to handle pending sync files via the main window, menu bar badge, and system notifications.

The current version is built with SwiftUI + SwiftData, with underlying monitoring based on macOS FSEvents. It supports local report exporting and optional Tencent IMA cloud uploading.

## 🖥️ UI Screenshots

### 📊 Core Dashboards
| Dashboard (Home) | Pending Sync |
| --- | --- |
| ![Dashboard](docs/screenshot/首页.png) | ![Pending Sync](docs/screenshot/待同步.png) |

### 📈 Records & Reports
| All Records | Reports & Stats |
| --- | --- |
| ![All Records](docs/screenshot/全部记录.png) | ![Reports](docs/screenshot/报告.png) |

### ⚙️ System Settings
| General Settings | Filters & Cloud Settings |
| --- | --- |
| ![Settings](docs/screenshot/设置.png) | ![Settings 2](docs/screenshot/设置2.png) |

### ❓ Onboarding & Help
| Help & FAQ | Onboarding - Step 1 | Onboarding - Step 2 |
| --- | --- | --- |
| ![Help & FAQ](docs/screenshot/帮助与关于.png) | ![Onboarding 1](docs/screenshot/引导1.png) | ![Onboarding 2](docs/screenshot/引导2.png) |

## Features

- **Directory Monitoring**: Add multiple directories and recursively monitor file and folder changes.
- **Event Logging**: Record path, type, time, sync status, etc., and persist to local SwiftData.
- **Pending Sync Confirmation**: New events default to pending sync status, and can be marked as completed individually or in bulk.
- **Menu Bar Access**: Resides in the menu bar, displays the number of pending syncs, and provides recent pending records.
- **Report Export**: Aggregate records by time range, supporting CSV and JSON export.
- **IMA Cloud Integration**: Supports WeChat QR scan login to sync files to designated cloud knowledge bases with one click.
- **Ignore Rules**: By default, it filters noise files like `.DS_Store`, temporary files, system directories, build caches, etc. It also supports custom file names, extensions, and directory names in the settings.
- **Modern Desktop UI**: Features a FileSync dashboard, ultra-narrow icon rail, secondary list sidebar, and a fully adaptive dark/light appearance.

## System Requirements

- macOS 14.0 Sonoma or later
- Swift 5.9+
- Xcode 15+ or Swift Package Manager

## Quick Start

```bash
swift build
swift run
```

After running:

1. Open the main window or the menu bar app.
2. Add the directories you want to monitor in the Home or Settings page.
3. Modify, create, or delete files in the directories.
4. Confirm events on the "Pending Sync" page, and mark them as completed, upload to IMA, or export records as needed.

## Development Commands

```bash
# Debug Build
swift build

# Run App
swift run

# Run Tests
swift test

# Release Build
swift build -c release
```

> The current test target is configured, but no automated test cases have been added yet.

## Ignore Rules

Ignore rules are executed before events are saved to the database. Ignored files will not generate records, trigger notifications, or increase the menu bar badge.

Default ignored items include:

- File names: `.DS_Store`, `Icon\r`, `.localized`, `Thumbs.db`, `desktop.ini`
- Temporary files: `~$*`, `.tmp`, `.temp`, `.swp`, `.swo`, `.part`, `.download`, `.crdownload`
- System directories: `.Trashes`, `.Spotlight-V100`, `.fseventsd`, `.TemporaryItems`
- Development directories: `.git`, `.svn`, `.hg`, `node_modules`, `.next`, `.nuxt`, `dist`, `build`, `.build`, `DerivedData`
- IDE and cache directories: `.idea`, `.vscode`, `.swiftpm`, `.cache`

In "Settings > Ignore Rules", you can:

- Enable or disable default ignore rules.
- Add custom ignored file names, e.g., `debug.log`.
- Add custom ignored extensions, e.g., `.log`, `.tmp`.
- Add custom ignored directory names, e.g., `node_modules`, `DerivedData`.
- Restore default settings.

## IMA Cloud Sync Usage

Click **WeChat Login** at the bottom-left of the main window or under "Settings > Cloud Sync". The system will display the official WeChat QR login page. Once logged in, you can:

- Test connection and storage quota.
- Bind specific monitored directories to designated IMA knowledge bases in Settings.
- Manually sync files or enable automatic background sync.

## Project Structure

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
│   │   └── StoreManager.swift
│   ├── UI
│   │   ├── MainView.swift
│   │   ├── SettingsView.swift
│   │   ├── ReportsView.swift
│   │   ├── MenuBarManager.swift
│   │   └── Theme.swift
│   └── Resources
│       └── Localizable.xcstrings
├── Tests
└── docs
```

## Data and Privacy

- File event records are saved in the local SwiftData/SQLite database.
- The app will not automatically sync file content unless the user actively clicks "Upload to IMA" or enables automatic sync.
- Exported files are saved to a location chosen by the user via a save panel.
- Monitored directory permissions are persisted via Security-Scoped Bookmarks.

## Known Limitations

- Currently, file content diffing is not performed; only file system events are recorded.
- FSEvents will coalesce high-frequency events in a short period; the event granularity depends on system callbacks.
- Historical records already in the database will not be automatically deleted due to newly added ignore rules.

## 💖 Donation & Support

FileSyncMonitor is fully open-source and free to use. If it has saved you time and boosted your productivity, feel free to support its active development via donation. Your contribution is the best fuel to keep this project growing!

**⚠️ Read Before Donating (Disclaimer Supplement):**
- Donations are purely voluntary and act as gratuitous sponsorship to support the author's learning and open-source maintenance.
- **Donation does not establish any purchase, employment, agency, or service contract**.
- Please make sure you fully understand the [⚠️ Disclaimer](#-disclaimer) below before making a donation. Donating does not waive your legal risks or potential account issues resulting from the use of unofficial APIs.

| WeChat Pay | Alipay |
| --- | --- |
| <img src="docs/pay/wechat.jpg" width="260" alt="WeChat Pay" /> | <img src="docs/pay/alipay.jpg" width="260" alt="Alipay" /> |

> 💡 Donation is entirely voluntary, and all features remain fully unlocked. Thank you for your support!

## ⚠️ Disclaimer

**Please read the following terms carefully. By using this software, you agree to and accept all contents of this disclaimer:**

1. **Educational & Personal Use Only**: This software (FileSyncMonitor) and its entire source code are intended for **academic research, educational purposes, and personal technical exchange only**. Any commercial use or illegal activity is strictly prohibited.
2. **Unofficial API Statement**: The Tencent IMA cloud synchronization integrated in this software uses APIs obtained through **unofficial packet analysis and reverse engineering**. The author of this software has no relationship or affiliation with Tencent Holdings Ltd. (or any of its affiliates). These unofficial APIs may stop working or return errors at any time due to server-side updates.
3. **Legal Risk & User Responsibility**:
   - The use of reverse-engineered APIs carries legal risks and potential account suspension/ban risks. Users assume all responsibility and consequences (including but not limited to account suspension, data loss, network issues) resulting from using unofficial APIs.
   - The author shall not be held liable for any direct, indirect, incidental, special, exemplary, or consequential damages (including but not limited to loss of profits, data loss, business interruption) arising in any way out of the use of this software.
4. **Donation Terms**:
   - The "Donation & Support" channel is completely **voluntary and gratuitous**. Donations are voluntary gifts to support the author's open-source maintenance.
   - **Donations do not establish any purchase, employment, agency, or service contract**. Donating does not waive the user's own legal risks or represent that the author will bear any joint liability for legal disputes, intellectual property issues, or data issues caused by the software APIs.
5. **No Warranty**: The software is provided "AS IS", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and non-infringement.

## 📄 License

This project is licensed under the [GPL-3.0 License](LICENSE). See the `LICENSE` file for details.
