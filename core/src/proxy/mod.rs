pub mod chat;
pub mod chat_sse;
pub mod messages;
pub mod models;
pub mod responses;
pub mod route;

use axum::body::Bytes;
use axum::http::StatusCode;
use axum::response::Response;
use std::sync::Arc;
use std::time::Instant;

use crate::app::App;
use crate::providers::Provider;
use crate::net::error::ApiError;
use crate::protocol::Protocol;
use crate::state::usage::UsageEvent;

use crate::translate::collect::Collector;
use self::route::Target;

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

    pub fn encode(&mut self, body: &impl serde::Serialize) -> Result<Bytes, Response> {
        match serde_json::to_vec(body) {
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
