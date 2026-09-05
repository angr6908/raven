pub mod auth;
pub mod client;
pub mod models;
pub mod oauth;
pub mod panel;
pub mod signatures;
pub mod sse;

use axum::body::Bytes;
use axum::http::StatusCode;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use crate::net::error::ApiError;
use crate::state::accounts::{Account, AccountPatch, AccountsManager, Channel};
use crate::translate::chat::types::ChatRequest;
use crate::translate::gemini::{self, Plan};
use crate::translate::ids::{now_unix_millis, now_unix_secs};

use self::auth::Auth;
use self::client::Client;
use self::signatures::Signatures;

use super::{SendFailure, Sent};

pub const REFRESH_SKEW: Duration = Duration::from_secs(10 * 60);
const CATALOG_TTL: Duration = Duration::from_secs(4 * 60 * 60);
const CATALOG_FAIL_COOLDOWN: Duration = Duration::from_secs(5 * 60);
const QUOTA_TTL: Duration = Duration::from_secs(60);
const OAUTH_TIMEOUT: Duration = Duration::from_secs(600);
const OAUTH_SESSION_TTL: i64 = 1800;
const RETRY_STATUS: [u16; 7] = [403, 404, 429, 500, 502, 503, 504];
const MAX_ATTEMPTS: usize = 40;
const RETRY_DELAY: Duration = Duration::from_millis(500);
const RETRY_BUDGET: Duration = Duration::from_secs(90);

fn is_retryable(status: u16) -> bool {
    matches!(status, 408 | 429 | 500 | 502 | 503 | 504)
}

fn is_fresh(fetched: Option<Instant>, ttl: Duration) -> bool {
    fetched.is_some_and(|at| at.elapsed() < ttl)
}

#[derive(Default)]
struct Catalog {
    models: Value,
    fetched: Option<Instant>,
    failed: Option<Instant>,
}

#[derive(Default)]
struct QuotaCache {
    value: Value,
    fetched: Option<Instant>,
}

#[derive(Debug, Default)]
struct OauthState {
    done: bool,
    success: bool,
    email: String,
    name: String,
    error: String,
}

struct Session {
    url: String,
    state: String,
    verifier: String,
    created: i64,
    status: Arc<Mutex<OauthState>>,
}

pub struct Antigravity {
    pub accounts: Arc<AccountsManager>,
    pub client: Client,
    pub signatures: Arc<Signatures>,
    catalog: Mutex<Catalog>,
    quota_cache: Mutex<QuotaCache>,
    oauth: Mutex<HashMap<String, Session>>,
    listener: tokio::sync::Mutex<Option<tokio::task::JoinHandle<()>>>,
}

impl Antigravity {
    pub fn new(accounts: Arc<AccountsManager>) -> Arc<Self> {
        Arc::new(Self {
            accounts,
            client: Client::new(),
            signatures: Arc::new(Signatures::new()),
            catalog: Mutex::new(Catalog::default()),
            quota_cache: Mutex::new(QuotaCache::default()),
            oauth: Mutex::new(HashMap::new()),
            listener: tokio::sync::Mutex::new(None),
        })
    }

    pub fn pool(&self) -> Vec<Account> {
        let mut pool: Vec<Account> = self
            .accounts
            .list()
            .into_iter()
            .filter(|account| account.channel() == Some(Channel::Antigravity))
            .filter(Account::antigravity_ready)
            .collect();
        pool.sort_by(|a, b| a.name.cmp(&b.name));
        pool
    }

    pub fn encode_request(&self, req: ChatRequest, model: &str) -> Result<Vec<u8>, String> {
        let runtime = models::runtime_model(model, &req.reasoning_effort);
        let plan = Plan {
            model_enum: models::model_enum(&runtime),
            max_output_tokens: models::max_output_tokens(&runtime),
            thinking: models::thinking(&runtime, &req.reasoning_effort),
            tool_call_ids: models::tool_call_ids(&runtime),
            legacy_tool_parameters: models::legacy_tool_parameters(&runtime),
            requires_thought_signature: models::requires_thought_signature(&runtime),
            runtime_model: runtime,
        };
        let signatures = Arc::clone(&self.signatures);
        let envelope = gemini::build_request(req, &plan, &move |id| signatures.get(id))?;
        serde_json::to_vec(&envelope).map_err(|err| format!("marshal antigravity request: {err}"))
    }

