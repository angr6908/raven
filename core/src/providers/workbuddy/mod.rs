pub mod auth;
pub mod client;
pub mod headers;
pub mod panel;
pub mod payload;
pub mod pool;
pub mod sanitize;
pub mod scheduler;
pub mod sse;

use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{json, Value};

use crate::state::accounts::{Account, AccountPatch, AccountsManager, Channel};
use crate::translate::ids::now_unix_millis;
use crate::providers::workbuddy::auth::Auth;
use crate::providers::workbuddy::client::{classify, ChatStreamError, Client, ErrKind, ModelInfo};
use crate::providers::workbuddy::pool::{CoolKind, Pool};

pub const MAX_ROTATE: usize = 3;
pub const SOFT_COOLDOWN: Duration = Duration::from_secs(60);
pub const ERR_THRESHOLD: i64 = 3;
pub const ERR_COOLDOWN: Duration = Duration::from_secs(10 * 60);
pub const REFRESH_SKEW: Duration = Duration::from_secs(10 * 60);

const STATIC_MODELS: &[&str] = &[
    "glm-5.2",
    "glm-5.1",
    "glm-5v-turbo",
    "kimi-k2.7",
    "minimax-m3",
    "hy3",
    "hy3-preview",
    "hy3-preview-agent",
    "deepseek-v4-pro",
    "deepseek-v4-flash",
];

const STATIC_CONTEXT_LENGTH: i64 = 131072;
const STATIC_CREATED: i64 = 1753600000;

const DYNAMIC_MODELS_TTL: Duration = Duration::from_secs(60 * 60);
const MODELS_FETCH_FAIL_COOLDOWN: Duration = Duration::from_secs(5 * 60);

#[derive(Default)]
struct ModelsCacheInner {
    ids: Vec<ModelInfo>,
    fetched: i64,
    last_fail: i64,
}

const OAUTH_LOGIN_TIMEOUT: Duration = Duration::from_secs(600);

const OAUTH_POLL_INTERVAL: Duration = Duration::from_secs(2);

const OAUTH_SESSION_TTL: i64 = 1800;

#[derive(Debug, Default)]
struct OauthState {
    done: bool,
    success: bool,
    uid: String,
    nickname: String,
    error: String,
}

struct OauthSession {
    auth_url: String,
    created: i64,
    state: Arc<Mutex<OauthState>>,
}

impl Clone for OauthSession {
    fn clone(&self) -> Self {
        OauthSession {
            auth_url: self.auth_url.clone(),
            created: self.created,
            state: Arc::clone(&self.state),
        }
    }
}

pub struct Workbuddy {
    pub pool: Arc<Pool>,
    pub client: Client,
    pub accounts: Arc<AccountsManager>,
    save_auth: Arc<dyn Fn(&Auth) + Send + Sync>,
    models: Mutex<ModelsCacheInner>,
    oauth: Mutex<HashMap<String, OauthSession>>,
}

impl Workbuddy {
    pub fn new(
        data_dir: &std::path::Path,
        accounts: Arc<AccountsManager>,
        http: reqwest::Client,
    ) -> Arc<Self> {
        let pool = Pool::new(data_dir.join("workbuddy_state.json"));
        let client = Client::new(http);

        let accounts_clone = Arc::clone(&accounts);
        let save_auth: Arc<dyn Fn(&Auth) + Send + Sync> = Arc::new(move |a: &Auth| {
            if a.account_name.is_empty() {
                return;
            }
            let patch = AccountPatch {
                workbuddy_access_token: a.access_token.clone(),
                workbuddy_refresh_token: a.refresh_token.clone(),
                workbuddy_expires_at: a.expires_at,
                workbuddy_domain: a.domain.clone(),
                ..Default::default()
            };
            if let Err(err) = accounts_clone.update(&a.account_name, patch) {
                eprintln!(
                    "workbuddy save auth uid={} account={}: {err}",
                    a.uid, a.account_name
                );
            }
        });

        let runtime = Arc::new(Workbuddy {
            pool: Arc::clone(&pool),
            client: client.clone(),
            accounts,
            save_auth: Arc::clone(&save_auth),
            models: Mutex::new(ModelsCacheInner::default()),
            oauth: Mutex::new(HashMap::new()),
        });

        runtime.sync_accounts();

        let runtime_spawn = Arc::clone(&runtime);
        tokio::spawn(async move {
            let client = runtime_spawn.client.clone();
            scheduler::run_loop(
                runtime_spawn.pool.clone(),
                client,
                runtime_spawn.save_auth.clone(),
            )
            .await;
        });

        runtime
    }

