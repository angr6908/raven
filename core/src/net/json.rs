use axum::body::{Body, Bytes};
use axum::extract::FromRequest;
use axum::http::{Request, StatusCode};
use axum::response::Response;
use serde::Serialize;

use super::error::ApiError;
use crate::protocol::Protocol;

#[derive(Serialize)]
pub struct ListEnvelope<'a, T> {
    object: &'static str,
    data: &'a [T],
}

impl<'a, T> ListEnvelope<'a, T> {
    pub fn new(data: &'a [T]) -> Self {
        Self {
            object: "list",
            data,
        }
    }
}

pub struct ApiJson<T>(pub T);

impl<T> ApiJson<T> {
    pub async fn from_request_with_limit<S>(
        request: Request<Body>,
        state: &S,
        max_bytes: usize,
    ) -> Result<Self, Response>
    where
        T: serde::de::DeserializeOwned,
        S: Send + Sync,
    {
        let bytes = Bytes::from_request(request, state)
            .await
            .map_err(|err| reject(format!("read body: {err}")))?;
        if bytes.len() > max_bytes {
            return Err(Protocol::Chat.error(&ApiError::coded(
                StatusCode::PAYLOAD_TOO_LARGE,
                "invalid_request_error",
                "request body too large",
            )));
        }
        serde_json::from_slice(&bytes)
            .map(ApiJson)
            .map_err(|err| reject(format!("parse body: {err}")))
    }
}

impl<S, T> FromRequest<S> for ApiJson<T>
where
    T: serde::de::DeserializeOwned,
    S: Send + Sync,
{
    type Rejection = Response;

    async fn from_request(request: Request<Body>, state: &S) -> Result<Self, Self::Rejection> {
        let bytes = Bytes::from_request(request, state)
            .await
            .map_err(|err| reject(format!("read body: {err}")))?;
        serde_json::from_slice(&bytes)
            .map(ApiJson)
            .map_err(|err| reject(format!("parse body: {err}")))
    }
}

fn reject(message: String) -> Response {
    Protocol::Chat.error(&ApiError::bad_request(message))
}
