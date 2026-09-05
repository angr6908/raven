use serde::Deserialize;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Duration;

use crate::translate::ids::now_unix_secs;

use super::auth::{stable_project_id, Auth};

pub const CLIENT_ID: &str =
    "1071006060591-tmhssin2h21lcre235vtolojh4g403ep.apps.googleusercontent.com";
pub const CLIENT_SECRET: &str = "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";
pub const AUTH_URL: &str = "https://accounts.google.com/o/oauth2/v2/auth";
pub const TOKEN_URL: &str = "https://oauth2.googleapis.com/token";
pub const REDIRECT_URI: &str = "http://localhost:51121/oauth-callback";
pub const CALLBACK_PORT: u16 = 51121;

pub const SCOPES: &[&str] = &[
    "https://www.googleapis.com/auth/aicode",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/userinfo.profile",
    "https://www.googleapis.com/auth/cclog",
    "https://www.googleapis.com/auth/experimentsandconfigs",
];

pub const BASE_URL_ENV: &str = "ANTIGRAVITY_BASE_URL";
pub const USER_AGENT_ENV: &str = "ANTIGRAVITY_USER_AGENT";
pub const PROJECT_ID_ENV: &str = "ANTIGRAVITY_PROJECT_ID";

const ENDPOINTS: &[&str] = &[
    "https://daily-cloudcode-pa.googleapis.com",
    "https://daily-cloudcode-pa.sandbox.googleapis.com",
    "https://cloudcode-pa.googleapis.com",
];

const DEFAULT_USER_AGENT: &str =
    "antigravity/cli/1.1.23 (aidev_client; os_type=linux; arch=amd64; cl=974125021; auth_method=consumer)";

const DISCOVERY_TIMEOUT: Duration = Duration::from_secs(15);
const STREAM_HEADER_TIMEOUT: Duration = Duration::from_secs(120);
const EXPIRY_SKEW: i64 = 5 * 60;

#[derive(Debug, Deserialize)]
struct TokenResponse {
    #[serde(default)]
    access_token: String,
    #[serde(default)]
    refresh_token: String,
    #[serde(default)]
    expires_in: i64,
}

pub struct Refreshed {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
}

#[derive(Clone)]
pub struct Client {
    http: reqwest::Client,
    user_agent: String,
}

impl Client {
    pub fn new() -> Self {
        let http = tls_client().unwrap_or_else(|err| {
            eprintln!("antigravity: falling back to the shared TLS stack ({err})");
            reqwest::Client::builder()
                .connect_timeout(Duration::from_secs(30))
                .pool_idle_timeout(Duration::from_secs(300))
                .pool_max_idle_per_host(8)
                .build()
                .expect("default http client")
        });
        Self {
            http,
            user_agent: std::env::var(USER_AGENT_ENV)
                .unwrap_or_else(|_| DEFAULT_USER_AGENT.to_string()),
        }
    }

    pub fn endpoints(&self) -> Vec<String> {
        match std::env::var(BASE_URL_ENV) {
            Ok(base) if !base.trim().is_empty() => {
                vec![base.trim().trim_end_matches('/').to_string()]
            }
            _ => ENDPOINTS.iter().map(|url| url.to_string()).collect(),
        }
    }

    fn authorized(&self, url: &str, token: &str) -> reqwest::RequestBuilder {
        self.http
            .post(url)
            .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
            .header(reqwest::header::CONTENT_TYPE, "application/json")
            .header(reqwest::header::USER_AGENT, &self.user_agent)
    }

    pub async fn refresh(&self, refresh_token: &str) -> Result<Refreshed, String> {
        if refresh_token.is_empty() {
            return Err("no refresh token stored; sign in again".to_string());
        }
        let response = self
            .http
            .post(TOKEN_URL)
            .form(&[
                ("client_id", CLIENT_ID),
                ("client_secret", CLIENT_SECRET),
                ("refresh_token", refresh_token),
                ("grant_type", "refresh_token"),
            ])
            .send()
            .await
            .map_err(|err| format!("refresh token: {err}"))?;
        let token = read_token(response, "refresh token").await?;
        Ok(Refreshed {
            access_token: token.access_token,
            refresh_token: match token.refresh_token.is_empty() {
                true => refresh_token.to_string(),
                false => token.refresh_token,
            },
            expires_at: expires_at(token.expires_in),
        })
    }

