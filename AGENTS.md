# PROJECT KNOWLEDGE BASE

**Updated:** 2026-05-23
**Stack:** Tauri 2, Rust 2021, Vanilla HTML/CSS/JS, SQLite, macOS + Windows

## OVERVIEW

FileSyncMonitor is now a cross-platform desktop app with a two-sided architecture:

- `desktop-portal/`: the Web UI frontend bundled by Tauri.
- `sync-kernel/`: the Rust/Tauri backend that owns file watching, SQLite persistence, tray integration, IMA sync, login capture, and OS-level commands.

The old SwiftUI/SwiftData implementation has been replaced. Do not look for `Package.swift`, `Sources/FileSyncMonitor`, SwiftData models, or Swift services in the current codebase.

## STRUCTURE

```text
.
├── package.json                     # npm scripts that delegate to Tauri
├── desktop-portal/
│   ├── index.html                   # Single-page desktop UI
│   ├── main.js                      # Frontend state, Tauri invokes, rendering, i18n hooks
│   ├── styles.css                   # UI theme and layout
│   ├── i18n.js                      # zh/en translation dictionary
│   └── assets/                      # App icon and donation images
├── sync-kernel/
│   ├── Cargo.toml                   # Rust crate and Tauri dependencies
│   ├── tauri.conf.json              # Tauri app config and bundle metadata
│   ├── build.rs
│   ├── capabilities/default.json
│   ├── permissions/default.toml
│   ├── icons/
│   └── src/
│       ├── main.rs                  # Thin executable entry point
│       ├── lib.rs                   # Tauri setup, commands, sync orchestration, login windows
│       ├── db.rs                    # SQLite schema, event/config CRUD
│       ├── monitor.rs               # notify-based recursive file watcher + debounce/coalescing
│       ├── ima_sync.rs              # Tencent IMA API client, upload/download/folders
│       ├── credentials.rs           # IMA credential file storage
│       └── tray.rs                  # Tauri system tray
├── docs/
│   ├── cross_platform_design.md     # Tauri/Rust redesign whitepaper
│   ├── IMA抓包接口总结.md
│   └── screenshot/
└── scripts/build_app.sh
```

## WHERE TO LOOK

| Task | Location | Notes |
|------|----------|-------|
| App entry point | `sync-kernel/src/main.rs` | Calls `file_sync_monitor_lib::run()` |
| Tauri setup / commands | `sync-kernel/src/lib.rs` | `run()`, `invoke_handler`, app state, login windows, sync orchestration |
| Data schema | `sync-kernel/src/db.rs` | SQLite tables `file_events` and `app_config` |
| File monitor | `sync-kernel/src/monitor.rs` | Rust `notify`, recursive watches, 2s debounce, ignore rules |
| IMA API client | `sync-kernel/src/ima_sync.rs` | Knowledge bases, folders, upload, download, delete, rename, HTTP logs |
| Credentials | `sync-kernel/src/credentials.rs` | Current storage is JSON in Tauri app data dir, with legacy temp migration |
| Tray | `sync-kernel/src/tray.rs` | Tauri tray menu and click behavior |
| Frontend app state | `desktop-portal/main.js` | `state`, boot sequence, rendering, sync actions |
| Main UI markup | `desktop-portal/index.html` | Single-page layout, navigation, panels, dialogs |
| Styling | `desktop-portal/styles.css` | Theme variables and component styles |
| i18n | `desktop-portal/i18n.js` | Translation dictionary for English mode |
| Cross-platform design | `docs/cross_platform_design.md` | Current architecture intent |

## BACKEND MODEL

- `AppState` in `sync-kernel/src/lib.rs` stores:
  - `db_conn: Mutex<rusqlite::Connection>`
  - `monitor: Arc<Mutex<DirectoryMonitor>>`
  - `db_path: PathBuf`
- `FileEvent` in `sync-kernel/src/db.rs` is serialized to the frontend:
  - `id`
  - `path`
  - `old_path`
  - `event_type` (`created`, `modified`, `deleted`, `renamed`)
  - `timestamp`
  - `is_synced`
  - `has_notified`
  - `is_directory`
  - `remote_id`
- App preferences and bindings live in SQLite `app_config`, though the frontend also mirrors some values in `localStorage`.

## FRONTEND MODEL

