use axum::Json;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use crate::app::App;
use crate::net::ApiJson;
use futures_util::future::join_all;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use super::{bad_request, failed};

pub const ACCOUNT_FILE: &str = "accounts.json";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Channel {
    Commandcode,
    Workbuddy,
    Antigravity,
}

impl Channel {
    pub const ALL: [Channel; 3] = [
        Channel::Commandcode,
        Channel::Workbuddy,
        Channel::Antigravity,
    ];

    pub const fn as_str(self) -> &'static str {
        match self {
            Channel::Commandcode => "commandcode",
            Channel::Workbuddy => "workbuddy",
            Channel::Antigravity => "antigravity",
        }
    }

    pub fn parse(value: &str) -> Option<Self> {
        Self::ALL
            .into_iter()
            .find(|channel| channel.as_str() == value)
    }
}

impl std::fmt::Display for Channel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

pub const DEFAULT_MONTHLY_CREDITS: f64 = 10.0;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Account {
    #[serde(default)]
    pub name: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub provider: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub key: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub session_token: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub plan: String,
    #[serde(default)]
    pub monthly_credits: f64,
    #[serde(default)]
    pub five_hour_cap: f64,
    #[serde(default)]
    pub weekly_cap: f64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_access_token: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_refresh_token: String,

    #[serde(default)]
    pub workbuddy_expires_at: i64,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_domain: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_uid: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_enterprise_id: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub workbuddy_nickname: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub antigravity_access_token: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub antigravity_refresh_token: String,

    #[serde(default)]
    pub antigravity_expires_at: i64,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub antigravity_project_id: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub antigravity_email: String,

    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub disabled: bool,
}

impl Account {
    pub fn provider(&self) -> String {
        if self.provider.is_empty() {
            Channel::Commandcode.to_string()
        } else {
            self.provider.clone()
        }
    }

    pub fn channel(&self) -> Option<Channel> {
        if self.provider.is_empty() {
            Some(Channel::Commandcode)
        } else {
            Channel::parse(&self.provider)
        }
    }

    pub fn has_live_credentials(&self) -> bool {
        !self.session_token.is_empty()
            || !self.workbuddy_access_token.is_empty()
            || !self.antigravity_access_token.is_empty()
            || !self.antigravity_refresh_token.is_empty()
    }

    pub fn workbuddy_ready(&self) -> bool {
        !self.disabled
            && (!self.workbuddy_access_token.is_empty() || !self.workbuddy_refresh_token.is_empty())
    }

    pub fn antigravity_ready(&self) -> bool {
        !self.disabled
            && (!self.antigravity_access_token.is_empty()
                || !self.antigravity_refresh_token.is_empty())
    }
}

pub fn monthly_cap(account: &Account) -> f64 {
    if account.monthly_credits > 0.0 {
        account.monthly_credits
    } else if account.channel() == Some(Channel::Commandcode) {
        DEFAULT_MONTHLY_CREDITS
    } else {
        0.0
    }
}

fn merge_string(target: &mut String, patch: &str) {
    if !patch.is_empty() {
        *target = patch.trim().to_string();
    }
}

#[derive(Debug, Serialize)]
pub struct AccountView {
    pub name: String,
    pub provider: String,
    pub key: String,
    pub session_token: String,
    pub workbuddy_uid: String,
    pub workbuddy_nickname: String,
    pub antigravity_email: String,
    pub antigravity_project_id: String,
    pub disabled: bool,
}

impl AccountView {
    pub fn new(account: Account) -> Self {
        Self {
            provider: account.provider(),
            name: account.name,
            key: account.key,
            session_token: account.session_token,
            workbuddy_uid: account.workbuddy_uid,
            workbuddy_nickname: account.workbuddy_nickname,
            antigravity_email: account.antigravity_email,
            antigravity_project_id: account.antigravity_project_id,
            disabled: account.disabled,
        }
    }
}

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct AccountsDoc {
    #[serde(default)]
    pub accounts: Vec<Account>,
}

pub struct AccountsManager {
    path: PathBuf,
    state: Mutex<AccountsDoc>,
}

#[derive(Debug, Clone, Default, Deserialize)]
pub struct AccountPatch {
    #[serde(default, rename = "new_name")]
    pub name: String,
    #[serde(default)]
    pub key: String,
    #[serde(default)]
    pub session_token: String,
    #[serde(default)]
    pub workbuddy_access_token: String,
    #[serde(default)]
    pub workbuddy_refresh_token: String,
    #[serde(default)]
    pub workbuddy_expires_at: i64,
    #[serde(default)]
    pub workbuddy_domain: String,
    #[serde(default)]
    pub workbuddy_uid: String,
    #[serde(default)]
    pub workbuddy_enterprise_id: String,
    #[serde(default)]
    pub workbuddy_nickname: String,
    #[serde(default)]
    pub antigravity_access_token: String,
    #[serde(default)]
    pub antigravity_refresh_token: String,
    #[serde(default)]
    pub antigravity_expires_at: i64,
    #[serde(default)]
    pub antigravity_project_id: String,
    #[serde(default)]
    pub antigravity_email: String,