    pub async fn exchange_code(&self, code: &str, verifier: &str) -> Result<Refreshed, String> {
        let response = self
            .http
            .post(TOKEN_URL)
            .form(&[
                ("client_id", CLIENT_ID),
                ("client_secret", CLIENT_SECRET),
                ("code", code),
                ("grant_type", "authorization_code"),
                ("redirect_uri", REDIRECT_URI),
                ("code_verifier", verifier),
            ])
            .send()
            .await
            .map_err(|err| format!("exchange code: {err}"))?;
        let token = read_token(response, "exchange code").await?;
        if token.refresh_token.is_empty() {
            return Err("google returned no refresh token; sign in again and allow offline access"
                .to_string());
        }
        Ok(Refreshed {
            access_token: token.access_token,
            refresh_token: token.refresh_token,
            expires_at: expires_at(token.expires_in),
        })
    }

    pub async fn user_email(&self, token: &str) -> Option<String> {
        let response = self
            .http
            .get("https://www.googleapis.com/oauth2/v1/userinfo?alt=json")
            .header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"))
            .timeout(DISCOVERY_TIMEOUT)
            .send()
            .await
            .ok()?;
        if !response.status().is_success() {
            return None;
        }
        response
            .json::<Value>()
            .await
            .ok()?
            .get("email")
            .and_then(Value::as_str)
            .map(str::to_string)
    }

    pub async fn load_code_assist(&self, token: &str) -> Option<String> {
        let body = json!({"metadata": {
            "ideType": "ANTIGRAVITY",
            "platform": "PLATFORM_UNSPECIFIED",
            "pluginType": "GEMINI",
        }});
        for endpoint in self.endpoints() {
            let Ok(payload) = self
                .rpc(&endpoint, "loadCodeAssist", token, &body)
                .await
            else {
                continue;
            };
            if let Some(project) = extract_project_id(&payload) {
                return Some(project);
            }
            if let Ok(listed) = self
                .rpc(&endpoint, "listCloudAICompanionProjects", token, &json!({}))
                .await
            {
                if let Some(project) = extract_project_id(&listed) {
                    return Some(project);
                }
            }
        }
        None
    }

    pub async fn tier(&self, token: &str) -> Option<Value> {
        let body = json!({"metadata": {"ideType": "ANTIGRAVITY"}});
        for endpoint in self.endpoints() {
            if let Ok(payload) = self.rpc(&endpoint, "loadCodeAssist", token, &body).await {
                return Some(payload);
            }
        }
        None
    }

    pub async fn quota_summary(&self, token: &str) -> Result<Value, String> {
        let mut last = "no endpoint available".to_string();
        for endpoint in self.endpoints() {
            match self
                .rpc(&endpoint, "retrieveUserQuotaSummary", token, &json!({}))
                .await
            {
                Ok(payload) => return Ok(payload),
                Err(err) => last = err,
            }
        }
        Err(last)
    }

    pub async fn available_models(&self, token: &str, project: &str) -> Result<Value, String> {
        let body = json!({"project": project});
        let mut merged = serde_json::Map::new();
        let mut last = "no endpoint available".to_string();
        for endpoint in self.endpoints() {
            match self
                .rpc(&endpoint, "fetchAvailableModels", token, &body)
                .await
            {
                Ok(payload) => {
                    if let Some(models) = payload.get("models").and_then(Value::as_object) {
                        for (id, info) in models {
                            merged.insert(id.clone(), info.clone());
                        }
                    }
                }
                Err(err) => last = err,
            }
        }
        match merged.is_empty() {
            true => Err(last),
            false => Ok(Value::Object(merged)),
        }
    }

    async fn rpc(
        &self,
        endpoint: &str,
        method: &str,
        token: &str,
        body: &Value,
    ) -> Result<Value, String> {
        let url = format!("{endpoint}/v1internal:{method}");
        let response = self
            .authorized(&url, token)
            .header(reqwest::header::ACCEPT, "application/json")
            .timeout(DISCOVERY_TIMEOUT)
            .json(body)
            .send()
            .await
            .map_err(|err| format!("{method}: {err}"))?;
        let status = response.status();
        let text = response.text().await.unwrap_or_default();
        if !status.is_success() {
            return Err(format!("{method}: status {status}: {}", error_text(&text)));
        }
        serde_json::from_str(&text).map_err(|err| format!("{method}: decode: {err}"))
    }

    pub async fn stream_generate_content(
        &self,
        endpoint: &str,
        token: &str,
        payload: Vec<u8>,
    ) -> Result<reqwest::Response, String> {
        let url = format!("{endpoint}/v1internal:streamGenerateContent?alt=sse");
        let request = self
            .authorized(&url, token)
            .header(reqwest::header::ACCEPT, "text/event-stream")
            .body(payload)
            .send();
        match tokio::time::timeout(STREAM_HEADER_TIMEOUT, request).await {
            Ok(Ok(response)) => Ok(response),
            Ok(Err(err)) => Err(format!("call upstream: {err}")),
            Err(_) => Err("call upstream: response header timeout".to_string()),
        }
    }
}

impl Default for Client {
    fn default() -> Self {
        Self::new()
    }
}

