use reqwest::header::{HeaderMap, HeaderValue};
use serde::{Serialize, Deserialize, de::DeserializeOwned};
use serde::de::{self, Deserializer, Visitor};
use std::collections::HashMap;
use std::fmt;
use std::path::Path;
use hmac::{Hmac, Mac};
use sha1::Sha1;

use crate::credentials::{self, CachedCredentials};

type HmacSha1 = Hmac<Sha1>;

fn hmac_sha1(key: &[u8], data: &str) -> String {
    let mut mac = HmacSha1::new_from_slice(key).expect("HMAC can take key of any size");
    mac.update(data.as_bytes());
    let result = mac.finalize();
    hex::encode(result.into_bytes())
}

fn sha1(data: &str) -> String {
    use sha1::Digest;
    let mut hasher = Sha1::new();
    hasher.update(data.as_bytes());
    let result = hasher.finalize();
    hex::encode(result)
}

const FRAGMENT: &percent_encoding::AsciiSet = &percent_encoding::NON_ALPHANUMERIC
    .remove(b'-')
    .remove(b'.')
    .remove(b'_')
    .remove(b'~');

fn rfc3986_encode(s: &str) -> String {
    percent_encoding::utf8_percent_encode(s, FRAGMENT).to_string()
}

pub struct COSSigner;

impl COSSigner {
    pub fn sign(
        method: &str,
        pathname: &str,
        secret_id: &str,
        secret_key: &str,
        start_time: i64,
        expired_time: i64,
        headers: &HashMap<String, String>,
    ) -> String {
        let key_time = format!("{};{}", start_time, expired_time);
        let sign_key = hmac_sha1(secret_key.as_bytes(), &key_time);

        let mut sorted_keys: Vec<String> = headers.keys().cloned().collect();
        sorted_keys.sort();

        let http_headers = sorted_keys
            .iter()
            .map(|k| {
                let val = headers.get(k).unwrap();
                format!("{}={}", k.to_lowercase(), rfc3986_encode(val))
            })
            .collect::<Vec<String>>()
            .join("&");

        let http_string = format!(
            "{}\n{}\n\n{}\n",
            method.to_lowercase(),
            pathname,
            http_headers
        );

        let string_to_sign = format!(
            "sha1\n{}\n{}\n",
            key_time,
            sha1(&http_string)
        );

        let signature = hmac_sha1(sign_key.as_bytes(), &string_to_sign);

        let header_list = sorted_keys
            .iter()
            .map(|k| k.to_lowercase())
            .collect::<Vec<String>>()
            .join(";");

        format!(
            "q-sign-algorithm=sha1&q-ak={}&q-sign-time={}&q-key-time={}&q-header-list={}&q-url-param-list=&q-signature={}",
            secret_id,
            key_time,
            key_time,
            header_list,
            signature
        )
    }
}

#[derive(Debug, Serialize)]
pub struct IMAResponse<T> {
    pub code: i32,
    pub msg: Option<String>,
    pub data: Option<T>,
    pub request_id: Option<String>,
}

impl<'de, T> Deserialize<'de> for IMAResponse<T>
where
    T: de::DeserializeOwned,
{
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        let value = serde_json::Value::deserialize(deserializer)?;
        
        let code = value.get("code")
            .and_then(|v| v.as_i64())
            .map(|v| v as i32)
            .unwrap_or(0);
            
        let msg = value.get("msg")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());
            
        let request_id = value.get("requestId")
            .or_else(|| value.get("request_id"))
            .and_then(|v| v.as_str())
            .map(|s| s.to_string());

        let mut data = None;

        // 1. Try to parse from "data" field
        if let Some(data_field) = value.get("data") {
            if let Ok(parsed_t) = serde_json::from_value::<T>(data_field.clone()) {
                data = Some(parsed_t);
            }
        }

        // 2. Try to parse from "info" field (e.g. get_user_info)
        if data.is_none() {
            if let Some(info_field) = value.get("info") {
                if let Ok(parsed_t) = serde_json::from_value::<T>(info_field.clone()) {
                    data = Some(parsed_t);
                }
            }
        }

        // 3. Try to parse "results" field directly into T (e.g. some result arrays)
        if data.is_none() {
            if let Some(results_field) = value.get("results") {
                if let Ok(parsed_t) = serde_json::from_value::<T>(results_field.clone()) {
                    data = Some(parsed_t);
                }
            }
        }

        // 4. Fallback: Parse the whole root object as T (e.g. get_knowledge_base_list response having results directly at root)
        if data.is_none() {
            if let Ok(parsed_t) = serde_json::from_value::<T>(value.clone()) {
                data = Some(parsed_t);
            }
        }

        Ok(IMAResponse {
            code,
            msg,
            data,
            request_id,
        })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeBase {
    #[serde(rename = "knowledgeBaseId")]
    pub kb_id: String,
    #[serde(default)]
    pub id: Option<String>,
    pub name: String,
    pub description: Option<String>,
    pub count: Option<i32>,
}

impl<'de> Deserialize<'de> for KnowledgeBase {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct RawKB {
            #[serde(alias = "knowledgeBaseId", alias = "knowledge_base_id", alias = "kb_id")]
            kb_id: Option<String>,
            id: Option<String>,
            #[serde(alias = "knowledge_base_name", alias = "kb_name", alias = "title", alias = "name")]
            name: Option<String>,
            description: Option<String>,
            count: Option<i32>,
            #[serde(alias = "basic_info")]
            basic_info: Option<serde_json::Value>,
        }

        let raw = RawKB::deserialize(deserializer)?;

        let final_id = raw.kb_id.or(raw.id).unwrap_or_default();
        
        let mut final_name = raw.name.unwrap_or_default();
        if final_name.is_empty() {
            if let Some(basic_info) = raw.basic_info {
                if let Some(name_val) = basic_info.get("name") {
                    if let Some(name_str) = name_val.as_str() {
                        final_name = name_str.to_string();
                    }
                }
            }
        }
        if final_name.is_empty() {
            final_name = "未命名知识库".to_string();
        }

