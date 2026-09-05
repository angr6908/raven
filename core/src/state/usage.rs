use axum::Json;
use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use chrono::{DateTime, SecondsFormat, Timelike, Utc};
use crate::app::App;
use crate::net::sse::sse_headers;
use crate::net::{ApiJson, ListEnvelope};
use crate::translate::collect::Collector;
use crate::translate::ids::uuid_v4;
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::collections::HashMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use std::time::Instant;
use super::failed;

pub const USAGE_MAX_RECORDS: usize = 2000;
pub const USAGE_JSONL: &str = "usage.jsonl";

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct TokenBreakdown {
    #[serde(default)]
    pub input: InputBreakdown,
    #[serde(default)]
    pub output: OutputBreakdown,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct InputBreakdown {
    #[serde(default)]
    pub total_tokens: i64,
    #[serde(default)]
    pub cache_read_tokens: i64,
    #[serde(default)]
    pub cache_write_tokens: i64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct OutputBreakdown {
    #[serde(default)]
    pub total_tokens: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct UsageRecord {
    pub id: String,
    pub timestamp: String,
    pub account: String,
    pub model: String,
    pub upstream_model: String,
    pub stream: bool,
    pub status: u16,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub error: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub cached_tokens: i64,
    pub total_tokens: i64,
    pub cache_read_rate: f64,
    pub latency_ms: i64,
    pub ttft_ms: i64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reasoning_effort: String,
    pub finish_reason: String,
    pub cost_usd: f64,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub provider: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub alias: String,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub request_id: String,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_breakdown: Option<TokenBreakdown>,
}

impl UsageEvent {
    pub fn set_account(&mut self, account: &str) {
        self.account = account.to_string();
    }
}

pub struct UsageEvent {
    id: String,
    account: String,
    model: String,
    upstream: String,
    stream: bool,
    effort: String,
    start: Instant,
    start_utc: DateTime<Utc>,
    first_byte: Option<Instant>,

    alias: String,

    provider: String,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PriceEntry {
    #[serde(default)]
    pub input: f64,
    #[serde(default)]
    pub output: f64,
    #[serde(default)]
    pub cached: f64,
    #[serde(default)]
    pub input_peak: f64,
    #[serde(default)]
    pub output_peak: f64,
    #[serde(default)]
    pub cached_peak: f64,

    #[serde(default)]
    pub peak_windows: Option<Vec<[u32; 2]>>,
}

impl PriceEntry {
    fn in_peak_hour(&self, hour: u32) -> bool {
        match &self.peak_windows {
            Some(windows) => windows.iter().any(|[start, end]| {
                if start < end {
                    hour >= *start && hour < *end
                } else {
                    hour >= *start || hour < *end
                }
            }),
            None => (1..4).contains(&hour) || (6..10).contains(&hour),
        }
    }
}

struct Records {
    records: Vec<UsageRecord>,
    file: Option<File>,
}

pub struct UsageRecorder {
    state: Mutex<Records>,
    prices: Mutex<HashMap<String, PriceEntry>>,
    dir: PathBuf,

    sender: tokio::sync::broadcast::Sender<UsageRecord>,
}

impl UsageRecorder {
    pub fn new(dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(dir).map_err(|err| format!("usage dir: {err}"))?;

        let records: Vec<UsageRecord> = replay_jsonl(&dir.join(USAGE_JSONL), USAGE_MAX_RECORDS);

        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(dir.join(USAGE_JSONL))
            .map_err(|err| format!("usage file: {err}"))?;

        let mut prices = default_prices();
        if let Ok(data) = fs::read(dir.join("prices.json")) {
            if let Ok(custom) = serde_json::from_slice::<HashMap<String, PriceEntry>>(&data) {
                prices.extend(normalize_prices(custom));
            }
        }

        let (sender, _receiver) = tokio::sync::broadcast::channel(512);

        Ok(Self {
            state: Mutex::new(Records {
                records,
                file: Some(file),
            }),
            prices: Mutex::new(prices),
            dir: dir.to_owned(),
            sender,
        })
    }

    pub fn subscribe(&self) -> tokio::sync::broadcast::Receiver<UsageRecord> {
        self.sender.subscribe()
    }

    pub fn begin(
        &self,
        model: &str,
        upstream: &str,
        stream: bool,
        effort: &str,
        account: &str,
    ) -> UsageEvent {
        UsageEvent {
            id: uuid_v4(),
            account: account.to_string(),
            model: model.to_string(),
            upstream: upstream.to_string(),
            stream,
            effort: effort.to_string(),
            start: Instant::now(),
            start_utc: Utc::now(),
            first_byte: None,
            alias: String::new(),
            provider: String::new(),
        }
    }

    pub fn describe(&self, event: &mut UsageEvent, alias: &str, provider: &str) {
        event.alias = alias.to_string();
        event.provider = provider.to_string();
    }

    pub fn mark_first_byte(&self, event: &mut UsageEvent, at: Instant) {
        event.first_byte.get_or_insert(at);
    }

    pub fn end(
        &self,
        event: &mut UsageEvent,
        state: Option<&Collector>,
        status: u16,
        error: &str,
        finish: &str,
    ) {
        let record = self.build(event, state, status, error, finish);
        let line = serde_json::to_vec(&record).ok().map(|mut data| {
            data.push(b'\n');
            data
        });
        {
            let mut state = match self.state.lock() {
                Ok(guard) => guard,
                Err(_) => return,
            };
            state.records.push(record.clone());
            if state.records.len() > USAGE_MAX_RECORDS {
                let cut = state.records.len() - USAGE_MAX_RECORDS;
                state.records.drain(..cut);
            }
            if let (Some(file), Some(data)) = (state.file.as_mut(), line.as_ref()) {
                if let Err(err) = file.write_all(data) {
                    eprintln!("usage write: {err}");
                }
            }
        }

        let _ = self.sender.send(record);
    }

    fn build(
        &self,
        event: &UsageEvent,
        state: Option<&Collector>,
        status: u16,
        error: &str,
        finish: &str,
    ) -> UsageRecord {
        let latency_ms = event.start.elapsed().as_millis() as i64;
        let ttft_ms = event
            .first_byte
            .and_then(|first| first.checked_duration_since(event.start))
            .map(|elapsed| (elapsed.as_millis() as i64).clamp(0, latency_ms.max(0)))
            .unwrap_or(0);
        let mut record = UsageRecord {
            id: event.id.clone(),
            timestamp: event.start_utc.to_rfc3339_opts(SecondsFormat::Secs, true),
            account: event.account.clone(),
            model: event.model.clone(),
            upstream_model: event.upstream.clone(),
            stream: event.stream,
            status,
            error: error.to_string(),
            input_tokens: 0,
            output_tokens: 0,
            cached_tokens: 0,
            total_tokens: 0,
            cache_read_rate: 0.0,
            latency_ms,
            ttft_ms,
            reasoning_effort: event.effort.clone(),
            finish_reason: finish.to_string(),
            cost_usd: 0.0,
            provider: event.provider.clone(),
            alias: event.alias.clone(),
            request_id: event.id.clone(),
            token_breakdown: None,
        };
        if let Some(collector) = state {
            record.input_tokens = collector.usage_input();
            record.output_tokens = collector.usage_output();
            record.cached_tokens = collector.cached_tokens();
            record.total_tokens = collector.total_tokens();
            if record.input_tokens > 0 {
                record.cache_read_rate = record.cached_tokens as f64 / record.input_tokens as f64;
            }
            if record.finish_reason.is_empty() {
                record.finish_reason = collector.finish_reason();
            }
            let cache_write = collector.cache_write_tokens();
            if cache_write > 0 || record.cached_tokens > 0 {
                record.token_breakdown = Some(TokenBreakdown {
                    input: InputBreakdown {
                        total_tokens: record.input_tokens,
                        cache_read_tokens: record.cached_tokens,
                        cache_write_tokens: cache_write,
                    },
                    output: OutputBreakdown {
                        total_tokens: record.output_tokens,
                    },
                });
            }
        }
        record.cost_usd = self.cost(&record);
        record
    }

    pub fn cost(&self, record: &UsageRecord) -> f64 {
        let Ok(prices) = self.prices.lock() else {
            return 0.0;
        };
        cost_with(&prices, record)
    }

    pub fn query(&self, account: Option<&str>) -> Vec<UsageRecord> {
        let Ok(state) = self.state.lock() else {
            return Vec::new();
        };
        let prices = self.prices.lock().ok();
        state
            .records
            .iter()
            .rev()
            .filter(|record| account.is_none_or(|name| record.account == name))
            .map(|record| {
                let mut record = record.clone();
                if let Some(prices) = prices.as_deref() {
                    record.cost_usd = cost_with(prices, &record);
                }
                record
            })
            .collect()
    }

    pub fn prices(&self) -> HashMap<String, PriceEntry> {
        match self.prices.lock() {
            Ok(guard) => guard.clone(),
            Err(_) => HashMap::new(),
        }
    }

    pub fn set_prices(&self, new: HashMap<String, PriceEntry>) -> Result<(), String> {
        let next = normalize_prices(new);
        {
            let mut guard = self
                .prices
                .lock()
                .map_err(|_| "prices mutex poisoned".to_string())?;
            *guard = next;
        }

        let data = serde_json::to_vec_pretty(&self.prices())
            .map_err(|err| format!("marshal prices: {err}"))?;
        fs::write(self.dir.join("prices.json"), data)
            .map_err(|err| format!("write {}: {err}", self.dir.join("prices.json").display()))
    }

    pub fn clear(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.records.clear();
        }
        if let Ok(mut file) = OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .open(self.dir.join(USAGE_JSONL))
        {
            let _ = file.write_all(b"");
        }
    }

    pub fn close(&self) {
        if let Ok(mut state) = self.state.lock() {
            state.file.take();
        }
    }
}

fn normalize_prices(raw: HashMap<String, PriceEntry>) -> HashMap<String, PriceEntry> {
    raw.into_iter()
        .filter_map(|(key, entry)| {
            let key = key.trim().to_lowercase();
            if key.is_empty() {
                return None;
            }
            Some((key, entry))
        })
        .collect()
}

fn replay_jsonl<T: serde::de::DeserializeOwned>(path: &Path, max: usize) -> Vec<T> {
    let Ok(data) = fs::read(path) else {
        return Vec::new();
    };
    let mut records: Vec<T> = String::from_utf8_lossy(&data)
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect();
    if records.len() > max {
        records.drain(..records.len() - max);
    }
    records
}

fn cost_with(prices: &HashMap<String, PriceEntry>, record: &UsageRecord) -> f64 {
    let Some(price) = [&record.alias, &record.model, &record.upstream_model]
        .into_iter()
        .filter(|name| !name.is_empty())
        .find_map(|name| prices.get(&name.to_lowercase()))
    else {
        return 0.0;
    };

    let peak_active = price.input_peak > 0.0
        && parse_utc_hour(&record.timestamp).is_some_and(|h| price.in_peak_hour(h));
    let (input_rate, output_rate, cache_rate) = if peak_active {
        (price.input_peak, price.output_peak, price.cached_peak)
    } else {
        (price.input, price.output, price.cached)
    };

    let uncached = (record.input_tokens - record.cached_tokens).max(0);
    let input_cost = if record.cached_tokens > 0 && cache_rate == 0.0 {
        record.input_tokens as f64 * input_rate
    } else {
        uncached as f64 * input_rate + record.cached_tokens as f64 * cache_rate
    };
    (input_cost + record.output_tokens as f64 * output_rate) / 1_000_000.0
}

fn parse_utc_hour(rfc3339: &str) -> Option<u32> {
    DateTime::parse_from_rfc3339(rfc3339)
        .ok()
        .map(|ts| ts.with_timezone(&Utc).hour())
}

pub fn default_prices() -> HashMap<String, PriceEntry> {
    HashMap::from([
        (
            "deepseek/deepseek-v4-pro".to_string(),
            PriceEntry {
                input: 0.66,
                output: 1.98,
                cached: 0.022,
                input_peak: 1.32,
                output_peak: 3.96,
                cached_peak: 0.044,
                ..PriceEntry::default()
            },
        ),
        (
            "deepseek/deepseek-v4-flash".to_string(),
            PriceEntry {
                input: 0.22,
                output: 0.66,
                cached: 0.007,
                input_peak: 0.44,
                output_peak: 1.32,
                cached_peak: 0.014,
                ..PriceEntry::default()
            },
        ),
    ])
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_deepseek_peak_windows() {
        let default = PriceEntry::default();
        let peak_at = |ts: &str| default.in_peak_hour(parse_utc_hour(ts).unwrap());
        assert!(peak_at("2026-08-19T02:00:00Z"));
        assert!(peak_at("2026-08-19T08:00:00Z"));
        assert!(!peak_at("2026-08-19T12:00:00Z"));
    }

    #[test]
    fn records_ttft_between_start_and_end() {
        let dir = std::env::temp_dir().join(format!("raven-usage-ttft-{}", std::process::id()));
        let recorder = UsageRecorder::new(&dir).unwrap();
        let mut event = recorder.begin("m", "u", true, "", "acct");

        std::thread::sleep(std::time::Duration::from_millis(50));
        let first = Instant::now();
        recorder.mark_first_byte(&mut event, first);
        recorder.mark_first_byte(
            &mut event,
            Instant::now() + std::time::Duration::from_secs(3600),
        );
        std::thread::sleep(std::time::Duration::from_millis(20));
        recorder.end(&mut event, None, 200, "", "stop");
        let rows = recorder.query(None);
        assert_eq!(rows.len(), 1);
        let row = &rows[0];
        assert!(row.ttft_ms >= 50, "ttft recorded: {}", row.ttft_ms);
        assert!(
            row.ttft_ms < row.latency_ms,
            "ttft {} < latency {}",
            row.ttft_ms,
            row.latency_ms
        );
        drop(recorder);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn ttft_stays_zero_without_a_mark() {
        let dir = std::env::temp_dir().join(format!("raven-usage-ttft-none-{}", std::process::id()));
        let recorder = UsageRecorder::new(&dir).unwrap();
        let mut event = recorder.begin("m", "u", false, "", "acct");
        recorder.end(&mut event, None, 200, "", "stop");
        let rows = recorder.query(None);
        assert_eq!(rows[0].ttft_ms, 0);
        drop(recorder);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn prices_unknown_models_as_zero() {
        let dir = std::env::temp_dir().join(format!(
            "raven-usage-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let recorder = UsageRecorder::new(&dir).unwrap();
        let record = UsageRecord {
            id: "id".to_string(),
            timestamp: "2026-08-19T12:00:00Z".to_string(),
            account: "default".to_string(),
            model: "unknown/model".to_string(),
            upstream_model: "unknown/model".to_string(),
            stream: false,
            status: 200,
            error: String::new(),
            input_tokens: 100,
            output_tokens: 10,
            cached_tokens: 10,
            total_tokens: 110,
            cache_read_rate: 0.1,
            latency_ms: 1,
            ttft_ms: 0,
            reasoning_effort: String::new(),
            finish_reason: "stop".to_string(),
            cost_usd: 0.0,
            provider: String::new(),
            alias: String::new(),
            request_id: String::new(),
            token_breakdown: None,
        };
        assert_eq!(recorder.cost(&record), 0.0);
        drop(recorder);
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn prices_by_alias_before_upstream_model() {
        let prices = HashMap::from([(
            "gpt-5.3@workbuddy".to_string(),
            PriceEntry {
                input: 1.0,
                output: 2.0,
                cached: 0.5,
                ..PriceEntry::default()
            },
        )]);
        let record = UsageRecord {
            id: "id".to_string(),
            timestamp: "2026-08-19T12:00:00Z".to_string(),
            account: "workbuddy".to_string(),
            model: "gpt-5.3@workbuddy".to_string(),
            upstream_model: "gpt-5.3-tiered".to_string(),
            stream: true,
            status: 200,
            error: String::new(),
            input_tokens: 1_000_000,
            output_tokens: 1_000_000,
            cached_tokens: 500_000,
            total_tokens: 2_000_000,
            cache_read_rate: 0.5,
            latency_ms: 1,
            ttft_ms: 0,
            reasoning_effort: String::new(),
            finish_reason: "stop".to_string(),
            cost_usd: 0.0,
            provider: "workbuddy".to_string(),
            alias: "GPT-5.3@Workbuddy".to_string(),
            request_id: String::new(),
            token_breakdown: None,
        };

        assert!((cost_with(&prices, &record) - 2.75).abs() < 1e-9);
    }
}

pub async fn handle_list(
    State(state): State<Arc<App>>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let records = state.usage.query(params.get("account").map(String::as_str));
    (StatusCode::OK, Json(ListEnvelope::new(&records))).into_response()
}

pub async fn handle_prices(State(state): State<Arc<App>>) -> Response {
    (
        StatusCode::OK,
        Json(json!({ "prices": state.usage.prices() })),
    )
        .into_response()
}

pub async fn handle_prices_save(
    State(state): State<Arc<App>>,
    ApiJson(prices): ApiJson<HashMap<String, crate::state::usage::PriceEntry>>,
) -> Response {
    match state.usage.set_prices(prices) {
        Ok(()) => (StatusCode::OK, Json(json!({"ok": true}))).into_response(),
        Err(err) => failed(StatusCode::BAD_REQUEST, "invalid_request_error", &err),
    }
}

pub async fn handle_clear(State(state): State<Arc<App>>) -> Response {
    state.usage.clear();
    (StatusCode::OK, Json(json!({ "ok": true, "cleared": true }))).into_response()
}

pub async fn handle_stream(State(state): State<Arc<App>>) -> Response {
    use axum::body::Body;

    let rx = state.usage.subscribe();

    let sse_stream = async_stream::stream! {
        yield Ok::<String, std::convert::Infallible>("event: ready\ndata: {}\n\n".to_string());
        let mut rx = rx;

        let mut interval = tokio::time::interval(Duration::from_secs(5));
        interval.tick().await;
        loop {
            tokio::select! {
                rec = rx.recv() => {
                    match rec {
                        Ok(record) => {
                            if let Ok(payload) = serde_json::to_string(&record) {
                                yield Ok(format!("event: record\ndata: {payload}\n\n"));
                            }
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Lagged(n)) => {
                            eprintln!("[usage:sse] lagged {n} records");
                            continue;
                        }
                        Err(tokio::sync::broadcast::error::RecvError::Closed) => break,
                    }
                }
                _ = interval.tick() => {
                    yield Ok(": ping\n\n".to_string());
                }
            }
        }
    };

    let body = Body::from_stream(sse_stream);

    (StatusCode::OK, sse_headers(), body).into_response()
}
