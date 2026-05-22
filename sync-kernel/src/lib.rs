mod db;
mod credentials;
mod monitor;
mod ima_sync;
mod tray;

use std::sync::{Arc, Mutex};
use std::path::{Path, PathBuf};
use std::collections::HashMap;
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Manager, State, Emitter, PhysicalPosition};
use rusqlite::params;

use db::FileEvent;
use monitor::{DirectoryMonitor, IgnoreRules};
use credentials::CachedCredentials;
use ima_sync::{IMASyncClient, KnowledgeBase, KnowledgeInfo};

#[derive(Debug, Clone, serde::Serialize)]
pub struct HttpLogEntry {
    pub id: String,
    pub timestamp: String,
    pub method: String,
    pub url: String,
    pub request_headers: Option<String>,
    pub request_body: Option<String>,
    pub response_code: Option<u16>,
    pub response_body: Option<String>,
    pub error: Option<String>,
}

pub static HTTP_LOGS: std::sync::OnceLock<Mutex<Vec<HttpLogEntry>>> = std::sync::OnceLock::new();
static LOG_ID_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

pub fn generate_log_id() -> String {
    LOG_ID_COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed).to_string()
}

pub fn get_http_logs_mutex() -> &'static Mutex<Vec<HttpLogEntry>> {
    HTTP_LOGS.get_or_init(|| Mutex::new(Vec::new()))
}

pub fn add_http_log(entry: HttpLogEntry) {
    if let Ok(mut logs) = get_http_logs_mutex().lock() {
        logs.insert(0, entry);
        if logs.len() > 100 {
            logs.truncate(100);
        }
    }
}

pub fn update_http_log_response(id: &str, code: u16, body: &str) {
    if let Ok(mut logs) = get_http_logs_mutex().lock() {
        if let Some(log) = logs.iter_mut().find(|l| l.id == id) {
            log.response_code = Some(code);
            log.response_body = Some(body.to_string());
        }
    }
}

pub fn update_http_log_error(id: &str, error: &str) {
    if let Ok(mut logs) = get_http_logs_mutex().lock() {
        if let Some(log) = logs.iter_mut().find(|l| l.id == id) {
            log.error = Some(error.to_string());
        }
    }
}

#[tauri::command]
fn get_http_logs() -> Result<Vec<HttpLogEntry>, String> {
    if let Ok(logs) = get_http_logs_mutex().lock() {
        Ok(logs.clone())
    } else {
        Err("Failed to acquire logs lock".to_string())
    }
}

#[tauri::command]
fn clear_http_logs() -> Result<(), String> {
    if let Ok(mut logs) = get_http_logs_mutex().lock() {
        logs.clear();
        Ok(())
    } else {
        Err("Failed to acquire logs lock".to_string())
    }
}

