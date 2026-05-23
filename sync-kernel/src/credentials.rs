use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::OnceLock;

pub static APP_DATA_DIR: OnceLock<PathBuf> = OnceLock::new();

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CachedCredentials {
    pub token: String,
    pub refresh_token: String,
    pub uid: String,
    pub guid: String,
}

fn get_credentials_path() -> PathBuf {
    if let Some(app_dir) = APP_DATA_DIR.get() {
        app_dir.join("ima_credentials.json")
    } else {
        // Fallback to legacy path in case of early call
        std::env::temp_dir().join("fsm_ima_creds.json")
    }
}

pub fn load_credentials() -> Option<CachedCredentials> {
    let path = get_credentials_path();
    if let Ok(json_str) = std::fs::read_to_string(&path) {
        if let Ok(creds) = serde_json::from_str::<CachedCredentials>(&json_str) {
            println!("[Credentials] Loaded from sandbox safe storage: {:?}", path);
            return Some(creds);
        }
    }

    // Attempt migration from legacy path if exists
    let legacy_path = std::env::temp_dir().join("fsm_ima_creds.json");
    if legacy_path.exists() {
        if let Ok(json_str) = std::fs::read_to_string(&legacy_path) {
            if let Ok(creds) = serde_json::from_str::<CachedCredentials>(&json_str) {
                println!("[Credentials] Legacy file found. Migrating to sandbox storage...");
                let _ = save_credentials(&creds);
                let _ = std::fs::remove_file(&legacy_path);
                return Some(creds);
            }
        }
    }

    None
}

pub fn save_credentials(creds: &CachedCredentials) -> Result<(), String> {
    let path = get_credentials_path();
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }

    let json_str = serde_json::to_string(creds).map_err(|e| e.to_string())?;
    std::fs::write(&path, &json_str).map_err(|e| format!("Failed to write credentials: {}", e))?;
    println!(
        "[Credentials] Saved successfully to sandbox storage: {:?}",
        path
    );
    Ok(())
}

pub fn clear_credentials() -> Result<(), String> {
    let path = get_credentials_path();
    if path.exists() {
        let _ = std::fs::remove_file(&path);
    }

    let legacy_path = std::env::temp_dir().join("fsm_ima_creds.json");
    if legacy_path.exists() {
        let _ = std::fs::remove_file(&legacy_path);
    }

    println!("[Credentials] Sandbox and legacy credentials cleared.");
    Ok(())
}

pub fn calculate_bkn(token: &str) -> u32 {
    let mut hash: u32 = 5381;
    for &b in token.as_bytes() {
        hash = hash.wrapping_add(hash << 5).wrapping_add(b as u32);
    }
    hash & 0x7FFFFFFF
}

pub fn get_cookie_string(creds: &CachedCredentials) -> String {
    format!(
        "PLATFORM=H5; CLIENT-TYPE=256020; WEB-VERSION=4.25.3; \
         IMA-GUID={}; \
         IMA-Q36=e749267b48b3622b592f9d2d200018c19311; \
         IMA-IUA=PR=IMA&PP=com.tencent.imamac&PPVN=2.5.1&PL=MAC&COVC=143.0.7499.4456&RL=3024*1964&MO=Mac OS X&OS=15.7.7&SYSARCH=Arm&DN=&BC=release&BN=4262&BT=1778318655445&CH=9caac41887&DC=10000074&EV=; \
         IMA-UID={}; \
         IMA-TOKEN={}; \
         IMA-REFRESH-TOKEN={}; \
         UID-TYPE=2; TOKEN-TYPE=14",
        creds.guid, creds.uid, creds.token, creds.refresh_token
    )
}