fn tls_client() -> Result<reqwest::Client, String> {
    let mut roots = rustls::RootCertStore::empty();
    roots.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let mut config = rustls::ClientConfig::builder_with_provider(provider)
        .with_safe_default_protocol_versions()
        .map_err(|err| format!("tls protocol versions: {err}"))?
        .with_root_certificates(roots)
        .with_no_client_auth();
    config.alpn_protocols.clear();

    reqwest::Client::builder()
        .use_preconfigured_tls(config)
        .connect_timeout(Duration::from_secs(30))
        .pool_idle_timeout(Duration::from_secs(300))
        .pool_max_idle_per_host(8)
        .build()
        .map_err(|err| format!("build http client: {err}"))
}

async fn read_token(response: reqwest::Response, label: &str) -> Result<TokenResponse, String> {
    let status = response.status();
    let text = response.text().await.unwrap_or_default();
    if !status.is_success() {
        return Err(format!("{label}: status {status}: {}", error_text(&text)));
    }
    let token: TokenResponse =
        serde_json::from_str(&text).map_err(|err| format!("{label}: decode: {err}"))?;
    if token.access_token.is_empty() {
        return Err(format!("{label}: google returned no access token"));
    }
    Ok(token)
}

fn expires_at(expires_in: i64) -> i64 {
    match expires_in > 0 {
        true => now_unix_secs() + expires_in - EXPIRY_SKEW,
        false => 0,
    }
}

pub fn error_text(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Ok(payload) = serde_json::from_str::<Value>(trimmed) {
        for pointer in ["/error/message", "/error_description", "/error"] {
            if let Some(message) = payload
                .pointer(pointer)
                .and_then(Value::as_str)
                .filter(|message| !message.trim().is_empty())
            {
                return message.chars().take(500).collect();
            }
        }
    }
    trimmed.chars().take(500).collect()
}

pub fn extract_project_id(payload: &Value) -> Option<String> {
    let object = payload.as_object()?;
    for key in [
        "antigravityProjectId",
        "projectId",
        "backendProjectId",
        "userDefinedCloudaicompanionProject",
        "cloudaicompanionProject",
        "project",
    ] {
        let Some(value) = object.get(key) else {
            continue;
        };
        if let Some(found) = value.as_str().filter(|found| !found.is_empty()) {
            return Some(found.to_string());
        }
        if let Some(found) = value
            .get("id")
            .and_then(Value::as_str)
            .filter(|found| !found.is_empty())
        {
            return Some(found.to_string());
        }
    }
    for key in ["projects", "projectIds", "cloudaicompanionProjects"] {
        let Some(items) = object.get(key).and_then(Value::as_array) else {
            continue;
        };
        for item in items {
            if let Some(found) = extract_project_id(item) {
                return Some(found);
            }
            if let Some(found) = item.as_str().filter(|found| !found.is_empty()) {
                return Some(found.to_string());
            }
        }
    }
    None
}

pub fn project_for(auth: &Auth) -> String {
    if let Ok(configured) = std::env::var(PROJECT_ID_ENV) {
        let configured = configured.trim();
        if !configured.is_empty() {
            return configured.to_string();
        }
    }
    if !auth.project_id.is_empty() {
        return auth.project_id.clone();
    }
    let seed = match auth.email.is_empty() {
        true => "antigravity-default",
        false => auth.email.as_str(),
    };
    stable_project_id(seed)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_ids_are_read_from_every_advertised_shape() {
        assert_eq!(
            extract_project_id(&json!({"cloudaicompanionProject": "p-1"})).as_deref(),
            Some("p-1")
        );
        assert_eq!(
            extract_project_id(&json!({"project": {"id": "p-2"}})).as_deref(),
            Some("p-2")
        );
        assert_eq!(
            extract_project_id(&json!({"projects": [{"projectId": "p-3"}]})).as_deref(),
            Some("p-3")
        );
        assert_eq!(extract_project_id(&json!({"other": 1})), None);
    }

    #[test]
    fn upstream_errors_are_unwrapped_to_their_message() {
        assert_eq!(
            error_text(r#"{"error":{"message":"quota reached","code":429}}"#),
            "quota reached"
        );
        assert_eq!(
            error_text(r#"{"error":"invalid_grant","error_description":"expired"}"#),
            "expired"
        );
        assert_eq!(error_text("  plain text  "), "plain text");
    }

    #[test]
    fn the_project_falls_back_to_a_stable_id_per_account() {
        let auth = Auth {
            email: "a@example.com".into(),
            ..Auth::default()
        };
        assert_eq!(project_for(&auth), stable_project_id("a@example.com"));

        let pinned = Auth {
            project_id: "explicit".into(),
            ..auth
        };
        assert_eq!(project_for(&pinned), "explicit");
    }
}
