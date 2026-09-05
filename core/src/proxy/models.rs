use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::Utc;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::app::App;
use crate::state::models::{effort_options, provider_zone_name, RESPONSES_API_BACKEND};

pub async fn handle(State(state): State<Arc<App>>) -> Response {
    let mut data: Vec<Value> = Vec::new();
    let mut seen_ids: std::collections::HashSet<String> = std::collections::HashSet::new();

    let now = Utc::now().timestamp();
    for provider in state.providers.list() {
        if provider.get("disabled").and_then(Value::as_bool) == Some(true) {
            continue;
        }
        let provider_name = provider_zone_name(&provider);
        let Some(models) = provider.get("models").and_then(Value::as_array) else {
            continue;
        };
        for entry in models {
            let name = entry
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let alias = entry.get("alias").and_then(Value::as_str).unwrap_or(name);
            if name.is_empty() {
                continue;
            }
            if !seen_ids.insert(alias.to_string()) {
                continue;
            }
            let display_name = entry
                .get("display-name")
                .and_then(Value::as_str)
                .unwrap_or(alias);

            let configured_context = entry
                .get("max-context-length")
                .and_then(Value::as_i64)
                .filter(|v| *v > 0);
            let context_length = configured_context.unwrap_or(1_000_000);
            let mut model_entry = json!({
                "id": alias,
                "object": "model",
                "created": now,
                "owned_by": provider_name,
                "display_name": display_name,
                "context_length": context_length,

                "context_window": context_length,

                "api_backend": RESPONSES_API_BACKEND,

                "supports_reasoning_effort": true,
                "reasoning_efforts": effort_options(entry),
            });

            if let Some(configured) = configured_context {
                model_entry["max_context_length"] = json!(configured);
            }
            data.push(model_entry);
        }
    }

    (
        StatusCode::OK,
        Json(json!({"object": "list", "data": data})),
    )
        .into_response()
}
