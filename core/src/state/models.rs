use axum::extract::{Path, Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;

use crate::app::App;
use crate::providers::{antigravity, commandcode};
use crate::state::accounts::Channel;

use super::{bad_request, failed};

pub(crate) const RESPONSES_API_BACKEND: &str = "responses";

pub(crate) const EFFORT_LEVELS: [&str; 7] =
    ["none", "minimal", "low", "medium", "high", "xhigh", "max"];

pub async fn handle_effort_levels() -> Response {
    (StatusCode::OK, Json(json!({ "levels": EFFORT_LEVELS }))).into_response()
}

pub(crate) fn ordered_effort_levels(entry: &Value) -> Vec<&str> {
    let curated: Vec<&str> = entry
        .pointer("/thinking/levels")
        .and_then(Value::as_array)
        .map(|levels| levels.iter().filter_map(Value::as_str).collect())
        .unwrap_or_default();

    let mut ordered: Vec<&str> = EFFORT_LEVELS
        .iter()
        .copied()
        .filter(|level| curated.is_empty() || curated.contains(level))
        .collect();

    for level in &curated {
        if !ordered.contains(level) {
            ordered.push(level);
        }
    }
    if ordered.is_empty() {
        ordered = EFFORT_LEVELS.to_vec();
    }
    ordered
}

pub(crate) fn effort_options(entry: &Value) -> Vec<Value> {
    let ordered = ordered_effort_levels(entry);
    let default = if ordered.contains(&"high") {
        "high"
    } else {
        ordered[ordered.len() - 1]
    };
    ordered
        .into_iter()
        .map(|level| json!({"value": level, "default": level == default}))
        .collect()
}

#[cfg(test)]
mod effort_menu_tests {
    use super::*;
    use serde_json::json;

    fn values(entry: &Value) -> Vec<String> {
        effort_options(entry)
            .iter()
            .map(|o| o["value"].as_str().unwrap_or_default().to_string())
            .collect()
    }

    fn default_of(entry: &Value) -> String {
        effort_options(entry)
            .iter()
            .find(|o| o["default"] == json!(true))
            .map(|o| o["value"].as_str().unwrap_or_default().to_string())
            .unwrap_or_default()
    }

    #[test]
    fn a_curated_list_is_offered_in_canonical_order() {
        let entry = json!({"thinking": {"levels": ["max", "low", "high"]}});
        assert_eq!(values(&entry), ["low", "high", "max"]);
        assert_eq!(default_of(&entry), "high");
    }

    #[test]
    fn a_model_without_curated_levels_gets_the_whole_menu() {
        let entry = json!({"name": "m"});
        assert_eq!(
            values(&entry),
            ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        );

        assert_eq!(default_of(&entry), "high");
    }

    #[test]
    fn without_high_the_top_level_is_the_default() {
        let entry = json!({"thinking": {"levels": ["low", "medium"]}});
        assert_eq!(default_of(&entry), "medium");
    }

    #[test]
    fn a_hand_written_level_survives_after_the_canonical_ones() {
        let entry = json!({"thinking": {"levels": ["high", "ultra"]}});
        assert_eq!(values(&entry), ["high", "ultra"]);
        assert_eq!(default_of(&entry), "high");
    }

    #[test]
    fn an_empty_level_list_is_treated_as_absent() {
        let entry = json!({"thinking": {"levels": []}});
        assert_eq!(values(&entry).len(), 7);
    }
}

pub(crate) fn provider_zone_name(provider: &Value) -> String {
    match crate::providers::from_entry(provider).channel() {
        Some(channel @ (Channel::Workbuddy | Channel::Antigravity)) => channel.to_string(),
        _ => provider
            .get("name")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string(),
    }
}

pub async fn handle_provider_models(
    State(state): State<Arc<App>>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let index: usize = match params.get("index").map(String::as_str) {
        Some(raw) => match raw.parse() {
            Ok(index) => index,
            Err(_) => return bad_request(&format!("invalid index: {raw}")),
        },
        None => return bad_request("index query param is required"),
    };

    let Some(provider) = state.providers.get(index) else {
        return failed(StatusCode::NOT_FOUND, "provider_not_found", &format!("no provider at index {index}"),
        );
    };

    let base = provider
        .get("base-url")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .trim_end_matches('/')
        .to_string();
    if base.is_empty() {
        return bad_request("provider has no base-url");
    }

    let key = provider
        .get("api-key-entries")
        .and_then(Value::as_array)
        .and_then(|entries| entries.first())
        .and_then(|entry| entry.get("api-key"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if key.is_empty() {
        return bad_request("provider has no api-key to fetch models with");
    }

    let url = format!("{base}/models");
    let res = match state
        .client
        .get(&url)
        .header("Authorization", format!("Bearer {key}"))
        .header("Accept", "application/json")
        .timeout(crate::state::providers::MANAGEMENT_TIMEOUT)
        .send()
        .await
    {
        Ok(res) => res,
        Err(err) => {
            return failed(StatusCode::BAD_GATEWAY, "upstream_error", &format!("fetch {url}: {err}"),
            )
        }
    };
    let res = match crate::net::fetch::ok_or_status_err(res, "fetch provider models").await {
        Ok(res) => res,
        Err(err) => return failed(StatusCode::BAD_GATEWAY, "upstream_error", &err),
    };
    let payload: Value = match res.json().await {
        Ok(payload) => payload,
        Err(err) => {
            return failed(StatusCode::BAD_GATEWAY, "upstream_error", &format!("decode {url}: {err}"),
            )
        }
    };

    let (ids, entries) = upstream_catalog_entries(&payload);

    (
        StatusCode::OK,
        Json(json!({ "models": ids, "entries": entries })),
    )
        .into_response()
}

fn upstream_catalog_entries(payload: &Value) -> (Vec<String>, Vec<Value>) {
    let items: Vec<&Value> = payload
        .get("data")
        .and_then(Value::as_array)
        .or_else(|| payload.as_array())
        .map(|items| items.iter().collect())
        .unwrap_or_default();

    let mut ids: Vec<String> = Vec::new();
    let mut entries: Vec<Value> = Vec::new();
    for item in items {
        let Some(id) = item
            .get("id")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
        else {
            continue;
        };
        ids.push(id.to_string());
        let mut entry = json!({ "id": id });

        let context = ["max_context_length", "context_length", "context_window"]
            .iter()
            .find_map(|key| item.get(*key).and_then(Value::as_i64))
            .or_else(|| {
                item.pointer("/top_provider/context_length")
                    .and_then(Value::as_i64)
            })
            .filter(|v| *v > 0);
        if let Some(context) = context {
            entry["context_length"] = json!(context);
        }
        if let Some(display) = item
            .get("display_name")
            .or_else(|| item.get("name"))
            .and_then(Value::as_str)
            .filter(|name| *name != id)
        {
            entry["display_name"] = json!(display);
        }
        entries.push(entry);
    }
    (ids, entries)
}

#[cfg(test)]
mod upstream_catalog_tests {
    use super::*;

    #[test]
    fn ids_and_windows_come_through_in_either_shape() {
        let payload = json!({"data": [
            {"id": "a", "context_length": 262144},
            {"id": "b", "context_window": 128000, "display_name": "B model"},
            {"id": "c", "top_provider": {"context_length": 1000000}},
            {"id": "d"},
            {"name": "e", "context_length": 32768},
            {"context_length": 8},
        ]});
        let (ids, entries) = upstream_catalog_entries(&payload);
        assert_eq!(ids, ["a", "b", "c", "d", "e"]);
        assert_eq!(entries[0]["context_length"], 262144);
        assert_eq!(entries[1]["context_length"], 128000);
        assert_eq!(entries[1]["display_name"], "B model");
        assert_eq!(entries[2]["context_length"], 1_000_000);

        assert!(entries[3].get("context_length").is_none());

        assert!(entries[4].get("display_name").is_none());

        let bare = json!([{"id": "solo", "context_length": 0}]);
        let (ids, entries) = upstream_catalog_entries(&bare);
        assert_eq!(ids, ["solo"]);

        assert!(entries[0].get("context_length").is_none());
    }

    #[test]
    fn an_explicit_override_outranks_the_advertised_window() {
        let payload = json!({"data": [
            {"id": "m", "context_length": 1000000, "max_context_length": 262144},
        ]});
        let (_, entries) = upstream_catalog_entries(&payload);
        assert_eq!(entries[0]["context_length"], 262144);
    }
}

pub async fn handle_provider_kind_models(
    State(state): State<Arc<App>>,
    Path(kind): Path<String>,
) -> Response {
    match Channel::parse(&kind) {
        Some(Channel::Workbuddy) => handle_provider_workbuddy_models(State(state)).await,
        Some(Channel::Commandcode) => commandcode::models::handle_catalog(State(state)).await,
        Some(Channel::Antigravity) => antigravity::panel::handle_models(State(state)).await,
        None => StatusCode::NOT_FOUND.into_response(),
    }
}

async fn handle_provider_workbuddy_models(State(state): State<Arc<App>>) -> Response {
    let models: Vec<Value> = state
        .workbuddy
        .model_list()
        .await
        .into_iter()
        .map(|m| {
            let id = m.get("id").and_then(Value::as_str).unwrap_or_default();
            let display_name = m
                .get("display_name")
                .and_then(Value::as_str)
                .filter(|name| !name.is_empty())
                .unwrap_or(id);
            let mut entry = json!({
                "id": id,
                "display_name": display_name,
                "owned_by": Channel::Workbuddy.as_str(),
            });

            if let Some(context) = m
                .get("context_length")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
            {
                entry["context_length"] = json!(context);
            }
            if let Some(max_out) = m
                .get("max_output_tokens")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0)
            {
                entry["max_completion_tokens"] = json!(max_out);
            }
            entry
        })
        .collect();
    (StatusCode::OK, Json(json!({ "models": models }))).into_response()
}

pub async fn handle_models_dev(
    State(state): State<Arc<App>>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let Some(model) = params
        .get("model")
        .map(String::as_str)
        .filter(|m| !m.trim().is_empty())
    else {
        return bad_request("model query param is required");
    };
    match state.catalog.lookup(model).await {
        Ok(Some(lookup)) => (StatusCode::OK, Json(lookup)).into_response(),
        Ok(None) => failed(StatusCode::NOT_FOUND, "model_not_found", &format!("model not in models.dev catalog: {model}"),
        ),
        Err(err) => failed(StatusCode::BAD_GATEWAY, "upstream_error", &err),
    }
}
