use crate::state::accounts::Account;
use chrono::Utc;
use serde::Deserialize;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{Arc, PoisonError, RwLock};
use std::time::{Duration, Instant};

const LIMITS_TTL: Duration = Duration::from_secs(5 * 60);

const FETCH_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_COOKIE: &str = "__Secure-commandcode_prod_.session_token=";
const CLI_CREDITS_PATH: &str = "/alpha/billing/credits";
const INTERNAL_CREDITS_PATH: &str = "/internal/billing/credits";

#[derive(Debug, Clone, Serialize)]
pub struct LimitsData {
    pub name: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub provider: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub plan: String,
    pub monthly_credits: f64,
    pub monthly_cap: f64,
    pub five_hour_cap: f64,
    pub five_hour_used: f64,
    pub five_hour_reset_at: i64,
    pub weekly_cap: f64,
    pub weekly_used: f64,
    pub weekly_reset_at: i64,
    pub purchased_credits: f64,
    pub source: String,
    pub fetched_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

struct CachedLimits {
    data: LimitsData,
    fetched: Instant,
}

pub struct AccountLimits {
    cache: RwLock<HashMap<String, CachedLimits>>,
    client: reqwest::Client,
    agent: String,
    api_base: String,
    accounts: Arc<crate::state::accounts::AccountsManager>,
}

impl AccountLimits {
    pub fn new(
        client: reqwest::Client,
        agent: String,
        settings: super::Settings,
        accounts: Arc<crate::state::accounts::AccountsManager>,
    ) -> Self {
        Self {
            cache: RwLock::new(HashMap::new()),
            client,
            agent,
            api_base: settings.api_base,
            accounts,
        }
    }

    pub async fn invalidate(&self, name: &str) {
        self.cache
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(name);
    }

    async fn fetch_current(&self, account: &Account) -> Result<LimitsData, String> {
        let current = self
            .accounts
            .list()
            .into_iter()
            .find(|candidate| candidate.name == account.name)
            .unwrap_or_else(|| account.clone());
        fetch_live_limits(&current, &self.client, &self.agent, &self.api_base).await
    }

    pub async fn get(&self, account: &Account) -> LimitsData {
        if account.key.is_empty() && !account.has_live_credentials() {
            return stored(account);
        }

        {
            let cache = self.cache.read().unwrap_or_else(PoisonError::into_inner);
            if let Some(cached) = cache.get(&account.name) {
                if cached.fetched.elapsed() < LIMITS_TTL {
                    return cached.data.clone();
                }
            }
        }

        let fetched = self.fetch_current(account).await;
        let mut cache = self.cache.write().unwrap_or_else(PoisonError::into_inner);
        match fetched {
            Ok(data) => {
                cache.insert(
                    account.name.clone(),
                    CachedLimits {
                        data: data.clone(),
                        fetched: Instant::now(),
                    },
                );
                data
            }
            Err(err) => {
                eprintln!("limits {:?}: {err} — serving stored values", account.name);
                let mut data = cache
                    .get(&account.name)
                    .map(|cached| cached.data.clone())
                    .unwrap_or_else(|| stored(account));
                let sign_in = needs_sign_in(&err);
                data.error = Some(err);
                if sign_in {
                    data.source = "reauth_required".to_string();
                }
                data
            }
        }
    }
}

fn needs_sign_in(error: &str) -> bool {
    error.contains("status 401") || error.contains("session is missing")
}

fn stored(account: &Account) -> LimitsData {
    LimitsData {
        name: account.name.clone(),
        provider: account.provider(),
        plan: account.plan.clone(),
        monthly_credits: crate::state::accounts::monthly_cap(account),
        monthly_cap: crate::state::accounts::monthly_cap(account),
        five_hour_cap: account.five_hour_cap,
        five_hour_used: 0.0,
        five_hour_reset_at: 0,
        weekly_cap: account.weekly_cap,
        weekly_used: 0.0,
        weekly_reset_at: 0,
        purchased_credits: 0.0,
        source: "stored".to_string(),
        fetched_at: String::new(),
        error: None,
    }
}

fn fetched_now() -> String {
    Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true)
}