    pub fn sync_accounts(&self) {
        let auths: Vec<Arc<Mutex<Auth>>> = self
            .accounts
            .list()
            .iter()
            .filter(|a| a.channel() == Some(Channel::Workbuddy))
            .filter(|a| a.workbuddy_ready())
            .map(account_to_auth)
            .collect();
        self.pool.sync_to_auths(auths);
    }

    pub async fn chat_rotate(&self, body: &[u8]) -> Result<reqwest::Response, ChatError> {
        self.sync_accounts();
        let prepared = self.client.prepare_body(body);
        let mut tried: HashMap<String, bool> = HashMap::new();
        let mut last_err: Option<String> = None;

        for _ in 0..MAX_ROTATE {
            let Some(auth) = self.pool.pick_excluding(&tried) else {
                break;
            };
            let uid = auth.lock().unwrap().uid.clone();
            tried.insert(uid.clone(), true);

            if auth.lock().unwrap().needs_refresh(REFRESH_SKEW) {
                if let Err(err) = self.client.refresh_token(&auth).await {
                    last_err = Some(err.to_string());
                    if err.kind == ErrKind::SessionDead {
                        self.pool.disable(&uid, "refresh session dead");
                    } else {
                        self.pool.cooldown(
                            &uid,
                            CoolKind::CoolErr,
                            ERR_COOLDOWN,
                            &format!("refresh: {err}"),
                        );
                    }
                    continue;
                }

                let snapshot = auth.lock().unwrap().clone();
                (self.save_auth)(&snapshot);
            }

            let snapshot = auth.lock().unwrap().clone();
            match self.client.chat_stream(&snapshot, &prepared).await {
                Ok(resp) => {
                    self.pool.note_success(&uid);
                    return Ok(resp);
                }
                Err(ChatStreamError::Transport(e)) => {
                    last_err = Some(format!("transport: {e}"));
                    continue;
                }
                Err(ChatStreamError::Upstream { status, body }) => {
                    let body_str = String::from_utf8_lossy(&body).to_string();
                    let kind = classify(status, &body_str);
                    last_err = Some(format!(
                        "upstream {} ({status}): {}",
                        kind.as_str(),
                        truncate(&body_str, 120)
                    ));
                    self.apply_error_policy(&uid, kind, status, &body_str);
                    continue;
                }
            }
        }

        let mut msg = "all accounts unavailable (cooling/disabled)".to_string();
        if let Some(err) = last_err {
            msg.push_str(": ");
            msg.push_str(&err);
        }
        Err(ChatError::NoHealthy(msg))
    }

    fn apply_error_policy(&self, uid: &str, kind: ErrKind, status: u16, body: &str) {
        match kind {
            ErrKind::HardCredit => {
                self.pool.cooldown_until_tomorrow_4am(uid, "余额不足");
            }
            ErrKind::SoftRate => {
                self.pool
                    .cooldown(uid, CoolKind::CoolSoft, SOFT_COOLDOWN, "429 rate limit");
            }
            ErrKind::SessionDead => {
                self.pool.disable(uid, "12153 session dead");
            }
            ErrKind::NotFound => {
                self.pool
                    .cooldown(uid, CoolKind::CoolSoft, SOFT_COOLDOWN, "upstream 404");
            }
            _ => {
                if status >= 500 {
                    self.pool.note_error(uid, ERR_THRESHOLD, ERR_COOLDOWN);
                }
            }
        }
        let _ = body;
    }

    pub fn status(&self) -> Value {
        self.sync_accounts();
        let (total, healthy, cooling, disabled) = self.pool.counts_detailed();
        json!({
            "accounts": self.pool.list(),
            "total": total,
            "healthy": healthy,
            "cooling": cooling,
            "disabled": disabled,
        })
    }

    pub async fn checkin_now(&self) {
        self.sync_accounts();
        scheduler::run_checkin_now(&self.pool, &self.client).await;
    }

    pub async fn keepalive_now(&self) {
        self.sync_accounts();
        scheduler::run_keepalive_now(&self.pool, &self.client, self.save_auth.as_ref()).await;
    }

