use std::fmt;
use std::sync::{Arc, Mutex};

use reqwest::Response;
use serde_json::Value;

use super::auth::Auth;
use super::headers;
use super::payload::prepare_body_opt;
use super::truncate;
use crate::translate::ids::now_unix_secs;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ErrKind {
    None,
    HardCredit,
    SoftRate,
    SessionDead,
    NotFound,
    Server,
    Client,
}

impl ErrKind {
    pub fn as_str(&self) -> &'static str {
        match self {
            ErrKind::None => "none",
            ErrKind::HardCredit => "hard_credit",
            ErrKind::SoftRate => "soft_rate",
            ErrKind::SessionDead => "session_dead",
            ErrKind::NotFound => "not_found",
            ErrKind::Server => "server",
            ErrKind::Client => "client",
        }
    }
}

const HARD_MARKERS: &[&str] = &[
    "insufficient credit",
    "no credit",
    "credit exhausted",
    "out of credit",
    "quota exceeded",
    "quota exhaust",
    "payment required",
    "credit not enough",
    "not enough credit",
    "积分不足",
    "额度不足",
    "余额不足",
    "积分用完",
    "额度用尽",
    "没有积分",
];

const SESSION_DEAD_MARKERS: &[&str] = &["Offline user session not found", "12153"];

pub fn classify(status: u16, body: &str) -> ErrKind {
    if status == 402 {
        return ErrKind::HardCredit;
    }
    let lower = body.to_ascii_lowercase();
    for marker in HARD_MARKERS {
        let marker_lower = marker.to_ascii_lowercase();
        if lower.contains(&marker_lower) || body.contains(marker) {
            return ErrKind::HardCredit;
        }
    }
    for marker in SESSION_DEAD_MARKERS {
        if body.contains(marker) {
            return ErrKind::SessionDead;
        }
    }
    if status == 429 {
        return ErrKind::SoftRate;
    }
    if status == 404 {
        return ErrKind::NotFound;
    }
    if status >= 500 {
        return ErrKind::Server;
    }
    if status >= 400 {
        return ErrKind::Client;
    }
    ErrKind::None
}

#[derive(Debug, Clone)]
pub struct Error {
    pub kind: ErrKind,
    pub status: u16,
    pub msg: String,
}

impl fmt::Display for Error {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "upstream {} (http {}): {}",
            self.kind.as_str(),
            self.status,
            self.msg
        )
    }
}

impl std::error::Error for Error {}

#[derive(serde::Deserialize)]
struct ApiEnvelope {
    code: i32,
    #[serde(default)]
    msg: String,
    #[serde(default)]
    data: serde_json::Value,
}

#[derive(Clone)]
pub struct Client {
    pub http: reqwest::Client,
    pub sanitize_fingerprints: bool,
}

impl Client {
    pub fn new(http: reqwest::Client) -> Self {
        Self {
            http,
            sanitize_fingerprints: true,
        }
    }

