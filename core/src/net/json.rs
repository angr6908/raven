use axum::body::{Body, Bytes};
use axum::extract::FromRequest;
use axum::http::Request;
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
