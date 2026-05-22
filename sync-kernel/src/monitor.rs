use notify::{RecommendedWatcher, RecursiveMode, Watcher, Event, EventKind};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::collections::HashMap;
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
            custom_extensions: custom_extensions.iter().map(|s| s.trim_start_matches('.').to_lowercase()).collect(),
            custom_directory_names: custom_directory_names.iter().map(|s| s.to_lowercase()).collect(),
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
            let default_files = [".ds_store", "icon\r", ".localized", "thumbs.db", "desktop.ini"];
            if default_files.contains(&lowered_file_name.as_str()) {
                return true;
            }

            // Prefixes
            let default_prefixes = ["~$", "._", "~wrl", "~df", "~rf"];
            if default_prefixes.iter().any(|pre| lowered_file_name.starts_with(pre)) {
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
                        ".trashes", ".spotlight-v100", ".fseventsd", ".temporaryitems",
                        ".git", ".svn", ".hg", "node_modules", ".next", ".nuxt",
                        "dist", "build", ".build", "deriveddata", ".idea", ".vscode",
                        ".swiftpm", ".cache"
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
                    "asd", "lck", "lock", "tmp", "temp", "swp", "swo", "part",
                    "download", "crdownload"
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

    pub fn start<F>(&mut self, paths: Vec<PathBuf>, db_path: PathBuf, on_events_coalesced: F) -> Result<(), String>
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
                    EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::Both)) => {
                        if event.paths.len() == 2 {
                            let old_path = &event.paths[0];
                            let new_path = &event.paths[1];
                            let rules = ignore_rules.lock().unwrap();
                            let old_ignored = rules.matches(old_path);
                            let new_ignored = rules.matches(new_path);
                            if !old_ignored && !new_ignored {
                                let _ = tx_clone.blocking_send((new_path.clone(), format!("renamed:{}", old_path.to_string_lossy())));
                                let _ = tx_clone.blocking_send((old_path.clone(), "rename_source".to_string()));
                            } else if !old_ignored {
                                let _ = tx_clone.blocking_send((old_path.clone(), "deleted".to_string()));
                            } else if !new_ignored {
                                let _ = tx_clone.blocking_send((new_path.clone(), "created".to_string()));
                            }
                            return;
                        }
                    }
                    EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::From)) => {
                        if event.paths.len() == 1 {
                            let old_path = &event.paths[0];
                            let rules = ignore_rules.lock().unwrap();
                            if !rules.matches(old_path) {
                                let _ = tx_clone.blocking_send((old_path.clone(), "rename_from".to_string()));
                            }
                            return;
                        }
                    }
                    EventKind::Modify(notify::event::ModifyKind::Name(notify::event::RenameMode::To)) => {
                        if event.paths.len() == 1 {
                            let new_path = &event.paths[0];
                            let rules = ignore_rules.lock().unwrap();
                            if !rules.matches(new_path) {
                                let _ = tx_clone.blocking_send((new_path.clone(), "rename_to".to_string()));
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
                            pending_events.remove(&path);
                            recent_froms.push((path, Instant::now()));
                        } else if event_type == "rename_to" {
                            // Part of separate RenameMode::To - find a matching from within last 2 seconds
                            if let Some(pos) = recent_froms.iter().position(|_| true) {
                                let (old_path, _) = recent_froms.remove(pos);
                                let resolved_type = format!("renamed:{}", old_path.to_string_lossy());
                                pending_events.insert(path, (resolved_type, Instant::now()));
                            } else {
                                // No matching from, treat as created
                                pending_events.insert(path, ("created".to_string(), Instant::now()));
                            }
                        } else if event_type.starts_with("renamed:") {
                            // Direct RenameMode::Both destination
                            pending_events.insert(path, (event_type, Instant::now()));
                        } else {
                            // Standard event (created, modified, deleted)
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
                        let mut completed_paths = Vec::new();

                        for (path, (event_type, last_time)) in &pending_events {
                            if now.duration_since(*last_time) >= Duration::from_secs(2) {
                                completed_paths.push(path.clone());

                                // Resolve the true final event state by disk checks
                                let exists = path.exists();
                                let mut final_old_path = None;
                                let resolved_type = if !exists {
                                    "deleted".to_string()
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

                                let file_event = FileEvent {
                                    id: Uuid::new_v4().to_string(),
                                    path: path.to_string_lossy().to_string(),
                                    old_path: final_old_path,
                                    event_type: resolved_type,
                                    timestamp,
                                    is_synced: false,
                                    has_notified: false,
                                    is_directory: path.is_dir(),
                                    remote_id: None,
                                };

                                // Save event directly into SQLite database
                                if let Ok(conn) = db::init_db(&db_path) {
                                    let _ = db::insert_event(&conn, &file_event);
                                }

                                resolved_events.push(file_event);
                            }
                        }

                        // Remove completed items
                        for path in completed_paths {
                            pending_events.remove(&path);
                        }

                        // Trigger front-end notification if new debounced events completed
                        if !resolved_events.is_empty() {
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
