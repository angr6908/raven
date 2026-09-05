pub mod limits;
pub mod models;

use axum::body::Bytes;
use axum::http::{header, StatusCode};
use std::time::Duration;

use crate::app::App;
use crate::net::error::ApiError;
use crate::state::accounts::Channel;
use self::limits::LimitsData;
use crate::translate::generate::types::GenerateErrorEnvelope;

use super::{SendFailure, Sent};

pub const DEFAULT_API_BASE: &str = "https://api.commandcode.ai";
pub const DEFAULT_CLI_VERSION: &str = "0.29.0";
pub const API_BASE_ENV: &str = "COMMANDCODE_API_BASE";

#[derive(Clone)]
pub struct Settings {
    pub api_base: String,
    pub cli_version: String,
}

impl Settings {
    pub fn resolve(api_base_flag: &str, cli_version_flag: &str) -> Self {
        let api_base = match api_base_flag.is_empty() {
            true => std::env::var(API_BASE_ENV).unwrap_or_else(|_| DEFAULT_API_BASE.to_string()),
            false => api_base_flag.to_string(),
        };
        let cli_version = match cli_version_flag.is_empty() {
            true => DEFAULT_CLI_VERSION.to_string(),
            false => cli_version_flag.to_string(),
        };
        Self {
            api_base: api_base.trim_end_matches('/').to_string(),
            cli_version,
        }
    }

    pub fn url(&self, path: &str) -> String {
        format!("{}{path}", self.api_base)
    }
}

const MAX_ATTEMPTS: usize = 3;
const RETRY_BASE_DELAY: Duration = Duration::from_millis(500);
const RESPONSE_TIMEOUT: Duration = Duration::from_secs(5 * 60);

struct Credential {
    name: String,
    key: String,
}

fn headroom(limits: &LimitsData) -> f64 {
    let mut headroom = 1.0f64;
    if limits.monthly_cap > 0.0 {
        let remaining =
            (limits.monthly_credits + limits.purchased_credits).max(0.0) / limits.monthly_cap;
        headroom = headroom.min(remaining);
    }
    if limits.five_hour_cap > 0.0 {
        let remaining =
            (limits.five_hour_cap - limits.five_hour_used).max(0.0) / limits.five_hour_cap;
        headroom = headroom.min(remaining);
    }
    if limits.weekly_cap > 0.0 {
        let remaining = (limits.weekly_cap - limits.weekly_used).max(0.0) / limits.weekly_cap;
        headroom = headroom.min(remaining);
    }
    headroom.clamp(0.0, 1.0)
}

async fn pool(app: &App) -> Vec<Credential> {
    let mut scored: Vec<(f64, String, String)> = Vec::new();
    for account in app.accounts.list() {
        if account.channel() != Some(Channel::Commandcode)
            || account.disabled
            || account.key.is_empty()
        {
            continue;
        }
        let headroom = headroom(&app.limits.get(&account).await);
        if headroom <= 0.0 {
            continue;
        }
        scored.push((headroom, account.name.clone(), account.key.clone()));
    }
    scored.sort_by(|a, b| {
        a.0.partial_cmp(&b.0)
            .unwrap_or(std::cmp::Ordering::Equal)
            .then_with(|| a.1.cmp(&b.1))
    });
    scored
        .into_iter()
        .map(|(_, name, key)| Credential { name, key })
        .collect()
}

