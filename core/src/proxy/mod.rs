pub mod chat;
pub mod chat_sse;
pub mod messages;
pub mod models;
pub mod responses;
pub mod route;

use axum::body::Bytes;
use axum::http::StatusCode;
use axum::response::Response;
use serde_json::Value;
use std::sync::Arc;
use std::time::Instant;

use crate::app::App;
use crate::providers::Provider;
use crate::net::error::ApiError;
use crate::protocol::Protocol;
use crate::state::usage::UsageEvent;

use crate::translate::chat::types::ChatRequest;
use crate::translate::collect::Collector;
use crate::translate::generate::build_generate_request;
use self::route::Target;

fn rename_history_reasoning_to_cerebras(body: &mut Value) {
    if let Some(messages) = body.get_mut("messages").and_then(Value::as_array_mut) {
        for message in messages.iter_mut() {
            let Some(obj) = message.as_object_mut() else {
                continue;
            };
            if obj.get("role").and_then(Value::as_str) != Some("assistant") {
                continue;
            }
            if let Some(reasoning) = obj.remove("reasoning_content") {
                if reasoning
                    .as_str()
                    .is_some_and(|text| !text.trim().is_empty())
                {
                    obj.insert("reasoning".to_string(), reasoning);
                }
            }
        }
    }
    if let Some(effort) = body
        .get("reasoning_effort")
        .and_then(Value::as_str)
        .map(str::to_string)
    {
        let clamped = match effort.as_str() {
            "none" | "low" | "medium" | "high" => None,
            "minimal" => Some("low"),
            "xhigh" | "max" => Some("high"),
            _ => Some(""),
        };
        if let Some(clamped) = clamped {
            if clamped.is_empty() {
                if let Some(obj) = body.as_object_mut() {
                    obj.remove("reasoning_effort");
                }
            } else {
                body["reasoning_effort"] = serde_json::json!(clamped);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cerebras_shape_moves_assistant_reasoning_and_clamps_effort() {
        let mut body = json!({
            "model": "qwen-3.8-27b",
            "reasoning_effort": "xhigh",
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": "hello", "reasoning_content": "let me think"},
                {"role": "assistant", "content": "plain", "reasoning_content": " "},
            ],
        });
        rename_history_reasoning_to_cerebras(&mut body);
        assert_eq!(body["messages"][1].get("reasoning_content"), None);
        assert_eq!(body["messages"][1]["reasoning"], "let me think");
        assert_eq!(body["messages"][2].get("reasoning"), None);
        assert_eq!(body["reasoning_effort"], "high");
    }

    #[test]
    fn cerebras_shape_keeps_supported_efforts_and_leaves_tool_roles_alone() {
        let mut body = json!({
            "model": "qwen-3.8-27b",
            "reasoning_effort": "low",
            "messages": [
                {"role": "tool", "content": "42", "tool_call_id": "t1", "reasoning_content": "stray"},
            ],
        });
        rename_history_reasoning_to_cerebras(&mut body);
        assert_eq!(body["messages"][0]["reasoning_content"], "stray");
        assert_eq!(body["messages"][0].get("reasoning"), None);
        assert_eq!(body["reasoning_effort"], "low");
    }

    #[test]
    fn cerebras_shape_drops_unknown_and_empty_effort() {
        for effort in ["", "ultra", "12"] {
            let mut body = json!({ "reasoning_effort": effort, "messages": [] });
            rename_history_reasoning_to_cerebras(&mut body);
            assert_eq!(body.get("reasoning_effort"), None, "for {effort:?}");
        }
    }
}

pub struct Meter {
    app: Arc<App>,
    event: UsageEvent,
}

impl Meter {
    pub fn attribute(&mut self, account: &str) {
        if !account.is_empty() {
            self.event.set_account(account);
        }
    }

    pub fn first_byte(&mut self, at: Instant) {
        self.app.usage.mark_first_byte(&mut self.event, at);
    }

    pub fn first_byte_maybe(&mut self, at: Option<Instant>) {
        if let Some(at) = at {
            self.first_byte(at);
        }
    }

    pub fn ok(&mut self, usage: Option<&Collector>, finish: &str) {
        self.app
            .usage
            .end(&mut self.event, usage, StatusCode::OK.as_u16(), "", finish);
    }

    pub fn fail(&mut self, err: &ApiError) {
        self.app.usage.end(
            &mut self.event,
            None,
            err.status_u16(),
            &err.message,
            "",
        );
    }

    pub fn fail_with(&mut self, usage: Option<&Collector>, status: u16, message: &str) {
        self.app.usage.end(&mut self.event, usage, status, message, "");
    }

}

pub struct Exchange {
    pub app: Arc<App>,
    pub dialect: Protocol,
    pub target: Target,
    pub alias: String,
    pub stream: bool,
    pub meter: Meter,
}

impl Exchange {
    pub fn open(
        app: Arc<App>,
        dialect: Protocol,
        target: Target,
        alias: &str,
        stream: bool,
        effort: &str,
    ) -> Self {
        let mut event = app.usage.begin(
            alias,
            &target.upstream_model,
            stream,
            effort,
            &target.name,
        );
        app.usage.describe(&mut event, alias, &target.name);
        Self {
            dialect,
            target,
            alias: alias.to_string(),
            stream,
            meter: Meter {
                app: Arc::clone(&app),
                event,
            },
            app,
        }
    }

    pub fn backend(&self) -> &Provider {
        &self.target.provider
    }

    pub fn upstream_model(&self) -> &str {
        &self.target.upstream_model
    }

    pub async fn send(&mut self, payload: Bytes) -> Result<reqwest::Response, Response> {
        match self
            .target
            .provider
            .send(&self.app, payload, self.stream)
            .await
        {
            Ok(sent) => {
                self.meter.attribute(&sent.account);
                Ok(sent.response)
            }
            Err(failure) => {
                self.meter.attribute(&failure.account);
                Err(self.fail(failure.error))
            }
        }
    }

    pub fn encode_generate(&mut self, mut req: ChatRequest) -> Result<Bytes, Response> {
        req.model = self.target.upstream_model.clone();
        if matches!(self.target.provider, Provider::Antigravity) {
            return match self
                .app
                .antigravity
                .encode_request(req, &self.target.upstream_model)
            {
                Ok(body) => Ok(Bytes::from(body)),
                Err(err) => Err(self.fail(ApiError::bad_request(err))),
            };
        }
        let work_dir = self.app.work_dir.clone();
        match build_generate_request(req, &work_dir, chrono::Utc::now()) {
            Ok(body) => self.encode(&body),
            Err(err) => Err(self.fail(ApiError::bad_request(format!("build cc request: {err}")))),
        }
    }

    pub fn encode(&mut self, body: &impl serde::Serialize) -> Result<Bytes, Response> {
        let encoded = if self.target.provider.is_cerebras() {
            serde_json::to_value(body).and_then(|mut value| {
                rename_history_reasoning_to_cerebras(&mut value);
                serde_json::to_vec(&value)
            })
        } else {
            serde_json::to_vec(body)
        };
        match encoded {
            Ok(bytes) => Ok(Bytes::from(bytes)),
            Err(err) => Err(self.fail(ApiError::internal(format!("marshal: {err}")))),
        }
    }

    pub async fn read_body(
        &mut self,
        response: reqwest::Response,
    ) -> Result<serde_json::Value, Response> {
        match self.target.provider.read_body(response).await {
            Ok(body) => Ok(body),
            Err(err) => Err(self.fail(err)),
        }
    }

    pub fn fail(&mut self, err: ApiError) -> Response {
        self.meter.fail(&err);
        self.dialect.error(&err)
    }

    pub fn gateway(&mut self, message: impl Into<String>) -> Response {
        self.fail(ApiError::gateway("upstream_error", message))
    }

    pub fn into_meter(self) -> Meter {
        self.meter
    }

}