    pub async fn send(&self, payload: Bytes) -> Result<Sent, SendFailure> {
        let pool = self.pool();
        if pool.is_empty() {
            return Err(SendFailure {
                account: String::new(),
                error: ApiError::coded(
                    StatusCode::UNAUTHORIZED,
                    "authentication_error",
                    "no antigravity account signed in; connect one in the panel",
                ),
            });
        }

        let quota = match pool.len() > 1 {
            true => self.quota().await,
            false => Value::Null,
        };
        let group = bucket_group(&payload);

        let mut last: Option<SendFailure> = None;
        for (index, account) in pool.iter().enumerate() {
            let name = account.name.clone();
            let spare = has_next(index, pool.len());
            if spare && is_used_up(&quota, &name, group) {
                eprintln!("antigravity {name}: {group} quota used up, next account");
                continue;
            }
            let auth = match self.fresh_auth(account).await {
                Ok(auth) => auth,
                Err(message) => {
                    eprintln!("antigravity {name}: {message}");
                    last = Some(SendFailure {
                        account: name,
                        error: ApiError::coded(
                            StatusCode::UNAUTHORIZED,
                            "authentication_error",
                            message,
                        ),
                    });
                    continue;
                }
            };
            let started = Instant::now();
            let mut attempt = 1usize;
            let outcome = loop {
                let error = match self.attempt(&auth, &payload).await {
                    Ok(response) => {
                        if attempt > 1 {
                            eprintln!("antigravity {name}: recovered on attempt {attempt}");
                        }
                        return Ok(Sent {
                            account: name,
                            response: sse::transcode(response, Arc::clone(&self.signatures)),
                        });
                    }
                    Err(error) => error,
                };
                let status = error.status_u16();
                eprintln!("upstream {name} -> {status} {}: {}", error.code, error.message);
                if !is_retryable(status) || attempt >= MAX_ATTEMPTS {
                    break error;
                }
                if started.elapsed() + RETRY_DELAY > RETRY_BUDGET {
                    break error;
                }
                eprintln!(
                    "retry {name} after {status} in {RETRY_DELAY:?} (attempt {}/{MAX_ATTEMPTS})",
                    attempt + 1
                );
                tokio::time::sleep(RETRY_DELAY).await;
                attempt += 1;
            };

            let fatal = !RETRY_STATUS.contains(&outcome.status_u16()) && outcome.status_u16() != 401;
            last = Some(SendFailure {
                account: name,
                error: outcome,
            });
            if fatal {
                break;
            }
        }
        Err(last.expect("a non-empty pool always records its last failure"))
    }

    async fn attempt(&self, auth: &Auth, payload: &Bytes) -> Result<reqwest::Response, ApiError> {
        let project = client::project_for(auth);
        let body = with_project(payload, &project);
        match self.post(auth, body.clone()).await {
            Ok(response) => Ok(response),
            Err(error) if error.status_u16() == 404 => match fallback_payload(&body) {
                Some(retry) => self.post(auth, retry).await,
                None => Err(error),
            },
            Err(error) => Err(error),
        }
    }

    async fn post(&self, auth: &Auth, body: Vec<u8>) -> Result<reqwest::Response, ApiError> {
        let mut last = ApiError::gateway("upstream_error", "no antigravity endpoint available");
        for endpoint in self.client.endpoints() {
            let response = match self
                .client
                .stream_generate_content(&endpoint, &auth.access_token, body.clone())
                .await
            {
                Ok(response) => response,
                Err(message) => {
                    last = ApiError::gateway("upstream_error", message);
                    continue;
                }
            };
            if response.status().is_success() {
                return Ok(response);
            }
            let status = response.status();
            let text = response.text().await.unwrap_or_default();
            let message = client::error_text(&text);
            last = ApiError::coded(status, "upstream_error", message.clone());
            if status.as_u16() == 429 {
                break;
            }
            if !RETRY_STATUS.contains(&status.as_u16()) {
                break;
            }
        }
        Err(last)
    }