    #[serde(default)]
    pub disabled: Option<bool>,
}

impl AccountsManager {
    pub fn new(dir: &Path) -> Result<Self, String> {
        let path = dir.join(ACCOUNT_FILE);
        let mut manager = Self {
            path,
            state: Mutex::new(AccountsDoc::default()),
        };

        match fs::read(&manager.path) {
            Ok(data) => {
                let doc: AccountsDoc = serde_json::from_slice(&data)
                    .map_err(|err| format!("parse {}: {err}", ACCOUNT_FILE))?;
                if !doc.accounts.is_empty() {
                    *manager
                        .state
                        .lock()
                        .map_err(|_| "accounts mutex poisoned".to_string())? = doc;
                    return Ok(manager);
                }
                manager.start_empty()?;
                Ok(manager)
            }
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
                manager.start_empty()?;
                Ok(manager)
            }
            Err(err) => Err(format!("read {}: {err}", ACCOUNT_FILE)),
        }
    }

    fn start_empty(&mut self) -> Result<(), String> {
        self.state = Mutex::new(AccountsDoc::default());
        self.persist()
    }

    pub fn list(&self) -> Vec<Account> {
        self.state
            .lock()
            .map(|state| state.accounts.clone())
            .unwrap_or_default()
    }

    pub fn serving(&self, channel: Channel) -> Vec<Account> {
        self.list()
            .into_iter()
            .filter(|account| {
                account.channel() == Some(channel)
                    && !account.disabled
                    && (!account.key.is_empty() || account.has_live_credentials())
            })
            .collect()
    }

    pub fn add(&self, account: Account) -> Result<(), String> {
        let mut account = account;
        for field in [
            &mut account.name,
            &mut account.key,
            &mut account.session_token,
            &mut account.workbuddy_access_token,
            &mut account.workbuddy_refresh_token,
            &mut account.workbuddy_domain,
            &mut account.workbuddy_uid,
            &mut account.workbuddy_enterprise_id,
            &mut account.workbuddy_nickname,
            &mut account.antigravity_access_token,
            &mut account.antigravity_refresh_token,
            &mut account.antigravity_project_id,
            &mut account.antigravity_email,
        ] {
            *field = field.trim().to_string();
        }
        let Some(channel) = account.channel() else {
            return Err(format!(
                "unknown provider {:?}: raven serves only {}",
                account.provider,
                Channel::ALL.map(Channel::as_str).join(", ")
            ));
        };
        if account.name.is_empty() {
            return Err("account name is required".to_string());
        }
        if !matches!(channel, Channel::Workbuddy | Channel::Antigravity) && account.key.is_empty() {
            return Err("account key is required".to_string());
        }
        if channel == Channel::Workbuddy
            && account.workbuddy_access_token.is_empty()
            && account.workbuddy_refresh_token.is_empty()
        {
            return Err("workbuddy accounts require a token (paste the auth json)".to_string());
        }
        if channel == Channel::Antigravity
            && account.antigravity_access_token.is_empty()
            && account.antigravity_refresh_token.is_empty()
        {
            return Err("antigravity accounts require a Google sign-in".to_string());
        }
        if channel == Channel::Commandcode && account.monthly_credits <= 0.0 {
            account.monthly_credits = DEFAULT_MONTHLY_CREDITS;
        }

        let mut state = self
            .state
            .lock()
            .map_err(|_| "accounts mutex poisoned".to_string())?;
        let name = account.name.clone();
        if let Some(index) = state
            .accounts
            .iter()
            .position(|existing| existing.name == name)
        {
            state.accounts[index] = account;
        } else {
            state.accounts.push(account);
        }
        self.persist_doc(&state)
    }

    pub fn update(&self, name: &str, patch: AccountPatch) -> Result<(), String> {
        let name = name.trim().to_string();
        if name.is_empty() {
            return Err("account name is required".to_string());
        }
        let mut state = self
            .state
            .lock()
            .map_err(|_| "accounts mutex poisoned".to_string())?;
        let Some(index) = state
            .accounts
            .iter()
            .position(|account| account.name == name)
        else {
            return Err(format!("no account named {name:?}"));
        };
        {
            let current = &mut state.accounts[index];
            merge_string(&mut current.key, &patch.key);
            merge_string(&mut current.session_token, &patch.session_token);
            merge_string(&mut current.workbuddy_access_token, &patch.workbuddy_access_token);
            merge_string(&mut current.workbuddy_refresh_token, &patch.workbuddy_refresh_token);
            merge_string(&mut current.workbuddy_domain, &patch.workbuddy_domain);
            merge_string(&mut current.workbuddy_uid, &patch.workbuddy_uid);
            merge_string(&mut current.workbuddy_enterprise_id, &patch.workbuddy_enterprise_id);
            merge_string(&mut current.workbuddy_nickname, &patch.workbuddy_nickname);
            merge_string(
                &mut current.antigravity_access_token,
                &patch.antigravity_access_token,
            );
            merge_string(
                &mut current.antigravity_refresh_token,
                &patch.antigravity_refresh_token,
            );
            merge_string(
                &mut current.antigravity_project_id,
                &patch.antigravity_project_id,
            );
            merge_string(&mut current.antigravity_email, &patch.antigravity_email);
            if patch.workbuddy_expires_at != 0 {
                current.workbuddy_expires_at = patch.workbuddy_expires_at;
            }
            if patch.antigravity_expires_at != 0 {
                current.antigravity_expires_at = patch.antigravity_expires_at;
            }
            if let Some(disabled) = patch.disabled {
                current.disabled = disabled;
            }
            if !patch.name.is_empty() && patch.name.trim() != current.name {
                current.name = patch.name.trim().to_string();
            }
        }
        self.persist_doc(&state)
    }

    pub fn remove(&self, name: &str) -> Result<(), String> {
        let mut state = self
            .state
            .lock()
            .map_err(|_| "accounts mutex poisoned".to_string())?;
        let before = state.accounts.len();
        state.accounts.retain(|account| account.name != name);
        if state.accounts.len() == before {
            return Err(format!("no account named {name:?}"));
        }
        self.persist_doc(&state)
    }

    fn persist(&self) -> Result<(), String> {
        let state = self
            .state
            .lock()
            .map_err(|_| "accounts mutex poisoned".to_string())?;
        self.persist_doc(&state)
    }

    fn persist_doc(&self, state: &AccountsDoc) -> Result<(), String> {
        let data =
            serde_json::to_vec_pretty(state).map_err(|err| format!("marshal accounts: {err}"))?;
        fs::write(&self.path, data)
            .and_then(|()| fs::set_permissions(&self.path, fs::Permissions::from_mode(0o600)))
            .map_err(|err| format!("write {}: {err}", self.path.display()))
    }
}

