mod credentials;
mod db;
mod ima_sync;
mod monitor;
mod tray;

use base64::Engine;
use rusqlite::params;
use std::cmp::Ordering;
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};
use tauri::{AppHandle, Emitter, Manager, State};

use credentials::CachedCredentials;
use db::FileEvent;
use ima_sync::{IMASyncClient, KnowledgeBase, KnowledgeInfo};
use monitor::{DirectoryMonitor, IgnoreRules};

#[cfg(target_os = "macos")]
const WEBVIEW_USER_AGENT: &str = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
#[cfg(not(target_os = "macos"))]
const WEBVIEW_USER_AGENT: &str = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";
const IMA_WECHAT_APP_ID: &str = "wx0d63f5de059f1d52";
const IMA_WECHAT_REDIRECT_URI: &str = "https%3A%2F%2Fima.qq.com%2Flogin%23%2Fweixin-login";

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

#[derive(Debug, Clone, serde::Serialize)]
struct WeChatLoginSession {
    uuid: String,
    qr_url: String,
    qr_data_url: String,
}

#[derive(Debug, Clone, serde::Serialize)]
struct WeChatLoginPollResult {
    status: String,
    redirect_url: Option<String>,
    message: Option<String>,
}

pub static HTTP_LOGS: std::sync::OnceLock<Mutex<Vec<HttpLogEntry>>> = std::sync::OnceLock::new();
pub static APP_HANDLE: std::sync::OnceLock<tauri::AppHandle> = std::sync::OnceLock::new();
static LOG_ID_COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);

pub fn generate_log_id() -> String {
    LOG_ID_COUNTER
        .fetch_add(1, std::sync::atomic::Ordering::Relaxed)
        .to_string()
}

pub fn sanitize_http_log_text(input: &str) -> String {
    let mut out = input.to_string();
    let sensitive_keys = [
        "token",
        "refresh_token",
        "refreshToken",
        "IMA-TOKEN",
        "IMA-REFRESH-TOKEN",
        "x-ima-cookie",
        "cookie",
        "Cookie",
        "code",
        "wx_code",
    ];

    for key in sensitive_keys {
        out = mask_json_like_value(&out, key);
        out = mask_query_like_value(&out, key);
        out = mask_header_like_value(&out, key);
    }

    if out.len() > 20_000 {
        out.truncate(20_000);
        out.push_str("\n...[truncated]");
    }
    out
}

fn mask_json_like_value(input: &str, key: &str) -> String {
    let quoted = format!("\"{}\"", key);
    let mut result = String::with_capacity(input.len());
    let mut rest = input;

    while let Some(key_pos) = rest.find(&quoted) {
        let (before, after_key) = rest.split_at(key_pos + quoted.len());
        result.push_str(before);

        let Some(colon_rel) = after_key.find(':') else {
            rest = after_key;
            break;
        };
        let (between, after_colon) = after_key.split_at(colon_rel + 1);
        result.push_str(between);

        let leading_ws_len = after_colon
            .char_indices()
            .find(|(_, ch)| !ch.is_whitespace())
            .map(|(idx, _)| idx)
            .unwrap_or(after_colon.len());
        let (leading_ws, value_part) = after_colon.split_at(leading_ws_len);
        result.push_str(leading_ws);

        if let Some(stripped) = value_part.strip_prefix('"') {
            if let Some(end) = stripped.find('"') {
                result.push_str("\"***\"");
                rest = &stripped[end + 1..];
            } else {
                result.push_str("\"***\"");
                rest = "";
            }
        } else {
            let end = value_part
                .char_indices()
                .find(|(_, ch)| [',', '}', '\n', '\r'].contains(ch))
                .map(|(idx, _)| idx)
                .unwrap_or(value_part.len());
            result.push_str("***");
            rest = &value_part[end..];
        }
    }

    result.push_str(rest);
    result
}

fn mask_query_like_value(input: &str, key: &str) -> String {
    let mut result = String::with_capacity(input.len());
    let mut rest = input;
    let patterns = [format!("{}=", key), format!("{}%3D", key)];

    loop {
        let next = patterns
            .iter()
            .filter_map(|pattern| rest.find(pattern).map(|idx| (idx, pattern.len())))
            .min_by_key(|(idx, _)| *idx);
        let Some((idx, pattern_len)) = next else {
            result.push_str(rest);
            break;
        };

        let (before, after_before) = rest.split_at(idx + pattern_len);
        result.push_str(before);
        let end = after_before
            .char_indices()
            .find(|(_, ch)| ['&', '#', ' ', '\n', '\r', '"', '\''].contains(ch))
            .map(|(i, _)| i)
            .unwrap_or(after_before.len());
        result.push_str("***");
        rest = &after_before[end..];
    }

    result
}