    fn chat_base(&self, a: &Auth) -> &'static str {
        if a.region() == "global" {
            "https://www.workbuddy.ai"
        } else {
            "https://copilot.tencent.com"
        }
    }

    fn billing_base(&self, a: &Auth) -> &'static str {
        if a.region() == "global" {
            "https://www.workbuddy.ai"
        } else {
            "https://www.codebuddy.cn"
        }
    }

    pub fn prepare_body(&self, body: &[u8]) -> Vec<u8> {
        prepare_body_opt(body, self.sanitize_fingerprints)
    }

    async fn do_json(&self, request: reqwest::RequestBuilder) -> Result<Value, Error> {
        let resp = request.send().await.map_err(|e| Error {
            kind: ErrKind::Server,
            status: 502,
            msg: format!("transport: {e}"),
        })?;
        let status = resp.status().as_u16();
        let raw = resp.bytes().await.unwrap_or_default();
        let raw_str = String::from_utf8_lossy(&raw).to_string();

        if status >= 400 {
            let kind = classify(status, &raw_str);
            return Err(Error {
                kind,
                status,
                msg: truncate(&raw_str, 200),
            });
        }

        let env: ApiEnvelope = match serde_json::from_slice(&raw) {
            Ok(e) => e,
            Err(e) => {
                return Err(Error {
                    kind: ErrKind::Client,
                    status,
                    msg: format!("parse failed: {e} (body: {})", truncate(&raw_str, 120)),
                })
            }
        };

        if env.code != 0 {
            let kind = classify(status, &env.msg);
            let kind = if kind == ErrKind::None {
                ErrKind::Client
            } else {
                kind
            };
            return Err(Error {
                kind,
                status,
                msg: format!("code={} msg={}", env.code, truncate(&env.msg, 160)),
            });
        }

        Ok(env.data)
    }

    pub async fn refresh_token(&self, a: &Arc<Mutex<Auth>>) -> Result<(), Error> {
        let url;
        let headers;
        {
            let guard = a.lock().unwrap();
            if guard.refresh_token.trim().is_empty() {
                return Err(Error {
                    kind: ErrKind::Client,
                    status: 0,
                    msg: "no refreshToken".to_string(),
                });
            }
            url = format!("{}/v2/plugin/auth/token/refresh", self.chat_base(&guard));
            headers = headers::refresh_headers(&guard);
        }

        let data = self.do_json(self.http.post(&url).headers(headers)).await?;

        let access_token = data
            .get("accessToken")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        if access_token.is_empty() {
            return Err(Error {
                kind: ErrKind::SessionDead,
                status: 401,
                msg: "refresh_failed: no accessToken in response — re-login required".to_string(),
            });
        }

        let new_refresh = data
            .get("refreshToken")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let domain = data
            .get("domain")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let expires_in = data.get("expiresIn").and_then(Value::as_i64).unwrap_or(0);

        {
            let mut guard = a.lock().unwrap();
            guard.access_token = access_token;
            if !new_refresh.is_empty() {
                guard.refresh_token = new_refresh;
            }
            if !domain.is_empty() {
                guard.domain = domain;
            }

            if expires_in > 0 {
                guard.expires_at = now_unix_secs() + expires_in;
            }
        }
        Ok(())
    }

    pub async fn chat_stream(
        &self,
        a: &Auth,
        prepared: &[u8],
    ) -> Result<Response, ChatStreamError> {
        let url = format!("{}/v2/chat/completions", self.chat_base(a));
        let headers = headers::chat_headers(a);

        let resp = match self
            .http
            .post(&url)
            .headers(headers)
            .body(prepared.to_vec())
            .send()
            .await
        {
            Ok(r) => r,
            Err(e) => {
                eprintln!("chat_stream uid={}: transport error: {e}", a.uid);
                return Err(ChatStreamError::Transport(e.to_string()));
            }
        };

        let status = resp.status().as_u16();
        if status >= 400 {
            let raw = resp.bytes().await.unwrap_or_default();
            let raw_str = String::from_utf8_lossy(&raw).to_string();
            let kind = classify(status, &raw_str);
            eprintln!(
                "chat_stream uid={}: upstream {} {} body={}",
                a.uid,
                status,
                kind.as_str(),
                truncate(&raw_str, 200)
            );
            return Err(ChatStreamError::Upstream {
                status,
                body: raw.to_vec(),
            });
        }

        Ok(resp)
    }

    pub async fn fetch_models(&self, a: &Auth) -> Result<Vec<ModelInfo>, String> {
        let url = format!("{}/console/enterprises/personal/models", self.chat_base(a));
        let headers = headers::models_headers(a);
        let resp = self
            .http
            .get(&url)
            .headers(headers)
            .send()
            .await
            .map_err(|e| format!("models fetch transport: {e}"))?;
        let status = resp.status().as_u16();
        let raw = resp.bytes().await.unwrap_or_default();
        let raw_str = String::from_utf8_lossy(&raw).to_string();

        if status != 200 {
            return Err(format!(
                "models api status {status}: {}",
                truncate(&raw_str, 120)
            ));
        }

        #[derive(serde::Deserialize)]
        struct ModelsResponse {
            code: i32,
            #[serde(default)]
            data: ModelsData,
        }
        #[derive(serde::Deserialize, Default)]
        struct ModelsData {
            #[serde(default)]
            models: Vec<ModelEntry>,
            #[serde(default)]
            agents: Vec<AgentEntry>,
        }
        #[derive(serde::Deserialize)]
        struct ModelEntry {
            id: String,
            #[serde(default)]
            name: String,
            #[serde(rename = "maxInputTokens", default)]
            max_input_tokens: i64,
            #[serde(rename = "maxOutputTokens", default)]
            max_output_tokens: i64,
            #[serde(default)]
            disabled: bool,
        }
        #[derive(serde::Deserialize)]
        struct AgentEntry {
            #[serde(default)]
            name: String,
            #[serde(default)]
            models: Vec<String>,
        }

        let parsed: ModelsResponse =
            serde_json::from_str(&raw_str).map_err(|e| format!("models parse: {e}"))?;
        if parsed.code != 0 {
            return Err(format!("models api code={}", parsed.code));
        }

        let cli_ids: Vec<String> = parsed
            .data
            .agents
            .iter()
            .find(|a| a.name == "cli")
            .map(|a| a.models.clone())
            .unwrap_or_default();
        if cli_ids.is_empty() {
            return Err("no cli agent models found".to_string());
        }

        let cli_id_set: std::collections::HashSet<String> = cli_ids.into_iter().collect();

        let mut out: Vec<ModelInfo> = Vec::new();
        for m in parsed.data.models {
            if m.disabled {
                continue;
            }
            if !cli_id_set.contains(&m.id) {
                continue;
            }
            out.push(ModelInfo {
                id: m.id,
                name: m.name,
                context_window: m.max_input_tokens,
                max_tokens: m.max_output_tokens,
            });
        }
        if out.is_empty() {
            return Err("models api returned empty list".to_string());
        }
        Ok(out)
    }

    pub async fn user_resource(&self, a: &Auth) -> Result<i64, String> {
        let url = format!(
            "{}/v2/billing/meter/get-user-resource",
            self.billing_base(a)
        );
        let now = now_unix_secs();

        let body = serde_json::json!({
            "PageNumber": 1,
            "PageSize": 100,
            "ProductCode": "p_tcaca",
            "Status": [0, 3],
            "PackageEndTimeRangeBegin": format_date_from_epoch(now, 0),
            "PackageEndTimeRangeEnd": format_date_from_epoch(now, 365 * 101),
        });

        let headers = headers::billing_headers(a);
        let rb = self
            .http
            .post(&url)
            .headers(headers)
            .body(serde_json::to_vec(&body).unwrap_or_default());

        let data = self.do_json(rb).await.map_err(|e| e.to_string())?;

        #[derive(serde::Deserialize, Default)]
        #[allow(non_snake_case)]
        struct ResourceResponse {
            #[serde(default)]
            Response: ResponseData,
        }
        #[derive(serde::Deserialize, Default)]
        #[allow(non_snake_case)]
        struct ResponseData {
            #[serde(default)]
            Data: ResponseInner,
        }
        #[derive(serde::Deserialize, Default)]
        #[allow(non_snake_case)]
        struct ResponseInner {
            #[serde(default)]
            Accounts: Vec<AccountEntry>,
        }
        #[derive(serde::Deserialize, Default)]
        #[allow(non_snake_case, dead_code)]
        struct AccountEntry {
            #[serde(default)]
            PackageName: String,
            #[serde(default)]
            CapacitySize: i64,
            #[serde(default)]
            CapacityRemain: i64,
            #[serde(default)]
            CapacityUsed: i64,
            #[serde(default)]
            CycleCapacitySize: i64,
            #[serde(default)]
            CycleCapacityRemain: i64,
            #[serde(default)]
            CycleCapacityUsed: i64,
        }

        let resp: ResourceResponse =
            serde_json::from_value(data).map_err(|e| format!("resource parse: {e}"))?;

        let mut remain: i64 = 0;
        for acct in resp.Response.Data.Accounts {
            let r = if acct.CycleCapacitySize > 0 {
                acct.CycleCapacityRemain
            } else if acct.CycleCapacityRemain > 0 || acct.CycleCapacityUsed > 0 {
                acct.CycleCapacityRemain
            } else {
                acct.CapacityRemain
            };
            remain += if r < 0 { 0 } else { r };
        }
        Ok(remain)
    }

    pub async fn daily_checkin(&self, a: &Auth) -> Result<(), String> {
        let url = format!("{}/v2/billing/meter/daily-checkin", self.billing_base(a));
        let headers = headers::billing_headers(a);
        let rb = self.http.post(&url).headers(headers).body("{}");
        self.do_json(rb).await.map_err(|e| e.to_string())?;
        Ok(())
    }
}

