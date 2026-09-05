use serde::Serialize;
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::Mutex;

const MODELS_DEV_URL: &str = "https://models.dev/api.json";
const CATALOG_TTL: Duration = Duration::from_secs(60 * 60);

const FETCH_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize)]
pub struct ModelLookup {
    pub source: String,
    pub input: Option<f64>,
    pub output: Option<f64>,
    pub cache_read: Option<f64>,
    pub cache_write: Option<f64>,

    pub efforts: Vec<String>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub context: Option<i64>,

    #[serde(skip_serializing_if = "Option::is_none")]
    pub peak_input: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peak_output: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub peak_cache_read: Option<f64>,
}

struct DeepSeekPrice {
    input: f64,
    output: f64,
    cache_read: f64,
    peak_input: f64,
    peak_output: f64,
    peak_cache_read: f64,
    efforts: &'static [&'static str],

    context: i64,
}

const DEEPSEEK_PRICES: &[(&str, DeepSeekPrice)] = &[
    (
        "deepseek flash v",
        DeepSeekPrice {
            input: 0.22,
            output: 0.66,
            cache_read: 0.007,
            peak_input: 0.44,
            peak_output: 1.32,
            peak_cache_read: 0.014,
            efforts: &["low", "high", "max"],
            context: 1_000_000,
        },
    ),
    (
        "deepseek pro v",
        DeepSeekPrice {
            input: 0.66,
            output: 1.98,
            cache_read: 0.022,
            peak_input: 1.32,
            peak_output: 3.96,
            peak_cache_read: 0.044,
            efforts: &["low", "high", "max"],
            context: 1_000_000,
        },
    ),
];

fn deepseek_override(query_alphas: &[String]) -> Option<&'static DeepSeekPrice> {
    DEEPSEEK_PRICES
        .iter()
        .filter(|(k, _)| k.split(' ').all(|w| query_alphas.iter().any(|a| a == w)))
        .max_by_key(|(k, _)| k.split(' ').count())
        .map(|(_, p)| p)
}

struct Cache {
    catalog: Option<Arc<serde_json::Value>>,
    fetched_at: Option<std::time::Instant>,
}

pub struct CatalogCache {
    client: reqwest::Client,
    cache: Mutex<Cache>,
}

