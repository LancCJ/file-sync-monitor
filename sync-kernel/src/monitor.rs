use notify::{Event, EventKind, RecommendedWatcher, RecursiveMode, Watcher};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Instant, SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc;
use tokio::time::{sleep, Duration};
use uuid::Uuid;

use crate::db::{self, FileEvent};

// Struct to store custom and default ignore rules
#[derive(Clone, Debug)]
pub struct IgnoreRules {
    pub enable_default_rules: bool,
    pub custom_file_names: Vec<String>,
    pub custom_extensions: Vec<String>,
    pub custom_directory_names: Vec<String>,
}

impl IgnoreRules {
    pub fn new(
        enable_default_rules: bool,
        custom_file_names: Vec<String>,
        custom_extensions: Vec<String>,
        custom_directory_names: Vec<String>,
    ) -> Self {
        Self {
            enable_default_rules,
            custom_file_names: custom_file_names.iter().map(|s| s.to_lowercase()).collect(),
            custom_extensions: custom_extensions
                .iter()
                .map(|s| s.trim_start_matches('.').to_lowercase())
                .collect(),
            custom_directory_names: custom_directory_names
                .iter()
                .map(|s| s.to_lowercase())
                .collect(),
        }
    }

    pub fn matches(&self, path: &Path) -> bool {
        let file_name = match path.file_name().and_then(|s| s.to_str()) {
            Some(name) => name,
            None => return false,
        };
        let lowered_file_name = file_name.to_lowercase();

        // 1. Check direct file name matches
        if self.enable_default_rules {
            let default_files = [
                ".ds_store",
                "icon\r",
                ".localized",
                "thumbs.db",
                "desktop.ini",
            ];
            if default_files.contains(&lowered_file_name.as_str()) {
                return true;
            }

            // Prefixes
            let default_prefixes = ["~$", "._", "~wrl", "~df", "~rf"];
            if default_prefixes
                .iter()
                .any(|pre| lowered_file_name.starts_with(pre))
            {
                return true;
            }

            // Suffixes
            if lowered_file_name.ends_with('#') {
                return true;
            }
        }

        if self.custom_file_names.contains(&lowered_file_name) {
            return true;
        }

        // 2. Check directory name matches in path components
        for component in path.components() {
            if let Some(comp_str) = component.as_os_str().to_str() {
                let lowered_comp = comp_str.to_lowercase();
                if self.enable_default_rules {
                    let default_dirs = [
                        ".trashes",
                        ".spotlight-v100",
                        ".fseventsd",
                        ".temporaryitems",
                        ".git",
                        ".svn",
                        ".hg",
                        "node_modules",
                        ".next",
                        ".nuxt",
                        "dist",
                        "build",
                        ".build",
                        "deriveddata",
                        ".idea",
                        ".vscode",
                        ".swiftpm",
                        ".cache",
                    ];
                    if default_dirs.contains(&lowered_comp.as_str()) {
                        return true;
                    }
                }
                if self.custom_directory_names.contains(&lowered_comp) {
                    return true;
                }
            }
        }

        // 3. Check extensions
        if let Some(ext) = path.extension().and_then(|s| s.to_str()) {
            let lowered_ext = ext.to_lowercase();
            if self.enable_default_rules {
                let default_exts = [
                    "asd",
                    "lck",
                    "lock",
                    "tmp",
                    "temp",
                    "swp",
                    "swo",
                    "part",
                    "download",
                    "crdownload",
                ];
                if default_exts.contains(&lowered_ext.as_str()) {
                    return true;
                }
            }
            if self.custom_extensions.contains(&lowered_ext) {
                return true;
            }
        }

        false
    }
}

fn is_default_new_folder_name(path: &Path) -> bool {
    let Some(file_name) = path.file_name().and_then(|s| s.to_str()) else {
        return false;
    };

    let normalized = file_name.trim().to_lowercase();
    normalized == "untitled folder"
        || normalized == "new folder"
        || normalized == "未命名文件夹"
        || normalized == "新建文件夹"
        || normalized.starts_with("untitled folder ")
        || normalized.starts_with("new folder ")
        || normalized.starts_with("未命名文件夹 ")
        || normalized.starts_with("新建文件夹 ")
}