const LOGIN_BASE: &str = "https://copilot.tencent.com";

#[derive(Debug, Clone, Default)]
pub struct LoginToken {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_in: i64,
    pub domain: String,
}

#[derive(Debug, Clone, Default)]
pub struct LoginAccount {
    pub uid: String,
    pub enterprise_id: String,
    pub nickname: String,
}

pub enum LoginPoll {
    Complete(LoginToken),

    Pending,

    Retry(String),
}

pub fn new_login_client() -> reqwest::Client {
    reqwest::Client::builder()
        .cookie_store(true)
        .timeout(std::time::Duration::from_secs(30))
        .build()
        .unwrap_or_default()
}

async fn login_do_json(
    http: &reqwest::Client,
    method: reqwest::Method,
    url: &str,
    authorization: Option<&str>,
    body: Option<&str>,
) -> Result<Value, (bool, String)> {
    let mut req = http.request(method, url).headers(headers::login_headers());

    if let Some(body) = body {
        req = req.body(body.to_string());
    }
    if let Some(token) = authorization {
        req = req.header(reqwest::header::AUTHORIZATION, format!("Bearer {token}"));
    }
    let resp = req
        .send()
        .await
        .map_err(|e| (true, format!("transport: {e}")))?;
    let status = resp.status().as_u16();
    let raw = resp.bytes().await.unwrap_or_default();
    if status >= 500 {
        return Err((true, format!("upstream {status}")));
    }
    if status >= 300 {
        return Err((false, format!("http {status}")));
    }
    let env: ApiEnvelope = match serde_json::from_slice(&raw) {
        Ok(env) => env,
        Err(e) => return Err((false, format!("parse failed: {e}"))),
    };
    if env.code != 0 {
        return Err((
            false,
            format!("code={} msg={}", env.code, truncate(&env.msg, 160)),
        ));
    }
    Ok(env.data)
}