    pub async fn oauth_start(self: Arc<Self>) -> Result<Value, String> {
        let login = client::new_login_client();
        let (state, auth_url) = client::login_auth_state(&login).await?;
        let session_id = format!("oauth_{}", now_unix_millis());
        let st = Arc::new(Mutex::new(OauthState::default()));
        {
            let mut sessions = self.oauth.lock().unwrap();
            let now = pool::now_unix();
            sessions.retain(|_, s| now - s.created < OAUTH_SESSION_TTL);
            sessions.insert(
                session_id.clone(),
                OauthSession {
                    auth_url: auth_url.clone(),
                    created: now,
                    state: Arc::clone(&st),
                },
            );
        }

        let runtime = Arc::clone(&self);
        tokio::spawn(async move {
            let outcome = runtime.oauth_finish(login, state).await;
            let mut s = st.lock().unwrap();
            s.done = true;
            match outcome {
                Ok((uid, nickname)) => {
                    s.success = true;
                    s.uid = uid;
                    s.nickname = nickname;
                }
                Err(err) => s.error = err,
            }
        });

        Ok(json!({ "session": session_id, "url": auth_url }))
    }

    async fn oauth_finish(
        self: Arc<Self>,
        login: reqwest::Client,
        state: String,
    ) -> Result<(String, String), String> {
        let deadline = tokio::time::Instant::now() + OAUTH_LOGIN_TIMEOUT;
        let mut last_err = String::new();
        let token = loop {
            match client::login_poll(&login, &state).await {
                client::LoginPoll::Complete(token) => break token,
                client::LoginPoll::Pending => {}
                client::LoginPoll::Retry(err) => last_err = err,
            }
            if tokio::time::Instant::now() >= deadline {
                return Err(if last_err.is_empty() {
                    "login not completed (waiting for browser sign-in)".to_string()
                } else {
                    format!("login not completed: {last_err}")
                });
            }
            tokio::time::sleep(OAUTH_POLL_INTERVAL).await;
        };

        let acct = client::login_account(&login, &state, &token.access_token).await;

        if acct.uid.is_empty() {
            return Err("login/account returned no uid — token may be invalid".to_string());
        }
        let expires_at = if token.expires_in > 0 {
            pool::now_unix() + token.expires_in
        } else {
            0
        };

        let account = self.oauth_account(&token, &acct, expires_at);
        let auth = account_to_auth(&account);
        let uid = auth.lock().unwrap().uid.clone();
        self.accounts.add(account)?;
        self.sync_accounts();

        let snapshot = auth.lock().unwrap().clone();
        if let Err(err) = self.client.daily_checkin(&snapshot).await {
            eprintln!("workbuddy login checkin {uid}: {err}");
        }
        match self.client.user_resource(&snapshot).await {
            Ok(remain) => self.pool.reenable_if_credits(&uid, remain),
            Err(err) => eprintln!("workbuddy login balance {uid}: {err}"),
        }
        Ok((acct.uid, acct.nickname))
    }

    pub fn oauth_status(&self, session: &str) -> Value {
        let found = self.oauth.lock().unwrap().get(session).cloned();
        let Some(s) = found else {
            return json!({
                "done": true,
                "success": false,
                "error": "unknown or expired session",
            });
        };
        let st = s.state.lock().unwrap();
        json!({
            "done": st.done,
            "success": st.success,
            "uid": st.uid,
            "nickname": st.nickname,
            "error": st.error,
            "url": s.auth_url,
        })
    }

    fn oauth_account(
        &self,
        token: &client::LoginToken,
        acct: &client::LoginAccount,
        expires_at: i64,
    ) -> Account {
        let existing = self
            .accounts
            .list()
            .into_iter()
            .find(|a| a.channel() == Some(Channel::Workbuddy) && a.workbuddy_uid == acct.uid);
        let mut account = existing.unwrap_or_else(|| Account {
            name: self.derive_account_name(&acct.nickname, &acct.uid),
            provider: Channel::Workbuddy.to_string(),
            ..Account::default()
        });
        account.provider = Channel::Workbuddy.to_string();
        account.workbuddy_access_token = token.access_token.clone();
        account.workbuddy_refresh_token = token.refresh_token.clone();
        account.workbuddy_expires_at = expires_at;
        account.workbuddy_domain = token.domain.clone();
        account.workbuddy_uid = acct.uid.clone();
        account.workbuddy_enterprise_id = acct.enterprise_id.clone();
        account.workbuddy_nickname = acct.nickname.clone();
        account
    }