        Ok(KnowledgeBase {
            kb_id: final_id.clone(),
            id: Some(final_id),
            name: final_name,
            description: raw.description,
            count: raw.count,
        })
    }
}

#[derive(Debug, Serialize, Deserialize)]
pub struct KBListResult {
    #[serde(rename = "knowledgeBaseList", alias = "knowledge_base_list")]
    pub knowledge_base_list: Vec<KnowledgeBase>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5KnowledgeBaseListResponse {
    pub results: Vec<KBListResult>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5OpenInfo {
    #[serde(rename = "avatar_url", alias = "avatarUrl")]
    pub avatar_url: String,
    pub nickname: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5UserInfoDetail {
    #[serde(rename = "open_info", alias = "openInfo")]
    pub open_info: H5OpenInfo,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct H5SpaceDetail {
    #[serde(rename = "total_space")]
    pub total_space: String,
    #[serde(rename = "used_space")]
    pub used_space: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct H5SpaceQuotaResponse {
    #[serde(rename = "total_user_space")]
    pub total_user_space: Option<H5SpaceDetail>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SpaceQuota {
    pub total_quota: i64,
    pub used_quota: i64,
}

fn deserialize_flexible_int<'de, D>(deserializer: D) -> Result<Option<i32>, D::Error>
where
    D: Deserializer<'de>,
{
    struct FlexibleIntVisitor;

    impl<'de> Visitor<'de> for FlexibleIntVisitor {
        type Value = Option<i32>;

        fn expecting(&self, formatter: &mut fmt::Formatter) -> fmt::Result {
            formatter.write_str("an integer or a string containing an integer")
        }

        fn visit_none<E>(self) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(None)
        }

        fn visit_some<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
        where
            D: Deserializer<'de>,
        {
            deserializer.deserialize_any(self)
        }

        fn visit_i64<E>(self, v: i64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(Some(v as i32))
        }

        fn visit_u64<E>(self, v: u64) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(Some(v as i32))
        }

        fn visit_str<E>(self, v: &str) -> Result<Self::Value, E>
        where
            E: de::Error,
        {
            Ok(v.parse::<i32>().ok())
        }
    }

    deserializer.deserialize_option(FlexibleIntVisitor)
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct FolderInfo {
    #[serde(rename = "folder_id")]
    pub folder_id: Option<String>,
    pub name: Option<String>,
    #[serde(rename = "parent_folder_id")]
    pub parent_folder_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NotebookExtInfo {
    pub notebook_id: Option<String>,
}

impl<'de> Deserialize<'de> for NotebookExtInfo {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct RawNotebook {
            notebook_id: Option<String>,
            note_id: Option<String>,
            content_id: Option<String>,
        }

        let raw = RawNotebook::deserialize(deserializer)?;
        let notebook_id = raw.notebook_id.or(raw.note_id).or(raw.content_id);
        Ok(NotebookExtInfo { notebook_id })
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct KnowledgeInfo {
    pub media_id: String,
    pub title: String,
    pub parent_folder_id: Option<String>,
    pub folder_id: Option<String>,
    pub name: Option<String>,
    pub media_type: Option<i32>,
    pub folder_info: Option<FolderInfo>,
    pub file_number: Option<i32>,
    pub folder_number: Option<i32>,
    pub is_top: Option<bool>,
    pub notebook_ext_info: Option<NotebookExtInfo>,
}

impl<'de> Deserialize<'de> for KnowledgeInfo {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct RawInfo {
            media_id: Option<String>,
            folder_id: Option<String>,
            title: Option<String>,
            name: Option<String>,
            parent_folder_id: Option<String>,
            media_type: Option<i32>,
            folder_info: Option<FolderInfo>,
            #[serde(default, deserialize_with = "deserialize_flexible_int")]
            file_number: Option<i32>,
            #[serde(default, deserialize_with = "deserialize_flexible_int")]
            folder_number: Option<i32>,
            is_top: Option<bool>,
            notebook_ext_info: Option<NotebookExtInfo>,
        }

        let raw = RawInfo::deserialize(deserializer)?;
        
        let media_id = raw.media_id.clone().or_else(|| raw.folder_id.clone()).unwrap_or_default();
        
        let title = raw.title.clone()
            .or_else(|| raw.name.clone())
            .or_else(|| raw.folder_info.as_ref().and_then(|fi| fi.name.clone()))
            .unwrap_or_default();

        let parent_folder_id = raw.parent_folder_id.clone()
            .or_else(|| raw.folder_info.as_ref().and_then(|fi| fi.parent_folder_id.clone()));

        Ok(KnowledgeInfo {
            media_id,
            title,
            parent_folder_id,
            folder_id: raw.folder_id,
            name: raw.name,
            media_type: raw.media_type,
            folder_info: raw.folder_info,
            file_number: raw.file_number,
            folder_number: raw.folder_number,
            is_top: raw.is_top,
            notebook_ext_info: raw.notebook_ext_info,
        })
    }
}

impl KnowledgeInfo {
    pub fn display_name(&self) -> &str {
        if let Some(ref n) = self.name {
            if !n.is_empty() {
                return n;
            }
        }
        &self.title
    }

    pub fn folder_identifier(&self) -> Option<String> {
        if let Some(ref fi) = self.folder_info {
            if let Some(ref fid) = fi.folder_id {
                if !fid.is_empty() {
                    return Some(fid.clone());
                }
            }
        }

        if let Some(mt) = self.media_type {
            if mt != 0 && mt != 16 {
                return None;
            }
        }

        if self.is_folder_media_type() {
            if let Some(ref fid) = self.folder_id {
                if !fid.is_empty() {
                    return Some(fid.clone());
                }
            }
            if !self.media_id.is_empty() {
                return Some(self.media_id.clone());
            }
        }

        if self.has_folder_metadata() {
            if let Some(ref fid) = self.folder_id {
                if !fid.is_empty() {
                    return Some(fid.clone());
                }
            }
            if !self.media_id.is_empty() {
                return Some(self.media_id.clone());
            }
        }

        if self.media_id.starts_with("folder_") {
            return Some(self.media_id.clone());
        }

        if let Some(ref fid) = self.folder_id {
            if fid.starts_with("folder_") && self.media_type.is_none() && (self.media_id.is_empty() || self.media_id == *fid) {
                return Some(fid.clone());
            }
        }

        None
    }

    pub fn is_folder_media_type(&self) -> bool {
        self.media_type == Some(16)
    }

    pub fn has_folder_metadata(&self) -> bool {
        self.file_number.is_some() || self.folder_number.is_some()
    }

    pub fn is_folder(&self) -> bool {
        self.folder_identifier().is_some()
    }

    #[allow(dead_code)]
    pub fn is_note(&self) -> bool {
        self.media_type == Some(11) || self.notebook_ext_info.as_ref().map(|nei| nei.notebook_id.as_ref().map(|n| !n.is_empty()).unwrap_or(false)).unwrap_or(false)
    }
}

#[derive(Debug, Serialize)]
pub struct KnowledgeListPayload {
    pub knowledge_list: Vec<KnowledgeInfo>,
    pub is_end: bool,
    pub next_cursor: String,
}

impl<'de> Deserialize<'de> for KnowledgeListPayload {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        #[derive(Deserialize)]
        struct RawPayload {
            knowledge_list: Option<Vec<KnowledgeInfo>>,
            folder_list: Option<Vec<KnowledgeInfo>>,
            info_list: Option<Vec<KnowledgeInfo>>,
            list: Option<Vec<KnowledgeInfo>>,
            items: Option<Vec<KnowledgeInfo>>,
            is_end: Option<bool>,
            next_cursor: Option<String>,
        }

        let raw = RawPayload::deserialize(deserializer)?;
        let mut items = Vec::new();
        if let Some(list) = raw.knowledge_list { items.extend(list); }
        if let Some(list) = raw.folder_list { items.extend(list); }
        if let Some(list) = raw.info_list { items.extend(list); }
        if let Some(list) = raw.list { items.extend(list); }
        if let Some(list) = raw.items { items.extend(list); }

        let mut seen = std::collections::HashSet::new();
        let deduped = items.into_iter().filter(|item| {
            let id = item.folder_identifier().unwrap_or_else(|| item.media_id.clone());
            if id.is_empty() { return true; }
            seen.insert(id)
        }).collect();

        Ok(KnowledgeListPayload {
            knowledge_list: deduped,
            is_end: raw.is_end.unwrap_or(true),
            next_cursor: raw.next_cursor.unwrap_or_default(),
        })
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CreateMediaPayload {
    #[serde(rename = "media_id")]
    pub media_id: String,
    #[serde(rename = "cos_credential")]
    pub cos_credential: COSCredential,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct COSCredential {
    #[serde(rename = "bucket_name")]
    pub bucket_name: String,
    pub region: String,
    #[serde(rename = "cos_key")]
    pub cos_key: String,
    #[serde(rename = "secret_id")]
    pub secret_id: String,
    #[serde(rename = "secret_key")]
    pub secret_key: String,
    pub token: String,
    #[serde(rename = "start_time")]
    pub start_time: String,
    #[serde(rename = "expired_time")]
    pub expired_time: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaInfoPayload {
    #[serde(rename = "media_type")]
    pub media_type: i32,
    #[serde(rename = "url_info")]
    pub url_info: Option<URLInfo>,
    #[serde(rename = "notebook_ext_info")]
    pub notebook_ext_info: Option<NotebookExtInfo>,
}

impl MediaInfoPayload {
    pub fn has_usable_content(&self) -> bool {
        if self.media_type == 11 {
            return self.notebook_ext_info.as_ref().map(|nei| nei.notebook_id.as_ref().map(|n| !n.is_empty()).unwrap_or(false)).unwrap_or(false);
        }
        self.url_info.as_ref().map(|ui| !ui.url.is_empty()).unwrap_or(false)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct URLInfo {
    pub url: String,
    pub headers: Option<HashMap<String, String>>,
}

#[derive(Debug, Clone, Serialize)]
pub struct NoteContentPayload {
    pub content: Option<String>,
}

impl<'de> Deserialize<'de> for NoteContentPayload {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let val = serde_json::Value::deserialize(deserializer)?;
        let content = find_string_in_value(&val, &["content", "doc_content", "text", "plain_text", "markdown", "md_content"]);
        Ok(NoteContentPayload { content })
    }
}

fn find_string_in_value(val: &serde_json::Value, keys: &[&str]) -> Option<String> {
    match val {
        serde_json::Value::String(s) => Some(s.clone()),
        serde_json::Value::Object(map) => {
            for key in keys {
                if let Some(serde_json::Value::String(s)) = map.get(*key) {
                    return Some(s.clone());
                }
            }
            for (_k, v) in map {
                if let Some(s) = find_string_in_value(v, keys) {
                    return Some(s);
                }
            }
            None
        }
        serde_json::Value::Array(arr) => {
            for v in arr {
                if let Some(s) = find_string_in_value(v, keys) {
                    return Some(s);
                }
            }
            None
        }
        _ => None,
    }
}


#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmptyPayload {}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckRepeatedNamesPayload {
    pub results: Vec<CheckRepeatedNameResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CheckRepeatedNameResult {
    pub name: String,
    #[serde(rename = "is_repeated")]
    pub is_repeated: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteKnowledgeWebResponse {
    pub code: i32,
    pub msg: Option<String>,
    pub results: HashMap<String, DeleteKnowledgeResult>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DeleteKnowledgeResult {
    #[serde(rename = "media_id")]
    pub media_id: String,
    #[serde(rename = "ret_code")]
    pub ret_code: i32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IMACreateFolderResponse {
    pub knowledge: IMAFolderKnowledge,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct IMAFolderKnowledge {
    #[serde(rename = "media_id")]
    pub media_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct H5GetKnowledgeResponse {
    pub knowledge: H5KnowledgeDetail,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct H5KnowledgeDetail {
    #[serde(rename = "media_info")]
    pub media_info: MediaInfoPayload,
}

pub struct IMAMediaType;

impl IMAMediaType {
    pub fn resolve(ext: &str) -> Option<(i32, String)> {
        let ext_lower = ext.to_lowercase();
        match ext_lower.as_str() {
            "pdf" => Some((1, "application/pdf".to_string())),
            "doc" | "docx" => Some((3, "application/msword".to_string())),
            "ppt" | "pptx" => Some((4, "application/vnd.ms-powerpoint".to_string())),
            "xls" | "xlsx" => Some((5, "application/vnd.ms-excel".to_string())),
            "csv" => Some((5, "text/csv".to_string())),
            "md" | "markdown" => Some((7, "text/markdown".to_string())),
            "png" => Some((9, "image/png".to_string())),
            "jpg" | "jpeg" => Some((9, "image/jpeg".to_string())),
            "webp" => Some((9, "image/webp".to_string())),
            "txt" => Some((13, "text/plain".to_string())),
            "xmind" => Some((14, "application/x-xmind".to_string())),
            "mp3" => Some((15, "audio/mpeg".to_string())),
            "m4a" => Some((15, "audio/x-m4a".to_string())),
            "wav" => Some((15, "audio/wav".to_string())),
            "aac" => Some((15, "audio/aac".to_string())),
            _ => None,
        }
    }
}

pub struct IMASyncClient {
    client: reqwest::Client,
    base_url: String,
}

impl IMASyncClient {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(30))
                .build()
                .unwrap_or_default(),
            base_url: "https://ima.qq.com".to_string(),
        }
    }

    fn build_headers(&self, creds: &CachedCredentials) -> HeaderMap {
        let mut headers = HeaderMap::new();
        headers.insert("Host", HeaderValue::from_static("ima.qq.com"));
        headers.insert("Connection", HeaderValue::from_static("keep-alive"));
        headers.insert("sec-ch-ua-platform", HeaderValue::from_static("macOS"));
        headers.insert("from_browser_ima", HeaderValue::from_static("1"));
        headers.insert("sec-ch-ua", HeaderValue::from_static("\"Chromium\";v=\"143\", \"Not A(Brand\";v=\"24\""));
        headers.insert("x-ima-bkn", HeaderValue::from_str(&credentials::calculate_bkn(&creds.token).to_string()).unwrap_or(HeaderValue::from_static("0")));
        headers.insert("sec-ch-ua-mobile", HeaderValue::from_static("?0"));
        headers.insert("x-ima-cookie", HeaderValue::from_str(&credentials::get_cookie_string(creds)).unwrap_or(HeaderValue::from_static("")));
        headers.insert("User-Agent", HeaderValue::from_static("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 IMA/143.0.7499.4456"));
        headers.insert("accept", HeaderValue::from_static("application/json"));
        headers.insert("extension_version", HeaderValue::from_static("4.25.3"));
        headers.insert("Origin", HeaderValue::from_static("chrome-extension://nkohmbngmopdajidckglcoehlaeepeoi"));
        headers.insert("Accept-Language", HeaderValue::from_static("zh-CN,zh;q=0.9"));
        headers
    }
    pub async fn post_json<T: DeserializeOwned>(&self, path: &str, body: serde_json::Value, creds: &CachedCredentials) -> Result<IMAResponse<T>, String> {
        let url = format!("{}/{}", self.base_url, path);
        let headers = self.build_headers(creds);

        // Capture request details
        let log_id = crate::generate_log_id();
        let timestamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
        let headers_str = headers.iter().map(|(key, val)| {
            format!("{}: {:?}", key, val)
        }).collect::<Vec<String>>().join("\n");
        let req_body_str = serde_json::to_string_pretty(&body).unwrap_or_else(|_| body.to_string());

        crate::add_http_log(crate::HttpLogEntry {
            id: log_id.clone(),
            timestamp,
            method: "POST".to_string(),
            url: url.clone(),
            request_headers: Some(headers_str),
            request_body: Some(req_body_str),
            response_code: None,
            response_body: None,
            error: None,
        });

        println!("[IMA Client] === REQUEST START ===");
        println!("[IMA Client] URL: {}", url);
        println!("[IMA Client] Method: POST");
        println!("[IMA Client] Headers:");
        for (key, val) in headers.iter() {
            println!("  {}: {:?}", key, val);
        }
        println!("[IMA Client] Body: {}", body);

        let res = self.client.post(&url)
            .headers(headers)
            .json(&body)
            .send()
            .await
            .map_err(|e| {
                let err_msg = format!("HTTP request error: {:?}", e);
                println!("[IMA Client] Request failed: {}", err_msg);
                crate::update_http_log_error(&log_id, &err_msg);
                err_msg
            })?;

        let status = res.status();
        let body_str = res.text().await.map_err(|e| {
            let err_msg = format!("Failed to read body: {:?}", e);
            println!("[IMA Client] Failed to read body: {}", err_msg);
            crate::update_http_log_error(&log_id, &err_msg);
            err_msg
        })?;

        println!("[IMA Client] === RESPONSE START ===");
        println!("[IMA Client] Status: {}", status);
        println!("[IMA Client] Body: {}", body_str);

        crate::update_http_log_response(&log_id, status.as_u16(), &body_str);

        if !status.is_success() {
            println!("[IMA Client] HTTP error response status: {}", status);
            let err_msg = format!("IMA API returned HTTP error: {} - {}", status, body_str);
            crate::update_http_log_error(&log_id, &err_msg);
            return Err(err_msg);
        }

        let parsed: IMAResponse<T> = serde_json::from_str(&body_str)
            .map_err(|e| {
                let err_msg = format!("Serialization failed: {:?}. Raw response: {}", e, body_str);
                println!("[IMA Client] Deserialization error: {}", err_msg);
                crate::update_http_log_error(&log_id, &err_msg);
                err_msg
            })?;

        println!("[IMA Client] Successfully parsed response with code: {}", parsed.code);

        if parsed.code == 600001 {
            println!("[IMA Client] Token expired (code 600001). Attempting silent refresh...");
            if let Some(app) = crate::APP_HANDLE.get() {
                match crate::refresh_ima_credentials_silently(app).await {
                    Ok(new_creds) => {
                        println!("[IMA Client] Silent refresh succeeded. Retrying request with new credentials...");
                        
                        let url = format!("{}/{}", self.base_url, path);
                        let headers = self.build_headers(&new_creds);
                        
                        let retry_log_id = crate::generate_log_id();
                        let retry_timestamp = chrono::Local::now().format("%Y-%m-%d %H:%M:%S").to_string();
                        let retry_headers_str = headers.iter().map(|(key, val)| {
                            format!("{}: {:?}", key, val)
                        }).collect::<Vec<String>>().join("\n");
                        let retry_req_body_str = serde_json::to_string_pretty(&body).unwrap_or_else(|_| body.to_string());

                        crate::add_http_log(crate::HttpLogEntry {
                            id: retry_log_id.clone(),
                            timestamp: retry_timestamp,
                            method: "POST".to_string(),
                            url: url.clone(),
                            request_headers: Some(retry_headers_str),
                            request_body: Some(retry_req_body_str),
                            response_code: None,
                            response_body: None,
                            error: None,
                        });

                        let res = self.client.post(&url)
                            .headers(headers)
                            .json(&body)
                            .send()
                            .await
                            .map_err(|e| {
                                let err_msg = format!("HTTP retry request error: {:?}", e);
                                crate::update_http_log_error(&retry_log_id, &err_msg);
                                err_msg
                            })?;

                        let status = res.status();
                        let body_str = res.text().await.map_err(|e| {
                            let err_msg = format!("Failed to read retry body: {:?}", e);
                            crate::update_http_log_error(&retry_log_id, &err_msg);
                            err_msg
                        })?;

                        crate::update_http_log_response(&retry_log_id, status.as_u16(), &body_str);

                        if !status.is_success() {
                            let err_msg = format!("IMA API retry returned HTTP error: {} - {}", status, body_str);
                            crate::update_http_log_error(&retry_log_id, &err_msg);
                            return Err(err_msg);
                        }

                        let parsed_retry: IMAResponse<T> = serde_json::from_str(&body_str)
                            .map_err(|e| {
                                let err_msg = format!("Serialization failed on retry: {:?}. Raw response: {}", e, body_str);
                                crate::update_http_log_error(&retry_log_id, &err_msg);
                                err_msg
                            })?;

                        println!("[IMA Client] Successfully parsed retry response with code: {}", parsed_retry.code);
                        return Ok(parsed_retry);
                    }
                    Err(e) => {
                        println!("[IMA Client] Silent refresh failed: {}. Returning original 600001 response.", e);
                    }
                }
            } else {
                println!("[IMA Client] APP_HANDLE not set. Cannot perform silent refresh.");
            }
        }

        Ok(parsed)
    }    #[allow(dead_code)]
    pub async fn validate_credentials(&self, creds: &CachedCredentials) -> bool {
        let res: Result<IMAResponse<H5UserInfoDetail>, String> = self.post_json("cgi-bin/user_info/get_user_info", serde_json::json!({}), creds).await;
        match res {
            Ok(response) => response.code == 0,
            Err(_) => false,
        }
    }

    pub async fn get_knowledge_bases(&self, creds: &CachedCredentials) -> Result<Vec<KnowledgeBase>, String> {
        let body = serde_json::json!({
            "params": [
                {"type": 1001, "cursor": "", "limit": 20},
                {"type": 1002, "cursor": "", "limit": 20},
                {"type": 1004, "cursor": "", "limit": 20},
                {"type": 1005, "cursor": "", "limit": 50}
            ]
        });

        let response: IMAResponse<H5KnowledgeBaseListResponse> = self.post_json("cgi-bin/knowledge_tab_reader/get_knowledge_base_list", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        let mut list = Vec::new();
        if let Some(data) = response.data {
            for result in data.results {
                for mut kb in result.knowledge_base_list {
                    kb.id = Some(kb.kb_id.clone());
                    list.push(kb);
                }
            }
        }
        Ok(list)
    }

    pub async fn get_user_profile(&self, creds: &CachedCredentials) -> Result<(String, String), String> {
        let response: IMAResponse<H5UserInfoDetail> = self.post_json("cgi-bin/user_info/get_user_info", serde_json::json!({}), creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        if let Some(data) = response.data {
            Ok((data.open_info.avatar_url, data.open_info.nickname))
        } else {
            Err("No openInfo found in response data".to_string())
        }
    }

    pub async fn get_space_quota(&self, creds: &CachedCredentials) -> Result<SpaceQuota, String> {
        let body = serde_json::json!({
            "condition": {
                "need_knowledge": true,
                "need_note": true,
                "need_total": true,
                "need_share": true
            }
        });

        let response: IMAResponse<H5SpaceQuotaResponse> = self.post_json("cgi-bin/space/get_user_space", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        if let Some(data) = response.data {
            if let Some(space) = data.total_user_space {
                let total = space.total_space.parse::<i64>().unwrap_or(0);
                let used = space.used_space.parse::<i64>().unwrap_or(0);
                return Ok(SpaceQuota {
                    total_quota: total,
                    used_quota: used,
                });
            }
        }

        Ok(SpaceQuota {
            total_quota: 0,
            used_quota: 0,
        })
    }

    pub async fn get_knowledge_list(&self, kb_id: &str, folder_id: Option<&str>, cursor: &str, creds: &CachedCredentials) -> Result<KnowledgeListPayload, String> {
        let mut body = serde_json::json!({
            "sort_type": 9,
            "need_default_cover": true,
            "knowledge_base_id": kb_id,
            "cursor": cursor,
            "limit": 50,
            "ext_info": {}
        });

        if let Some(fid) = folder_id {
            if !fid.is_empty() {
                body.as_object_mut().unwrap().insert("folder_id".to_string(), serde_json::Value::String(fid.to_string()));
            }
        }

        let response: IMAResponse<KnowledgeListPayload> = self.post_json("cgi-bin/knowledge_tab_reader/get_knowledge_list", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        response.data.ok_or_else(|| "No knowledge base list data returned".to_string())
    }

    pub async fn get_media_info(&self, media_id: &str, kb_id: &str, creds: &CachedCredentials) -> Result<MediaInfoPayload, String> {
        // Attempt H5 web endpoint first
        let h5_body = serde_json::json!({
            "media_id": media_id,
            "knowledge_base_id": kb_id,
            "need_default_cover": true
        });

        let h5_res: Result<IMAResponse<H5GetKnowledgeResponse>, String> = self.post_json("cgi-bin/knowledge_tab_reader/get_knowledge", h5_body, creds).await;
        if let Ok(resp) = h5_res {
            if resp.code == 0 {
                if let Some(data) = resp.data {
                    let info = data.knowledge.media_info;
                    if info.has_usable_content() {
                        return Ok(info);
                    }
                }
            }
        }

        // Fallback to OpenAPI
        let open_body = serde_json::json!({
            "media_id": media_id
        });

        let open_res: IMAResponse<MediaInfoPayload> = self.post_json("openapi/wiki/v1/get_media_info", open_body, creds).await?;
        if open_res.code != 0 {
            return Err(format!("OpenAPI Error ({}): {:?}", open_res.code, open_res.msg));
        }

        open_res.data.ok_or_else(|| "Failed to get media info from both H5 and OpenAPI".to_string())
    }

    pub async fn get_note_content(&self, note_id: &str, creds: &CachedCredentials) -> Result<String, String> {
        // Attempt openapi
        let open_body = serde_json::json!({
            "note_id": note_id,
            "target_content_format": 0
        });

        let open_res: Result<IMAResponse<NoteContentPayload>, String> = self.post_json("openapi/note/v1/get_doc_content", open_body, creds).await;
        if let Ok(resp) = open_res {
            if resp.code == 0 {
                if let Some(data) = resp.data {
                    if let Some(content) = data.content {
                        if !content.is_empty() {
                            return Ok(content);
                        }
                    }
                }
            }
        }

        // Fallback to H5
        let h5_body = serde_json::json!({
            "docid": note_id,
            "op": {
                "op_basic": true,
                "op_content": true,
                "op_resource": true,
                "op_attach": true,
                "disable_cover": false,
                "op_attach_detail": true
            }
        });

        for path in &["cgi-bin/notebook_logic_get_doc", "cgi-bin/notebook_logic/get_doc"] {
            let h5_res: Result<IMAResponse<NoteContentPayload>, String> = self.post_json(path, h5_body.clone(), creds).await;
            if let Ok(resp) = h5_res {
                if resp.code == 0 {
                    if let Some(data) = resp.data {
                        if let Some(content) = data.content {
                            if !content.is_empty() {
                                return Ok(content);
                            }
                        }
                    }
                }
            }
        }

        Err("未能读取 IMA 笔记正文".to_string())
    }

    pub async fn download_file(&self, media_id: &str, kb_id: &str, destination: &Path, creds: &CachedCredentials) -> Result<(), String> {
        let info = self.get_media_info(media_id, kb_id, creds).await?;

        if info.media_type == 11 {
            // Note type: get note markdown content and write
            let note_id = info.notebook_ext_info.as_ref()
                .and_then(|nei| nei.notebook_id.as_ref())
                .cloned()
                .unwrap_or_else(|| media_id.to_string());
                
            let content = self.get_note_content(&note_id, creds).await?;
            if let Some(parent) = destination.parent() {
                std::fs::create_dir_all(parent).map_err(|e| format!("Failed to create folder: {:?}", e))?;
            }
            std::fs::write(destination, content).map_err(|e| format!("Failed to write note: {:?}", e))?;
            return Ok(());
        }

        let url_info = info.url_info.ok_or_else(|| format!("This media type is not supported for export (media_type = {})", info.media_type))?;
        if url_info.url.is_empty() {
            return Err("Empty download URL received from cloud".to_string());
        }

        // Build GET request
        let mut request = self.client.get(&url_info.url);
        if let Some(headers) = url_info.headers {
            for (key, val) in headers {
                request = request.header(key, val);
            }
        }

        let resp = request.send().await.map_err(|e| format!("Download HTTP error: {:?}", e))?;
        if !resp.status().is_success() {
            return Err(format!("Download failed with status: {}", resp.status()));
        }

        let bytes = resp.bytes().await.map_err(|e| format!("Failed to read response bytes: {:?}", e))?;
        if let Some(parent) = destination.parent() {
            std::fs::create_dir_all(parent).map_err(|e| format!("Failed to create folder: {:?}", e))?;
        }
        std::fs::write(destination, bytes).map_err(|e| format!("Failed to write file: {:?}", e))?;

        Ok(())
    }

    pub async fn create_folder(&self, title: &str, kb_id: &str, parent_folder_id: Option<&str>, creds: &CachedCredentials) -> Result<String, String> {
        let actual_folder_id = parent_folder_id.unwrap_or(kb_id);

        let body = serde_json::json!({
            "knowledge_base_id": kb_id,
            "folder_id": actual_folder_id,
            "title": title
        });

        let response: IMAResponse<IMACreateFolderResponse> = self.post_json("cgi-bin/knowledge_tab_writer/create_folder", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        let data = response.data.ok_or_else(|| "No folder response data returned".to_string())?;
        Ok(data.knowledge.media_id)
    }

    pub async fn rename_knowledge(&self, media_id: &str, title: &str, kb_id: &str, folder_id: Option<&str>, creds: &CachedCredentials) -> Result<(), String> {
        let actual_folder_id = folder_id.unwrap_or(kb_id);

        let body = serde_json::json!({
            "media_id": media_id,
            "knowledge_base_id": kb_id,
            "folder_id": actual_folder_id,
            "title": title
        });

        let response: IMAResponse<EmptyPayload> = self.post_json("cgi-bin/knowledge_tab_writer/rename_knowledge", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        Ok(())
    }

    pub async fn delete_knowledge_by_web_api(&self, media_ids: &[String], kb_id: &str, creds: &CachedCredentials) -> Result<(), String> {
        let body = serde_json::json!({
            "knowledge_base_id": kb_id,
            "media_ids": media_ids
        });

        let response: IMAResponse<DeleteKnowledgeWebResponse> = self.post_json("cgi-bin/knowledge_tab_writer/del_knowledge", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        if let Some(data) = response.data {
            let mut failed = Vec::new();
            for media_id in media_ids {
                if let Some(res) = data.results.get(media_id) {
                    if res.ret_code != 0 {
                        failed.push(format!("{}(ret_code={})", media_id, res.ret_code));
                    }
                }
            }
            if !failed.is_empty() {
                return Err(format!("Failed to delete some items: {}", failed.join(", ")));
            }
        }

        Ok(())
    }

    pub async fn check_repeated_names(&self, name: &str, media_type: i32, kb_id: &str, folder_id: Option<&str>, creds: &CachedCredentials) -> Result<bool, String> {
        let inner_param = serde_json::json!({
            "name": name,
            "media_type": media_type
        });

        let mut body = serde_json::json!({
            "params": [inner_param],
            "knowledge_base_id": kb_id
        });

        if let Some(fid) = folder_id {
            if !fid.is_empty() {
                body.as_object_mut().unwrap().insert("folder_id".to_string(), serde_json::Value::String(fid.to_string()));
            }
        }

        let response: IMAResponse<CheckRepeatedNamesPayload> = self.post_json("cgi-bin/knowledge_tab_reader/check_repeated_names", body, creds).await?;
        if response.code != 0 {
            return Err(format!("API Error ({}): {:?}", response.code, response.msg));
        }

        if let Some(data) = response.data {
            for result in data.results {
                if result.name == name && result.is_repeated {
                    return Ok(true);
                }
            }
        }

        Ok(false)
    }

    pub async fn fetch_all_knowledge_items(&self, kb_id: &str, folder_id: Option<&str>, creds: &CachedCredentials) -> Result<Vec<KnowledgeInfo>, String> {
        if folder_id.is_none() {
            let default_root = self.fetch_knowledge_items_page_by_page(kb_id, None, creds).await?;
            // Merge with explicit root if successful
            match self.fetch_knowledge_items_page_by_page(kb_id, Some(kb_id), creds).await {
                Ok(explicit_root) => {
                    let mut merged = default_root;
                    for item in explicit_root {
                        if !merged.iter().any(|x| x.media_id == item.media_id) {
                            merged.push(item);
                        }
                    }
                    Ok(merged)
                }
                Err(_) => Ok(default_root)
            }
        } else {
            self.fetch_knowledge_items_page_by_page(kb_id, folder_id, creds).await
        }
    }

    async fn fetch_knowledge_items_page_by_page(&self, kb_id: &str, folder_id: Option<&str>, creds: &CachedCredentials) -> Result<Vec<KnowledgeInfo>, String> {
        let mut all_items = Vec::new();
        let mut cursor = String::new();

        loop {
            let page = self.get_knowledge_list(kb_id, folder_id, &cursor, creds).await?;
            all_items.extend(page.knowledge_list);

            if page.is_end || page.next_cursor.is_empty() {
                break;
            }
            cursor = page.next_cursor;
        }

        Ok(all_items)
    }

    pub async fn upload_to_wiki(
        &self,
        file_path: &Path,
        kb_id: &str,
        folder_id: Option<&str>,
        existing_remote_id: Option<&str>,
        creds: &CachedCredentials,
    ) -> Result<String, String> {
        let original_file_name = file_path.file_name()
            .ok_or_else(|| "Invalid file path".to_string())?
            .to_string_lossy()
            .to_string();

        let file_data = std::fs::read(file_path)
            .map_err(|e| format!("Failed to read file contents: {:?}", e))?;

        let file_size = file_data.len();
        if file_size == 0 {
            return Err("Empty local file is not allowed for upload".to_string());
        }

        let file_ext = file_path.extension()
            .map(|e| e.to_string_lossy().to_string().to_lowercase())
            .unwrap_or_default();

        let (media_type, content_type) = IMAMediaType::resolve(&file_ext)
            .ok_or_else(|| format!("Unsupported file extension: .{}", file_ext))?;

        // 1. Check Repeated Names
        let is_repeated = self.check_repeated_names(&original_file_name, media_type, kb_id, folder_id, creds).await?;
        let mut upload_file_name = original_file_name.clone();

        if is_repeated {
            // Check strategy: if existing_remote_id is provided or we can find it, delete it. Otherwise generate a timestamped filename
            let mut resolved_id = existing_remote_id.unwrap_or("").to_string();
            if resolved_id.is_empty() {
                // Try to find it by display name
                let items = self.fetch_all_knowledge_items(kb_id, folder_id, creds).await?;
                if let Some(found) = items.iter().find(|item| !item.is_folder() && item.display_name() == original_file_name) {
                    resolved_id = found.media_id.clone();
                }
            }

            if !resolved_id.is_empty() {
                // Delete old file
                let _ = self.delete_knowledge_by_web_api(&[resolved_id], kb_id, creds).await;
            } else {
                // Auto rename with timestamp
                let stem = file_path.file_stem().map(|s| s.to_string_lossy().to_string()).unwrap_or_else(|| "file".to_string());
                let timestamp = chrono::Local::now().format("%Y%m%d%H%M%S").to_string();
                upload_file_name = if file_ext.is_empty() {
                    format!("{}_{}", stem, timestamp)
                } else {
                    format!("{}_{}.{}", stem, timestamp, file_ext)
                };
            }
        }

        // 2. Create Media
        let create_body = serde_json::json!({
            "file_name": upload_file_name,
            "file_size": file_size,
            "content_type": content_type,
            "media_type": media_type,
            "knowledge_base_id": kb_id
        });

        let create_res: IMAResponse<CreateMediaPayload> = self.post_json("cgi-bin/file_manager/create_media", create_body, creds).await?;
        if create_res.code != 0 {
            return Err(format!("Create Media Error ({}): {:?}", create_res.code, create_res.msg));
        }

        let payload = create_res.data.ok_or_else(|| "No create media payload returned".to_string())?;

        // 3. Upload to COS
        self.upload_to_cos(&file_data, &upload_file_name, &payload, &content_type, file_size).await?;

        // Short cooldown to ensure cloud metadata persistence completes
        tokio::time::sleep(std::time::Duration::from_millis(800)).await;

        // 4. Add Knowledge to Wiki
        let mut add_body = serde_json::json!({
            "media_type": media_type,
            "media_id": payload.media_id,
            "title": upload_file_name,
            "knowledge_base_id": kb_id,
            "need_parse": true,
            "file_info": {
                "cos_key": payload.cos_credential.cos_key,
                "file_size": file_size,
                "file_name": upload_file_name,
                "content_type": ""
            }
        });

        if let Some(fid) = folder_id {
            if !fid.is_empty() {
                add_body.as_object_mut().unwrap().insert("folder_id".to_string(), serde_json::Value::String(fid.to_string()));
            }
        }

        let add_res: IMAResponse<EmptyPayload> = self.post_json("cgi-bin/knowledge_tab_writer/add_knowledge", add_body, creds).await?;
        if add_res.code != 0 {
            return Err(format!("Add Knowledge Error ({}): {:?}", add_res.code, add_res.msg));
        }

        Ok(payload.media_id)
    }

    async fn upload_to_cos(&self, file_data: &[u8], _file_name: &str, payload: &CreateMediaPayload, content_type: &str, file_size: usize) -> Result<(), String> {
        let cos = &payload.cos_credential;
        let hostname = format!("{}.cos.{}.myqcloud.com", cos.bucket_name, cos.region);
        let url = format!("https://{}/{}", hostname, cos.cos_key);

        let mut headers = HashMap::new();
        headers.insert("host".to_string(), hostname.clone());
        headers.insert("content-length".to_string(), file_size.to_string());

        let start_time = cos.start_time.parse::<i64>().unwrap_or_else(|_| chrono::Utc::now().timestamp());
        let expired_time = cos.expired_time.parse::<i64>().unwrap_or_else(|_| start_time + 3600);

        let signature = COSSigner::sign(
            "PUT",
            &format!("/{}", cos.cos_key),
            &cos.secret_id,
            &cos.secret_key,
            start_time,
            expired_time,
            &headers,
        );

        let res = self.client.put(&url)
            .header("Content-Type", content_type)
            .header("Content-Length", file_size)
            .header("x-cos-security-token", &cos.token)
            .header("Host", &hostname)
            .header("Authorization", &signature)
            .body(file_data.to_vec())
            .send()
            .await
            .map_err(|e| format!("COS PUT connection error: {:?}", e))?;

        if !res.status().is_success() {
            let status = res.status();
            let err_body = res.text().await.unwrap_or_default();
            return Err(format!("COS upload failed with HTTP status {}: {}", status, err_body));
        }

        Ok(())
    }

    pub async fn resolve_folder_id_if_needed(&self, kb_id: &str, relative_path: &str, creds: &CachedCredentials) -> Result<Option<String>, String> {
        if relative_path.trim().is_empty() {
            return Ok(None);
        }

        let segments: Vec<&str> = relative_path.split('/')
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();

        if segments.is_empty() {
            return Ok(None);
        }

        let mut parent_id: Option<String> = None;

        for segment in segments {
            let children = self.fetch_all_knowledge_items(kb_id, parent_id.as_deref(), creds).await?;
            if let Some(folder) = children.iter().find(|item| item.is_folder() && item.display_name() == segment) {
                parent_id = folder.folder_identifier();
                continue;
            }

            // Create folder automatically
            let new_folder_id = self.create_folder(segment, kb_id, parent_id.as_deref(), creds).await?;
            parent_id = Some(new_folder_id);
        }

        Ok(parent_id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::credentials;

    #[tokio::test]
    async fn test_fetch_kb() {
        if let Some(creds) = credentials::load_credentials() {
            println!("Testing with creds: {:?}", creds);
            let client = IMASyncClient::new();
            
            // 1. Check get_user_info
            let user_res = client.post_json::<serde_json::Value>(
                "cgi-bin/user_info/get_user_info",
                serde_json::json!({}),
                &creds,
            ).await;
            
            match user_res {
                Ok(val) => {
                    println!("SUCCESS User Info Response: {}", serde_json::to_string_pretty(&val).unwrap());
                }
                Err(e) => {
                    println!("ERROR User Info: {}", e);
                }
            }

            // 2. Check get_knowledge_base_list
            let body = serde_json::json!({
                "params": [
                    {"type": 1001, "cursor": "", "limit": 20},
                    {"type": 1002, "cursor": "", "limit": 20},
                    {"type": 1004, "cursor": "", "limit": 20},
                    {"type": 1005, "cursor": "", "limit": 50}
                ]
            });
            
            let res = client.post_json::<serde_json::Value>(
                "cgi-bin/knowledge_tab_reader/get_knowledge_base_list",
                body,
                &creds,
            ).await;
            
            match res {
                Ok(val) => {
                    println!("SUCCESS KB List Response: {}", serde_json::to_string_pretty(&val).unwrap());
                }
                Err(e) => {
                    println!("ERROR KB List: {}", e);
                }
            }
        } else {
            println!("No credentials found, skip test_fetch_kb");
        }
    }
}