fn mask_header_like_value(input: &str, key: &str) -> String {
    input
        .lines()
        .map(|line| {
            let lower = line.to_ascii_lowercase();
            if lower.starts_with(&format!("{}:", key.to_ascii_lowercase())) {
                format!("{}: ***", line.split(':').next().unwrap_or(key))
            } else {
                line.to_string()
            }
        })
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn add_logged_http_request(
    method: &str,
    url: &str,
    headers: Option<String>,
    body: Option<String>,
) -> String {
    let log_id = generate_log_id();
    add_http_log(HttpLogEntry {
        id: log_id.clone(),
        timestamp: chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string(),
        method: method.to_string(),
        url: sanitize_http_log_text(url),
        request_headers: headers.map(|h| sanitize_http_log_text(&h)),
        request_body: body.map(|b| sanitize_http_log_text(&b)),
        response_code: None,
        response_body: None,
        error: None,
    });
    log_id
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
            log.response_body = Some(sanitize_http_log_text(body));
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
        let _ = app_handle.emit(
            "sync-progress",
            SyncProgressPayload {
                step: step.to_string(),
                title: title.to_string(),
                status: status.to_string(),
                progress,
            },
        );
    };

    let run_pull =
        direction.as_deref() != Some("push") && direction.as_deref() != Some("sync_to_ima");
    let run_push =
        direction.as_deref() != Some("pull") && direction.as_deref() != Some("pull_from_remote");

    emit_progress("start", "开始同步...", "正在初始化云端连接...", 0.0);

    let total_dirs = mappings.len();
    if total_dirs == 0 {
        let conn = state.db_conn.lock().unwrap();
        let _ = resume_watcher(&state, &conn, &app_handle);
        emit_progress(
            "complete",
            "同步完成！",
            "没有绑定任何需要同步的知识库。",
            100.0,
        );
        return Ok(());
    }

    let mut current_dir_idx = 0;
    let mut failed_pushes: Vec<String> = Vec::new();

    for (local_path_str, kb_id) in &mappings {
        current_dir_idx += 1;
        let base_progress = ((current_dir_idx - 1) as f64 / total_dirs as f64) * 100.0;
        let step_progress_slice = 100.0 / total_dirs as f64;

        let root_path = Path::new(local_path_str);
        if !root_path.exists() {
            println!("Local monitored path does not exist: {}", local_path_str);
            continue;
        }

        let dir_name = root_path
            .file_name()
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
                    emit_progress(
                        "error",
                        "同步发生错误",
                        &format!("获取云端列表失败: {}", e),
                        100.0,
                    );
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

            let folders: Vec<&KnowledgeInfo> =
                remote_items.iter().filter(|x| x.is_folder()).collect();
            let mut folder_meta = HashMap::new();
            for f in &folders {
                if let Some(fid) = f.folder_identifier() {
                    if !fid.is_empty() {
                        folder_meta.insert(
                            fid,
                            (f.parent_folder_id.clone(), f.display_name().to_string()),
                        );
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
                                let _ = conn.execute(
                                    "DELETE FROM file_events WHERE id = ?1",
                                    params![local_ev.id],
                                );
                            }
                        }
                    }
                }
            }

            // 2. Sync remote to local
            let file_items: Vec<&KnowledgeInfo> =
                remote_items.iter().filter(|x| !x.is_folder()).collect();
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
                let file_progress = base_progress
                    + step_progress_slice * 0.1
                    + (f_idx as f64 / total_files.max(1) as f64) * step_progress_slice * 0.4;
                emit_progress(
                    "pull",
                    &format!("正在拉取云端变动 ({}/{})", current_dir_idx, total_dirs),
                    &format!(
                        "正在下载云端文件 ({}/{}): {}",
                        f_idx + 1,
                        total_files,
                        item.display_name()
                    ),
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
                    if client
                        .download_file(&item.media_id, kb_id, &local_file_path, &creds)
                        .await
                        .is_ok()
                    {
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

            let mut current_root_events: Vec<FileEvent> = pending_local_events
                .into_iter()
                .filter(|ev| Path::new(&ev.path).starts_with(root_path))
                .collect();
            current_root_events.sort_by(|a, b| {
                let a_path = Path::new(&a.path);
                let b_path = Path::new(&b.path);
                let a_depth = a_path.components().count();
                let b_depth = b_path.components().count();
                let a_kind = if a.is_directory { 0 } else { 1 };
                let b_kind = if b.is_directory { 0 } else { 1 };

                a_depth
                    .cmp(&b_depth)
                    .then_with(|| a_kind.cmp(&b_kind))
                    .then_with(|| {
                        a.timestamp
                            .partial_cmp(&b.timestamp)
                            .unwrap_or(Ordering::Equal)
                    })
            });

            let total_pushes = current_root_events.len();

            for (p_idx, ev) in current_root_events.iter().enumerate() {
                let push_progress = base_progress
                    + step_progress_slice * 0.5
                    + (p_idx as f64 / total_pushes.max(1) as f64) * step_progress_slice * 0.45;
                let file_name = Path::new(&ev.path)
                    .file_name()
                    .map(|s| s.to_string_lossy().to_string())
                    .unwrap_or_else(|| ev.path.clone());

                emit_progress(
                    "push",
                    &format!("正在上传本地变动 ({}/{})", current_dir_idx, total_dirs),
                    &format!(
                        "正在同步本地改动 ({}/{}): {}",
                        p_idx + 1,
                        total_pushes,
                        file_name
                    ),
                    push_progress,
                );

                let ev_path = Path::new(&ev.path);
                let rel_folder_path = if let Ok(rel) = ev_path
                    .parent()
                    .unwrap_or(root_path)
                    .strip_prefix(root_path)
                {
                    rel.to_string_lossy().to_string()
                } else {
                    "".to_string()
                };

                match ev.event_type.as_str() {
                    "deleted" => {
                        if let Some(ref rid) = ev.remote_id {
                            let _ = client
                                .delete_knowledge_by_web_api(&[rid.clone()], kb_id, &creds)
                                .await;
                        }
                        let conn = state.db_conn.lock().unwrap();
                        let _ = db::mark_event_synced(&conn, &ev.id);
                    }
                    "renamed" => {
                        if let Some(remote_id) = find_remote_id_for_event(&state, ev) {
                            match client
                                .resolve_folder_id_if_needed(kb_id, &rel_folder_path, &creds)
                                .await
                            {
                                Ok(folder_id) => {
                                    match client
                                        .rename_knowledge(
                                            &remote_id,
                                            &file_name,
                                            kb_id,
                                            folder_id.as_deref(),
                                            &creds,
                                        )
                                        .await
                                    {
                                        Ok(_) => {
                                            let conn = state.db_conn.lock().unwrap();
                                            let _ = db::mark_event_synced_with_remote_id(
                                                &conn, &ev.id, &remote_id,
                                            );
                                        }
                                        Err(e) => {
                                            let message = format!(
                                                "重命名云端项目失败 '{}': {}",
                                                file_name, e
                                            );
                                            println!("{}", message);
                                            failed_pushes.push(message);
                                        }
                                    }
                                }
                                Err(e) => {
                                    let message =
                                        format!("定位云端父目录失败 '{}': {}", rel_folder_path, e);
                                    println!("{}", message);
                                    failed_pushes.push(message);
                                }
                            }
                        } else {
                            let message = format!(
                                "无法重命名云端项目 '{}': 未找到旧路径对应的云端 ID",
                                file_name
                            );
                            println!("{}", message);
                            failed_pushes.push(message);
                        }
                    }
                    "created" | "modified" => {
                        if ev.is_directory {
                            let rel_dir_path = ev_path
                                .strip_prefix(root_path)
                                .map(|rel| rel.to_string_lossy().to_string())
                                .unwrap_or_else(|_| file_name.clone());
                            match client
                                .resolve_folder_id_if_needed(kb_id, &rel_dir_path, &creds)
                                .await
                            {
                                Ok(Some(folder_id)) => {
                                    let conn = state.db_conn.lock().unwrap();
                                    let _ = db::mark_event_synced_with_remote_id(
                                        &conn, &ev.id, &folder_id,
                                    );
                                }
                                Ok(None) => {
                                    let conn = state.db_conn.lock().unwrap();
                                    let _ = db::mark_event_synced(&conn, &ev.id);
                                }
                                Err(e) => {
                                    let message =
                                        format!("创建云端目录失败 '{}': {}", rel_dir_path, e);
                                    println!("{}", message);
                                    failed_pushes.push(message.clone());
                                    emit_progress(
                                        "push",
                                        &format!(
                                            "正在上传本地变动 ({}/{})",
                                            current_dir_idx, total_dirs
                                        ),
                                        &format!(
                                            "同步失败 ({}/{}): {}",
                                            p_idx + 1,
                                            total_pushes,
                                            message
                                        ),
                                        push_progress,
                                    );
                                }
                            }
                        } else {
                            let resolved_folder_id = match client
                                .resolve_folder_id_if_needed(kb_id, &rel_folder_path, &creds)
                                .await
                            {
                                Ok(fid) => fid,
                                Err(_) => None,
                            };

                            match client
                                .upload_to_wiki(
                                    ev_path,
                                    kb_id,
                                    resolved_folder_id.as_deref(),
                                    ev.remote_id.as_deref(),
                                    &creds,
                                )
                                .await
                            {
                                Ok(media_id) => {
                                    let conn = state.db_conn.lock().unwrap();
                                    let _ = db::mark_event_synced_with_remote_id(
                                        &conn, &ev.id, &media_id,
                                    );
                                }
                                Err(e) => {
                                    let message = format!("上传文件失败 '{}': {}", file_name, e);
                                    println!("{}", message);
                                    failed_pushes.push(message);
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

    if !failed_pushes.is_empty() {
        let summary = if failed_pushes.len() == 1 {
            failed_pushes[0].clone()
        } else {
            format!(
                "{} 个项目同步失败：{}",
                failed_pushes.len(),
                failed_pushes
                    .iter()
                    .take(3)
                    .cloned()
                    .collect::<Vec<String>>()
                    .join("；")
            )
        };
        emit_progress("error", "同步未完成", &summary, 100.0);
        return Err(summary);
    }

    emit_progress(
        "complete",
        "同步完成！",
        "所有关联知识库与本地目录已双向同步成功。",
        100.0,
    );

    Ok(())
}

fn resume_watcher(
    state: &AppState,
    conn: &rusqlite::Connection,
    app_handle: &AppHandle,
) -> Result<(), String> {
    let paths_str = db::get_config(conn, "monitoredDirectories")
        .unwrap_or(None)
        .or_else(|| db::get_config(conn, "monitoredPaths").unwrap_or(None))
        .unwrap_or_default();

    let disabled_paths_str = db::get_config(conn, "disabledMonitoredDirectories")
        .unwrap_or(None)
        .unwrap_or_default();
    let disabled_paths: HashSet<String> = parse_config_path_list(&disabled_paths_str)
        .into_iter()
        .collect();
    let paths: Vec<String> = parse_config_path_list(&paths_str)
        .into_iter()
        .filter(|path| !disabled_paths.contains(path))
        .collect();

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

fn parse_config_path_list(value: &str) -> Vec<String> {
    if value.trim().is_empty() {
        return Vec::new();
    }

    serde_json::from_str(value).unwrap_or_else(|_| {
        value
            .split(',')
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .collect()
    })
}

#[tauri::command]
fn get_file_events(
    state: State<'_, AppState>,
    pending_only: bool,
) -> Result<Vec<FileEvent>, String> {
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
fn mark_all_events_synced(state: State<'_, AppState>) -> Result<usize, String> {
    let conn = state.db_conn.lock().unwrap();
    let affected = conn
        .execute(
            "UPDATE file_events SET is_synced = 1 WHERE is_synced = 0",
            [],
        )
        .map_err(|e| e.to_string())?;
    Ok(affected)
}

fn find_remote_id_for_event(state: &AppState, ev: &FileEvent) -> Option<String> {
    if let Some(remote_id) = ev.remote_id.clone() {
        return Some(remote_id);
    }

    let old_path = ev.old_path.as_ref()?;
    let conn = state.db_conn.lock().ok()?;
    db::get_latest_synced_event(&conn, old_path)
        .ok()
        .flatten()
        .and_then(|event| event.remote_id)
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

    let file_name = Path::new(&ev.path)
        .file_name()
        .map(|s| s.to_string_lossy().to_string())
        .unwrap_or_else(|| ev.path.clone());

    let ev_path = Path::new(&ev.path);
    let root_path = Path::new(&root_path_str);
    let rel_folder_path = if let Ok(rel) = ev_path
        .parent()
        .unwrap_or(root_path)
        .strip_prefix(root_path)
    {
        rel.to_string_lossy().to_string()
    } else {
        "".to_string()
    };

    let sync_result = match ev.event_type.as_str() {
        "deleted" => {
            if let Some(ref rid) = ev.remote_id {
                let _ = client
                    .delete_knowledge_by_web_api(&[rid.clone()], &kb_id, &creds)
                    .await;
            }
            let conn = state.db_conn.lock().unwrap();
            db::mark_event_synced(&conn, &ev.id).map_err(|e| e.to_string())
        }
        "renamed" => {
            let remote_id = find_remote_id_for_event(&state, &ev)
                .ok_or_else(|| "无法重命名云端项目：未找到旧路径对应的云端 ID".to_string())?;

            let resolved_folder_id = client
                .resolve_folder_id_if_needed(&kb_id, &rel_folder_path, &creds)
                .await
                .map_err(|e| format!("定位云端父目录失败: {}", e))?;

            match client
                .rename_knowledge(
                    &remote_id,
                    &file_name,
                    &kb_id,
                    resolved_folder_id.as_deref(),
                    &creds,
                )
                .await
            {
                Ok(_) => {
                    let conn = state.db_conn.lock().unwrap();
                    db::mark_event_synced_with_remote_id(&conn, &ev.id, &remote_id)
                        .map_err(|e| e.to_string())
                }
                Err(e) => Err(format!("重命名云端项目失败: {}", e)),
            }
        }
        "created" | "modified" => {
            if ev.is_directory {
                let rel_dir_path = ev_path
                    .strip_prefix(root_path)
                    .map(|rel| rel.to_string_lossy().to_string())
                    .unwrap_or_else(|_| file_name.clone());
                match client
                    .resolve_folder_id_if_needed(&kb_id, &rel_dir_path, &creds)
                    .await
                {
                    Ok(Some(folder_id)) => {
                        let conn = state.db_conn.lock().unwrap();
                        db::mark_event_synced_with_remote_id(&conn, &ev.id, &folder_id)
                            .map_err(|e| e.to_string())
                    }
                    Ok(None) => {
                        let conn = state.db_conn.lock().unwrap();
                        db::mark_event_synced(&conn, &ev.id).map_err(|e| e.to_string())
                    }
                    Err(e) => Err(format!("创建云端文件夹失败: {}", e)),
                }
            } else {
                let resolved_folder_id = match client
                    .resolve_folder_id_if_needed(&kb_id, &rel_folder_path, &creds)
                    .await
                {
                    Ok(fid) => fid,
                    Err(_) => None,
                };

                match client
                    .upload_to_wiki(
                        ev_path,
                        &kb_id,
                        resolved_folder_id.as_deref(),
                        ev.remote_id.as_deref(),
                        &creds,
                    )
                    .await
                {
                    Ok(media_id) => {
                        let conn = state.db_conn.lock().unwrap();
                        db::mark_event_synced_with_remote_id(&conn, &ev.id, &media_id)
                            .map_err(|e| e.to_string())
                    }
                    Err(e) => Err(format!("上传文件失败: {:?}", e)),
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
async fn clear_all_events(state: State<'_, AppState>) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    db::clear_all_events(&conn).map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_config_value(
    state: State<'_, AppState>,
    key: String,
) -> Result<Option<String>, String> {
    let conn = state.db_conn.lock().unwrap();
    db::get_config(&conn, &key).map_err(|e| e.to_string())
}

#[tauri::command]
async fn set_config_value(
    state: State<'_, AppState>,
    key: String,
    value: String,
) -> Result<(), String> {
    let conn = state.db_conn.lock().unwrap();
    db::save_config(&conn, &key, &value).map_err(|e| e.to_string())
}

#[tauri::command]
async fn get_ima_credentials() -> Option<CachedCredentials> {
    credentials::load_credentials()
}

#[tauri::command]
async fn save_ima_credentials(
    token: String,
    refresh_token: String,
    uid: String,
    guid: String,
) -> Result<(), String> {
    let creds = CachedCredentials {
        token,
        refresh_token,
        uid,
        guid,
    };
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
    if home.is_empty() {
        return false;
    }
    let plist_path =
        std::path::PathBuf::from(home).join("Library/LaunchAgents/com.filesyncmonitor.plist");
    plist_path.exists()
}

#[tauri::command]
fn set_launch_at_login(enable: bool) -> Result<(), String> {
    let home = std::env::var("HOME").map_err(|e| e.to_string())?;
    if home.is_empty() {
        return Err("HOME directory not found".to_string());
    }

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
async fn get_ima_knowledge_bases(
    token: String,
    refresh_token: String,
    uid: String,
    guid: String,
) -> Result<Vec<KnowledgeBase>, String> {
    let creds = CachedCredentials {
        token,
        refresh_token,
        uid,
        guid,
    };
    let client = IMASyncClient::new();
    client.get_knowledge_bases(&creds).await
}

#[tauri::command]
async fn get_ima_user_profile(
    token: String,
    refresh_token: String,
    uid: String,
    guid: String,
) -> Result<(String, String), String> {
    let creds = CachedCredentials {
        token,
        refresh_token,
        uid,
        guid,
    };
    let client = IMASyncClient::new();
    client.get_user_profile(&creds).await
}

#[tauri::command]
async fn get_ima_space_quota(
    token: String,
    refresh_token: String,
    uid: String,
    guid: String,
) -> Result<ima_sync::SpaceQuota, String> {
    let creds = CachedCredentials {
        token,
        refresh_token,
        uid,
        guid,
    };
    let client = IMASyncClient::new();
    client.get_space_quota(&creds).await
}

#[tauri::command]
async fn start_file_monitor(
    state: State<'_, AppState>,
    paths: Vec<String>,
    app_handle: AppHandle,
) -> Result<(), String> {
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
    #[cfg(target_os = "macos")]
    {
        let (tx, rx) = tokio::sync::oneshot::channel();
        app_handle
            .run_on_main_thread(move || {
                let folder = rfd::FileDialog::new().pick_folder();
                let res = folder.map(|path| path.to_string_lossy().to_string());
                let _ = tx.send(res);
            })
            .map_err(|e| e.to_string())?;
        rx.await.map_err(|e| e.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let res = tokio::task::spawn_blocking(move || {
            let folder = rfd::FileDialog::new().pick_folder();
            folder.map(|path| path.to_string_lossy().to_string())
        })
        .await
        .map_err(|e| e.to_string())?;
        Ok(res)
    }
}

#[tauri::command]
async fn stop_file_monitor(state: State<'_, AppState>) -> Result<(), String> {
    let mut monitor = state.monitor.lock().unwrap();
    monitor.stop();
    Ok(())
}

#[tauri::command]
fn exit_app(app_handle: AppHandle) {
    app_handle.exit(0);
}

#[tauri::command]
async fn show_main_window(app: tauri::AppHandle) {
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

fn app_window_icon() -> Option<tauri::image::Image<'static>> {
    tauri::image::Image::from_bytes(include_bytes!("../icons/icon.png")).ok()
}

fn ima_wechat_qr_login_url_string() -> String {
    format!(
        "https://open.weixin.qq.com/connect/qrconnect?appid={}&scope=snsapi_login&redirect_uri={}&state=fsm-native-login&login_type=jssdk&styletype=&sizetype=&bgcolor=&rst=&stylelite=1&fast_login=1&lang=cn&ts={}",
        IMA_WECHAT_APP_ID,
        IMA_WECHAT_REDIRECT_URI,
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_millis())
            .unwrap_or_default()
    )
}

#[cfg(not(target_os = "windows"))]
fn ima_wechat_qr_login_url() -> Result<tauri::WebviewUrl, String> {
    let url = ima_wechat_qr_login_url_string();
    tauri::Url::parse(&url)
        .map(tauri::WebviewUrl::External)
        .map_err(|e| e.to_string())
}

fn extract_between<'a>(text: &'a str, start_marker: &str, end_markers: &[char]) -> Option<&'a str> {
    let start = text.find(start_marker)? + start_marker.len();
    let rest = &text[start..];
    let end = rest
        .char_indices()
        .find(|(_, ch)| end_markers.contains(ch))
        .map(|(idx, _)| idx)
        .unwrap_or(rest.len());
    Some(&rest[..end])
}

fn extract_wechat_qr_uuid(html: &str) -> Option<String> {
    extract_between(
        html,
        "/connect/qrcode/",
        &['"', '\'', '<', '>', '?', '&', ' '],
    )
    .map(str::trim)
    .filter(|uuid| !uuid.is_empty())
    .map(ToString::to_string)
}

fn extract_wechat_js_var(script: &str, name: &str) -> Option<String> {
    let pattern = format!("{}=", name);
    let value = extract_between(script, &pattern, &[';', '\n', '\r'])?.trim();
    Some(
        value
            .trim_matches('"')
            .trim_matches('\'')
            .trim()
            .to_string(),
    )
}

#[tauri::command]
async fn create_wechat_login_session() -> Result<WeChatLoginSession, String> {
    let login_url = ima_wechat_qr_login_url_string();
    let client = reqwest::Client::builder()
        .user_agent(WEBVIEW_USER_AGENT)
        .build()
        .map_err(|e| e.to_string())?;
    let headers_str = format!("User-Agent: {}", WEBVIEW_USER_AGENT);
    let page_log_id = add_logged_http_request("GET", &login_url, Some(headers_str.clone()), None);
    let page_res = client.get(&login_url).send().await.map_err(|e| {
        let err = format!("Failed to request WeChat login page: {}", e);
        update_http_log_error(&page_log_id, &err);
        err
    })?;
    let page_status = page_res.status();
    let html = page_res.text().await.map_err(|e| {
        let err = format!("Failed to read WeChat login page: {}", e);
        update_http_log_error(&page_log_id, &err);
        err
    })?;
    update_http_log_response(&page_log_id, page_status.as_u16(), &html);

    let uuid = extract_wechat_qr_uuid(&html)
        .ok_or_else(|| "Failed to locate WeChat QR code in login page".to_string())?;
    let qr_url = format!("https://open.weixin.qq.com/connect/qrcode/{}", uuid);
    let qr_log_id = add_logged_http_request("GET", &qr_url, Some(headers_str), None);
    let qr_res = client.get(&qr_url).send().await.map_err(|e| {
        let err = format!("Failed to request WeChat QR image: {}", e);
        update_http_log_error(&qr_log_id, &err);
        err
    })?;
    let qr_status = qr_res.status();
    let qr_content_type = qr_res
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("image/jpeg")
        .to_string();
    let qr_bytes = qr_res.bytes().await.map_err(|e| {
        let err = format!("Failed to read WeChat QR image: {}", e);
        update_http_log_error(&qr_log_id, &err);
        err
    })?;
    update_http_log_response(
        &qr_log_id,
        qr_status.as_u16(),
        &format!(
            "[binary {} image, {} bytes]",
            qr_content_type,
            qr_bytes.len()
        ),
    );
    if !qr_status.is_success() {
        let err = format!("WeChat QR image returned HTTP {}", qr_status);
        update_http_log_error(&qr_log_id, &err);
        return Err(err);
    }

    let qr_base64 = base64::engine::general_purpose::STANDARD.encode(qr_bytes);
    Ok(WeChatLoginSession {
        qr_data_url: format!("data:{};base64,{}", qr_content_type, qr_base64),
        qr_url,
        uuid,
    })
}

#[tauri::command]
async fn poll_wechat_qr_status(uuid: String) -> Result<WeChatLoginPollResult, String> {
    if uuid.trim().is_empty() {
        return Err("Missing WeChat QR uuid".to_string());
    }

    let ts = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or_default();
    let poll_url = format!(
        "https://long.open.weixin.qq.com/connect/l/qrconnect?uuid={}&_={}",
        uuid, ts
    );
    let referer = ima_wechat_qr_login_url_string();
    let client = reqwest::Client::builder()
        .user_agent(WEBVIEW_USER_AGENT)
        .build()
        .map_err(|e| e.to_string())?;
    let headers_str = format!("User-Agent: {}\nReferer: {}", WEBVIEW_USER_AGENT, referer);
    let poll_log_id = add_logged_http_request("GET", &poll_url, Some(headers_str), None);
    let poll_res = client
        .get(&poll_url)
        .header(reqwest::header::REFERER, referer)
        .send()
        .await
        .map_err(|e| {
            let err = format!("Failed to poll WeChat QR status: {}", e);
            update_http_log_error(&poll_log_id, &err);
            err
        })?;
    let poll_status = poll_res.status();
    let script = poll_res.text().await.map_err(|e| {
        let err = format!("Failed to read WeChat QR status: {}", e);
        update_http_log_error(&poll_log_id, &err);
        err
    })?;
    update_http_log_response(&poll_log_id, poll_status.as_u16(), &script);
    if !poll_status.is_success() {
        let err = format!("WeChat QR status poll returned HTTP {}", poll_status);
        update_http_log_error(&poll_log_id, &err);
        return Err(err);
    }

    let errcode = extract_wechat_js_var(&script, "window.wx_errcode")
        .or_else(|| extract_wechat_js_var(&script, "wx_errcode"))
        .unwrap_or_default();

    let result = match errcode.as_str() {
        "405" => {
            let code = extract_wechat_js_var(&script, "window.wx_code")
                .or_else(|| extract_wechat_js_var(&script, "wx_code"))
                .ok_or_else(|| "WeChat confirmed login but did not return code".to_string())?;
            WeChatLoginPollResult {
                status: "success".to_string(),
                redirect_url: Some(format!(
                    "https://ima.qq.com/login#/weixin-login?code={}&state=fsm-native-login",
                    code
                )),
                message: None,
            }
        }
        "404" => WeChatLoginPollResult {
            status: "scanned".to_string(),
            redirect_url: None,
            message: Some("Scanned, waiting for confirmation".to_string()),
        },
        "403" => WeChatLoginPollResult {
            status: "cancelled".to_string(),
            redirect_url: None,
            message: Some("Login cancelled in WeChat".to_string()),
        },
        "402" => WeChatLoginPollResult {
            status: "expired".to_string(),
            redirect_url: None,
            message: Some("QR code expired".to_string()),
        },
        _ => WeChatLoginPollResult {
            status: "pending".to_string(),
            redirect_url: None,
            message: None,
        },
    };

    Ok(result)
}

#[tauri::command]
fn set_window_theme(window: tauri::Window, theme: String) -> Result<(), String> {
    let tauri_theme = match theme.as_str() {
        "dark" => Some(tauri::Theme::Dark),
        "light" => Some(tauri::Theme::Light),
        _ => None,
    };
    window.set_theme(tauri_theme).map_err(|e| e.to_string())
}

async fn refresh_credentials_via_api(
    creds: &CachedCredentials,
) -> Result<CachedCredentials, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    let url = "https://ima.qq.com/auth_login/refresh";

    let mut headers = reqwest::header::HeaderMap::new();
    headers.insert(
        "Host",
        reqwest::header::HeaderValue::from_static("ima.qq.com"),
    );
    headers.insert(
        "Content-Type",
        reqwest::header::HeaderValue::from_static("application/json"),
    );
    headers.insert(
        "from_browser_ima",
        reqwest::header::HeaderValue::from_static("1"),
    );
    headers.insert(
        "LAUNCH_CHANNELID",
        reqwest::header::HeaderValue::from_static("900000"),
    );
    headers.insert(
        "Origin",
        reqwest::header::HeaderValue::from_static("https://ima.qq.com"),
    );
    headers.insert(
        "Referer",
        reqwest::header::HeaderValue::from_static("https://ima.qq.com/"),
    );
    headers.insert("User-Agent", reqwest::header::HeaderValue::from_static("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 IMA/143.0.7499.4456"));

    let bkn = credentials::calculate_bkn(&creds.token);
    headers.insert(
        "x-ima-bkn",
        reqwest::header::HeaderValue::from_str(&bkn.to_string())
            .unwrap_or(reqwest::header::HeaderValue::from_static("0")),
    );

    let cookie_str = credentials::get_cookie_string(creds);
    headers.insert(
        "x-ima-cookie",
        reqwest::header::HeaderValue::from_str(&cookie_str)
            .unwrap_or(reqwest::header::HeaderValue::from_static("")),
    );

    let body = serde_json::json!({
        "refresh_token": creds.refresh_token,
        "token_type": 14,
        "user_id": creds.uid
    });

    println!(
        "[IMASilentRefresh] Sending direct API refresh request to {}",
        url
    );

    let headers_str = headers
        .iter()
        .map(|(key, val)| format!("{}: {:?}", key, val))
        .collect::<Vec<String>>()
        .join("\n");
    let req_body_str = serde_json::to_string_pretty(&body).unwrap_or_else(|_| body.to_string());

    let log_id = add_logged_http_request("POST", url, Some(headers_str), Some(req_body_str));

    let res = client
        .post(url)
        .headers(headers)
        .json(&body)
        .send()
        .await
        .map_err(|e| {
            let err = format!("Direct refresh request error: {:?}", e);
            update_http_log_error(&log_id, &err);
            err
        })?;

    let status = res.status();
    let body_str = res.text().await.map_err(|e| {
        let err = format!("Failed to read direct refresh body: {:?}", e);
        update_http_log_error(&log_id, &err);
        err
    })?;

    update_http_log_response(&log_id, status.as_u16(), &body_str);

    if !status.is_success() {
        return Err(format!(
            "Direct refresh returned HTTP error: {} - {}",
            status, body_str
        ));
    }

    #[derive(serde::Deserialize)]
    struct RefreshResponse {
        code: i32,
        msg: String,
        token: String,
        user_id: String,
    }

    let parsed: RefreshResponse = serde_json::from_str(&body_str).map_err(|e| {
        format!(
            "Failed to parse refresh response: {:?}. Body: {}",
            e, body_str
        )
    })?;

    if parsed.code != 0 {
        return Err(format!(
            "Direct refresh API returned error code {}: {}",
            parsed.code, parsed.msg
        ));
    }

    if parsed.token.is_empty() {
        return Err("Direct refresh API returned empty token".to_string());
    }

    let mut updated_creds = creds.clone();
    updated_creds.token = parsed.token;
    if !parsed.user_id.is_empty() {
        updated_creds.uid = parsed.user_id;
    }

    credentials::save_credentials(&updated_creds)?;
    println!("[IMASilentRefresh] Direct API refresh succeeded.");

    Ok(updated_creds)
}

pub async fn refresh_ima_credentials_silently(
    app: &tauri::AppHandle,
) -> Result<CachedCredentials, String> {
    println!("[IMASilentRefresh] Starting silent credentials refresh...");

    // 1. Try direct API refresh first if credentials exist
    if let Some(creds) = credentials::load_credentials() {
        if !creds.refresh_token.is_empty() {
            match refresh_credentials_via_api(&creds).await {
                Ok(new_creds) => {
                    println!("[IMASilentRefresh] Direct API refresh succeeded. Bypassing WebView fallback.");
                    return Ok(new_creds);
                }
                Err(e) => {
                    println!("[IMASilentRefresh] Direct API refresh failed: {}. Falling back to WebView-based capture.", e);
                }
            }
        } else {
            println!("[IMASilentRefresh] Stored refresh_token is empty. Falling back to WebView-based capture.");
        }
    } else {
        println!("[IMASilentRefresh] No stored credentials found. Falling back to WebView-based capture.");
    }

    // If a silent refresh window is already open, close it
    if let Some(win) = app.get_webview_window("ima_silent_refresh") {
        let _ = win.close();
    }

    let (tx, rx) = tokio::sync::oneshot::channel::<Result<CachedCredentials, String>>();
    let tx = Arc::new(Mutex::new(Some(tx)));

    let url_str = "https://ima.qq.com/login/";
    let url = tauri::Url::parse(url_str).map_err(|e| e.to_string())?;

    let js_injection = r##"
        (() => {
            if (window.__fsmLoginCaptureInstalled) return;
            window.__fsmLoginCaptureInstalled = true;

            let hasSubmitted = false;

            function bridge(action, params = {}) {
                try {
                    const query = new URLSearchParams(params).toString();
                    window.location.href = `https://fsmsync.localhost/${action}${query ? `?${query}` : ""}`;
                } catch (e) {
                    log(`bridge error: ${e}`);
                }
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
                try {
                    if (typeof input === "string") return input;
                    if (input instanceof URL) return input.href;
                    if (input && typeof input.url === "string") return input.url;
                    return String(input || "");
                } catch (e) {
                    return "";
                }
            }

            function isLoginResponseUrl(url) {
                if (!url) return false;
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
                try {
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
                } catch (e) {
                    log(`normalize error: ${e}`);
                }
                return null;
            }

            function submitLogin(data, source) {
                try {
                    if (hasSubmitted) return;
                    const creds = normalizeLoginData(data);
                    if (!creds || !creds.token || !creds.uid || creds.token === "guest") return;
                    hasSubmitted = true;
                    log(`Login credentials captured via ${source}; uid=${creds.uid}`);
                    bridge("login-success", creds);
                } catch (e) {
                    log(`submitLogin error: ${e}`);
                }
            }

            try {
                if (window.fetch) {
                    const originalFetch = window.fetch.bind(window);
                    window.fetch = async function(...args) {
                        try {
                            const url = requestUrl(args[0]);
                            const response = await originalFetch(...args);
                            try {
                                if (isLoginResponseUrl(url)) {
                                    response.clone().text()
                                        .then(text => submitLogin(text, "fetch"))
                                        .catch(error => log(`Fetch login parse error: ${error}`));
                                }
                            } catch (e) {
                                log(`Fetch response check error: ${e}`);
                            }
                            return response;
                        } catch (err) {
                            log(`Fetch execution error: ${err}`);
                            return originalFetch(...args);
                        }
                    };
                }
            } catch (e) {
                log(`Fetch hook setup error: ${e}`);
            }

            try {
                const originalOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
                if (originalOpen) {
                    window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                        try {
                            this.__fsmLoginUrl = requestUrl(url);
                        } catch (e) {
                            log(`XHR open hook error: ${e}`);
                        }
                        return originalOpen.apply(this, [method, url, ...rest]);
                    };

                    const originalSend = window.XMLHttpRequest.prototype.send;
                    window.XMLHttpRequest.prototype.send = function(...args) {
                        try {
                            this.addEventListener("loadend", function() {
                                try {
                                    if (!isLoginResponseUrl(this.__fsmLoginUrl || "")) return;
                                    submitLogin(this.responseText || this.response, "xhr");
                                } catch (error) {
                                    log(`XHR login parse error: ${error}`);
                                }
                            });
                        } catch (e) {
                            log(`XHR send hook setup error: ${e}`);
                        }
                        return originalSend.apply(this, args);
                    };
                }
            } catch (e) {
                log(`XHR hook setup error: ${e}`);
            }

            log("Login capture hooks installed");
        })();
    "##;

    let app_clone = app.clone();
    let app_clone_for_nav = app.clone();
    let app_for_silent_nav = app.clone();
    let tx_clone = Arc::clone(&tx);
    let tx_clone_for_nav = Arc::clone(&tx);

    app.run_on_main_thread(move || {
        let builder = tauri::WebviewWindowBuilder::new(
            &app_clone,
            "ima_silent_refresh",
            tauri::WebviewUrl::External(url),
        )
        .visible(false)
        .devtools(true)
        .user_agent(WEBVIEW_USER_AGENT)
        .initialization_script(js_injection)
        .on_navigation(move |url| {
            let scheme = url.scheme();
            if scheme != "http" && scheme != "https" {
                use tauri_plugin_opener::OpenerExt;
                let url_str = url.to_string();
                println!(
                    "[SilentRefresh Navigation] Custom scheme intercepted: {}. Opening via OS...",
                    url_str
                );
                let _ = app_for_silent_nav
                    .opener()
                    .open_path(&url_str, None::<&str>);
                return false;
            }

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
                        println!("[SilentRefresh Log] {}", msg);
                    }
                }
                "login-cancel" => {
                    if let Some(win) = app_clone_for_nav.get_webview_window("ima_silent_refresh") {
                        let _ = win.close();
                    }
                    let mut guard = tx_clone_for_nav.lock().unwrap();
                    if let Some(sender) = guard.take() {
                        let _ = sender.send(Err("Silent refresh canceled".to_string()));
                    }
                }
                "login-success" => {
                    let token = parsed_query.get("token").cloned().unwrap_or_default();
                    let refresh_token = parsed_query
                        .get("refresh_token")
                        .cloned()
                        .unwrap_or_default();
                    let uid = parsed_query.get("uid").cloned().unwrap_or_default();
                    let guid = parsed_query.get("guid").cloned().unwrap_or_default();
                    let _avatar = parsed_query.get("avatar").cloned().unwrap_or_default();
                    let _nickname = parsed_query.get("nickname").cloned().unwrap_or_default();

                    if !token.is_empty() {
                        println!("[SilentRefresh] Captured Credentials! UID: {}", uid);
                        let creds = CachedCredentials {
                            token,
                            refresh_token,
                            uid: uid.clone(),
                            guid,
                        };
                        if let Err(e) = credentials::save_credentials(&creds) {
                            println!("[SilentRefresh] Failed to save credentials: {:?}", e);
                        } else {
                            println!("[SilentRefresh] Credentials saved successfully.");
                        }
                        // Background silent refresh does not emit "login_success" to prevent showing duplicate success toasts/resetting UI.

                        if let Some(win) =
                            app_clone_for_nav.get_webview_window("ima_silent_refresh")
                        {
                            let _ = win.close();
                        }

                        let mut guard = tx_clone_for_nav.lock().unwrap();
                        if let Some(sender) = guard.take() {
                            let _ = sender.send(Ok(creds));
                        }
                    }
                }
                _ => {}
            }
            false
        });

        if let Err(e) = builder.build() {
            println!(
                "[SilentRefresh] Failed to build hidden WebviewWindow: {:?}",
                e
            );
            let mut guard = tx_clone.lock().unwrap();
            if let Some(sender) = guard.take() {
                let _ = sender.send(Err(e.to_string()));
            }
        }
    })
    .map_err(|e| e.to_string())?;

    // Wait up to 10 seconds for the silent login
    let timeout = tokio::time::sleep(std::time::Duration::from_secs(10));
    tokio::pin!(timeout);

    tokio::select! {
        res = rx => {
            match res {
                Ok(Ok(creds)) => {
                    println!("[SilentRefresh] Silent refresh succeeded!");
                    Ok(creds)
                }
                Ok(Err(e)) => Err(e),
                Err(_) => Err("Channel receiver dropped".to_string()),
            }
        }
        _ = &mut timeout => {
            println!("[SilentRefresh] Silent refresh timed out after 10s.");
            let app_clone = app.clone();
            let _ = app.run_on_main_thread(move || {
                if let Some(win) = app_clone.get_webview_window("ima_silent_refresh") {
                    let _ = win.close();
                }
            });
            Err("Silent refresh timed out".to_string())
        }
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
#[tauri::command]
async fn open_login_window(app: tauri::AppHandle) -> Result<(), String> {
    use tauri::Manager;

    if let Some(win) = app.get_webview_window("ima_login") {
        win.set_focus().map_err(|e| e.to_string())?;
        return Ok(());
    }

    #[cfg(target_os = "windows")]
    let login_url = tauri::WebviewUrl::App("wechat-login.html".into());
    #[cfg(not(target_os = "windows"))]
    let login_url = ima_wechat_qr_login_url()?;

    let js_injection = r##"
        (() => {
            if (window.__fsmLoginCaptureInstalled) return;
            window.__fsmLoginCaptureInstalled = true;

            let hasSubmitted = false;

            function bridge(action, params = {}) {
                try {
                    const query = new URLSearchParams(params).toString();
                    window.location.href = `https://fsmsync.localhost/${action}${query ? `?${query}` : ""}`;
                } catch (e) {
                    log(`bridge error: ${e}`);
                }
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

            function installLoginPolish() {
                try {
                    if (document.getElementById("fsm-login-polish")) return;
                    const style = document.createElement("style");
                    style.id = "fsm-login-polish";
                    style.textContent = `
                        html, body {
                            width: 100% !important;
                            min-width: 0 !important;
                            min-height: 0 !important;
                            margin: 0 !important;
                            overflow: hidden !important;
                            background: linear-gradient(180deg, #f7fffb 0%, #ffffff 58%, #f2fbf7 100%) !important;
                            font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif !important;
                        }
                        * {
                            box-sizing: border-box !important;
                        }
                        *::-webkit-scrollbar {
                            width: 8px !important;
                            height: 8px !important;
                        }
                        *::-webkit-scrollbar-track {
                            background: transparent !important;
                        }
                        *::-webkit-scrollbar-thumb {
                            border-radius: 999px !important;
                            background: rgba(0, 173, 111, 0.32) !important;
                            border: 2px solid transparent !important;
                            background-clip: content-box !important;
                        }
                        *::-webkit-scrollbar-thumb:hover {
                            background: rgba(0, 173, 111, 0.48) !important;
                            background-clip: content-box !important;
                        }
                        .web_qrcode_area,
                        body.web_qrcode_type_page_self {
                            min-width: 0 !important;
                            min-height: 0 !important;
                            width: 100% !important;
                            height: 100vh !important;
                            display: flex !important;
                            align-items: center !important;
                            justify-content: center !important;
                            background: transparent !important;
                            overflow: hidden !important;
                            padding: 0 !important;
                        }
                        .web_qrcode_wrp {
                            position: relative !important;
                            top: auto !important;
                            left: auto !important;
                            transform: none !important;
                            display: flex !important;
                            flex-direction: column !important;
                            align-items: center !important;
                            justify-content: center !important;
                            width: 332px !important;
                            min-height: 432px !important;
                            margin: 0 auto !important;
                            padding: 32px 24px 28px !important;
                            box-sizing: border-box !important;
                            border-radius: 22px !important;
                            border: 1px solid rgba(0, 173, 111, 0.16) !important;
                            background: rgba(255, 255, 255, 0.94) !important;
                            box-shadow: 0 24px 60px rgba(28, 43, 34, 0.16) !important;
                        }
                        .web_qrcode_wrp::before {
                            content: "微信授权登录";
                            display: block;
                            margin: 0 0 8px;
                            color: #1d1f22;
                            font-size: 24px;
                            font-weight: 800;
                            line-height: 1.2;
                            letter-spacing: 0;
                            text-align: center;
                        }
                        .web_qrcode_wrp::after {
                            content: "扫码或快捷授权后自动返回 FileSyncMonitor";
                            display: block;
                            margin: 18px 0 0;
                            color: #6f7885;
                            font-size: 13px;
                            font-weight: 600;
                            line-height: 1.35;
                            text-align: center;
                        }
                        .web_qrcode_app_wrp,
                        .web_qrcode_tips_logo,
                        .web_qrcode_tips {
                            display: none !important;
                        }
                        .web_qrcode_img_wrp {
                            display: flex !important;
                            align-items: center !important;
                            justify-content: center !important;
                            width: 248px !important;
                            height: 248px !important;
                            margin: 0 auto !important;
                            border-radius: 18px !important;
                            background: #ffffff !important;
                            box-shadow: inset 0 0 0 1px rgba(0,0,0,0.06) !important;
                        }
                        .web_qrcode_img {
                            width: 224px !important;
                            height: 224px !important;
                            margin: 0 !important;
                        }
                        .web_qrcode_refresh_btn {
                            border-radius: 14px !important;
                        }
                        .qlogin_mod {
                            display: flex !important;
                            flex-direction: column !important;
                            align-items: center !important;
                            gap: 14px !important;
                            padding: 8px 0 0 !important;
                        }
                        .qlogin_user_avatar {
                            width: 96px !important;
                            height: 96px !important;
                            border-radius: 18px !important;
                            box-shadow: 0 12px 30px rgba(28, 43, 34, 0.14) !important;
                        }
                        .qlogin_user_nickname {
                            color: #1d1f22 !important;
                            font-size: 20px !important;
                            font-weight: 800 !important;
                            line-height: 1.2 !important;
                            margin: 2px 0 0 !important;
                        }
                        .qlogin_btn,
                        .weui-btn_primary {
                            width: 236px !important;
                            height: 48px !important;
                            border: 0 !important;
                            border-radius: 14px !important;
                            background: linear-gradient(135deg, #06c985 0%, #00a96b 100%) !important;
                            color: #ffffff !important;
                            font-size: 17px !important;
                            font-weight: 800 !important;
                            box-shadow: 0 14px 28px rgba(0, 173, 111, 0.24) !important;
                        }
                        .web_qrcode_switch,
                        .weui-link {
                            color: #00a96b !important;
                            font-size: 14px !important;
                            font-weight: 700 !important;
                            text-decoration: none !important;
                        }
                        .web_qrcode_msg,
                        .web_qrcode_msg_icon_success,
                        .web_qrcode_msg_icon_error {
                            color: #1d1f22 !important;
                        }
                    `;
                    (document.head || document.documentElement).appendChild(style);
                    log("Login polish installed");
                } catch (e) {
                    log(`Login polish error: ${e}`);
                }
            }

            installLoginPolish();
            if (document.readyState === "loading") {
                document.addEventListener("DOMContentLoaded", installLoginPolish, { once: true });
            }
            setTimeout(installLoginPolish, 500);
            setTimeout(installLoginPolish, 1500);

            function requestUrl(input) {
                try {
                    if (typeof input === "string") return input;
                    if (input instanceof URL) return input.href;
                    if (input && typeof input.url === "string") return input.url;
                    return String(input || "");
                } catch (e) {
                    return "";
                }
            }

            function isLoginResponseUrl(url) {
                if (!url) return false;
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
                try {
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
                } catch (e) {
                    log(`normalize error: ${e}`);
                }
                return null;
            }

            function submitLogin(data, source) {
                try {
                    if (hasSubmitted) return;
                    const creds = normalizeLoginData(data);
                    if (!creds || !creds.token || !creds.uid || creds.token === "guest") return;
                    hasSubmitted = true;
                    log(`Login credentials captured via ${source}; uid=${creds.uid}`);
                    bridge("login-success", creds);
                } catch (e) {
                    log(`submitLogin error: ${e}`);
                }
            }

            try {
                if (window.fetch) {
                    const originalFetch = window.fetch.bind(window);
                    window.fetch = async function(...args) {
                        try {
                            const url = requestUrl(args[0]);
                            const response = await originalFetch(...args);
                            try {
                                if (isLoginResponseUrl(url)) {
                                    response.clone().text()
                                        .then(text => submitLogin(text, "fetch"))
                                        .catch(error => log(`Fetch login parse error: ${error}`));
                                }
                            } catch (e) {
                                log(`Fetch response check error: ${e}`);
                            }
                            return response;
                        } catch (err) {
                            log(`Fetch execution error: ${err}`);
                            return originalFetch(...args);
                        }
                    };
                }
            } catch (e) {
                log(`Fetch hook setup error: ${e}`);
            }

            try {
                const originalOpen = window.XMLHttpRequest && window.XMLHttpRequest.prototype.open;
                if (originalOpen) {
                    window.XMLHttpRequest.prototype.open = function(method, url, ...rest) {
                        try {
                            this.__fsmLoginUrl = requestUrl(url);
                        } catch (e) {
                            log(`XHR open hook error: ${e}`);
                        }
                        return originalOpen.apply(this, [method, url, ...rest]);
                    };

                    const originalSend = window.XMLHttpRequest.prototype.send;
                    window.XMLHttpRequest.prototype.send = function(...args) {
                        try {
                            this.addEventListener("loadend", function() {
                                try {
                                    if (!isLoginResponseUrl(this.__fsmLoginUrl || "")) return;
                                    submitLogin(this.responseText || this.response, "xhr");
                                } catch (error) {
                                    log(`XHR login parse error: ${error}`);
                                }
                            });
                        } catch (e) {
                            log(`XHR send hook setup error: ${e}`);
                        }
                        return originalSend.apply(this, args);
                    };
                }
            } catch (e) {
                log(`XHR hook setup error: ${e}`);
            }

            log("Login capture hooks installed");
        })();
    "##;

    let app_clone = app.clone();
    let app_clone2 = app.clone();
    let (build_result_tx, build_result_rx) = std::sync::mpsc::channel::<Result<(), String>>();

    app.run_on_main_thread(move || {
        let app_for_nav = app_clone2.clone();
        let builder = tauri::WebviewWindowBuilder::new(&app_clone2, "ima_login", login_url)
            .title("微信扫码登录")
            .inner_size(380.0, 540.0)
            .resizable(false)
            .decorations(true)
            .devtools(true)
            .user_agent(WEBVIEW_USER_AGENT)
            .initialization_script(js_injection);
        let builder = if let Some(icon) = app_window_icon() {
            match builder.icon(icon) {
                Ok(builder) => builder,
                Err(err) => {
                    let message = format!("Failed to set IMA login window icon: {}", err);
                    println!("[IMALogin] {}", message);
                    let _ = build_result_tx.send(Err(message));
                    return;
                }
            }
        } else {
            builder
        };
        let builder = builder.on_navigation(move |url| {
            println!("[IMALogin Navigation] {}", url);
            let scheme = url.scheme();
            if scheme == "tauri" || scheme == "asset" {
                return true;
            }
            if scheme != "http" && scheme != "https" {
                use tauri_plugin_opener::OpenerExt;
                let url_str = url.to_string();
                println!(
                    "[WebView Navigation] Custom scheme intercepted: {}. Opening via OS...",
                    url_str
                );
                let _ = app_for_nav.opener().open_path(&url_str, None::<&str>);
                return false;
            }

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
                    let refresh_token = parsed_query
                        .get("refresh_token")
                        .cloned()
                        .unwrap_or_default();
                    let uid = parsed_query.get("uid").cloned().unwrap_or_default();
                    let guid = parsed_query.get("guid").cloned().unwrap_or_default();
                    let avatar = parsed_query.get("avatar").cloned().unwrap_or_default();
                    let nickname = parsed_query.get("nickname").cloned().unwrap_or_default();

                    if !token.is_empty() {
                        println!("[IMALogin] Captured Credentials! UID: {}", uid);
                        let creds = CachedCredentials {
                            token,
                            refresh_token,
                            uid: uid.clone(),
                            guid,
                        };
                        if let Err(e) = credentials::save_credentials(&creds) {
                            println!("[IMALogin] Failed to save credentials to Keyring: {:?}", e);
                        } else {
                            println!("[IMALogin] Credentials saved successfully.");
                        }
                        let _ = app_clone.emit(
                            "login_success",
                            serde_json::json!({
                                "avatar": avatar,
                                "nickname": nickname,
                                "uid": uid,
                            }),
                        );

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

        let build_result = match builder.center().build() {
            Ok(win) => {
                let _ = win.set_focus();
                Ok(())
            }
            Err(err) => {
                if let Some(win) = app_clone2.get_webview_window("ima_login") {
                    let _ = win.set_focus();
                    Ok(())
                } else {
                    let message = format!("Failed to create IMA login window: {}", err);
                    println!("[IMALogin] {}", message);
                    Err(message)
                }
            }
        };
        let _ = build_result_tx.send(build_result);
    })
    .map_err(|e| e.to_string())?;

    build_result_rx
        .recv_timeout(std::time::Duration::from_secs(5))
        .map_err(|e| format!("Timed out waiting for IMA login window: {}", e))??;

    Ok(())
}

pub fn run() {
    tauri::Builder::default()
        .plugin(tauri_plugin_opener::init())
        .setup(|app| {
            // Save global AppHandle for silent refresh
            let _ = APP_HANDLE.set(app.handle().clone());

            // Locate user data directory for SQLite database
            let app_dir = app
                .path()
                .app_data_dir()
                .unwrap_or_else(|_| PathBuf::from("./"));

            // Ensure app directory exists
            std::fs::create_dir_all(&app_dir).unwrap_or_default();

            // Initalize credentials module with the correct sandbox data directory
            let _ = credentials::APP_DATA_DIR.set(app_dir.clone());

            let db_path = app_dir.join("file_sync_monitor.db");
            let conn = db::init_db(&db_path).expect("Failed to initialize SQLite database");

            let monitor = DirectoryMonitor::new(IgnoreRules::new(true, vec![], vec![], vec![]));

            // Setup global shared State
            app.manage(AppState {
                db_conn: Mutex::new(conn),
                monitor: Arc::new(Mutex::new(monitor)),
                db_path,
            });

            // Scaffold dynamic System Tray
            tray::setup_system_tray(app.handle())?;

            if let Some(win) = app.get_webview_window("main") {
                if let Some(icon) = app_window_icon() {
                    let _ = win.set_icon(icon);
                }
            }

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
            create_wechat_login_session,
            poll_wechat_qr_status,
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
            clear_http_logs,
            set_window_theme
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri application");
}
