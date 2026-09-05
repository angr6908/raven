pub mod antigravity;
pub mod commandcode;
pub mod workbuddy;

use axum::body::Bytes;
use axum::http::StatusCode;
use serde_json::Value;

use crate::app::App;
use crate::net::error::ApiError;
use crate::net::fetch::post_json;
use crate::state::accounts::Channel;
use crate::protocol::Protocol;

#[derive(Debug, Clone)]
pub enum Provider {
    ChatCompletions { base_url: String, api_key: String },
    Responses { base_url: String, api_key: String },
    Workbuddy,
    CommandCode,
    Antigravity,
}

pub struct Sent {
    pub account: String,
    pub response: reqwest::Response,
}

pub struct SendFailure {
    pub account: String,
    pub error: ApiError,
}

impl Provider {
    pub fn protocol(&self) -> Protocol {
        match self {
            Self::ChatCompletions { .. } | Self::Workbuddy => Protocol::Chat,
            Self::Responses { .. } => Protocol::Responses,
            Self::CommandCode | Self::Antigravity => Protocol::Generate,
        }
    }

    pub fn channel(&self) -> Option<Channel> {
        match self {
            Self::Workbuddy => Some(Channel::Workbuddy),
            Self::CommandCode => Some(Channel::Commandcode),
            Self::Antigravity => Some(Channel::Antigravity),
            Self::ChatCompletions { .. } | Self::Responses { .. } => None,
        }
    }

    pub fn streams_only(&self) -> bool {
        matches!(self, Self::Workbuddy)
    }

    pub fn needs_usage_opt_in(&self) -> bool {
        matches!(self, Self::ChatCompletions { .. })
    }

    pub async fn send(
        &self,
        app: &App,
        payload: Bytes,
        stream: bool,
    ) -> Result<Sent, SendFailure> {
        match self {
            Self::ChatCompletions { base_url, api_key } => {
                self.post(app, &format!("{base_url}/chat/completions"), api_key, payload, stream)
                    .await
            }
            Self::Responses { base_url, api_key } => {
                self.post(app, &format!("{base_url}/responses"), api_key, payload, stream)
                    .await
            }
            Self::Workbuddy => match app.workbuddy.chat_rotate(payload.as_ref()).await {
                Ok(response) => Ok(Sent {
                    account: String::new(),
                    response,
                }),
                Err(workbuddy::ChatError::NoHealthy(message)) => Err(SendFailure {
                    account: String::new(),
                    error: ApiError::unavailable("no_healthy_account", message),
                }),
            },
            Self::CommandCode => commandcode::send(app, payload).await,
            Self::Antigravity => app.antigravity.send(payload).await,
        }
    }

    async fn post(
        &self,
        app: &App,
        url: &str,
        api_key: &str,
        payload: Bytes,
        stream: bool,
    ) -> Result<Sent, SendFailure> {
        match post_json(&app.client, url, api_key, payload, stream).await {
            Ok(response) => Ok(Sent {
                account: String::new(),
                response,
            }),
            Err(err) => Err(SendFailure {
                account: String::new(),
                error: err.into_api_error(),
            }),
        }
    }

    pub async fn read_body(&self, response: reqwest::Response) -> Result<Value, ApiError> {
        if self.streams_only() {
            return workbuddy::sse::aggregate_response(response)
                .await
                .map_err(|err| ApiError::gateway("upstream_parse", err));
        }
        response
            .json::<Value>()
            .await
            .map_err(|err| ApiError::gateway("upstream_error", format!("decode: {err}")))
    }
}

pub fn from_entry(provider: &Value) -> Provider {
    let base_url = provider
        .get("base-url")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim_end_matches('/')
        .to_string();
    let api_key = provider
        .get("api-key-entries")
        .and_then(Value::as_array)
        .and_then(|entries| entries.first())
        .and_then(|entry| entry.get("api-key"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    let kind = provider.get("kind").and_then(Value::as_str).unwrap_or("");
    if kind == "responses" {
        return Provider::Responses { base_url, api_key };
    }
    match Channel::parse(kind) {
        Some(Channel::Workbuddy) => Provider::Workbuddy,
        Some(Channel::Commandcode) => Provider::CommandCode,
        Some(Channel::Antigravity) => Provider::Antigravity,
        None => Provider::ChatCompletions { base_url, api_key },
    }
}

pub fn status_or_gateway(status: u16) -> StatusCode {
    StatusCode::from_u16(status).unwrap_or(StatusCode::BAD_GATEWAY)
}