fn same_parent(left: &Path, right: &Path) -> bool {
    left.parent().is_some() && left.parent() == right.parent()
}

fn same_file_extension(left: &Path, right: &Path) -> bool {
    left.extension()
        .and_then(|s| s.to_str())
        .map(|s| s.to_lowercase())
        == right
            .extension()
            .and_then(|s| s.to_str())
            .map(|s| s.to_lowercase())
}

fn paths_look_like_same_item_kind(old_path: &Path, new_path: &Path) -> bool {
    if new_path.is_dir() {
        return true;
    }

    same_file_extension(old_path, new_path)
}

fn has_synced_history(conn: &rusqlite::Connection, path: &Path) -> bool {
    db::get_latest_synced_event(conn, &path.to_string_lossy())
        .ok()
        .flatten()
        .is_some()
}

fn cleanup_transient_default_folder_records(conn: &rusqlite::Connection, final_path: &Path) {
    let Ok(mut stmt) = conn.prepare(
        "SELECT id, path FROM file_events
         WHERE is_synced = 0 AND is_directory = 1
         AND type IN ('created', 'modified', 'deleted')",
    ) else {
        return;
    };

    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, String>(1)?))
    });

    let Ok(rows) = rows else {
        return;
    };

    for row in rows.flatten() {
        let (id, candidate_path) = row;
        let candidate = PathBuf::from(candidate_path);
        if is_default_new_folder_name(&candidate) && same_parent(&candidate, final_path) {
            let _ = conn.execute(
                "DELETE FROM file_events WHERE id = ?1",
                rusqlite::params![id],
            );
        }
    }
}

pub struct DirectoryMonitor {
    watcher: Option<RecommendedWatcher>,
    active_paths: Arc<Mutex<Vec<PathBuf>>>,
    ignore_rules: Arc<Mutex<IgnoreRules>>,
    stop_tx: Option<mpsc::Sender<()>>,
}

impl DirectoryMonitor {
    pub fn new(ignore_rules: IgnoreRules) -> Self {
        Self {
            watcher: None,
            active_paths: Arc::new(Mutex::new(Vec::new())),
            ignore_rules: Arc::new(Mutex::new(ignore_rules)),
            stop_tx: None,
        }
    }

    pub fn update_ignore_rules(&self, new_rules: IgnoreRules) {
        if let Ok(mut rules) = self.ignore_rules.lock() {
            *rules = new_rules;
        }
    }