    async fn fresh_auth(&self, account: &Account) -> Result<Auth, String> {
        let mut auth = Auth::from_account(account);
        let mut patch = AccountPatch::default();
        let mut changed = false;

        if auth.needs_refresh(REFRESH_SKEW) {
            let refreshed = self.client.refresh(&auth.refresh_token).await?;
            auth.access_token = refreshed.access_token.clone();
            auth.refresh_token = refreshed.refresh_token.clone();
            auth.expires_at = refreshed.expires_at;
            patch.antigravity_access_token = refreshed.access_token;
            patch.antigravity_refresh_token = refreshed.refresh_token;
            patch.antigravity_expires_at = refreshed.expires_at;
            changed = true;
        }
        if auth.project_id.is_empty() {
            if let Some(project) = self.client.load_code_assist(&auth.access_token).await {
                auth.project_id = project.clone();
                patch.antigravity_project_id = project;
                changed = true;
            }
        }
        if changed {
            if let Err(err) = self.accounts.update(&account.name, patch) {
                eprintln!("antigravity save auth {}: {err}", account.name);
            }
        }
        Ok(auth)
    }

    async fn any_auth(&self) -> Option<Auth> {
        let account = self.pool().into_iter().next()?;
        self.fresh_auth(&account).await.ok()
    }

    pub async fn model_list(&self) -> Vec<Value> {
        models::catalog_entries(&self.discovered().await)
    }

    async fn discovered(&self) -> Vec<models::Discovered> {
        {
            let catalog = self.catalog.lock().expect("antigravity catalog mutex");
            if is_fresh(catalog.fetched, CATALOG_TTL)
                || is_fresh(catalog.failed, CATALOG_FAIL_COOLDOWN)
            {
                return models::group_catalog(&catalog.models);
            }
        }

        let Some(auth) = self.any_auth().await else {
            return Vec::new();
        };
        let project = client::project_for(&auth);
        let fetched = self
            .client
            .available_models(&auth.access_token, &project)
            .await;
        let mut catalog = self.catalog.lock().expect("antigravity catalog mutex");
        match fetched {
            Ok(models) => {
                catalog.models = models;
                catalog.fetched = Some(Instant::now());
                catalog.failed = None;
            }
            Err(err) => {
                eprintln!("antigravity catalog: {err}");
                catalog.failed = Some(Instant::now());
            }
        }
        models::group_catalog(&catalog.models)
    }

    pub fn refresh_catalog(&self) {
        let mut catalog = self.catalog.lock().expect("antigravity catalog mutex");
        catalog.fetched = None;
        catalog.failed = None;
        drop(catalog);
        self.quota_cache
            .lock()
            .expect("antigravity quota mutex")
            .fetched = None;
    }

    pub fn status(&self) -> Value {
        let now = now_unix_secs();
        let accounts: Vec<Value> = self
            .accounts
            .list()
            .into_iter()
            .filter(|account| account.channel() == Some(Channel::Antigravity))
            .map(|account| {
                json!({
                    "name": account.name,
                    "email": account.antigravity_email,
                    "project": account.antigravity_project_id,
                    "expires_at": account.antigravity_expires_at,
                    "expired": account.antigravity_expires_at > 0
                        && account.antigravity_expires_at <= now,
                    "disabled": account.disabled,
                })
            })
            .collect();
        let healthy = self.pool().len();
        json!({
            "accounts": accounts,
            "total": accounts.len(),
            "healthy": healthy,
        })
    }

    pub async fn quota(&self) -> Value {
        {
            let cache = self.quota_cache.lock().expect("antigravity quota mutex");
            if is_fresh(cache.fetched, QUOTA_TTL) {
                return cache.value.clone();
            }
        }
        let fresh = self.fetch_quota().await;
        let mut cache = self.quota_cache.lock().expect("antigravity quota mutex");
        cache.value = fresh.clone();
        cache.fetched = Some(Instant::now());
        fresh
    }

