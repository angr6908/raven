use axum::body::Bytes;
use axum::http::{header, StatusCode};
use serde::de::DeserializeOwned;

use super::error::ApiError;

pub enum PostError {
    Transport(String),
    Status(u16, String),
}

impl PostError {
    pub fn status(&self) -> u16 {
        match self {
            Self::Transport(_) => StatusCode::BAD_GATEWAY.as_u16(),
            Self::Status(status, _) => *status,
        }
    }

    pub fn status_code(&self) -> StatusCode {
        StatusCode::from_u16(self.status()).unwrap_or(StatusCode::BAD_GATEWAY)
    }

        pub fn client_message(&self) -> String {
        match self {
            Self::Transport(message) => message.clone(),
            Self::Status(status, text) => format!("upstream error ({status}): {text}"),
        }
    }

    pub fn into_api_error(self) -> ApiError {
        ApiError::upstream(self.status_code(), self.client_message())
    }
}

pub async fn post_json(
    client: &reqwest::Client,
    url: &str,
    api_key: &str,
    payload: Bytes,
    stream: bool,
) -> Result<reqwest::Response, PostError> {
    let accept = if stream {
        "text/event-stream"
    } else {
        "application/json"
    };
    let response = client
        .post(url)
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::AUTHORIZATION, format!("Bearer {api_key}"))
        .header(header::ACCEPT, accept)
        .body(payload)
        .send()
        .await
        .map_err(|err| PostError::Transport(format!("call {url}: {err}")))?;
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status().as_u16();
    let text = response.text().await.unwrap_or_default();
    Err(PostError::Status(status, text))
}

pub async fn send_json<T: DeserializeOwned>(
    request: reqwest::RequestBuilder,
    label: &str,
) -> Result<T, String> {
    let response = request
        .send()
        .await
        .map_err(|err| format!("{label}: {err}"))?;
    ok_or_status_err(response, label)
        .await?
        .json::<T>()
        .await
        .map_err(|err| format!("{label}: decode: {err}"))
}

pub async fn ok_or_status_err(
    response: reqwest::Response,
    label: &str,
) -> Result<reqwest::Response, String> {
    if response.status().is_success() {
        return Ok(response);
    }
    let status = response.status();
    let body = response.text().await.unwrap_or_default();
    Err(format!("{label}: status {status}: {}", body.trim()))
}
