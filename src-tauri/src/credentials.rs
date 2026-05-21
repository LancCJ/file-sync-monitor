use keyring::Entry;
use serde::{Serialize, Deserialize};

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
pub struct CachedCredentials {
    pub token: String,
    pub refresh_token: String,
    pub uid: String,
    pub guid: String,
}

const SERVICE_NAME: &str = "com.filesyncmonitor.credentials";
const CREDENTIALS_KEY: &str = "ima_combined_credentials";

pub fn load_credentials() -> Option<CachedCredentials> {
    match Entry::new(SERVICE_NAME, CREDENTIALS_KEY) {
        Ok(entry) => {
            match entry.get_password() {
                Ok(json_str) => {
                    if let Ok(creds) = serde_json::from_str::<CachedCredentials>(&json_str) {
                        return Some(creds);
                    }
                }
                Err(e) => {
                    println!("[Credentials] Failed to load password: {:?}", e);
                }
            }
        }
        Err(e) => {
            println!("[Credentials] Failed to create keyring entry: {:?}", e);
        }
    }
    None
}

pub fn save_credentials(creds: &CachedCredentials) -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, CREDENTIALS_KEY)
        .map_err(|e| format!("Keyring init error: {:?}", e))?;
        
    let json_str = serde_json::to_string(creds)
        .map_err(|e| format!("Serialization error: {:?}", e))?;
        
    entry.set_password(&json_str)
        .map_err(|e| format!("Keyring save error: {:?}", e))?;
        
    Ok(())
}

pub fn clear_credentials() -> Result<(), String> {
    let entry = Entry::new(SERVICE_NAME, CREDENTIALS_KEY)
        .map_err(|e| format!("Keyring init error: {:?}", e))?;
        
    match entry.delete_password() {
        Ok(_) => Ok(()),
        Err(keyring::Error::NoEntry) => Ok(()), // Already cleared
        Err(e) => Err(format!("Keyring delete error: {:?}", e)),
    }
}

pub fn calculate_bkn(token: &str) -> u32 {
    let mut hash: u32 = 5381;
    for c in token.chars() {
        let code = c as u32;
        hash = hash.wrapping_add(hash << 5).wrapping_add(code);
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
         IMA-REFRESH-TOKEN={}; \
         IMA-TOKEN={};",
        creds.guid, creds.uid, creds.refresh_token, creds.token
    )
}