async fn fetch_live_limits(
    account: &Account,
    client: &reqwest::Client,
    agent: &str,
    api_base: &str,
) -> Result<LimitsData, String> {
    if account.key.is_empty() && account.session_token.is_empty() {
        return Err(if account.password.is_empty() {
            "no API key or session cookie to read quota from".to_string()
        } else {
            "Command Code session is missing; sign in again".to_string()
        });
    }

    let mut errors: Vec<String> = Vec::new();
    if !account.key.is_empty() {
        match get_cli_credits(client, agent, &account.key, api_base).await {
            Ok(credits) => return Ok(limits_from(account, credits)),
            Err(err) => errors.push(err),
        }
    }
    if !account.session_token.is_empty() {
        let cookie = format!("{SESSION_COOKIE}{}", account.session_token);
        match get_web_credits(client, agent, &cookie, api_base).await {
            Ok(credits) => return Ok(limits_from(account, credits)),
            Err(err) => errors.push(err),
        }
    }
    Err(errors.join("; "))
}

fn limits_from(account: &Account, credits: BillingCredits) -> LimitsData {
    let WindowLimit {
        used: five_hour_used,
        cap: five_hour_cap,
        reset_at: five_hour_reset_at,
    } = credits.window_limits.five_hour;
    let WindowLimit {
        used: weekly_used,
        cap: weekly_cap,
        reset_at: weekly_reset_at,
    } = credits.window_limits.weekly;

    let monthly_cap = credits
        .credits
        .monthly_credits_granted
        .unwrap_or_else(|| crate::state::accounts::monthly_cap(account));

    LimitsData {
        monthly_credits: credits.credits.monthly_credits,
        monthly_cap,
        five_hour_cap,
        five_hour_used,
        five_hour_reset_at,
        weekly_cap,
        weekly_used,
        weekly_reset_at,
        purchased_credits: credits.credits.purchased_credits,
        source: "live".to_string(),
        fetched_at: fetched_now(),
        error: None,
        ..stored(account)
    }
}

async fn get_cli_credits(
    client: &reqwest::Client,
    agent: &str,
    api_key: &str,
    api_base: &str,
) -> Result<BillingCredits, String> {
    crate::net::fetch::send_json(
        client
            .get(format!("{api_base}{CLI_CREDITS_PATH}"))
            .header("Accept", "application/json")
            .header("Authorization", format!("Bearer {api_key}"))
            .header("User-Agent", agent)
            .timeout(FETCH_TIMEOUT),
        "cli credits",
    )
    .await
}

async fn get_web_credits(
    client: &reqwest::Client,
    agent: &str,
    cookie: &str,
    api_base: &str,
) -> Result<BillingCredits, String> {
    crate::net::fetch::send_json(
        client
            .get(format!("{api_base}{INTERNAL_CREDITS_PATH}"))
            .header("Accept", "application/json")
            .header("Cookie", cookie)
            .header("User-Agent", agent)
            .timeout(FETCH_TIMEOUT),
        "web credits",
    )
    .await
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct BillingCredits {
    #[serde(default)]
    pub credits: Credits,
    #[serde(default)]
    pub window_limits: WindowLimits,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Credits {
    #[serde(default)]
    pub monthly_credits: f64,
    #[serde(default)]
    pub purchased_credits: f64,
    #[serde(default)]
    pub monthly_credits_granted: Option<f64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowLimits {
    #[serde(default)]
    pub five_hour: WindowLimit,
    #[serde(default)]
    pub weekly: WindowLimit,
}

#[derive(Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WindowLimit {
    #[serde(default)]
    pub used: f64,
    #[serde(default)]
    pub cap: f64,
    #[serde(default)]
    pub reset_at: i64,
}

#[cfg(test)]
mod tests {
    use super::BillingCredits;

    #[test]
    fn billing_credits_deserialize_live_quota_fields() {
        let credits: BillingCredits = serde_json::from_str(
            r#"{"credits":{"monthlyCredits":7.962995042,"purchasedCredits":0,"monthlyCreditsGranted":10},"windowLimits":{"fiveHour":{"used":1.187026437,"cap":3,"resetAt":1790774128845},"weekly":{"used":1.219732282,"cap":6,"resetAt":1790835895394}}}"#,
        )
        .unwrap();

        assert_eq!(credits.credits.monthly_credits, 7.962995042);
        assert_eq!(credits.credits.purchased_credits, 0.0);
        assert_eq!(credits.credits.monthly_credits_granted, Some(10.0));
        assert_eq!(credits.window_limits.five_hour.used, 1.187026437);
        assert_eq!(credits.window_limits.five_hour.cap, 3.0);
        assert_eq!(credits.window_limits.five_hour.reset_at, 1790774128845);
        assert_eq!(credits.window_limits.weekly.used, 1.219732282);
        assert_eq!(credits.window_limits.weekly.cap, 6.0);
        assert_eq!(credits.window_limits.weekly.reset_at, 1790835895394);
    }
}