    async fn fetch_quota(&self) -> Value {
        let mut out: Vec<Value> = Vec::new();
        for account in self.pool() {
            let Ok(auth) = self.fresh_auth(&account).await else {
                out.push(json!({"name": account.name, "error": "sign-in expired"}));
                continue;
            };
            let mut entry = json!({
                "name": account.name,
                "email": auth.email,
                "project": client::project_for(&auth),
            });
            match self.client.quota_summary(&auth.access_token).await {
                Ok(summary) => {
                    entry["groups"] = summary.get("groups").cloned().unwrap_or(json!([]));
                    if let Some(description) = summary.get("description") {
                        entry["description"] = description.clone();
                    }
                }
                Err(err) => entry["error"] = json!(err),
            }
            if let Some(tier) = self.client.tier(&auth.access_token).await {
                for (key, pointer) in [("tier", "/currentTier"), ("paid_tier", "/paidTier")] {
                    if let Some(found) = tier.pointer(pointer) {
                        entry[key] = found.clone();
                    }
                }
            }
            out.push(entry);
        }
        json!({"accounts": out})
    }

    pub async fn oauth_start(self: &Arc<Self>) -> Result<Value, String> {
        let mut running = self.listener.lock().await;
        if let Some(previous) = running.take() {
            previous.abort();
            let _ = previous.await;
        }
        let listener = oauth::listen().await?;
        let pending = oauth::begin();
        let session_id = format!("agy_{}", now_unix_millis());
        let status = Arc::new(Mutex::new(OauthState::default()));
        {
            let mut sessions = self.oauth.lock().expect("antigravity oauth mutex");
            let now = now_unix_secs();
            sessions.retain(|_, session| now - session.created < OAUTH_SESSION_TTL);
            sessions.insert(
                session_id.clone(),
                Session {
                    url: pending.url.clone(),
                    state: pending.state.clone(),
                    verifier: pending.verifier.clone(),
                    created: now,
                    status: Arc::clone(&status),
                },
            );
        }

        let runtime = Arc::clone(self);
        let expected = pending.state.clone();
        let verifier = pending.verifier.clone();
        *running = Some(tokio::spawn(async move {
            let outcome = match oauth::wait_for_code(listener, &expected, OAUTH_TIMEOUT).await {
                Ok(code) => runtime.finish_login(&code, &verifier).await,
                Err(err) => Err(err),
            };
            settle(&status, outcome);
        }));

        Ok(json!({"session": session_id, "url": pending.url}))
    }

    pub async fn oauth_paste(&self, session_id: &str, callback: &str) -> Result<Value, String> {
        let found = {
            let sessions = self.oauth.lock().expect("antigravity oauth mutex");
            sessions.get(session_id).map(|session| {
                (
                    session.state.clone(),
                    session.verifier.clone(),
                    Arc::clone(&session.status),
                )
            })
        };
        let Some((state, verifier, status)) = found else {
            return Err("unknown or expired sign-in session".to_string());
        };
        if status.lock().expect("antigravity oauth state").success {
            return Err("this sign-in already completed".to_string());
        }
        let code = oauth::parse_callback(callback, &state)?;
        let outcome = self.finish_login(&code, &verifier).await;
        settle(&status, outcome.clone());
        outcome.map(|(name, email)| json!({"ok": true, "name": name, "email": email}))
    }

    pub fn oauth_status(&self, session_id: &str) -> Value {
        let sessions = self.oauth.lock().expect("antigravity oauth mutex");
        let Some(session) = sessions.get(session_id) else {
            return json!({
                "done": true,
                "success": false,
                "error": "unknown or expired session",
            });
        };
        let status = session.status.lock().expect("antigravity oauth state");
        json!({
            "done": status.done,
            "success": status.success,
            "email": status.email,
            "name": status.name,
            "error": status.error,
            "url": session.url,
        })
    }