pub async fn send(app: &App, payload: Bytes) -> Result<Sent, SendFailure> {
    let pool = pool(app).await;
    if pool.is_empty() {
        return Err(SendFailure {
            account: String::new(),
            error: ApiError::coded(
                StatusCode::UNAUTHORIZED,
                "authentication_error",
                "no commandcode account with remaining credits; add one in the panel or via accounts.json",
            ),
        });
    }

    let mut last: Option<SendFailure> = None;
    for credential in &pool {
        let mut attempt = 1usize;
        loop {
            let error = match post(app, &credential.key, payload.clone()).await {
                Ok(response) if response.status().is_success() => {
                    return Ok(Sent {
                        account: credential.name.clone(),
                        response,
                    })
                }
                Ok(response) => upstream_error(response).await,
                Err(message) => ApiError::gateway("upstream_error", message),
            };
            eprintln!(
                "upstream {} -> {} {}: {}",
                credential.name,
                error.status_u16(),
                error.code,
                error.message
            );

            let switch_now = matches!(error.status_u16(), 401 | 402 | 429);
            if !switch_now && !retryable(error.status_u16()) {
                return Err(SendFailure {
                    account: credential.name.clone(),
                    error,
                });
            }
            last = Some(SendFailure {
                account: credential.name.clone(),
                error: error.clone(),
            });
            if switch_now || attempt >= MAX_ATTEMPTS {
                break;
            }
            eprintln!(
                "retry {} after {} {} (attempt {}/{MAX_ATTEMPTS})",
                credential.name,
                error.status_u16(),
                error.code,
                attempt + 1
            );
            tokio::time::sleep(RETRY_BASE_DELAY * attempt as u32).await;
            attempt += 1;
        }
        app.limits.invalidate(&credential.name).await;
    }
    Err(last.expect("a non-empty pool always records its last failure"))
}

fn retryable(status: u16) -> bool {
    matches!(status, 408 | 429 | 500 | 502 | 503 | 504)
}

async fn post(app: &App, api_key: &str, payload: Bytes) -> Result<reqwest::Response, String> {
    let request = app
        .client
        .post(app.commandcode.url("/alpha/generate"))
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {api_key}"))
        .header(header::USER_AGENT, &app.user_agent)
        .header("x-command-code-version", &app.commandcode.cli_version)
        .header("x-cli-environment", "production")
        .header("x-project-slug", &app.project_slug)
        .header("x-taste-learning", "true")
        .header("x-co-flag", "false")
        .body(payload)
        .send();

    match tokio::time::timeout(RESPONSE_TIMEOUT, request).await {
        Ok(Ok(response)) => Ok(response),
        Ok(Err(err)) => Err(format!("call upstream: {err}")),
        Err(_) => Err("call upstream: response header timeout".to_string()),
    }
}

async fn upstream_error(response: reqwest::Response) -> ApiError {
    let status = response.status();
    let bytes = response.bytes().await.unwrap_or_default();
    let raw = String::from_utf8_lossy(&bytes[..bytes.len().min(8192)]);

    if let Ok(envelope) = serde_json::from_str::<GenerateErrorEnvelope>(&raw) {
        if !envelope.error.message.is_empty() {
            let reported = envelope.error.status.unwrap_or(0);
            let status = match (400..=599).contains(&reported) {
                true => super::status_or_gateway(reported as u16),
                false => status,
            };
            let code = match envelope.error.code.is_empty() {
                true => "upstream_error".to_string(),
                false => envelope.error.code,
            };
            return ApiError::coded(status, &code, envelope.error.message);
        }
    }
    let message = raw.trim();
    let message = match message.is_empty() {
        true => status.to_string(),
        false => message.to_string(),
    };
    ApiError::coded(status, "upstream_error", message)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn limits(monthly_credits: f64, monthly_cap: f64, purchased: f64) -> LimitsData {
        LimitsData {
            name: "t".into(),
            provider: String::new(),
            plan: String::new(),
            monthly_credits,
            monthly_cap,
            five_hour_cap: 0.0,
            five_hour_used: 0.0,
            five_hour_reset_at: 0,
            weekly_cap: 0.0,
            weekly_used: 0.0,
            weekly_reset_at: 0,
            purchased_credits: purchased,
            source: String::new(),
            fetched_at: String::new(),
        }
    }

    #[test]
    fn unknown_limits_rank_as_full() {
        assert_eq!(headroom(&limits(0.0, 0.0, 0.0)), 1.0);
    }

    #[test]
    fn headroom_is_the_tightest_window() {
        let mut l = limits(25.0, 100.0, 0.0);
        l.five_hour_cap = 10.0;
        l.five_hour_used = 9.0;
        assert!((headroom(&l) - 0.1).abs() < 1e-9);
    }

    #[test]
    fn purchased_credits_count_toward_monthly_remaining() {
        let l = limits(10.0, 100.0, 40.0);
        assert!((headroom(&l) - 0.5).abs() < 1e-9);
    }

    #[test]
    fn exhausted_window_scores_zero() {
        let l = limits(0.0, 100.0, 0.0);
        assert_eq!(headroom(&l), 0.0);
    }
}
