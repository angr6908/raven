pub mod accounts;
pub mod catalog;
pub mod models;
pub mod providers;
pub mod usage;

use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::json;
use std::sync::Arc;

use crate::app::App;
use crate::config::VERSION;
use crate::net::error::ApiError;
use crate::protocol::Protocol;
use crate::state::accounts::Channel;

pub(crate) fn bad_request(message: &str) -> Response {
    Protocol::Chat.error(&ApiError::bad_request(message))
}

pub(crate) fn failed(status: StatusCode, code: &str, message: &str) -> Response {
    Protocol::Chat.error(&ApiError::coded(status, code, message))
}

pub async fn handle_health(State(app): State<Arc<App>>) -> Response {
    let commandcode = app.accounts.serving(Channel::Commandcode).len();
    (
        StatusCode::OK,
        Json(json!({
            "status": "ok",
            "detail": "",
            "version": VERSION,
            "api": app.commandcode.api_base,
            "accounts": commandcode,
            "pools": {
                "commandcode": commandcode,
                "workbuddy": app.accounts.serving(Channel::Workbuddy).len(),
                "antigravity": app.antigravity.pool().len(),
            },
        })),
    )
        .into_response()
}
