use axum::Json;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use crate::app::App;
use crate::net::ApiJson;
use serde_json::Value;
use serde_json::json;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::Mutex;
use std::time::Duration;
use super::failed;

pub const MANAGEMENT_TIMEOUT: Duration = Duration::from_secs(5);
pub const PROVIDERS_JSON: &str = "providers.json";

#[derive(Debug, Clone)]
pub struct Entry {
    pub provider: Value,
    pub model: Value,
}

impl Entry {
    pub fn provider_name(&self) -> &str {
        self.provider
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
    }

    pub fn upstream_model<'a>(&'a self, fallback: &'a str) -> &'a str {
        self.model
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or(fallback)
    }
}

pub struct Store {
    path: PathBuf,
    providers: Mutex<Vec<Value>>,
}

impl Store {
    pub fn new(dir: &Path) -> Result<Self, String> {
        fs::create_dir_all(dir).map_err(|err| format!("providers dir: {err}"))?;
        let path = dir.join(PROVIDERS_JSON);
        let providers = match fs::read(&path) {
            Ok(data) => serde_json::from_slice::<Vec<Value>>(&data).unwrap_or_else(|err| {
                eprintln!("providers: unparseable {PROVIDERS_JSON}, starting empty ({err})");
                Vec::new()
            }),
            Err(_) => Vec::new(),
        };
        Ok(Self {
            path,
            providers: Mutex::new(providers),
        })
    }

    pub fn list(&self) -> Vec<Value> {
        self.providers
            .lock()
            .map(|providers| providers.clone())
            .unwrap_or_default()
    }

    pub fn get(&self, index: usize) -> Option<Value> {
        self.providers
            .lock()
            .ok()
            .and_then(|providers| providers.get(index).cloned())
    }

    pub fn replace(&self, incoming: Vec<Value>) -> Result<(), String> {
        let incoming: Vec<Value> = incoming
            .into_iter()
            .map(|mut provider| {
                if let Some(base) = provider
                    .get("base-url")
                    .and_then(Value::as_str)
                    .map(str::trim)
                {
                    provider["base-url"] = Value::String(base.to_string());
                }
                provider
            })
            .collect();
        {
            let mut providers = self
                .providers
                .lock()
                .map_err(|_| "providers mutex poisoned".to_string())?;
            *providers = incoming;
        }
        let data = serde_json::to_vec_pretty(&self.list())
            .map_err(|err| format!("marshal providers: {err}"))?;
        fs::write(&self.path, data).map_err(|err| format!("write {}: {err}", self.path.display()))
    }

    pub fn find(&self, model: &str) -> Option<Entry> {
        if model.is_empty() {
            return None;
        }
        let providers = self.providers.lock().ok()?;
        providers.iter().find_map(|provider| {
            let matched = matching_model(provider, model)?;
            Some(Entry {
                provider: provider.clone(),
                model: matched,
            })
        })
    }

    pub fn commandcode_model(&self, model: &str) -> Option<String> {
        if model.is_empty() {
            return None;
        }
        let providers = self.providers.lock().ok()?;
        providers.iter().find_map(|provider| {
            if provider.get("kind").and_then(Value::as_str) != Some("commandcode") {
                return None;
            }
            matching_model(provider, model)?
                .get("name")
                .and_then(Value::as_str)
                .map(str::to_string)
        })
    }
}

fn matching_model(provider: &Value, model: &str) -> Option<Value> {
    provider
        .get("models")
        .and_then(Value::as_array)?
        .iter()
        .find(|entry| {
            entry.get("alias").and_then(Value::as_str) == Some(model)
                || entry.get("name").and_then(Value::as_str) == Some(model)
        })
        .cloned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn store_with(providers: Vec<Value>) -> Store {
        Store {
            path: PathBuf::new(),
            providers: Mutex::new(providers),
        }
    }

    fn fixture() -> Store {
        store_with(vec![
            json!({
                "name": "CommandCode",
                "kind": "commandcode",
                "base-url": "",
                "models": [{"name": "deepseek/deepseek-v4-flash", "alias": "deepseek-v4-flash@CommandCode"}],
            }),
            json!({
                "name": "BAI",
                "kind": "openai",
                "base-url": "https://api.bai.example/v1",
                "api-key-entries": [{"api-key": "k"}],
                "models": [{"name": "glm-4.6", "alias": "glm-4.6@BAI"}],
            }),
        ])
    }

    #[test]
    fn commandcode_model_resolves_zone_aliases() {
        let store = fixture();
        assert_eq!(
            store
                .commandcode_model("deepseek-v4-flash@CommandCode")
                .as_deref(),
            Some("deepseek/deepseek-v4-flash")
        );
        assert_eq!(
            store
                .commandcode_model("deepseek/deepseek-v4-flash")
                .as_deref(),
            Some("deepseek/deepseek-v4-flash")
        );
        assert_eq!(store.commandcode_model("gpt-4o"), None);
        assert_eq!(store.commandcode_model(""), None);
    }

    #[test]
    fn find_matches_on_alias_or_upstream_name() {
        let store = fixture();
        let zone = store
            .find("deepseek-v4-flash@CommandCode")
            .expect("zone alias matches the commandcode entry");
        assert_eq!(zone.provider_name(), "CommandCode");
        assert_eq!(zone.upstream_model("fallback"), "deepseek/deepseek-v4-flash");

        assert_eq!(store.find("glm-4.6@BAI").expect("BAI alias").provider_name(), "BAI");
        assert!(store.find("claude-sonnet-4").is_none());
        assert!(store.find("").is_none());
        assert!(store_with(vec![]).find("x").is_none());
    }

    #[test]
    fn upstream_model_falls_back_when_the_entry_has_no_name() {
        let store = store_with(vec![json!({
            "name": "P",
            "models": [{"alias": "only-alias"}],
        })]);
        let entry = store.find("only-alias").expect("alias matches");
        assert_eq!(entry.upstream_model("client-model"), "client-model");
    }
}

pub async fn handle_get(State(state): State<Arc<App>>) -> Response {
    let providers = state.providers.list();
    (StatusCode::OK, Json(providers)).into_response()
}

pub async fn handle_put(
    State(state): State<Arc<App>>,
    ApiJson(providers): ApiJson<Vec<serde_json::Value>>,
) -> Response {
    match state.providers.replace(providers) {
        Ok(()) => (StatusCode::OK, Json(json!({"ok": true}))).into_response(),
        Err(err) => failed(StatusCode::BAD_REQUEST, "invalid_request_error", &err),
    }
}
