use axum::extract::{Query, State};
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::json;
use std::collections::HashMap;
use std::sync::Arc;

use crate::app::App;

use crate::state::{bad_request, failed};
use crate::net::ApiJson;
use crate::state::accounts::{Account, Channel};

#[derive(Debug, Deserialize)]
pub struct WorkbuddyAddBody {
    #[serde(default)]
    auth_json: String,
}

pub async fn handle_add(
    State(state): State<Arc<App>>,
    ApiJson(body): ApiJson<WorkbuddyAddBody>,
) -> Response {
    if body.auth_json.trim().is_empty() {
        return bad_request("auth_json is required (paste the WorkBuddy auth JSON)");
    }
    let parsed = match crate::providers::workbuddy::auth::parse(body.auth_json.as_bytes()) {
        Ok(parsed) => parsed,
        Err(err) => return bad_request(&format!("parse auth json: {err}")),
    };

    let existing = state.accounts.list().into_iter().find(|a| {
        a.channel() == Some(Channel::Workbuddy)
            && !parsed.uid.trim().is_empty()
            && a.workbuddy_uid == parsed.uid
    });
    let account = match existing {
        Some(mut account) => {
            account.provider = Channel::Workbuddy.to_string();
            account.workbuddy_access_token = parsed.access_token.clone();
            account.workbuddy_refresh_token = parsed.refresh_token.clone();
            account.workbuddy_expires_at = parsed.expires_at;
            account.workbuddy_domain = parsed.domain.clone();
            account.workbuddy_uid = parsed.uid.clone();
            account.workbuddy_enterprise_id = parsed.enterprise_id.clone();
            account.workbuddy_nickname = parsed.nickname.clone();
            account
        }
        None => Account {
            name: state
                .workbuddy
                .derive_account_name(&parsed.nickname, &parsed.uid),
            provider: Channel::Workbuddy.to_string(),
            workbuddy_access_token: parsed.access_token.clone(),
            workbuddy_refresh_token: parsed.refresh_token.clone(),
            workbuddy_expires_at: parsed.expires_at,
            workbuddy_domain: parsed.domain.clone(),
            workbuddy_uid: parsed.uid.clone(),
            workbuddy_enterprise_id: parsed.enterprise_id.clone(),
            workbuddy_nickname: parsed.nickname.clone(),
            ..Account::default()
        },
    };
    let name = account.name.clone();

    match state.accounts.add(account) {
        Ok(()) => {
            state.workbuddy.sync_accounts();
            (
                StatusCode::OK,
                Json(json!({
                    "ok": true,
                    "name": name,
                    "uid": parsed.uid,
                    "nickname": parsed.nickname,
                })),
            )
                .into_response()
        }
        Err(err) => bad_request(&err),
    }
}

pub async fn handle_local(State(_state): State<Arc<App>>) -> Response {
    match crate::providers::workbuddy::auth::read_local() {
        Ok((path, auth)) => {
            let doc = crate::providers::workbuddy::auth::to_nested_value(&auth);
            let auth_json = serde_json::to_string_pretty(&doc).unwrap_or_default();
            (
                StatusCode::OK,
                Json(json!({
                    "found": true,
                    "source": path.display().to_string(),
                    "uid": auth.uid,
                    "nickname": auth.nickname,
                    "domain": auth.domain,
                    "auth_json": auth_json,
                })),
            )
                .into_response()
        }
        Err(searched) => {
            let searched: Vec<String> = searched
                .iter()
                .map(|path| path.display().to_string())
                .collect();
            (
                StatusCode::OK,
                Json(json!({ "found": false, "searched": searched })),
            )
                .into_response()
        }
    }
}

pub async fn handle_status(State(state): State<Arc<App>>) -> Response {
    (StatusCode::OK, Json(state.workbuddy.status())).into_response()
}

pub async fn handle_refresh(State(state): State<Arc<App>>) -> Response {
    state.workbuddy.keepalive_now().await;
    state.workbuddy.checkin_now().await;
    (StatusCode::OK, Json(state.workbuddy.status())).into_response()
}

pub async fn handle_oauth_start(State(state): State<Arc<App>>) -> Response {
    match Arc::clone(&state.workbuddy).oauth_start().await {
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
    (StatusCode::OK, Json(state.workbuddy.oauth_status(session))).into_response()
}
