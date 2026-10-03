use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Deserialize;
use serde_json::json;
use std::sync::Arc;

use crate::app::App;
use crate::net::ApiJson;
use crate::state::accounts::Channel;
use crate::state::bad_request;

#[derive(Debug, Deserialize)]
pub struct SignInBody {
    name: String,
    #[serde(default)]
    key: String,
    #[serde(default)]
    email: String,
    password: Option<String>,
    session_token: Option<String>,
    captcha_response: Option<String>,
}

pub async fn handle_renew(
    State(state): State<Arc<App>>,
    request: axum::http::Request<axum::body::Body>,
) -> Response {
    let body = match ApiJson::<RenewBody>::from_request_with_limit(request, &state, 16 * 1024).await
    {
        Ok(body) => body.0,
        Err(response) => return response,
    };
    let Some(account) = state
        .accounts
        .list()
        .into_iter()
        .find(|account| account.name == body.name.trim())
    else {
        return bad_request("Command Code account not found");
    };
    if account.email.is_empty() || account.password.is_empty() {
        return bad_request("This account has no saved sign-in credentials");
    }
    let token = match state
        .commandcode_auth
        .sign_in(
            &account.email,
            &account.password,
            Some(&body.captcha_response),
        )
        .await
    {
        Ok(token) => token,
        Err(error) => {
            let status = if error.contains("rejected") {
                StatusCode::UNAUTHORIZED
            } else if error.contains("rate limited") {
                StatusCode::TOO_MANY_REQUESTS
            } else {
                StatusCode::BAD_GATEWAY
            };
            return (status, Json(json!({ "ok": false, "error": error }))).into_response();
        }
    };
    if let Err(error) = state.accounts.replace_session_token(&account.name, &token) {
        return bad_request(&error);
    }
    state.limits.invalidate(&account.name).await;
    (
        StatusCode::OK,
        Json(json!({"ok": true, "name": account.name})),
    )
        .into_response()
}

#[derive(Debug, Deserialize)]
pub struct RenewBody {
    name: String,
    captcha_response: String,
}

pub async fn handle_sign_in(
    State(state): State<Arc<App>>,
    request: axum::http::Request<axum::body::Body>,
) -> Response {
    let body =
        match ApiJson::<SignInBody>::from_request_with_limit(request, &state, 16 * 1024).await {
            Ok(body) => body.0,
            Err(response) => return response,
        };
    if body.email.trim().is_empty()
        || (body
            .session_token
            .as_deref()
            .unwrap_or_default()
            .trim()
            .is_empty()
            && body.password.as_deref().unwrap_or_default().is_empty())
    {
        return bad_request("email and either a session token or a password are required");
    }
    if body.key.trim().is_empty()
        && !state.accounts.list().iter().any(|account| {
            account.channel() == Some(Channel::Commandcode)
                && (account.email == body.email.trim() || account.name == body.name.trim())
                && !account.key.is_empty()
        })
    {
        return bad_request("API key is required for a new Command Code account");
    }

    let session_token = match body.session_token.as_deref() {
        Some(token) if !token.trim().is_empty() => token.trim().to_string(),
        _ => match state
            .commandcode_auth
            .sign_in(
                &body.email,
                body.password.as_deref().unwrap_or_default(),
                body.captcha_response.as_deref(),
            )
            .await
        {
            Ok(token) => token,
            Err(error) => {
                let status = if error.contains("rejected") {
                    StatusCode::UNAUTHORIZED
                } else if error.contains("rate limited") {
                    StatusCode::TOO_MANY_REQUESTS
                } else {
                    StatusCode::BAD_GATEWAY
                };
                return (status, Json(json!({ "ok": false, "error": error }))).into_response();
            }
        },
    };

    match state.accounts.upsert_commandcode_credentials(
        &body.name,
        &body.key,
        &body.email,
        body.password.as_deref(),
        &session_token,
    ) {
        Ok(name) => {
            state.limits.invalidate(&name).await;
            let old = body.name.trim();
            if !old.is_empty() && old != name {
                state.limits.invalidate(old).await;
            }
            (StatusCode::OK, Json(json!({"ok": true, "name": name}))).into_response()
        }
        Err(error) => bad_request(&error),
    }
}
