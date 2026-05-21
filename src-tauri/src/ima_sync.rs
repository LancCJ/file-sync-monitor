use reqwest::header::{HeaderMap, HeaderValue};
use serde::{Serialize, Deserialize, de::DeserializeOwned};
use std::path::Path;
use tokio::fs::File;
use tokio_util::codec::{BytesCodec, FramedRead};

use crate::credentials::{self, CachedCredentials};

#[derive(Debug, Serialize, Deserialize)]
pub struct IMAResponse<T> {
    pub code: i32,
    pub msg: Option<String>,
    pub data: Option<T>,
    #[serde(rename = "requestId")]
    pub request_id: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct KnowledgeBase {
    #[serde(rename = "knowledgeBaseId")]
    pub kb_id: String,
    pub name: String,
    pub description: Option<String>,
    pub count: Option<i32>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct KBListResult {
    #[serde(rename = "knowledgeBaseList")]
    pub knowledge_base_list: Vec<KnowledgeBase>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5KnowledgeBaseListResponse {
    pub results: Vec<KBListResult>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5OpenInfo {
    #[serde(rename = "avatarUrl")]
    pub avatar_url: String,
    pub nickname: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct H5UserInfoDetail {
    #[serde(rename = "openInfo")]
    pub open_info: H5OpenInfo,
}

pub struct IMASyncClient {
    client: reqwest::Client,
    base_url: String,
}

impl IMASyncClient {
    pub fn new() -> Self {
        Self {
            client: reqwest::Client::builder()
                .timeout(std::time::Duration::from_secs(15))
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

        let res = self.client.post(&url)
            .headers(headers)
            .json(&body)
            .send()
            .await
            .map_err(|e| format!("HTTP request error: {:?}", e))?;

        let status = res.status();
        let body_str = res.text().await.map_err(|e| format!("Failed to read body: {:?}", e))?;

        if !status.is_success() {
            return Err(format!("IMA API returned HTTP error: {} - {}", status, body_str));
        }

        let parsed: IMAResponse<T> = serde_json::from_str(&body_str)
            .map_err(|e| format!("Serialization failed: {:?}. Raw response: {}", e, body_str))?;

        Ok(parsed)
    }

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
                list.extend(result.knowledge_base_list);
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
}
