mod db;
mod credentials;
mod monitor;
mod ima_sync;
mod tray;

use std::sync::{Arc, Mutex};
use std::path::PathBuf;
use tauri::{AppHandle, Manager, State, Emitter};

use db::FileEvent;
use monitor::{DirectoryMonitor, IgnoreRules};
use credentials::CachedCredentials;
use ima_sync::{IMASyncClient, KnowledgeBase};

pub struct AppState {
    db_conn: Mutex<rusqlite::Connection>,
    monitor: Arc<Mutex<DirectoryMonitor>>,
    db_path: PathBuf,
}

#[tauri::command]
fn get_file_events(state: State<'_, AppState>, pending_only: bool) -> Result<Vec<FileEvent>, String> {
    let conn = state.db_conn.lock().unwrap();
    if pending_only {
        db::get_pending_events(&conn).map_err(|e| e.to_string())
    } else {
        db::get_all_events(&conn).map_err(|e| e.to_string())
    }
}

#[tauri::command]
fn mark_event_synced(state: State<'_, AppState>, id: String) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    db::mark_event_synced(&conn, &id).map_err(|e| e.to_string())
}

#[tauri::command]
fn clear_all_events(state: State<'_, AppState>) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    db::clear_all_events(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_config_value(state: State<'_, AppState>, key: String) -> Result<Option<String>, String> {
    let conn = state.db_conn.lock().unwrap();
    db::get_config(&conn, &key).map_err(|e| e.to_string())
}

#[tauri::command]
fn set_config_value(state: State<'_, AppState>, key: String, value: String) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    db::save_config(&conn, &key, &value).map_err(|e| e.to_string())
}

#[tauri::command]
fn get_ima_credentials() -> Option<CachedCredentials> {
    credentials::load_credentials()
}

#[tauri::command]
fn save_ima_credentials(token: String, refresh_token: String, uid: String, guid: String) -> Result<(), String> {
    let creds = CachedCredentials { token, refresh_token, uid, guid };
    credentials::save_credentials(&creds)
}

#[tauri::command]
fn clear_ima_credentials() -> Result<(), String> {
    credentials::clear_credentials()
}

#[tauri::command]
async fn get_ima_knowledge_bases(token: String, refresh_token: String, uid: String, guid: String) -> Result<Vec<KnowledgeBase>, String> {
    let creds = CachedCredentials { token, refresh_token, uid, guid };
    let client = IMASyncClient::new();
    client.get_knowledge_bases(&creds).await
}

#[tauri::command]
async fn get_ima_user_profile(token: String, refresh_token: String, uid: String, guid: String) -> Result<(String, String), String> {
    let creds = CachedCredentials { token, refresh_token, uid, guid };
    let client = IMASyncClient::new();
    client.get_user_profile(&creds).await
}

#[tauri::command]
fn start_file_monitor(state: State<'_, AppState>, paths: Vec<String>, app_handle: AppHandle) -> Result<(), String> {
    let mut monitor = state.monitor.lock().unwrap();
    let path_bufs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
    
    // Load config ignore settings to pass to monitor
    let conn = state.db_conn.lock().unwrap();
    let enable_default = db::get_config(&conn, "enableDefaultIgnoreRules")
        .unwrap_or(None)
        .map(|v| v == "true")
        .unwrap_or(true);
        
    let custom_files = db::get_config(&conn, "customIgnoredFileNames")
        .unwrap_or(None)
        .map(|v| v.split(',').map(|s| s.to_string()).collect())
        .unwrap_or_else(Vec::new);
        
    let custom_exts = db::get_config(&conn, "customIgnoredExtensions")
        .unwrap_or(None)
        .map(|v| v.split(',').map(|s| s.to_string()).collect())
        .unwrap_or_else(Vec::new);
        
    let custom_dirs = db::get_config(&conn, "customIgnoredDirectoryNames")
        .unwrap_or(None)
        .map(|v| v.split(',').map(|s| s.to_string()).collect())
        .unwrap_or_else(Vec::new);

    let ignore_rules = IgnoreRules::new(enable_default, custom_files, custom_exts, custom_dirs);
    monitor.update_ignore_rules(ignore_rules);

    let db_path = state.db_path.clone();
    monitor.start(path_bufs, db_path, move |events| {
        // Emit events to frontend dynamically
        let _ = app_handle.emit("file-change-events", events);
    })?;

    Ok(())
}

#[tauri::command]
fn select_directory() -> Result<Option<String>, String> {
    let folder = rfd::FileDialog::new()
        .pick_folder();
    
    match folder {
        Some(path) => Ok(Some(path.to_string_lossy().to_string())),
        None => Ok(None),
    }
}

#[tauri::command]
fn stop_file_monitor(state: State<'_, AppState>) {
    let mut monitor = state.monitor.lock().unwrap();
    monitor.stop();
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // Locate user data directory for SQLite database
            let app_dir = app.path().app_data_dir()
                .unwrap_or_else(|_| PathBuf::from("./"));
            
            // Ensure app directory exists
            std::fs::create_dir_all(&app_dir).unwrap_or_default();
            
            let db_path = app_dir.join("file_sync_monitor.db");
            let conn = db::init_db(&db_path)
                .expect("Failed to initialize SQLite database");

            let monitor = DirectoryMonitor::new(IgnoreRules::new(true, vec![], vec![], vec![]));

            // Setup global shared State
            app.manage(AppState {
                db_conn: Mutex::new(conn),
                monitor: Arc::new(Mutex::new(monitor)),
                db_path,
            });

            // Scaffold dynamic System Tray
            tray::setup_system_tray(app.handle())?;

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_file_events,
            mark_event_synced,
            clear_all_events,
            get_config_value,
            set_config_value,
            get_ima_credentials,
            save_ima_credentials,
            clear_ima_credentials,
            get_ima_knowledge_bases,
            get_ima_user_profile,
            start_file_monitor,
            stop_file_monitor,
            select_directory
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