impl CatalogCache {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .gzip(true)
            .connect_timeout(Duration::from_secs(30))
            .build()
            .unwrap_or_default();
        Self {
            client,
            cache: Mutex::new(Cache {
                catalog: None,
                fetched_at: None,
            }),
        }
    }

    async fn catalog(&self) -> Result<Arc<serde_json::Value>, String> {
        let mut cache = self.cache.lock().await;
        if let (Some(catalog), Some(at)) = (&cache.catalog, cache.fetched_at) {
            if at.elapsed() < CATALOG_TTL {
                return Ok(Arc::clone(catalog));
            }
        }
        let stale = cache.catalog.clone();
        match self.fetch().await {
            Ok(catalog) => {
                cache.catalog = Some(Arc::clone(&catalog));
                cache.fetched_at = Some(std::time::Instant::now());
                Ok(catalog)
            }

            Err(err) => match stale {
                Some(catalog) => {
                    eprintln!("models.dev refresh failed ({err}); serving stale catalog");
                    Ok(catalog)
                }
                None => Err(err),
            },
        }
    }

    async fn fetch(&self) -> Result<Arc<serde_json::Value>, String> {
        let res = self
            .client
            .get(MODELS_DEV_URL)
            .header("Accept", "application/json")
            .timeout(FETCH_TIMEOUT)
            .send()
            .await
            .map_err(|e| format!("models.dev request: {e}"))?;
        let res = crate::net::fetch::ok_or_status_err(res, "models.dev fetch").await?;
        let catalog: serde_json::Value = res
            .json()
            .await
            .map_err(|e| format!("models.dev decode: {e}"))?;
        Ok(Arc::new(catalog))
    }

    pub async fn lookup(&self, model: &str) -> Result<Option<ModelLookup>, String> {
        let wanted = model.trim();
        if wanted.is_empty() {
            return Ok(None);
        }
        let lower = wanted.to_lowercase();

        let base = lower.rsplit('/').next().unwrap_or(&lower).to_string();
        let query = fingerprint(&base);

        let stripped_query = fingerprint(&strip_variants(&base));

        if let Some(price) = deepseek_override(&stripped_query.alphas) {
            return Ok(Some(ModelLookup {
                source: "deepseek-canonical".to_string(),
                input: Some(price.input),
                output: Some(price.output),
                cache_read: Some(price.cache_read),
                cache_write: None,
                efforts: price.efforts.iter().map(|s| s.to_string()).collect(),
                context: Some(price.context),
                peak_input: Some(price.peak_input),
                peak_output: Some(price.peak_output),
                peak_cache_read: Some(price.peak_cache_read),
            }));
        }

        let catalog = self.catalog().await?;
        let Some(providers) = catalog.as_object() else {
            return Ok(None);
        };

        let mut candidates: Vec<(u8, usize, String, &serde_json::Value)> = Vec::new();
        for (slug, provider) in providers {
            if !is_canonical(slug) {
                continue;
            }
            let Some(models) = provider
                .get("models")
                .and_then(serde_json::Value::as_object)
            else {
                continue;
            };
            for (id, entry) in models {
                let id_base = id.rsplit('/').next().unwrap_or(id);
                let fp = fingerprint(id_base);

                if fp.alphas.is_empty() && fp.numerics.is_empty() {
                    continue;
                }
                let class = if fp == query {
                    0
                } else if fp == stripped_query {
                    1
                } else if fp.numerics == query.numerics
                    && query.alphas.iter().all(|a| fp.alphas.contains(a))
                    && (query.alphas.len() >= 2 || !query.numerics.is_empty())
                {
                    2
                } else {
                    continue;
                };
                let extra = fp.alphas.len().saturating_sub(query.alphas.len());
                candidates.push((class, extra, slug.clone(), entry));
            }
        }

        let Some((_, _, source, entry)) =
            candidates
                .into_iter()
                .min_by_key(|(class, extra, _slug, entry)| {
                    (*class, *extra, std::cmp::Reverse(completeness(entry)))
                })
        else {
            return Ok(None);
        };

        Ok(Some(ModelLookup {
            source,
            input: num(&entry, ["cost", "input"]),
            output: num(&entry, ["cost", "output"]),
            cache_read: num(&entry, ["cost", "cache_read"]),
            cache_write: num(&entry, ["cost", "cache_write"]),
            efforts: efforts(&entry),
            context: num(&entry, ["limit", "context"]).map(|v| v as i64),
            peak_input: None,
            peak_output: None,
            peak_cache_read: None,
        }))
    }
}

#[derive(Debug, PartialEq, Eq)]
struct Fingerprint {
    alphas: Vec<String>,

    numerics: String,
}