pub struct AppState {
    db_conn: Mutex<rusqlite::Connection>,
    monitor: Arc<Mutex<DirectoryMonitor>>,
    db_path: PathBuf,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct SyncProgressPayload {
    pub step: String, // "pull", "push", "complete", "error"
    pub title: String,
    pub status: String,
    pub progress: f64,
}

#[tauri::command]
async fn sync_all_directories(
    state: State<'_, AppState>,
    mappings: HashMap<String, String>,
    direction: Option<String>,
    app_handle: AppHandle,
) -> Result<(), String> {
    let creds = credentials::load_credentials()
        .ok_or_else(|| "请先在系统设置中登录 IMA 微信账号".to_string())?;

    let client = IMASyncClient::new();

    // Pause file watcher during sync to prevent feedback loop
    {
        let mut monitor = state.monitor.lock().unwrap();
        monitor.stop();
    }

    let emit_progress = |step: &str, title: &str, status: &str, progress: f64| {
        let _ = app_handle.emit("sync-progress", SyncProgressPayload {
            step: step.to_string(),
            title: title.to_string(),
            status: status.to_string(),
            progress,
        });
    };

    let run_pull = direction.as_deref() != Some("push") && direction.as_deref() != Some("sync_to_ima");
    let run_push = direction.as_deref() != Some("pull") && direction.as_deref() != Some("pull_from_remote");

    emit_progress("start", "开始同步...", "正在初始化云端连接...", 0.0);

    let total_dirs = mappings.len();
    if total_dirs == 0 {
        let conn = state.db_conn.lock().unwrap();
        let _ = resume_watcher(&state, &conn, &app_handle);
        emit_progress("complete", "同步完成！", "没有绑定任何需要同步的知识库。", 100.0);
        return Ok(());
    }

    let mut current_dir_idx = 0;

    for (local_path_str, kb_id) in &mappings {
        current_dir_idx += 1;
        let base_progress = ((current_dir_idx - 1) as f64 / total_dirs as f64) * 100.0;
        let step_progress_slice = 100.0 / total_dirs as f64;

        let root_path = Path::new(local_path_str);
        if !root_path.exists() {
            println!("Local monitored path does not exist: {}", local_path_str);
            continue;
        }

        let dir_name = root_path.file_name()
            .map(|s| s.to_string_lossy().to_string())
            .unwrap_or_else(|| local_path_str.clone());

        // --- PULL PHASE (Remote to Local) ---
        if run_pull {
            emit_progress(
                "pull",
                &format!("正在拉取云端变动 ({}/{})", current_dir_idx, total_dirs),
                &format!("正在获取知识库 '{}' 文件树...", dir_name),
                base_progress + step_progress_slice * 0.1,
            );

            let remote_items = match client.fetch_all_knowledge_items(kb_id, None, &creds).await {
                Ok(items) => items,
                Err(e) => {
                    let conn = state.db_conn.lock().unwrap();
                    let _ = resume_watcher(&state, &conn, &app_handle);
                    emit_progress("error", "同步发生错误", &format!("获取云端列表失败: {}", e), 100.0);
                    return Err(format!("获取云端列表失败: {}", e));
                }
            };

            let mut active_remote_ids = std::collections::HashSet::new();
            for item in &remote_items {
                active_remote_ids.insert(item.media_id.clone());
                if let Some(fid) = item.folder_identifier() {
                    active_remote_ids.insert(fid);
                }
            }

            let folders: Vec<&KnowledgeInfo> = remote_items.iter().filter(|x| x.is_folder()).collect();
            let mut folder_meta = HashMap::new();
            for f in &folders {
                if let Some(fid) = f.folder_identifier() {
                    if !fid.is_empty() {
                        folder_meta.insert(fid, (f.parent_folder_id.clone(), f.display_name().to_string()));
                    }
                }
            }

            let mut folder_id_to_path = HashMap::new();
            for fid in folder_meta.keys() {
                let mut parts = Vec::new();
                let mut curr = fid.clone();
                let mut visited = std::collections::HashSet::new();
                while !curr.is_empty() && curr != *kb_id && visited.insert(curr.clone()) {
                    if let Some((parent, name)) = folder_meta.get(&curr) {
                        parts.push(name.clone());
                        curr = parent.clone().unwrap_or_default();
                    } else {
                        break;
                    }
                }
                parts.reverse();
                folder_id_to_path.insert(fid.clone(), parts.join("/"));
            }

            // 1. Check for remote deletions
            {
                let conn = state.db_conn.lock().unwrap();
                if let Ok(synced_locals) = db::get_synced_events_under_path(&conn, local_path_str) {
                    for local_ev in synced_locals {
                        if let Some(ref rid) = local_ev.remote_id {
                            if !active_remote_ids.contains(rid) {
                                let p = Path::new(&local_ev.path);
                                if p.exists() {
                                    if local_ev.is_directory {
                                        let _ = std::fs::remove_dir_all(p);
                                    } else {
                                        let _ = std::fs::remove_file(p);
                                    }
                                }
                                let _ = conn.execute("DELETE FROM file_events WHERE id = ?1", params![local_ev.id]);
                            }
                        }
                    }
                }
            }

            // 2. Sync remote to local
            let file_items: Vec<&KnowledgeInfo> = remote_items.iter().filter(|x| !x.is_folder()).collect();
            let total_files = file_items.len();

            for f in &folders {
                if let Some(fid) = f.folder_identifier() {
                    let rel = folder_id_to_path.get(&fid).cloned().unwrap_or_default();
                    if !rel.is_empty() {
                        let local_folder_path = root_path.join(rel);
                        let _ = std::fs::create_dir_all(&local_folder_path);
                    }
                }
            }

            for (f_idx, item) in file_items.iter().enumerate() {
                let file_progress = base_progress + step_progress_slice * 0.1 + (f_idx as f64 / total_files.max(1) as f64) * step_progress_slice * 0.4;
                emit_progress(
                    "pull",
                    &format!("正在拉取云端变动 ({}/{})", current_dir_idx, total_dirs),
                    &format!("正在下载云端文件 ({}/{}): {}", f_idx + 1, total_files, item.display_name()),
                    file_progress,
                );

                let rel_parent = if let Some(ref pid) = item.parent_folder_id {
                    if pid == kb_id {
                        "".to_string()
                    } else {
                        folder_id_to_path.get(pid).cloned().unwrap_or_default()
                    }
                } else {
                    "".to_string()
                };

                let local_file_path = if rel_parent.is_empty() {
                    root_path.join(item.display_name())
                } else {
                    root_path.join(&rel_parent).join(item.display_name())
                };

                let local_path_str = local_file_path.to_string_lossy().to_string();

                let exists_locally = local_file_path.exists();
                let mut should_download = true;

                if exists_locally {
                    let conn = state.db_conn.lock().unwrap();
                    if let Ok(Some(local_ev)) = db::get_event_by_path(&conn, &local_path_str) {
                        if local_ev.is_synced {
                            should_download = false;
                        }
                    }
                }

                if should_download {
                    if client.download_file(&item.media_id, kb_id, &local_file_path, &creds).await.is_ok() {
                        let conn = state.db_conn.lock().unwrap();
                        let timestamp = SystemTime::now()
                            .duration_since(UNIX_EPOCH)
                            .unwrap_or_default()
                            .as_secs_f64();

                        let sync_ev = db::FileEvent {
                            id: uuid::Uuid::new_v4().to_string(),
                            path: local_path_str.clone(),
                            old_path: None,
                            event_type: "created".to_string(),
                            timestamp,
                            is_synced: true,
                            has_notified: true,
                            is_directory: false,
                            remote_id: Some(item.media_id.clone()),
                        };
                        let _ = db::insert_event(&conn, &sync_ev);
                    }
                }
            }
        }

        // --- PUSH PHASE (Local to Remote) ---
        if run_push {
            emit_progress(
                "push",
                &format!("正在上传本地变动 ({}/{})", current_dir_idx, total_dirs),
                "正在扫描本地待同步的改动记录...",
                base_progress + step_progress_slice * 0.5,
            );

            let pending_local_events = {
                let conn = state.db_conn.lock().unwrap();
                db::get_pending_events(&conn).unwrap_or_default()
            };

            let current_root_events: Vec<FileEvent> = pending_local_events.into_iter()
                .filter(|ev| Path::new(&ev.path).starts_with(root_path))
                .collect();

            let total_pushes = current_root_events.len();

            for (p_idx, ev) in current_root_events.iter().enumerate() {
                let push_progress = base_progress + step_progress_slice * 0.5 + (p_idx as f64 / total_pushes.max(1) as f64) * step_progress_slice * 0.45;
                let file_name = Path::new(&ev.path).file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| ev.path.clone());

                emit_progress(
                    "push",
                    &format!("正在上传本地变动 ({}/{})", current_dir_idx, total_dirs),
                    &format!("正在同步本地改动 ({}/{}): {}", p_idx + 1, total_pushes, file_name),
                    push_progress,
                );

                let ev_path = Path::new(&ev.path);
                let rel_folder_path = if let Ok(rel) = ev_path.parent().unwrap_or(root_path).strip_prefix(root_path) {
                    rel.to_string_lossy().to_string()
                } else {
                    "".to_string()
                };

                match ev.event_type.as_str() {
                    "deleted" => {
                        if let Some(ref rid) = ev.remote_id {
                            let _ = client.delete_knowledge_by_web_api(&[rid.clone()], kb_id, &creds).await;
                        }
                        let conn = state.db_conn.lock().unwrap();
                        let _ = db::mark_event_synced(&conn, &ev.id);
                    }
                    "renamed" => {
                        if let Some(ref rid) = ev.remote_id {
                            let _ = client.rename_knowledge(rid, &file_name, kb_id, None, &creds).await;
                        }
                        let conn = state.db_conn.lock().unwrap();
                        let _ = db::mark_event_synced(&conn, &ev.id);
                    }
                    "created" | "modified" => {
                        if ev.is_directory {
                            let resolved_folder_id = match client.resolve_folder_id_if_needed(kb_id, &rel_folder_path, &creds).await {
                                Ok(fid) => fid,
                                Err(_) => None,
                            };
                            match client.create_folder(&file_name, kb_id, resolved_folder_id.as_deref(), &creds).await {
                                Ok(new_fid) => {
                                    let conn = state.db_conn.lock().unwrap();
                                    let _ = db::mark_event_synced_with_remote_id(&conn, &ev.id, &new_fid);
                                }
                                Err(e) => {
                                    println!("Failed to create remote directory '{}': {:?}", file_name, e);
                                }
                            }
                        } else {
                            let resolved_folder_id = match client.resolve_folder_id_if_needed(kb_id, &rel_folder_path, &creds).await {
                                Ok(fid) => fid,
                                Err(_) => None,
                            };

                            match client.upload_to_wiki(ev_path, kb_id, resolved_folder_id.as_deref(), ev.remote_id.as_deref(), &creds).await {
                                Ok(media_id) => {
                                    let conn = state.db_conn.lock().unwrap();
                                    let _ = db::mark_event_synced_with_remote_id(&conn, &ev.id, &media_id);
                                }
                                Err(e) => {
                                    println!("Failed to upload file '{}': {:?}", file_name, e);
                                }
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
    }

    let conn = state.db_conn.lock().unwrap();
    let _ = resume_watcher(&state, &conn, &app_handle);

    emit_progress("complete", "同步完成！", "所有关联知识库与本地目录已双向同步成功。", 100.0);

    Ok(())
}

fn resume_watcher(state: &AppState, conn: &rusqlite::Connection, app_handle: &AppHandle) -> Result<(), String> {
    let paths_str = db::get_config(conn, "monitoredDirectories")
        .unwrap_or(None)
        .or_else(|| db::get_config(conn, "monitoredPaths").unwrap_or(None))
        .unwrap_or_default();
    
    let paths: Vec<String> = if paths_str.is_empty() {
        Vec::new()
    } else {
        serde_json::from_str(&paths_str).unwrap_or_else(|_| {
            paths_str.split(',').map(|s| s.to_string()).filter(|s| !s.is_empty()).collect()
        })
    };

    if !paths.is_empty() {
        let mut monitor = state.monitor.lock().unwrap();
        let path_bufs: Vec<PathBuf> = paths.iter().map(PathBuf::from).collect();
        let app_handle_clone = app_handle.clone();
        
        let enable_default = db::get_config(conn, "enableDefaultIgnoreRules")
            .unwrap_or(None)
            .map(|v| v == "true")
            .unwrap_or(true);
            
        let custom_files = db::get_config(conn, "customIgnoredFileNames")
            .unwrap_or(None)
            .map(|v| v.split(',').map(|s| s.to_string()).collect())
            .unwrap_or_else(Vec::new);
            
        let custom_exts = db::get_config(conn, "customIgnoredExtensions")
            .unwrap_or(None)
            .map(|v| v.split(',').map(|s| s.to_string()).collect())
            .unwrap_or_else(Vec::new);
            
        let custom_dirs = db::get_config(conn, "customIgnoredDirectoryNames")
            .unwrap_or(None)
            .map(|v| v.split(',').map(|s| s.to_string()).collect())
            .unwrap_or_else(Vec::new);

        let ignore_rules = IgnoreRules::new(enable_default, custom_files, custom_exts, custom_dirs);
        monitor.update_ignore_rules(ignore_rules);

        let db_path = state.db_path.clone();
        monitor.start(path_bufs, db_path, move |events| {
            let _ = app_handle_clone.emit("file-change-events", events);
        })?;
    }
    
    Ok(())
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
fn mark_all_events_synced(state: State<'_, AppState>) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    conn.execute("UPDATE file_events SET is_synced = 1 WHERE is_synced = 0", [])
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
async fn sync_single_event(
    state: State<'_, AppState>,
    event_id: String,
    kb_id: String,
    root_path_str: String,
    app_handle: AppHandle,
) -> Result<(), String> {
    let creds = credentials::load_credentials()
        .ok_or_else(|| "请先在系统设置中登录 IMA 微信账号".to_string())?;

    let client = IMASyncClient::new();

    // Pause file watcher during sync to prevent feedback loop
    {
        let mut monitor = state.monitor.lock().unwrap();
        monitor.stop();
    }

    let ev = {
        let conn = state.db_conn.lock().unwrap();
        db::get_event_by_id(&conn, &event_id)
            .map_err(|e| e.to_string())?
            .ok_or_else(|| "找不到该文件变动记录".to_string())?
    };

    let file_name = Path::new(&ev.path).file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| ev.path.clone());

    let ev_path = Path::new(&ev.path);
    let root_path = Path::new(&root_path_str);
    let rel_folder_path = if let Ok(rel) = ev_path.parent().unwrap_or(root_path).strip_prefix(root_path) {
        rel.to_string_lossy().to_string()
    } else {
        "".to_string()
    };

    let sync_result = match ev.event_type.as_str() {
        "deleted" => {
            if let Some(ref rid) = ev.remote_id {
                let _ = client.delete_knowledge_by_web_api(&[rid.clone()], &kb_id, &creds).await;
            }
            let conn = state.db_conn.lock().unwrap();
            db::mark_event_synced(&conn, &ev.id).map_err(|e| e.to_string())
        }
        "renamed" => {
            if let Some(ref rid) = ev.remote_id {
                let _ = client.rename_knowledge(rid, &file_name, &kb_id, None, &creds).await;
            }
            let conn = state.db_conn.lock().unwrap();
            db::mark_event_synced(&conn, &ev.id).map_err(|e| e.to_string())
        }
        "created" | "modified" => {
            if ev.is_directory {
                let resolved_folder_id = match client.resolve_folder_id_if_needed(&kb_id, &rel_folder_path, &creds).await {
                    Ok(fid) => fid,
                    Err(_) => None,
                };
                match client.create_folder(&file_name, &kb_id, resolved_folder_id.as_deref(), &creds).await {
                    Ok(new_fid) => {
                        let conn = state.db_conn.lock().unwrap();
                        db::mark_event_synced_with_remote_id(&conn, &ev.id, &new_fid).map_err(|e| e.to_string())
                    }
                    Err(e) => {
                        Err(format!("创建云端文件夹失败: {:?}", e))
                    }
                }
            } else {
                let resolved_folder_id = match client.resolve_folder_id_if_needed(&kb_id, &rel_folder_path, &creds).await {
                    Ok(fid) => fid,
                    Err(_) => None,
                };

                match client.upload_to_wiki(ev_path, &kb_id, resolved_folder_id.as_deref(), ev.remote_id.as_deref(), &creds).await {
                    Ok(media_id) => {
                        let conn = state.db_conn.lock().unwrap();
                        db::mark_event_synced_with_remote_id(&conn, &ev.id, &media_id).map_err(|e| e.to_string())
                    }
                    Err(e) => {
                        Err(format!("上传文件失败: {:?}", e))
                    }
                }
            }
        }
        _ => Err("未知事件类型".to_string()),
    };

    let conn = state.db_conn.lock().unwrap();
    let _ = resume_watcher(&state, &conn, &app_handle);

    sync_result
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
async fn get_ima_credentials() -> Option<CachedCredentials> {
    credentials::load_credentials()
}

#[tauri::command]
async fn save_ima_credentials(token: String, refresh_token: String, uid: String, guid: String) -> Result<(), String> {
    let creds = CachedCredentials { token, refresh_token, uid, guid };
    credentials::save_credentials(&creds)
}

#[tauri::command]
async fn clear_ima_credentials() -> Result<(), String> {
    credentials::clear_credentials()
}

#[tauri::command]
async fn fetch_knowledge_bases() -> Result<Vec<KnowledgeBase>, String> {
    let creds = credentials::load_credentials()
        .ok_or_else(|| "请先在系统设置中登录 IMA 微信账号".to_string())?;
    let client = IMASyncClient::new();
    client.get_knowledge_bases(&creds).await
}

#[tauri::command]
fn set_kb_binding(state: State<'_, AppState>, path: String, kb_id: String) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    println!("[DB Binding] Binding path '{}' to KB '{}'", path, kb_id);
    db::save_config(&conn, &format!("kb_binding_{}", path), &kb_id).map_err(|e| {
        let err_msg = e.to_string();
        println!("[DB Binding Error] Failed to bind: {}", err_msg);
        err_msg
    })
}

#[tauri::command]
fn get_launch_at_login() -> bool {
    let home = std::env::var("HOME").unwrap_or_default();
    if home.is_empty() { return false; }
    let plist_path = std::path::PathBuf::from(home)
        .join("Library/LaunchAgents/com.filesyncmonitor.plist");
    plist_path.exists()
}

#[tauri::command]
fn set_launch_at_login(enable: bool) -> Result<(), String> {
    let home = std::env::var("HOME").map_err(|e| e.to_string())?;
    if home.is_empty() { return Err("HOME directory not found".to_string()); }
    
    let launch_agents_dir = std::path::PathBuf::from(&home).join("Library/LaunchAgents");
    let plist_path = launch_agents_dir.join("com.filesyncmonitor.plist");
    
    if enable {
        let exe_path = std::env::current_exe()
            .map_err(|e| format!("Failed to get current exe path: {}", e))?;
        let exe_str = exe_path.to_string_lossy();
        
        let _ = std::fs::create_dir_all(&launch_agents_dir);
        
        let plist_content = format!(
            r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.filesyncmonitor</string>
    <key>ProgramArguments</key>
    <array>
        <string>{}</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>"#,
            exe_str
        );
        std::fs::write(&plist_path, plist_content)
            .map_err(|e| format!("Failed to write plist file: {}", e))?;
    } else {
        if plist_path.exists() {
            std::fs::remove_file(&plist_path)
                .map_err(|e| format!("Failed to remove plist file: {}", e))?;
        }
    }
    Ok(())
}

#[tauri::command]
fn update_ignore_rules(state: State<'_, AppState>) -> Result<(), String> {
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
    let monitor = state.monitor.lock().unwrap();
    monitor.update_ignore_rules(ignore_rules);
    Ok(())
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
async fn get_ima_space_quota(token: String, refresh_token: String, uid: String, guid: String) -> Result<ima_sync::SpaceQuota, String> {
    let creds = CachedCredentials { token, refresh_token, uid, guid };
    let client = IMASyncClient::new();
    client.get_space_quota(&creds).await
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
async fn select_directory(app_handle: AppHandle) -> Result<Option<String>, String> {
    let (tx, rx) = tokio::sync::oneshot::channel();
    app_handle.run_on_main_thread(move || {
        let folder = rfd::FileDialog::new().pick_folder();
        let res = folder.map(|path| path.to_string_lossy().to_string());
        let _ = tx.send(res);
    }).map_err(|e| e.to_string())?;
    
    rx.await.map_err(|e| e.to_string())
}

#[tauri::command]
fn stop_file_monitor(state: State<'_, AppState>) {
    let mut monitor = state.monitor.lock().unwrap();
    monitor.stop();
}

#[tauri::command]
fn exit_app(app_handle: AppHandle) {
    app_handle.exit(0);
}

#[tauri::command]
fn show_main_window(app: tauri::AppHandle) {
    use tauri::Manager;
    if let Some(win) = app.get_webview_window("main") {
        let _ = win.show();
        let _ = win.set_focus();
        // #[cfg(debug_assertions)]
        // {
        //     win.open_devtools();
        // }
    }
}

#[tauri::command]
fn log_js_message(level: String, msg: String) {
    println!("[JS {}] {}", level, msg);
}


#[cfg_attr(mobile, tauri::mobile_entry_point)]
#[tauri::command]
fn open_login_window(app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Manager;
    
    if let Some(win) = app.get_webview_window("ima_login") {
        win.set_focus().unwrap();
        return Ok(());
    }

    let url_str = "https://ima.qq.com/login/";
    let url = tauri::Url::parse(url_str).map_err(|e| e.to_string())?;

    let js_injection = r##"
        (() => {
            if (window.__fsmLoginCaptureInstalled) return;
            window.__fsmLoginCaptureInstalled = true;

            let hasSubmitted = false;

            function bridge(action, params = {}) {
                const query = new URLSearchParams(params).toString();
                window.location.href = `https://fsmsync.localhost/${action}${query ? `?${query}` : ""}`;
            }

            function log(message) {
                try {
                    const iframe = document.createElement("iframe");
                    iframe.style.display = "none";
                    iframe.src = `https://fsmsync.localhost/log?msg=${encodeURIComponent(message)}`;
                    (document.documentElement || document).appendChild(iframe);
                    setTimeout(() => iframe.remove(), 3000);
                } catch (_) {}
            }

            function requestUrl(input) {
                if (typeof input === "string") return input;
                if (input instanceof URL) return input.href;
                if (input && typeof input.url === "string") return input.url;
                return String(input || "");
            }

            function isLoginResponseUrl(url) {
                return url.includes("/cgi-bin/auth_login/login") ||
                    (url.includes("auth_login") && url.includes("login")) ||
                    (url.includes("login") && url.includes("auth"));
            }

            function parsePossibleJson(value) {
                if (typeof value !== "string") return value;
                try {
                    return JSON.parse(value);
                } catch (_) {
                    return value;
                }
            }

            function normalizeLoginData(data) {
                data = parsePossibleJson(data);
                if (!data || typeof data !== "object") return null;

                const candidates = [data, parsePossibleJson(data.data), data.result, data.payload]
                    .filter(item => item && typeof item === "object");

                for (const item of candidates) {
                    const token = item.token || item.ima_token || item["IMA-TOKEN"];
                    const refreshToken = item.refresh_token || item.refreshToken || item["IMA-REFRESH-TOKEN"] || token || "";
                    const uid = item.user_id || item.uid || item.userId || item.user_info?.open_info?.uid || "";
                    const guid = item.guid || item.user_info?.open_info?.guid || item.client_info?.guid || "";
                    const avatar = item.avatar || item.avatar_url || item.user_info?.open_info?.avatar_url || item.user_info?.open_info?.avatarUrl || "";
                    const nickname = item.nickname || item.user_info?.open_info?.nickname || "";
                    if (token && uid) {
                        return {
                            token: String(token),
                            refresh_token: String(refreshToken),
                            uid: String(uid),
                            guid: String(guid),
                            avatar: String(avatar),
                            nickname: String(nickname)
                        };
                    }
                }

                return null;
            }

            function submitLogin(data, source) {
                if (hasSubmitted) return;
                const creds = normalizeLoginData(data);
                if (!creds || !creds.token || !creds.uid || creds.token === "guest") return;
                hasSubmitted = true;
                log(`Login credentials captured via ${source}; uid=${creds.uid}`);
                bridge("login-success", creds);
            }

            const originalFetch = window.fetch;
            window.fetch = async function(...args) {
                const url = requestUrl(args[0]);
                const response = await originalFetch.apply(this, args);
                if (isLoginResponseUrl(url)) {
                    response.clone().text()
                        .then(text => submitLogin(text, "fetch"))
                        .catch(error => log(`Fetch login parse error: ${error}`));
                }
                return response;
            };

            const originalOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
            if (originalOpen) {
                window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                    this.__fsmLoginUrl = requestUrl(url);
                    return originalOpen.call(this, method, url, ...rest);
                };

                const originalSend = window.XMLHttpRequest.prototype.send;
                window.XMLHttpRequest.prototype.send = function(...args) {
                    this.addEventListener("loadend", function() {
                        if (!isLoginResponseUrl(this.__fsmLoginUrl || "")) return;
                        try {
                            submitLogin(this.responseText || this.response, "xhr");
                        } catch (error) {
                            log(`XHR login parse error: ${error}`);
                        }
                    });
                    return originalSend.apply(this, args);
                };
            }

            log("Login capture hooks installed");
        })();

        function installLoginChrome() {
            if (!document.body || document.getElementById('custom-close-btn')) return;

            let style = document.createElement('style');
            style.innerHTML = `
                html, body, #app, .login-page, .main-container, .login-container, .login-box, .login-card {
                    background: transparent !important;
                    background-color: transparent !important;
                    overflow: hidden !important;
                }
                body {
                    border-radius: 20px !important;
                    margin: 0 !important;
                    padding: 0 !important;
                    border: 1px solid rgba(255,255,255,0.1) !important;
                }
                .header, .footer, .nav-bar, .login-footer, .logo-container {
                    display: none !important;
                }
                .login-box, .login-container {
                    margin: 0 !important;
                    padding: 0 !important;
                    position: absolute !important;
                    top: 50% !important;
                    left: 50% !important;
                    transform: translate(-50%, -50%) !important;
                }
            `;
            document.head.appendChild(style);

            let uiOverlay = document.createElement('div');
            uiOverlay.innerHTML = `
                <div style="position: absolute; top: 0; left: 0; right: 0; height: 50px; background: rgba(255,255,255,0.85); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); z-index: 9999; display: flex; align-items: center; justify-content: space-between; padding: 0 16px; border-bottom: 1px solid rgba(0,0,0,0.1); user-select: none;">
                    <div style="font-size: 14px; font-weight: bold; color: #333; display: flex; align-items: center; gap: 6px;">
                        <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="#22c55e" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" ry="2"></rect><rect x="7" y="7" width="3" height="3"></rect><rect x="14" y="7" width="3" height="3"></rect><rect x="7" y="14" width="3" height="3"></rect><rect x="14" y="14" width="3" height="3"></rect></svg>
                        微信扫码登录
                    </div>
                    <div style="display: flex; gap: 16px;">
                        <div id="custom-refresh-btn" style="cursor: pointer; display: flex; align-items: center; gap: 4px; font-size: 12px; color: #666;">
                            <svg viewBox="0 0 24 24" width="12" height="12" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
                            刷新
                        </div>
                        <div id="custom-close-btn" style="cursor: pointer; display: flex; align-items: center; gap: 4px; font-size: 12px; color: #ef4444;">
                            <svg viewBox="0 0 24 24" width="12" height="12" stroke="currentColor" stroke-width="2" fill="none" stroke-linecap="round" stroke-linejoin="round"><line x1="18" y1="6" x2="6" y2="18"></line><line x1="6" y1="6" x2="18" y2="18"></line></svg>
                            取消
                        </div>
                    </div>
                </div>
                <div style="position: absolute; bottom: 0; left: 0; right: 0; height: 40px; background: rgba(255,255,255,0.85); backdrop-filter: blur(10px); -webkit-backdrop-filter: blur(10px); z-index: 9999; display: flex; align-items: center; justify-content: center; border-top: 1px solid rgba(0,0,0,0.1); user-select: none;">
                    <div style="display: flex; align-items: center; gap: 6px; font-size: 10px; color: #999;">
                        <svg viewBox="0 0 24 24" width="12" height="12" fill="currentColor"><path d="M12 1L3 5v6c0 5.55 3.84 10.74 9 12 5.16-1.26 9-6.45 9-12V5l-9-4zm0 10.99h7c-.53 4.12-3.28 7.79-7 8.94V12H5V6.3l7-3.11v8.8z"/></svg>
                        微信凭证已安全加密托管至原生 Keychain
                    </div>
                </div>
            `;
            document.body.appendChild(uiOverlay);

            document.getElementById('custom-refresh-btn').onclick = () => window.location.reload();
            document.getElementById('custom-close-btn').onclick = () => {
                window.location.href = "https://fsmsync.localhost/login-cancel";
            };
        }

        if (document.readyState === "loading") {
            document.addEventListener("DOMContentLoaded", installLoginChrome, { once: true });
        } else {
            installLoginChrome();
        }

    "##;

    let app_clone = app.clone();
    let app_clone2 = app.clone();
    
    app.run_on_main_thread(move || {
        let builder = tauri::WebviewWindowBuilder::new(&app_clone2, "ima_login", tauri::WebviewUrl::External(url))
            .title("微信扫码登录")
            .inner_size(350.0, 410.0)
            .resizable(false)
            .decorations(false)
            .incognito(true)
            
            .user_agent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
            .initialization_script(js_injection)
            .on_navigation(move |url| {
                let is_login_bridge = url.host_str() == Some("fsmsync.localhost");

                if !is_login_bridge {
                    return true;
                }

                let action = url
                    .query_pairs()
                    .find(|(key, _)| key == "action")
                    .map(|(_, value)| value.into_owned())
                    .unwrap_or_else(|| url.path().trim_start_matches('/').to_string());
                let parsed_query: std::collections::HashMap<_, _> =
                    url.query_pairs().into_owned().collect();

                match action.as_str() {
                    "log" => {
                        if let Some(msg) = parsed_query.get("msg") {
                            println!("[WebView Log] {}", msg);
                        }
                        false
                    }
                    "login-cancel" => {
                        if let Some(win) = app_clone.get_webview_window("ima_login") {
                            let _ = win.close();
                        }
                        false
                    }
                    "login-success" => {
                        let token = parsed_query.get("token").cloned().unwrap_or_default();
                        let refresh_token = parsed_query.get("refresh_token").cloned().unwrap_or_default();
                        let uid = parsed_query.get("uid").cloned().unwrap_or_default();
                        let guid = parsed_query.get("guid").cloned().unwrap_or_default();
                        let avatar = parsed_query.get("avatar").cloned().unwrap_or_default();
                        let nickname = parsed_query.get("nickname").cloned().unwrap_or_default();

                        if !token.is_empty() {
                            println!("[IMALogin] Captured Credentials! UID: {}", uid);
                            let creds = CachedCredentials { token, refresh_token, uid: uid.clone(), guid };
                            if let Err(e) = credentials::save_credentials(&creds) {
                                println!("[IMALogin] Failed to save credentials to Keyring: {:?}", e);
                            } else {
                                println!("[IMALogin] Credentials saved successfully.");
                            }
                            let _ = app_clone.emit("login_success", serde_json::json!({
                                "avatar": avatar,
                                "nickname": nickname,
                                "uid": uid,
                            }));

                            if let Some(win) = app_clone.get_webview_window("ima_login") {
                                let _ = win.close();
                            }
                        }
                        false
                    }
                    _ => false,
                }
            });
            
        // Make it modal relative to main window
        
        
        if let Ok(win) = builder.center().build() {
            if let Some(main_window) = app_clone2.get_webview_window("main") {
                if let (Ok(main_pos), Ok(main_size), Ok(login_size)) = (
                    main_window.outer_position(),
                    main_window.outer_size(),
                    win.outer_size(),
                ) {
                    let x = main_pos.x + ((main_size.width as i32 - login_size.width as i32) / 2);
                    let y = main_pos.y + ((main_size.height as i32 - login_size.height as i32) / 2);
                    let _ = win.set_position(PhysicalPosition::new(x, y));
                }
            }
        } else if let Some(win) = app_clone2.get_webview_window("ima_login") {
            let _ = win.set_focus();
        }
    }).map_err(|e| e.to_string())?;

    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // Locate user data directory for SQLite database
            let app_dir = app.path().app_data_dir()
                .unwrap_or_else(|_| PathBuf::from("./"));
            
            // Ensure app directory exists
            std::fs::create_dir_all(&app_dir).unwrap_or_default();
            
            // Initalize credentials module with the correct sandbox data directory
            let _ = credentials::APP_DATA_DIR.set(app_dir.clone());
            
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
 
            // Automatically show and focus the main window in development mode
            #[cfg(debug_assertions)]
            {
                use tauri::Manager;
                if let Some(win) = app.get_webview_window("main") {
                    let _ = win.show();
                    let _ = win.set_focus();
                    // win.open_devtools();
                }
            }

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_file_events,
            mark_event_synced,
            mark_all_events_synced,
            sync_single_event,
            clear_all_events,
            get_config_value,
            set_config_value,
            get_ima_credentials,
            save_ima_credentials,
            clear_ima_credentials,
            get_ima_knowledge_bases,
            get_ima_user_profile,
            get_ima_space_quota,
            open_login_window,
            start_file_monitor,
            stop_file_monitor,
            select_directory,
            exit_app,
            show_main_window,
            sync_all_directories,
            fetch_knowledge_bases,
            set_kb_binding,
            get_launch_at_login,
            set_launch_at_login,
            update_ignore_rules,
            log_js_message,
            get_http_logs,
            clear_http_logs
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