    async fn finish_login(&self, code: &str, verifier: &str) -> Result<(String, String), String> {
        let token = self.client.exchange_code(code, verifier).await?;
        let email = self
            .client
            .user_email(&token.access_token)
            .await
            .unwrap_or_default();
        let project = self
            .client
            .load_code_assist(&token.access_token)
            .await
            .unwrap_or_default();

        let existing = self.accounts.list().into_iter().find(|account| {
            account.channel() == Some(Channel::Antigravity)
                && !email.is_empty()
                && account.antigravity_email == email
        });
        let mut account = existing.unwrap_or_else(|| Account {
            name: self.account_name(&email),
            provider: Channel::Antigravity.to_string(),
            ..Account::default()
        });
        account.provider = Channel::Antigravity.to_string();
        account.antigravity_access_token = token.access_token;
        account.antigravity_refresh_token = token.refresh_token;
        account.antigravity_expires_at = token.expires_at;
        account.antigravity_email = email.clone();
        if !project.is_empty() {
            account.antigravity_project_id = project;
        }
        let name = account.name.clone();
        self.accounts.add(account)?;
        self.refresh_catalog();
        Ok((name, email))
    }

    fn account_name(&self, email: &str) -> String {
        let base = match email.split('@').next().unwrap_or_default() {
            "" => Channel::Antigravity.to_string(),
            local => local.to_string(),
        };
        let taken: Vec<String> = self
            .accounts
            .list()
            .into_iter()
            .map(|account| account.name)
            .collect();
        if !taken.contains(&base) {
            return base;
        }
        for index in 2.. {
            let candidate = format!("{base}-{index}");
            if !taken.contains(&candidate) {
                return candidate;
            }
        }
        unreachable!()
    }
}

fn settle(status: &Arc<Mutex<OauthState>>, outcome: Result<(String, String), String>) {
    let mut state = status.lock().expect("antigravity oauth state");
    state.done = true;
    match outcome {
        Ok((name, email)) => {
            state.success = true;
            state.name = name;
            state.email = email;
        }
        Err(err) => state.error = err,
    }
}

fn has_next(index: usize, pool: usize) -> bool {
    index + 1 < pool
}

fn bucket_group(payload: &[u8]) -> &'static str {
    let model = payload
        .strip_prefix(b"{\"model\":\"")
        .and_then(|rest| rest.split(|byte| *byte == b'"').next())
        .unwrap_or_default();
    match model.starts_with(b"gemini") {
        true => "gemini",
        false => "3p",
    }
}

fn is_used_up(quota: &Value, account: &str, group: &str) -> bool {
    let Some(accounts) = quota.get("accounts").and_then(Value::as_array) else {
        return false;
    };
    let Some(entry) = accounts
        .iter()
        .find(|entry| entry.get("name").and_then(Value::as_str) == Some(account))
    else {
        return false;
    };
    entry
        .get("groups")
        .and_then(Value::as_array)
        .map(|groups| {
            groups
                .iter()
                .filter_map(|found| found.get("buckets").and_then(Value::as_array))
                .flatten()
                .filter(|bucket| {
                    bucket
                        .get("bucketId")
                        .and_then(Value::as_str)
                        .is_some_and(|id| id.starts_with(group))
                })
                .any(|bucket| {
                    bucket
                        .get("remainingFraction")
                        .and_then(Value::as_f64)
                        .is_some_and(|left| left <= 0.0)
                })
        })
        .unwrap_or(false)
}

pub fn with_project(payload: &[u8], project: &str) -> Vec<u8> {
    let rest = payload.strip_prefix(b"{").unwrap_or(payload);
    let mut out = Vec::with_capacity(payload.len() + project.len() + 16);
    out.extend_from_slice(b"{\"project\":");
    let _ = serde_json::to_writer(&mut out, project);
    if rest.iter().find(|byte| !byte.is_ascii_whitespace()) != Some(&b'}') {
        out.push(b',');
    }
    out.extend_from_slice(rest);
    out
}

