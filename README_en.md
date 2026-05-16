# FileSyncMonitor

[English](README_en.md) | [中文](README.md)

FileSyncMonitor is a macOS file change monitoring and sync confirmation tool. It monitors file changes in specified directories, records create, modify, delete, and rename events, and reminds users to handle pending sync files via the main window, menu bar badge, and system notifications.

The current version is built with SwiftUI + SwiftData, with underlying monitoring based on macOS FSEvents. It supports local report exporting and optional Tencent IMA cloud uploading.

## Features

- **Directory Monitoring**: Add multiple directories and recursively monitor file and folder changes.
- **Event Logging**: Record path, type, time, sync status, etc., and persist to local SwiftData.
- **Pending Sync Confirmation**: New events default to pending sync status, and can be marked as completed individually or in bulk.
- **Menu Bar Access**: Resides in the menu bar, displays the number of pending syncs, and provides recent pending records.
- **Report Export**: Aggregate records by time range, supporting CSV and JSON export.
- **IMA Cloud Integration**: Configure Client ID and API Key to upload files to IMA.
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

## IMA Cloud Configuration

Go to "Settings > IMA Cloud" and fill in:

- `Client ID`
- `API Key`

After configuration, you can test the connection and click "Upload to IMA" in the file details. The current upload uses the default knowledge base ID, which can be extended to a knowledge base selector in the future.

> Credentials are currently saved to UserDefaults via `@AppStorage`. If used in a production environment, it is recommended to migrate them to Keychain later.

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
- The app will not automatically sync file content unless the user actively clicks "Upload to IMA" on the detail page.
- Exported files are saved to a location chosen by the user via a save panel.
- Monitored directory permissions are persisted via Security-Scoped Bookmarks.

## Known Limitations

- Currently, file content diffing is not performed; only file system events are recorded.
- FSEvents will coalesce high-frequency events in a short period; the event granularity depends on system callbacks.
- Historical records already in the database will not be automatically deleted due to newly added ignore rules.
- IMA API credentials have not yet been migrated to Keychain.