pub async fn login_auth_state(http: &reqwest::Client) -> Result<(String, String), String> {
    let url = format!("{LOGIN_BASE}/v2/plugin/auth/state?platform=CLI");
    let data = login_do_json(http, reqwest::Method::POST, &url, None, Some("{}"))
        .await
        .map_err(|(_, msg)| format!("auth state failed: {msg}"))?;
    let state = str_field(&data, "state");
    let auth_url = str_field(&data, "authUrl");
    if state.is_empty() || auth_url.is_empty() {
        return Err("auth state: missing state or authUrl".to_string());
    }
    Ok((state, auth_url))
}

pub async fn login_poll(http: &reqwest::Client, state: &str) -> LoginPoll {
    let url = format!("{LOGIN_BASE}/v2/plugin/auth/token?state={state}");
    let data = match login_do_json(http, reqwest::Method::GET, &url, None, None).await {
        Ok(data) => data,
        Err((true, msg)) => return LoginPoll::Retry(msg),
        Err((false, _)) => return LoginPoll::Pending,
    };
    let token = LoginToken {
        access_token: str_field(&data, "accessToken"),
        refresh_token: str_field(&data, "refreshToken"),
        expires_in: data.get("expiresIn").and_then(Value::as_i64).unwrap_or(0),
        domain: str_field(&data, "domain"),
    };

    if token.access_token.is_empty() {
        return LoginPoll::Pending;
    }
    LoginPoll::Complete(token)
}

pub async fn login_account(
    http: &reqwest::Client,
    state: &str,
    access_token: &str,
) -> LoginAccount {
    let url = format!("{LOGIN_BASE}/v2/plugin/login/account?state={state}");
    let Ok(data) = login_do_json(http, reqwest::Method::GET, &url, Some(access_token), None).await
    else {
        return LoginAccount::default();
    };
    LoginAccount {
        uid: str_field(&data, "uid"),
        enterprise_id: str_field(&data, "enterpriseId"),
        nickname: str_field(&data, "nickname"),
    }
}

fn str_field(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

pub enum ChatStreamError {
    Upstream { status: u16, body: Vec<u8> },

    Transport(String),
}

impl fmt::Display for ChatStreamError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ChatStreamError::Upstream { status, .. } => write!(f, "upstream http {status}"),
            ChatStreamError::Transport(e) => write!(f, "transport: {e}"),
        }
    }
}

#[derive(Debug, Clone)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
    pub context_window: i64,
    pub max_tokens: i64,
}

fn format_date_from_epoch(unix_secs: i64, extra_days: i64) -> String {
    use chrono::TimeZone;
    let dt = chrono::Local
        .timestamp_opt(unix_secs + extra_days * 86400, 0)
        .single()
        .unwrap_or_else(|| chrono::Local.timestamp_opt(0, 0).single().unwrap());
    dt.format("%Y-%m-%d %H:%M:%S").to_string()
}