#[derive(Debug, Deserialize)]
pub struct EditAccountBody {
    #[serde(default)]
    name: String,
    #[serde(flatten)]
    patch: AccountPatch,
}

pub async fn handle_list(State(state): State<Arc<App>>) -> Response {
    let data: Vec<AccountView> = state
        .accounts
        .list()
        .into_iter()
        .map(AccountView::new)
        .collect();
    (StatusCode::OK, Json(json!({"accounts": data}))).into_response()
}

pub async fn handle_add(
    State(state): State<Arc<App>>,
    ApiJson(account): ApiJson<Account>,
) -> Response {
    let name = account.name.trim().to_string();
    match state.accounts.add(account) {
        Ok(()) => (StatusCode::OK, Json(json!({"ok": true, "name": name}))).into_response(),
        Err(err) => bad_request(&err),
    }
}


pub async fn handle_edit(
    State(state): State<Arc<App>>,
    ApiJson(body): ApiJson<EditAccountBody>,
) -> Response {
    match state.accounts.update(&body.name, body.patch) {
        Ok(()) => (StatusCode::OK, Json(json!({"ok": true, "name": body.name}))).into_response(),
        Err(err) => failed(StatusCode::NOT_FOUND, "account_not_found", &err),
    }
}

pub async fn handle_remove(
    State(state): State<Arc<App>>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let name = params.get("name").cloned().unwrap_or_default();
    if name.is_empty() {
        return failed(StatusCode::BAD_REQUEST, "invalid_request_error", "name query param is required",
        );
    }
    match state.accounts.remove(&name) {
        Ok(()) => (StatusCode::OK, Json(json!({"ok": true, "name": name}))).into_response(),
        Err(err) => failed(StatusCode::NOT_FOUND, "account_not_found", &err),
    }
}


pub async fn handle_limits(State(state): State<Arc<App>>) -> Response {
    let accounts: Vec<_> = state
        .accounts
        .list()
        .into_iter()
        .filter(|account| account.channel() == Some(Channel::Commandcode))
        .collect();
    let futures = accounts.into_iter().map(|account| {
        let limits = Arc::clone(&state.limits);
        async move { limits.get(&account).await }
    });
    let accounts = join_all(futures).await;
    (StatusCode::OK, Json(json!({"accounts": accounts}))).into_response()
}