    pub fn derive_account_name(&self, nickname: &str, uid: &str) -> String {
        let nickname = nickname.trim();
        let base = if !nickname.is_empty() {
            nickname.to_string()
        } else if !uid.is_empty() {
            uid.to_string()
        } else {
            Channel::Workbuddy.to_string()
        };
        let existing: Vec<String> = self.accounts.list().into_iter().map(|a| a.name).collect();
        if !existing.contains(&base) {
            return base;
        }
        for i in 2.. {
            let candidate = format!("{base}-{i}");
            if !existing.contains(&candidate) {
                return candidate;
            }
        }
        unreachable!()
    }

    pub async fn model_list(&self) -> Vec<Value> {
        let infos = self.fetch_dynamic_models().await;
        if infos.is_empty() {
            return STATIC_MODELS
                .iter()
                .map(|id| {
                    json!({
                        "id": id,
                        "object": "model",
                        "created": STATIC_CREATED,
                        "owned_by": Channel::Workbuddy.as_str(),
                        "context_length": STATIC_CONTEXT_LENGTH,
                    })
                })
                .collect();
        }
        infos
            .iter()
            .map(|mi| {
                let mut entry = json!({
                    "id": mi.id,
                    "object": "model",
                    "created": STATIC_CREATED,
                    "owned_by": Channel::Workbuddy.as_str(),
                    "context_length": if mi.context_window == 0 { STATIC_CONTEXT_LENGTH } else { mi.context_window },
                    "max_output_tokens": mi.max_tokens,
                });

                if !mi.name.is_empty() && mi.name != mi.id {
                    entry["display_name"] = json!(mi.name);
                }
                entry
            })
            .collect()
    }

    async fn fetch_dynamic_models(&self) -> Vec<ModelInfo> {
        let now = crate::providers::workbuddy::pool::now_unix();
        {
            let cache = self.models.lock().unwrap();
            if !cache.ids.is_empty() && now - cache.fetched < DYNAMIC_MODELS_TTL.as_secs() as i64 {
                return cache.ids.clone();
            }
            if cache.last_fail != 0
                && now - cache.last_fail < MODELS_FETCH_FAIL_COOLDOWN.as_secs() as i64
            {
                return Vec::new();
            }
        }

        self.sync_accounts();
        let Some(auth) = self.pool.pick() else {
            return Vec::new();
        };
        let snapshot = auth.lock().unwrap().clone();
        let uid = snapshot.uid.clone();
        match self.client.fetch_models(&snapshot).await {
            Ok(infos) if !infos.is_empty() => {
                let mut cache = self.models.lock().unwrap();
                cache.ids = infos.clone();
                cache.fetched = now;
                cache.last_fail = 0;
                infos
            }
            _ => {
                self.pool.note_error(&uid, ERR_THRESHOLD, ERR_COOLDOWN);
                let mut cache = self.models.lock().unwrap();
                cache.last_fail = now;
                Vec::new()
            }
        }
    }
}

pub enum ChatError {
    NoHealthy(String),
}

impl std::fmt::Display for ChatError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ChatError::NoHealthy(msg) => write!(f, "{msg}"),
        }
    }
}

fn account_to_auth(account: &Account) -> Arc<Mutex<Auth>> {
    let uid = if account.workbuddy_uid.is_empty() {
        account.name.clone()
    } else {
        account.workbuddy_uid.clone()
    };
    Arc::new(Mutex::new(Auth {
        access_token: account.workbuddy_access_token.clone(),
        refresh_token: account.workbuddy_refresh_token.clone(),
        expires_at: account.workbuddy_expires_at,
        domain: account.workbuddy_domain.clone(),
        uid,
        enterprise_id: account.workbuddy_enterprise_id.clone(),
        nickname: account.workbuddy_nickname.clone(),
        account_name: account.name.clone(),
    }))
}

pub(super) fn truncate(s: &str, n: usize) -> String {
    let s = s.trim();
    if s.chars().count() > n {
        s.chars().take(n).collect()
    } else {
        s.to_string()
    }
}