fn fingerprint(model: &str) -> Fingerprint {
    let mut name = model.trim().to_lowercase();

    if let Some(at) = name.find('@') {
        name.truncate(at);
    }

    for (len, with_dashes) in [(10usize, true), (8, false)] {
        if name.len() > len {
            let start = name.len() - len;
            let tail = &name[start..];
            let digit_ok =
                tail.chars().all(|c| c == '-' || c.is_ascii_digit()) && tail.starts_with('2');
            let dashes_ok = with_dashes == (tail.contains('-'));
            if digit_ok && dashes_ok {
                name.truncate(start);

                while name.ends_with('-') || name.ends_with('.') || name.ends_with('_') {
                    name.pop();
                }
                break;
            }
        }
    }

    let mut alphas: Vec<String> = Vec::new();
    let mut numerics = String::new();

    let lower = name;
    let mut chunks = Vec::new();
    let mut current = String::new();
    let mut last_was_digit: Option<bool> = None;
    for c in lower.chars() {
        if c.is_ascii_alphanumeric() {
            let digit = c.is_ascii_digit();
            if last_was_digit != Some(digit) && !current.is_empty() {
                chunks.push(std::mem::take(&mut current));
            }
            current.push(c);
            last_was_digit = Some(digit);
        } else {
            if !current.is_empty() {
                chunks.push(std::mem::take(&mut current));
            }
            last_was_digit = None;
        }
    }
    if !current.is_empty() {
        chunks.push(current);
    }

    for chunk in chunks {
        let noise = matches!(
            chunk.as_str(),
            "thinking"
                | "think"
                | "latest"
                | "v1"
                | "batch"
                | "free"
                | "none"
                | "minimal"
                | "low"
                | "medium"
                | "high"
                | "xhigh"
                | "max"
        ) || (chunk.len() == 8 && chunk.chars().all(|c| c.is_ascii_digit()));
        if noise {
            continue;
        }
        if chunk.chars().all(|c| c.is_ascii_digit()) {
            numerics.push_str(&chunk);
        } else if !alphas.contains(&chunk) {
            alphas.push(chunk);
        }
    }
    alphas.sort();
    Fingerprint { alphas, numerics }
}

fn strip_variants(name: &str) -> String {
    let mut out = name.trim().to_lowercase();
    loop {
        let before = out.clone();
        for suffix in ["-latest", "-exp"] {
            if let Some(stripped) = out.strip_suffix(suffix) {
                out = stripped.to_string();
            }
        }

        if let Some(pos) = out.rfind(|c: char| !c.is_ascii_digit()) {
            let tail = &out[pos + 1..];
            if tail.len() >= 3
                && tail.chars().all(|c| c.is_ascii_digit())
                && out[..=pos].ends_with('-')
                && pos + 1 < out.len()
            {
                let head_digits = out[..pos]
                    .chars()
                    .rev()
                    .take_while(|c| c.is_ascii_digit())
                    .count();
                if head_digits <= 1 {
                    out = out[..pos + 1].trim_end_matches('-').to_string();
                }
            }
        }
        if out == before {
            break;
        }
    }
    out
}

fn is_canonical(slug: &str) -> bool {
    matches!(
        slug,
        "anthropic"
            | "openai"
            | "google"
            | "google-vertex"
            | "google-vertex-anthropic"
            | "amazon-bedrock"
            | "azure"
            | "deepseek"
            | "xai"
            | "moonshotai"
            | "zai"
            | "minimax"
            | "qwen"
            | "alibaba"
            | "mistral"
            | "meta"
            | "nvidia"
            | "thinkingmachines"
            | "stepfun-ai"
            | "longcat"
    )
}

fn completeness(entry: &serde_json::Value) -> u8 {
    let cost = entry.get("cost");
    let mut score = 0u8;
    for key in ["input", "output", "cache_read", "cache_write"] {
        if cost
            .and_then(|c| c.get(key))
            .and_then(|v| v.as_f64())
            .is_some_and(|v| v > 0.0)
        {
            score += 1;
        }
    }
    if !efforts(entry).is_empty() {
        score += 1;
    }
    score
}

fn num(entry: &serde_json::Value, path: [&str; 2]) -> Option<f64> {
    entry.get(path[0])?.get(path[1]).and_then(|v| v.as_f64())
}

fn efforts(entry: &serde_json::Value) -> Vec<String> {
    entry
        .get("reasoning_options")
        .and_then(serde_json::Value::as_array)
        .map(|options| {
            options
                .iter()
                .filter_map(|o| {
                    if o.get("type").and_then(serde_json::Value::as_str) != Some("effort") {
                        return None;
                    }
                    o.get("values")
                        .and_then(serde_json::Value::as_array)
                        .map(|values| {
                            values
                                .iter()
                                .filter_map(serde_json::Value::as_str)
                                .map(str::to_string)
                                .collect::<Vec<_>>()
                        })
                })
                .flatten()
                .collect()
        })
        .unwrap_or_default()
}
