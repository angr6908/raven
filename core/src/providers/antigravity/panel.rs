use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;

use crate::app::App;
use crate::net::ApiJson;
use crate::state::{bad_request, failed};

#[derive(Debug, Deserialize)]
pub struct CallbackBody {
    #[serde(default)]
    session: String,
    #[serde(default)]
    callback: String,
}

pub async fn handle_oauth_start(State(state): State<Arc<App>>) -> Response {
    match state.antigravity.oauth_start().await {
        Ok(info) => (StatusCode::OK, Json(info)).into_response(),
        Err(err) => failed(StatusCode::BAD_GATEWAY, "oauth_start_failed", &err),
    }
}

pub async fn handle_oauth_status(
    State(state): State<Arc<App>>,
    Query(params): Query<HashMap<String, String>>,
) -> Response {
    let Some(session) = params.get("session") else {
        return bad_request("session query param is required");
    };
    (StatusCode::OK, Json(state.antigravity.oauth_status(session))).into_response()
}

pub async fn handle_add(State(state): State<Arc<App>>, ApiJson(body): ApiJson<CallbackBody>) -> Response {
    if body.session.trim().is_empty() {
        return bad_request("session is required (start the sign-in first)");
    }
    if body.callback.trim().is_empty() {
        return bad_request("callback is required (paste the full redirect URL)");
    }
    match state
        .antigravity
        .oauth_paste(body.session.trim(), body.callback.trim())
        .await
    {
        Ok(info) => (StatusCode::OK, Json(info)).into_response(),
        Err(err) => bad_request(&err),
    }
}

pub async fn handle_status(State(state): State<Arc<App>>) -> Response {
    (StatusCode::OK, Json(state.antigravity.status())).into_response()
}

pub async fn handle_refresh(State(state): State<Arc<App>>) -> Response {
    state.antigravity.refresh_catalog();
    let _ = state.antigravity.model_list().await;
    (StatusCode::OK, Json(state.antigravity.status())).into_response()
}

pub async fn handle_quota(State(state): State<Arc<App>>) -> Response {
    if state.antigravity.pool().is_empty() {
        return failed(
            StatusCode::NOT_FOUND,
            "account_not_found",
            "no antigravity account signed in",
        );
    }
    (StatusCode::OK, Json(state.antigravity.quota().await)).into_response()
}

pub async fn handle_models(State(state): State<Arc<App>>) -> Response {
    let models = state.antigravity.model_list().await;
    (StatusCode::OK, Json(json!({ "models": models }))).into_response()
}
