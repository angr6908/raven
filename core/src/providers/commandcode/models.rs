use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, PoisonError, RwLock};
use std::time::{Duration, Instant};

use crate::app::App;
use crate::state::accounts::Channel;
use crate::state::failed;


const MODEL_CACHE_TTL: Duration = Duration::from_secs(5 * 60);
const ALIAS_PREFIX: &str = "cc-";

#[derive(Debug, Clone, Deserialize)]
pub struct CommandCodeModel {
    #[serde(default)]
    pub id: String,
}

#[derive(Debug, Deserialize)]
pub struct CommandCodeModelList {
    #[serde(default)]
    pub data: Vec<CommandCodeModel>,
}

#[derive(Default)]
struct Cache {
    models: Vec<CommandCodeModel>,
    aliases: HashMap<String, String>,
    fetched: Option<Instant>,
}

pub struct ModelCache {
    client: reqwest::Client,
    url: String,
    agent: String,
    cache: RwLock<Cache>,
}

impl ModelCache {
    pub fn new(client: reqwest::Client, settings: &super::Settings, agent: String) -> Self {
        Self {
            client,
            url: settings.url("/provider/v1/models"),
            agent,
            cache: RwLock::new(Cache::default()),
        }
    }

    fn is_fresh(cache: &Cache) -> bool {
        cache.fetched.is_some_and(|t| t.elapsed() < MODEL_CACHE_TTL)
    }

    async fn with_fresh_cache<T>(&self, read: impl Fn(&Cache) -> T) -> T {
        {
            let cache = self.cache.read().unwrap_or_else(PoisonError::into_inner);
            if !cache.models.is_empty() && Self::is_fresh(&cache) {
                return read(&cache);
            }
        }

        if let Ok(models) = self.fetch().await {
            let mut cache = self.cache.write().unwrap_or_else(PoisonError::into_inner);
            cache.aliases = build_aliases(&models);
            cache.fetched = Some(Instant::now());
            cache.models = models;
        }
        read(&self.cache.read().unwrap_or_else(PoisonError::into_inner))
    }

    pub async fn resolve(&self, model: &str) -> String {
        let key = model.to_lowercase();
        self.with_fresh_cache(|cache| cache.aliases.get(&key).cloned())
            .await
            .unwrap_or_else(|| model.to_string())
    }

    pub async fn list(&self) -> Vec<String> {
        self.with_fresh_cache(|cache| cache.models.iter().map(|m| m.id.clone()).collect())
            .await
    }

    async fn fetch(&self) -> Result<Vec<CommandCodeModel>, String> {
        let list: CommandCodeModelList = crate::net::fetch::send_json(
            self.client
                .get(&self.url)
                .header("Accept", "application/json")
                .header("User-Agent", &self.agent),
            "fetch models",
        )
        .await?;
        if list.data.is_empty() {
            return Err("fetch models: empty catalog".to_string());
        }
        Ok(list.data)
    }
}

fn build_aliases(models: &[CommandCodeModel]) -> HashMap<String, String> {
    let mut counts: HashMap<String, usize> = HashMap::new();
    let mut candidates: Vec<HashSet<String>> = Vec::with_capacity(models.len());

    for model in models {
        let names: HashSet<String> = alias_names(&model.id);
        for name in &names {
            *counts.entry(name.clone()).or_default() += 1;
        }
        candidates.push(names);
    }

    let mut aliases = HashMap::new();
    for (model, names) in models.iter().zip(candidates) {
        for name in names {
            if counts.get(&name) == Some(&1) {
                aliases.insert(name, model.id.clone());
            }
        }
    }
    aliases
}

fn alias_names(id: &str) -> HashSet<String> {
    let lower = id.to_lowercase();
    let mut names = HashSet::from([lower.clone(), format!("{ALIAS_PREFIX}{lower}")]);
    if let Some((_, base)) = lower.rsplit_once('/') {
        if !base.is_empty() {
            names.insert(base.to_string());
            names.insert(format!("{ALIAS_PREFIX}{base}"));
        }
    }
    names
}

pub async fn handle_catalog(State(app): State<Arc<App>>) -> Response {
    let ids = app.models.list().await;
    if ids.is_empty() {
        return failed(
            StatusCode::BAD_GATEWAY,
            "upstream_error",
            "commandcode catalog unavailable (upstream fetch failed)",
        );
    }
    let models: Vec<Value> = ids
        .into_iter()
        .map(|id| {
            json!({
                "id": id,
                "display_name": id,
                "owned_by": Channel::Commandcode.as_str(),
            })
        })
        .collect();
    (StatusCode::OK, Json(json!({ "models": models }))).into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aliases_include_bare_and_cc_names_without_ambiguity() {
        let models = vec![
            CommandCodeModel {
                id: "vendor/model-one".to_string(),
            },
            CommandCodeModel {
                id: "other/model-one".to_string(),
            },
        ];
        let aliases = build_aliases(&models);
        assert_eq!(
            aliases.get("cc-vendor/model-one").map(String::as_str),
            Some("vendor/model-one")
        );
        assert_eq!(aliases.get("cc-model-one"), None, "bare name is ambiguous");
        assert_eq!(aliases.get("model-one"), None, "bare name is ambiguous");
    }
}
