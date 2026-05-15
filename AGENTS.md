# PROJECT KNOWLEDGE BASE

**Generated:** 2026-05-15
**Stack:** Swift 5.9, SwiftUI, SwiftData, macOS 14+

## OVERVIEW
Menu bar macOS app that monitors directories via FSEvents, records file changes (create/modify/delete/rename) in SwiftData/SQLite, and reminds users to sync. Supports CSV/JSON export and optional IMA cloud integration.

## STRUCTURE
```
.
├── Package.swift                    # SPM manifest, macOS 14+, single executable target
├── Sources/FileSyncMonitor/
│   ├── FileSyncMonitorApp.swift     # @main entry, SwiftUI WindowGroup + Settings scene
│   ├── Models/
│   │   └── FileEvent.swift          # @Model: id, path, oldPath, type, timestamp, isSynced, hasNotified
│   ├── Services/
│   │   ├── FileMonitorService.swift # FSEvents singleton, 2s latency debounce, background dispatch queue
│   │   ├── PersistenceController.swift # SwiftData ModelContainer singleton, @MainActor
│   │   ├── NotificationManager.swift   # UNUserNotificationCenter alerts
│   │   ├── ExportService.swift         # CSV (manual string concat) and JSON (JSONEncoder) export
│   │   ├── IMASyncService.swift        # IMA OpenAPI client: get knowledge bases, import docs (multipart)
│   │   └── StoreManager.swift          # StoreKit 2 in-app purchase (pro lifetime, ¥9.9)
│   ├── UI/
│   │   ├── MainView.swift           # NavigationSplitView, sidebar (all/pending/reports/settings), Table+tree views
│   │   ├── MenuBarManager.swift     # NSStatusItem + NSMenu, badge count, "sync all" action
│   │   └── SettingsView.swift       # TabView: General (appearance, dirs), IMA API keys, StoreKit pro tier
│   └── Resources/
│       └── Localizable.xcstrings    # zh-Hans string catalog
├── Tests/FileSyncMonitorTests/      # Empty test target (no tests yet)
└── docs/design.md                   # Full feature spec (172 lines, Chinese)
```

## WHERE TO LOOK
| Task | Location | Notes |
|------|----------|-------|
| App entry point | `Sources/FileSyncMonitor/FileSyncMonitorApp.swift` | `@main`, injects `.modelContainer` into both scenes |
| Data model / schema | `Sources/FileSyncMonitor/Models/FileEvent.swift` | `@Model` class, UUID primary, `type` is raw String not enum |
| File monitoring engine | `Sources/FileSyncMonitor/Services/FileMonitorService.swift` | `startMonitoring(paths:onEvent:)`, `kFSEventStreamCreateFlagFileEvents` |
| Persistence setup | `Sources/FileSyncMonitor/Services/PersistenceController.swift` | Single `ModelContainer`, `makeBackgroundContext()` for writes |
| Menu bar UI | `Sources/FileSyncMonitor/UI/MenuBarManager.swift` | `NSStatusItem`, badge via `button.title`, AppKit interop |
| Main window UI | `Sources/FileSyncMonitor/UI/MainView.swift` | `NavigationSplitView`, `@Query` on FileEvent, sidebar items |
| Settings | `Sources/FileSyncMonitor/UI/SettingsView.swift` | `@AppStorage` for appearance/clientId/apiKey, 3 tabs |
| Local notifications | `Sources/FileSyncMonitor/Services/NotificationManager.swift` | `UNMutableNotificationContent`, localized strings |
| Export | `Sources/FileSyncMonitor/Services/ExportService.swift` | CSV string concat (not CSVWriter), JSON via `JSONEncoder` |
| IMA cloud sync | `Sources/FileSyncMonitor/Services/IMASyncService.swift` | REST API, multipart upload, custom header auth |
| StoreKit / IAP | `Sources/FileSyncMonitor/Services/StoreManager.swift` | `@Observable`, `Transaction.currentEntitlements` |
| Feature spec | `docs/design.md` | All UI states, data retention policy, user scenarios |

## CONVENTIONS
- **Singletons**: All services use `static let shared` pattern, `private init()`
- **SwiftData**: `@Model` for data, `@Query` for reads, `ModelContext` for writes. PersistenceController injects `ModelContainer` at root
- **Observation**: `@Observable` on services that drive UI state (FileMonitorService, StoreManager). `@State`/`@Environment` for local view state
- **Event type**: Stored as raw `String` ("created"/"modified"/"deleted"/"renamed"), not an enum. Switch on string literals throughout
- **Localization**: Uses `String(localized:)` and `LocalizedStringKey`. String catalog at `Resources/Localizable.xcstrings`
- **AppKit interop**: `NSStatusItem`, `NSMenu`, `NSOpenPanel` used directly in SwiftUI app (no AppKit lifecycle needed for menu bar)
- **Error handling**: Custom `enum Error: Error` types. No `Result` types, uses `throws` throughout
- **No external dependencies**: Zero SPM package dependencies — pure Apple frameworks

## ANTI-PATTERNS (THIS PROJECT)
- **DO NOT convert `type: String` to enum** without updating all switch statements in MainView, NotificationManager, and any future views
- **DO NOT remove `@MainActor`** from PersistenceController — SwiftData container init requires main actor
- **DO NOT use `FileEvent` directly in JSONEncoder** — it's a `@Model` class, not `Codable`. Always map through `ExportableFileEvent` or equivalent
- **DO NOT add SPM dependencies** — project convention is zero external deps, Apple frameworks only
- **DO NOT change singleton pattern** — all services accessed via `.shared`, not dependency injection

## COMMANDS
```bash
# Build
swift build

# Run
swift run

# Test (no tests written yet)
swift test

# Build release
swift build -c release
```

## NOTES
- macOS 14+ required (Sonoma). Uses SwiftData which is iOS 17+/macOS 14+ only
- FSEvents uses 2.0s latency for event coalescing — rapid changes to same file within 2s produce single event
- Tests directory exists but is empty — test target is wired in Package.swift
- IMA API credentials stored in `@AppStorage` (UserDefaults), not Keychain despite code comments suggesting otherwise
- Not a sandboxed app — Security-Scoped Bookmarks pattern described in design.md but not yet implemented in code
- Tree view (`EventTreeView`) is a stub — just renders placeholder text
