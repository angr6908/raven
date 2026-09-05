use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde::Serialize;
use serde_json::{json, Value};

use crate::protocol::Protocol;

#[derive(Debug, Serialize)]
pub struct ErrorEnvelope {
    pub error: ErrorBody,
}

#[derive(Debug, Serialize)]
pub struct ErrorBody {
    pub message: String,
    #[serde(rename = "type")]
    pub error_type: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub code: String,
}

impl ErrorEnvelope {
    pub fn new(
        message: impl Into<String>,
        error_type: impl Into<String>,
        code: impl Into<String>,
    ) -> Self {
        Self {
            error: ErrorBody {
                message: message.into(),
                error_type: error_type.into(),
                code: code.into(),
            },
        }
    }
}

#[derive(Debug, Clone)]
pub struct ApiError {
    pub status: StatusCode,
    pub kind: String,
    pub code: String,
    pub message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, kind: &str, code: &str, message: impl Into<String>) -> Self {
        Self {
            status,
            kind: kind.to_string(),
            code: code.to_string(),
            message: message.into(),
        }
    }

    pub fn coded(status: StatusCode, code: &str, message: impl Into<String>) -> Self {
        Self::new(status, code, code, message)
    }

    pub fn bad_request(message: impl Into<String>) -> Self {
        Self::coded(StatusCode::BAD_REQUEST, "invalid_request_error", message)
    }

    pub fn internal(message: impl Into<String>) -> Self {
        Self::coded(
            StatusCode::INTERNAL_SERVER_ERROR,
            "internal_error",
            message,
        )
    }

    pub fn unavailable(code: &str, message: impl Into<String>) -> Self {
        Self::coded(StatusCode::SERVICE_UNAVAILABLE, code, message)
    }

    pub fn gateway(code: &str, message: impl Into<String>) -> Self {
        Self::coded(StatusCode::BAD_GATEWAY, code, message)
    }

    pub fn upstream(status: StatusCode, message: impl Into<String>) -> Self {
        Self::new(status, "upstream_error", "", message)
    }

    pub fn status_u16(&self) -> u16 {
        self.status.as_u16()
    }
}

impl Protocol {
    pub fn error(self, err: &ApiError) -> Response {
        match self {
            Self::Messages => messages_error(err.status, &err.message),
            Self::Responses => (
                err.status,
                Json(ErrorEnvelope::new(&err.message, &err.kind, "")),
            )
                .into_response(),
            Self::Chat | Self::Generate => (
                err.status,
                Json(ErrorEnvelope::new(&err.message, &err.kind, &err.code)),
            )
                .into_response(),
        }
    }
}

pub fn messages_error(status: StatusCode, message: impl Into<String>) -> Response {
    let (error_type, message) = messages_error_detail(status.as_u16(), &message.into());
    (
        status,
        Json(json!({
            "type": "error",
            "error": {"type": error_type, "message": message},
        })),
    )
        .into_response()
}

pub fn messages_error_type(status: u16) -> &'static str {
    match status {
        401 => "authentication_error",
        402 => "billing_error",
        403 => "permission_error",
        404 => "not_found_error",
        413 => "request_too_large",
        429 => "rate_limit_error",
        504 => "timeout_error",
        529 => "overloaded_error",
        s if s >= 500 => "api_error",
        _ => "invalid_request_error",
    }
}

pub fn messages_error_detail(status: u16, raw: &str) -> (String, String) {
    let mut message = raw.trim().to_string();
    if message.is_empty() {
        message = StatusCode::from_u16(status)
            .ok()
            .and_then(|status| status.canonical_reason().map(str::to_string))
            .unwrap_or_else(|| "error".to_string());
    }
    let mut error_type = messages_error_type(status).to_string();

    let Ok(payload) = serde_json::from_str::<Value>(&message) else {
        return (error_type, message);
    };
    match payload.get("error").and_then(Value::as_object) {
        Some(error) => {
            if let Some(found) = non_blank(error.get("type")) {
                error_type = found;
            }
            if let Some(found) = non_blank(error.get("message")).or_else(|| non_blank(error.get("code"))) {
                message = found;
            }
        }
        None => {
            if let Some(found) = non_blank(payload.get("type")).filter(|found| found != "error") {
                error_type = found;
            }
            if let Some(found) = non_blank(payload.get("message")) {
                message = found;
            }
        }
    }
    (error_type, message)
}

fn non_blank(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn messages_details_prefer_the_upstream_envelope() {
        let (kind, message) = messages_error_detail(
            400,
            r#"{"error":{"type":"invalid_request_error","message":"bad schema"}}"#,
        );
        assert_eq!(kind, "invalid_request_error");
        assert_eq!(message, "bad schema");
    }

    #[test]
    fn messages_details_fall_back_to_the_status() {
        let (kind, message) = messages_error_detail(429, "rate limited");
        assert_eq!(kind, "rate_limit_error");
        assert_eq!(message, "rate limited");

        let (kind, message) = messages_error_detail(500, "");
        assert_eq!(kind, "api_error");
        assert_eq!(message, "Internal Server Error");
    }
}