fn fallback_payload(body: &[u8]) -> Option<Vec<u8>> {
    let mut envelope: Value = serde_json::from_slice(body).ok()?;
    let runtime = envelope.get("model").and_then(Value::as_str)?;
    let fallback = models::fallback_runtime_model(runtime)?;
    eprintln!("antigravity: {runtime} unavailable, retrying on {fallback}");
    envelope["model"] = json!(fallback);
    serde_json::to_vec(&envelope).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_project_is_spliced_in_as_the_first_key() {
        let payload = br#"{"model":"gemini-3.8-flash-low","request":{}}"#;
        let out = with_project(payload, "p-1");
        let parsed: Value = serde_json::from_slice(&out).expect("valid json");
        assert_eq!(parsed["project"], "p-1");
        assert_eq!(parsed["model"], "gemini-3.8-flash-low");

        let empty = with_project(b"{}", "p-2");
        let parsed: Value = serde_json::from_slice(&empty).expect("valid json");
        assert_eq!(parsed["project"], "p-2");
        assert_eq!(parsed.as_object().expect("object").len(), 1);
    }

    #[test]
    fn transient_rejections_are_retried_and_refusals_are_not() {
        for status in [408, 429, 500, 502, 503, 504] {
            assert!(is_retryable(status), "{status} is worth another attempt");
        }
        for status in [400, 401, 403, 404, 422] {
            assert!(!is_retryable(status), "{status} will not improve on a retry");
        }
    }

    #[test]
    fn cache_freshness_expires_with_its_ttl() {
        assert!(!is_fresh(None, QUOTA_TTL), "an unfetched cache is never fresh");
        assert!(is_fresh(Some(Instant::now()), QUOTA_TTL));
        assert!(!is_fresh(
            Some(Instant::now() - QUOTA_TTL - Duration::from_secs(1)),
            QUOTA_TTL
        ));
        assert_eq!(QUOTA_TTL, Duration::from_secs(60));
    }

    #[test]
    fn the_request_model_picks_the_bucket_group_it_spends() {
        assert_eq!(
            bucket_group(br#"{"model":"gemini-3.8-flash-high","request":{}}"#),
            "gemini"
        );
        assert_eq!(
            bucket_group(br#"{"model":"claude-opus-4-6-thinking","request":{}}"#),
            "3p"
        );
        assert_eq!(bucket_group(br#"{"model":"gpt-oss-120b-medium"}"#), "3p");
    }

    #[test]
    fn an_account_is_used_up_when_a_bucket_of_its_group_reads_zero() {
        let quota = json!({"accounts": [{
            "name": "ann",
            "groups": [
                {"buckets": [
                    {"bucketId": "gemini-weekly", "remainingFraction": 0.98},
                    {"bucketId": "gemini-5h", "remainingFraction": 0.0}
                ]},
                {"buckets": [
                    {"bucketId": "3p-weekly", "remainingFraction": 0.73},
                    {"bucketId": "3p-5h", "remainingFraction": 0.19}
                ]}
            ]
        }]});

        assert!(is_used_up(&quota, "ann", "gemini"), "its 5-hour gemini bucket is empty");
        assert!(!is_used_up(&quota, "ann", "3p"), "both claude buckets still have room");
        assert!(!is_used_up(&quota, "bob", "gemini"), "an account with no reading is not skipped");
        assert!(!is_used_up(&Value::Null, "ann", "gemini"), "no quota reading skips nobody");
    }

    #[test]
    fn the_last_account_in_line_is_never_skipped() {
        assert!(has_next(0, 3), "the first of three can skip to the second");
        assert!(has_next(1, 3), "the second of three can skip to the third");
        assert!(!has_next(2, 3), "the last of three is tried whatever its quota reads");
        assert!(!has_next(0, 1), "a lone account is always the last in line");
    }

    #[test]
    fn the_retry_delay_is_a_flat_half_second() {
        assert_eq!(RETRY_DELAY, Duration::from_millis(500));
    }

    #[test]
    fn the_retry_ladder_fits_inside_the_budget() {
        let waiting = RETRY_DELAY * (MAX_ATTEMPTS as u32 - 1);
        assert!(
            waiting <= RETRY_BUDGET,
            "{MAX_ATTEMPTS} attempts spend {waiting:?} waiting, over the {RETRY_BUDGET:?} budget"
        );
    }

    #[test]
    fn a_404_retries_on_the_previous_model_generation() {
        let body = br#"{"project":"p","model":"gemini-3.8-flash-medium","request":{}}"#;
        let retry = fallback_payload(body).expect("a fallback generation exists");
        let parsed: Value = serde_json::from_slice(&retry).expect("valid json");
        assert_eq!(parsed["model"], "gemini-3.7-flash-medium");
        assert_eq!(parsed["project"], "p");

        let terminal = br#"{"model":"claude-sonnet-4-6"}"#;
        assert!(fallback_payload(terminal).is_none());
    }
}
