use chrono::Utc;
use crate::state::accounts::Account;
use serde::Deserialize;
use serde::Serialize;
use std::collections::HashMap;
use std::sync::{PoisonError, RwLock};
use std::time::{Duration, Instant};

const LIMITS_TTL: Duration = Duration::from_secs(5 * 60);

const FETCH_TIMEOUT: Duration = Duration::from_secs(15);
const SESSION_COOKIE: &str = "__Secure-commandcode_prod_.session_token=";

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
}

impl AccountLimits {
    pub fn new(client: reqwest::Client, agent: String, settings: super::Settings) -> Self {
        Self {
            cache: RwLock::new(HashMap::new()),
            client,
            agent,
            api_base: settings.api_base,
        }
    }

    pub async fn invalidate(&self, name: &str) {
        self.cache
            .write()
            .unwrap_or_else(PoisonError::into_inner)
            .remove(name);
    }

    pub async fn get(&self, account: &Account) -> LimitsData {
        if !account.has_live_credentials() {
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

        let fetched = fetch_live_limits(account, &self.client, &self.agent, &self.api_base).await;
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
                if let Some(cached) = cache.get(&account.name) {
                    cached.data.clone()
                } else {
                    stored(account)
                }
            }
        }
    }
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
    if account.session_token.is_empty() {
        return Err(format!(
            "account {:?} has no session cookie (set session_token)",
            account.name
        ));
    }
    let cookie = format!("{SESSION_COOKIE}{}", account.session_token);

    let credits = get_billing_credits(client, agent, &cookie, api_base).await?;
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

    Ok(LimitsData {
        monthly_credits: credits.credits.monthly_credits,
        five_hour_cap,
        five_hour_used,
        five_hour_reset_at,
        weekly_cap,
        weekly_used,
        weekly_reset_at,
        purchased_credits: credits.credits.purchased_credits,
        source: "live".to_string(),
        fetched_at: fetched_now(),
        ..stored(account)
    })
}

async fn get_billing_credits(
    client: &reqwest::Client,
    agent: &str,
    cookie: &str,
    api_base: &str,
) -> Result<BillingCredits, String> {
    crate::net::fetch::send_json(
        client
            .get(format!("{api_base}/internal/billing/credits"))
            .header("Accept", "application/json")
            .header("Cookie", cookie)
            .header("User-Agent", agent)
            .timeout(FETCH_TIMEOUT),
        "credits",
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