    pub fn start<F>(
        &mut self,
        paths: Vec<PathBuf>,
        db_path: PathBuf,
        on_events_coalesced: F,
    ) -> Result<(), String>
    where
        F: Fn(Vec<FileEvent>) + Send + Clone + 'static,
    {
        self.stop();

        let active_paths = self.active_paths.clone();
        if let Ok(mut active) = active_paths.lock() {
            *active = paths.clone();
        }

        let ignore_rules = self.ignore_rules.clone();
        let (tx, mut rx) = mpsc::channel::<(PathBuf, String)>(200);
        let (stop_tx, mut stop_rx) = mpsc::channel::<()>(1);
        self.stop_tx = Some(stop_tx);

        // Define raw notify event handler
        let tx_clone = tx.clone();
        let watcher_handler = move |res: Result<Event, notify::Error>| {
            if let Ok(event) = res {
                // 1. Check for rename events
                match event.kind {
                    EventKind::Modify(notify::event::ModifyKind::Name(
                        notify::event::RenameMode::Both,
                    )) => {
                        if event.paths.len() == 2 {
                            let old_path = &event.paths[0];
                            let new_path = &event.paths[1];
                            let rules = ignore_rules.lock().unwrap();
                            let old_ignored = rules.matches(old_path);
                            let new_ignored = rules.matches(new_path);
                            if !old_ignored && !new_ignored {
                                let _ = tx_clone.blocking_send((
                                    new_path.clone(),
                                    format!("renamed:{}", old_path.to_string_lossy()),
                                ));
                                let _ = tx_clone
                                    .blocking_send((old_path.clone(), "rename_source".to_string()));
                            } else if !old_ignored {
                                let _ = tx_clone
                                    .blocking_send((old_path.clone(), "deleted".to_string()));
                            } else if !new_ignored {
                                let _ = tx_clone
                                    .blocking_send((new_path.clone(), "created".to_string()));
                            }
                            return;
                        }
                    }
                    EventKind::Modify(notify::event::ModifyKind::Name(
                        notify::event::RenameMode::From,
                    )) => {
                        if event.paths.len() == 1 {
                            let old_path = &event.paths[0];
                            let rules = ignore_rules.lock().unwrap();
                            if !rules.matches(old_path) {
                                let _ = tx_clone
                                    .blocking_send((old_path.clone(), "rename_from".to_string()));
                            }
                            return;
                        }
                    }
                    EventKind::Modify(notify::event::ModifyKind::Name(
                        notify::event::RenameMode::To,
                    )) => {
                        if event.paths.len() == 1 {
                            let new_path = &event.paths[0];
                            let rules = ignore_rules.lock().unwrap();
                            if !rules.matches(new_path) {
                                let _ = tx_clone
                                    .blocking_send((new_path.clone(), "rename_to".to_string()));
                            }
                            return;
                        }
                    }
                    _ => {}
                }

                // 2. Fallback to generic events
                let kind = match event.kind {
                    EventKind::Create(_) => "created",
                    EventKind::Modify(_) => "modified",
                    EventKind::Remove(_) => "deleted",
                    _ => return, // Skip access / read / properties modification events
                };

                for path in event.paths {
                    let rules = ignore_rules.lock().unwrap();
                    if !rules.matches(&path) {
                        let _ = tx_clone.blocking_send((path, kind.to_string()));
                    }
                }
            }
        };

        let mut watcher = RecommendedWatcher::new(watcher_handler, notify::Config::default())
            .map_err(|e| format!("Watcher creation failed: {:?}", e))?;

        for path in &paths {
            if path.exists() {
                let _ = watcher.watch(path, RecursiveMode::Recursive);
            }
        }

        self.watcher = Some(watcher);

        // Async loop to debounce/coalesce events with 2.0s window
        tauri::async_runtime::spawn(async move {
            let mut pending_events: HashMap<PathBuf, (String, Instant)> = HashMap::new();
            let mut recent_froms: Vec<(PathBuf, Instant)> = Vec::new();

            loop {
                tokio::select! {
                    _ = stop_rx.recv() => {
                        break;
                    }
                    Some((path, event_type)) = rx.recv() => {
                        // Clean up old recent_froms (> 2.0 seconds old)
                        recent_froms.retain(|(_, time)| time.elapsed() < Duration::from_secs(2));

                        if event_type == "rename_source" {
                            // Part of RenameMode::Both - delete the source from pending events
                            pending_events.remove(&path);
                        } else if event_type == "rename_from" {
                            // Part of separate RenameMode::From - delete from pending and save in recent_froms
                            let was_newly_created = pending_events
                                .get(&path)
                                .map(|(existing_type, _)| existing_type == "created")
                                .unwrap_or(false);
                            pending_events.remove(&path);
                            let remembered_path = if was_newly_created {
                                PathBuf::from(format!("created:{}", path.to_string_lossy()))
                            } else {
                                path
                            };
                            recent_froms.push((remembered_path, Instant::now()));
                        } else if event_type == "rename_to" {
                            // Part of separate RenameMode::To - find a matching from within last 2 seconds
                            if let Some(pos) = recent_froms.iter().position(|_| true) {
                                let (old_path, _) = recent_froms.remove(pos);
                                let old_path_str = old_path.to_string_lossy();
                                if let Some(created_old_path) = old_path_str.strip_prefix("created:") {
                                    pending_events.insert(path, ("created".to_string(), Instant::now()));
                                    pending_events.remove(&PathBuf::from(created_old_path));
                                } else {
                                    let resolved_type = format!("renamed:{}", old_path_str);
                                    pending_events.insert(path, (resolved_type, Instant::now()));
                                }
                            } else {
                                // No matching from, treat as created
                                pending_events.insert(path, ("created".to_string(), Instant::now()));
                            }
                        } else if event_type.starts_with("renamed:") {
                            // Direct RenameMode::Both destination
                            let old_path_str = event_type.strip_prefix("renamed:").unwrap_or("");
                            let old_path = PathBuf::from(old_path_str);
                            let was_newly_created = pending_events
                                .get(&old_path)
                                .map(|(existing_type, _)| existing_type == "created")
                                .unwrap_or(false);

                            if was_newly_created {
                                pending_events.remove(&old_path);
                                pending_events.insert(path, ("created".to_string(), Instant::now()));
                            } else {
                                pending_events.insert(path, (event_type, Instant::now()));
                            }
                        } else {
                            // Standard event (created, modified, deleted)
                            if event_type == "created" || event_type == "modified" {
                                if is_default_new_folder_name(&path)
                                    && pending_events.iter().any(|(existing_path, (existing_type, _))| {
                                        same_parent(existing_path, &path)
                                            && !is_default_new_folder_name(existing_path)
                                            && (existing_type == "created" || existing_type == "modified")
                                    })
                                {
                                    continue;
                                }

                                let default_temp_paths: Vec<PathBuf> = pending_events
                                    .iter()
                                    .filter_map(|(existing_path, (existing_type, _))| {
                                        let is_temp_new_folder = same_parent(existing_path, &path)
                                            && is_default_new_folder_name(existing_path)
                                            && (existing_type == "created" || existing_type == "deleted");

                                        if is_temp_new_folder {
                                            Some(existing_path.clone())
                                        } else {
                                            None
                                        }
                                    })
                                    .collect();

                                if !default_temp_paths.is_empty()
                                    && !is_default_new_folder_name(&path)
                                {
                                    for old_default_path in default_temp_paths {
                                        pending_events.remove(&old_default_path);
                                    }
                                    pending_events.insert(path, ("created".to_string(), Instant::now()));
                                    continue;
                                }
                            } else if event_type == "deleted" && is_default_new_folder_name(&path) {
                                if pending_events
                                    .iter()
                                    .any(|(existing_path, (existing_type, _))| {
                                        existing_type == "created" && same_parent(existing_path, &path)
                                    })
                                {
                                    pending_events.remove(&path);
                                    continue;
                                }
                            }

                            if let Some((existing_type, _)) = pending_events.get(&path) {
                                let mut resolved_type = existing_type.clone();
                                let mut should_remove = false;

                                if existing_type.starts_with("renamed:") {
                                    if event_type == "deleted" {
                                        should_remove = true; // If renamed file is deleted, cancel it!
                                    }
                                    // Else keep the "renamed:..." type, ignoring subsequent modifications
                                } else if existing_type == "created" {
                                    if event_type == "deleted" {
                                        should_remove = true;
                                    }
                                    // Else keep "created"
                                } else if existing_type == "modified" {
                                    if event_type == "deleted" {
                                        resolved_type = "deleted".to_string();
                                    }
                                    // Else keep "modified"
                                } else if existing_type == "deleted" {
                                    if event_type != "deleted" {
                                        resolved_type = "created".to_string();
                                    }
                                } else {
                                    resolved_type = event_type;
                                }

                                if should_remove {
                                    pending_events.remove(&path);
                                } else {
                                    pending_events.insert(path, (resolved_type, Instant::now()));
                                }
                            } else {
                                pending_events.insert(path, (event_type, Instant::now()));
                            }
                        }
                    }
                    _ = sleep(Duration::from_millis(500)) => {
                        // Tick loop every 500ms to scan debounced paths
                        let now = Instant::now();
                        let mut resolved_events = Vec::new();
                        let mut db_changed = false;
                        let mut completed_paths = Vec::new();
                        let default_folder_grace = Duration::from_secs(12);
                        let matured_entries: Vec<(PathBuf, String)> = pending_events
                            .iter()
                            .filter_map(|(path, (event_type, last_time))| {
                                let debounce_duration = if is_default_new_folder_name(path)
                                    && (event_type == "created" || event_type == "modified")
                                {
                                    default_folder_grace
                                } else {
                                    Duration::from_secs(2)
                                };
                                if now.duration_since(*last_time) >= debounce_duration {
                                    Some((path.clone(), event_type.clone()))
                                } else {
                                    None
                                }
                            })
                            .collect();
                        let finalized_new_folder_paths: Vec<PathBuf> = pending_events
                            .iter()
                            .filter_map(|(path, (event_type, last_time))| {
                                if now.duration_since(*last_time) >= Duration::from_secs(2)
                                    && path.is_dir()
                                    && !is_default_new_folder_name(path)
                                    && (event_type == "created" || event_type == "modified")
                                {
                                    // Only treat as a finalized folder if there was a default folder created in the same directory
                                    let has_sibling_default_folder = pending_events.keys().any(|other| {
                                        is_default_new_folder_name(other) && same_parent(path, other)
                                    });
                                    if has_sibling_default_folder {
                                        Some(path.clone())
                                    } else {
                                        None
                                    }
                                } else {
                                    None
                                }
                            })
                            .collect();
                        let history_conn = db::init_db(&db_path).ok();
                        let mut inferred_renames: HashMap<PathBuf, (String, Option<String>)> = HashMap::new();
                        let mut suppressed_paths: HashSet<PathBuf> = HashSet::new();

                        for (old_path, old_type) in &matured_entries {
                            if suppressed_paths.contains(old_path)
                                || !(old_type == "created" || old_type == "modified")
                            {
                                continue;
                            }

                            for (new_path, new_type) in &matured_entries {
                                if old_path == new_path
                                    || suppressed_paths.contains(new_path)
                                    || !(new_type == "created" || new_type == "modified")
                                    || !same_parent(old_path, new_path)
                                    || !paths_look_like_same_item_kind(old_path, new_path)
                                    || !new_path.exists()
                                {
                                    continue;
                                }

                                let old_has_history = history_conn
                                    .as_ref()
                                    .map(|conn| has_synced_history(conn, old_path))
                                    .unwrap_or(false);
                                let new_has_history = history_conn
                                    .as_ref()
                                    .map(|conn| has_synced_history(conn, new_path))
                                    .unwrap_or(false);
                                let old_missing = !old_path.exists();

                                if old_missing || (old_has_history && !new_has_history) {
                                    let resolved_type = if old_has_history {
                                        "renamed".to_string()
                                    } else {
                                        "created".to_string()
                                    };
                                    let old_path_for_event = if old_has_history {
                                        Some(old_path.to_string_lossy().to_string())
                                    } else {
                                        None
                                    };
                                    inferred_renames.insert(
                                        new_path.clone(),
                                        (resolved_type, old_path_for_event),
                                    );
                                    suppressed_paths.insert(old_path.clone());
                                    break;
                                }
                            }
                        }

                        for (path, (event_type, last_time)) in &pending_events {
                            let debounce_duration = if is_default_new_folder_name(path)
                                && (event_type == "created" || event_type == "modified")
                            {
                                default_folder_grace
                            } else {
                                Duration::from_secs(2)
                            };
                            if now.duration_since(*last_time) >= debounce_duration {
                                if suppressed_paths.contains(path) {
                                    completed_paths.push(path.clone());
                                    continue;
                                }

                                let is_transient_default_folder = is_default_new_folder_name(path)
                                    && finalized_new_folder_paths
                                        .iter()
                                        .any(|new_path| same_parent(path, new_path));
                                if is_transient_default_folder {
                                    completed_paths.push(path.clone());
                                    continue;
                                }

                                completed_paths.push(path.clone());

                                // Resolve the true final event state by disk checks
                                let exists = path.exists();
                                let mut final_old_path = None;
                                let resolved_type = if let Some((inferred_type, inferred_old_path)) =
                                    inferred_renames.get(path)
                                {
                                    final_old_path = inferred_old_path.clone();
                                    inferred_type.clone()
                                } else if !exists {
                                    "deleted".to_string()
                                } else if finalized_new_folder_paths
                                    .iter()
                                    .any(|new_path| new_path == path)
                                    && event_type == "modified"
                                {
                                    "created".to_string()
                                } else if event_type.starts_with("renamed:") {
                                    // Parse the old path
                                    let old_path_str = event_type.strip_prefix("renamed:").unwrap_or("");
                                    final_old_path = Some(old_path_str.to_string());
                                    "renamed".to_string()
                                } else {
                                    event_type.clone()
                                };

                                let timestamp = SystemTime::now()
                                    .duration_since(UNIX_EPOCH)
                                    .unwrap_or_default()
                                    .as_secs_f64();

                                let remote_id = if resolved_type == "renamed" {
                                    final_old_path.as_ref().and_then(|old_path| {
                                        history_conn
                                            .as_ref()
                                            .and_then(|conn| {
                                                db::get_latest_synced_event(conn, old_path)
                                                    .ok()
                                                    .flatten()
                                            })
                                            .and_then(|event| event.remote_id)
                                    })
                                } else if resolved_type == "deleted" {
                                    history_conn
                                        .as_ref()
                                        .and_then(|conn| {
                                            db::get_latest_synced_event(conn, &path.to_string_lossy())
                                                .ok()
                                                .flatten()
                                        })
                                        .and_then(|event| event.remote_id)
                                } else {
                                    None
                                };

                                let mut is_directory = path.is_dir();
                                if resolved_type == "deleted" && !exists {
                                    if let Some(ref conn) = history_conn {
                                        if let Ok(Some(prev_ev)) = db::get_event_by_path(conn, &path.to_string_lossy()) {
                                            is_directory = prev_ev.is_directory;
                                        }
                                    }
                                }

                                let mut should_insert = true;
                                if resolved_type == "deleted" {
                                    if let Ok(ref conn) = db::init_db(&db_path) {
                                        // Check if there is an unsynced created event for this path
                                        let has_unsynced_created = conn.query_row(
                                            "SELECT COUNT(*) FROM file_events WHERE path = ?1 AND type = 'created' AND is_synced = 0",
                                            rusqlite::params![path.to_string_lossy().to_string()],
                                            |row| row.get::<_, i64>(0)
                                        ).unwrap_or(0) > 0;

                                        if has_unsynced_created {
                                            // Delete all events for this path from the database to cancel them out
                                            let _ = conn.execute(
                                                "DELETE FROM file_events WHERE path = ?1",
                                                rusqlite::params![path.to_string_lossy().to_string()],
                                            );
                                            should_insert = false;
                                            db_changed = true;
                                        }
                                    }
                                }

                                if should_insert {
                                    let file_event = FileEvent {
                                        id: Uuid::new_v4().to_string(),
                                        path: path.to_string_lossy().to_string(),
                                        old_path: final_old_path,
                                        event_type: resolved_type,
                                        timestamp,
                                        is_synced: false,
                                        has_notified: false,
                                        is_directory,
                                        remote_id,
                                    };

                                    // Save event directly into SQLite database
                                    if let Ok(conn) = db::init_db(&db_path) {
                                        if file_event.is_directory
                                            && !is_default_new_folder_name(Path::new(&file_event.path))
                                            && (file_event.event_type == "created"
                                                || file_event.event_type == "modified")
                                        {
                                            cleanup_transient_default_folder_records(
                                                &conn,
                                                Path::new(&file_event.path),
                                            );
                                        }
                                        let _ = db::insert_event(&conn, &file_event);
                                    }

                                    resolved_events.push(file_event);
                                }
                            }
                        }

                        // Remove completed items
                        for path in completed_paths {
                            pending_events.remove(&path);
                        }

                        // Trigger front-end notification if new debounced events completed or database changed
                        if !resolved_events.is_empty() || db_changed {
                            on_events_coalesced(resolved_events);
                        }
                    }
                }
            }
        });

        Ok(())
    }

    pub fn stop(&mut self) {
        if let Some(stop_tx) = self.stop_tx.take() {
            let _ = stop_tx.try_send(());
        }
        if let Some(mut watcher) = self.watcher.take() {
            if let Ok(paths) = self.active_paths.lock() {
                for path in paths.iter() {
                    let _ = watcher.unwatch(path);
                }
            }
        }
    }
}