- `desktop-portal/main.js` is a framework-free SPA.
- It imports `invoke` and `listen` from Tauri globals.
- It keeps a central `state` object with monitored paths, events, credentials, sync status, filters, selected event, knowledge bases, and view modes.
- It renders DOM manually for event trees, pending lists, all records, settings, logs, onboarding, and account status.
- Language is controlled by `localStorage.appLanguage`; translations are looked up from `desktop-portal/i18n.js`.
- Appearance is controlled by `localStorage.appearance` plus the Tauri `set_window_theme` command.

## EVENT FLOW

1. Frontend reads `monitoredDirectories` from SQLite config.
2. Frontend calls `start_file_monitor`.
3. Rust `DirectoryMonitor` starts recursive `notify` watchers.
4. Raw events are filtered by ignore rules and coalesced for 2 seconds.
5. Resolved events are inserted into SQLite.
6. Rust emits `file-change-events`.
7. Frontend calls `get_file_events` and rerenders stats, trees, tables, and details.
8. If auto sync is enabled, frontend calls `sync_all_directories`.

## SYNC FLOW

- `sync_all_directories` performs optional pull and push phases depending on `direction`.
- The file watcher is stopped during sync to avoid feedback loops, then resumed from saved config.
- Pull phase:
  - Fetches all IMA knowledge items.
  - Maps remote folders to local paths.
  - Downloads missing/changed remote files.
  - Writes synced local records with `remote_id`.
- Push phase:
  - Reads pending local events under each bound root.
  - Creates folders for directory events.
  - Uploads created/modified files.
  - Attempts remote delete/rename when `remote_id` is available.
  - Marks records synced.
- Progress is emitted through `sync-progress`.

## CURRENT COMMANDS

```bash
# Install frontend/Tauri CLI dependency
npm install

# Run Tauri dev app
npm run dev

# Build app bundle
npm run build

# Check Rust backend
cd sync-kernel && cargo check

# Run Rust tests if added later
cd sync-kernel && cargo test
```

## GITHUB PACKAGING

- GitHub Actions workflow: `.github/workflows/release-tauri.yml`
- Triggered by `workflow_dispatch` or pushed version tags matching `v*`.
- Builds macOS Apple Silicon, macOS Intel, and Windows x64 installers.
- Uses the official `tauri-apps/tauri-action`.
- Releases are created as drafts so generated assets can be reviewed before publishing.

## CONVENTIONS

- Keep the current Tauri/Rust + vanilla frontend architecture unless the user explicitly asks for a framework or rewrite.
- Prefer adding Tauri commands in `sync-kernel/src/lib.rs` and implementation helpers in focused modules.
- Keep event type values as strings: `created`, `modified`, `deleted`, `renamed`.
- Keep SQLite schema changes backward-compatible with `ALTER TABLE` migrations in `db::init_db`.
- Avoid adding frontend frameworks unless explicitly requested.
- Avoid adding Rust dependencies unless they clearly reduce complexity or are needed for platform support.
- Use Tauri `invoke`/`listen` for frontend/backend communication.
- For UI changes, keep `index.html`, `main.js`, `styles.css`, and `i18n.js` in sync.
- Do not commit generated `node_modules/`, temporary patch scripts, raw capture files, private credentials, or local debug artifacts.

## IMPORTANT CAVEATS

- README and docs may still contain older Swift wording. Treat actual code as the source of truth.
- Credentials are currently stored as `ima_credentials.json` in the Tauri app data directory, not in Keychain/Keyring.
- HTTP request logs are kept in memory only, capped at 100 entries.
- Tray currently exposes open window, sync all, and quit. It does not yet render a dynamic pending-count badge.
- CSV/JSON export is currently generated in the frontend.
- Some app settings are split between SQLite config and `localStorage`; preserve compatibility when changing them.
- IMA integration is based on non-official web/H5 interfaces and may break when Tencent changes server behavior.
- The current branch may contain untracked helper scripts and generated files. Do not clean or delete them unless asked.

## ANTI-PATTERNS

- Do not reintroduce SwiftUI/SwiftData instructions or paths.
- Do not assume `Package.swift` or `Sources/FileSyncMonitor` exists.
- Do not store real tokens, cookies, UIDs, request captures, or credentials in the repo.
- Do not delete local user files when clearing records or resetting app state.
- Do not restart watchers during sync without considering feedback loops.
- Do not silently change `event_type` names; frontend and backend switch on string literals.
- Do not tag releases or push to `main` without explicit user instruction.
