use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use chrono::Utc;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::Instant;

use crate::app::App;
use crate::protocol::Protocol;
use crate::net::error::ApiError;
use crate::net::sse::{data_payload, frame_channel, send_data_event, send_done, FrameSender, SseReader};
use crate::net::ApiJson;
use crate::translate::generate::build_generate_request;
use crate::translate::chat::via_responses_reply::{responses_to_chat_completion, ResponsesToChat};
use crate::translate::chat::via_responses_request::chat_request_to_responses_body;
use crate::translate::responses::apply_responses_usage;
use crate::translate::summary::{self, SummaryConfig, SummaryFormat};
use crate::translate::chat::types::ChatRequest;
use crate::translate::usage::TokenUsage;

use super::chat_sse::{self, process_line, process_openai_line};
use crate::translate::collect::{completion_id, Collector};
use crate::translate::tokens::is_chat_token_chunk;
use super::{route, Exchange};

const DIALECT: Protocol = Protocol::Chat;

pub async fn handle(State(app): State<Arc<App>>, ApiJson(req): ApiJson<ChatRequest>) -> Response {
    match run(app, req).await {
        Ok(response) | Err(response) => response,
    }
}

async fn run(app: Arc<App>, req: ChatRequest) -> Result<Response, Response> {
    if req.model.is_empty() {
        return Err(DIALECT.error(&ApiError::bad_request("model is required")));
    }
    if req.messages.is_empty() {
        return Err(DIALECT.error(&ApiError::bad_request("messages is required")));
    }

    let alias = req.model.clone();
    let stream = req.stream;
    let effort = req.reasoning_effort.clone();
    let target = route::resolve(&app, "chat", &alias).await;
    let protocol = target.provider.protocol();
    let exchange = Exchange::open(app, DIALECT, target, &alias, stream, &effort);

    match protocol {
        Protocol::Responses => via_responses(exchange, req).await,
        Protocol::Generate => via_generate(exchange, req).await,
        _ => via_chat(exchange, req).await,
    }
}

async fn via_chat(mut ex: Exchange, mut req: ChatRequest) -> Result<Response, Response> {
    req.model = ex.upstream_model().to_string();
    if ex.backend().needs_usage_opt_in() {
        req.apply_openai_compat_defaults();
    }
    let payload = ex.encode(&req)?;
    let upstream = ex.send(payload).await?;

    if !ex.stream {
        let body = ex.read_body(upstream).await?;
        return Ok(complete_from_body(&mut ex, body));
    }
    let model = ex.upstream_model().to_string();
    Ok(chat_sse::relay(ex.into_meter(), DIALECT, upstream, model, process_openai_line).await)
}

fn complete_from_body(ex: &mut Exchange, body: Value) -> Response {
    let collector = body
        .get("usage")
        .map(|usage| Collector::with_usage(TokenUsage::from_openai_chat_usage(usage)))
        .unwrap_or_default();
    let finish = body
        .pointer("/choices/0/finish_reason")
        .and_then(Value::as_str)
        .unwrap_or("stop")
        .to_string();
    ex.meter.ok(Some(&collector), &finish);
    (StatusCode::OK, Json(body)).into_response()
}

async fn via_responses(mut ex: Exchange, mut req: ChatRequest) -> Result<Response, Response> {
    let original = serde_json::to_value(&req).unwrap_or(Value::Null);
    req.model = ex.upstream_model().to_string();

    let mut body = chat_request_to_responses_body(&req);
    summary::apply(
        &mut body,
        SummaryFormat::Responses,
        &SummaryConfig::from_chat_effort(&req.reasoning_effort).or_visible_default(),
    );
    let payload = ex.encode(&body)?;
    let upstream = ex.send(payload).await?;

    if !ex.stream {
        let body = ex.read_body(upstream).await?;
        let framed = frame_terminal(body);
        let Some(mut completion) = responses_to_chat_completion(&framed, &original) else {
            return Err(ex.gateway("upstream produced no terminal response"));
        };
        completion["id"] = json!(completion_id());
        completion["model"] = json!(ex.alias);

        let finish = completion
            .pointer("/choices/0/finish_reason")
            .and_then(Value::as_str)
            .unwrap_or("stop")
            .to_string();
        let mut usage =
            TokenUsage::from_openai_chat_usage(completion.get("usage").unwrap_or(&Value::Null));
        usage.input_token_details.cache_write_tokens = completion
            .pointer("/usage/prompt_tokens_details/cached_creation_tokens")
            .and_then(Value::as_i64)
            .unwrap_or(0);
        ex.meter.ok(Some(&Collector::with_usage(usage)), &finish);
        return Ok((StatusCode::OK, Json(completion)).into_response());
    }

    let id = completion_id();
    let created = Utc::now().timestamp();
    let model = ex.alias.clone();
    let (sender, receiver) = frame_channel();
    let mut meter = ex.meter;
    let dialect = ex.dialect;
    tokio::spawn(async move {
        responses_stream_to_chat(upstream, &sender, &mut meter, &id, created, &model, &original)
            .await;
    });

    let no_events = || {
        dialect.error(&ApiError::gateway(
            "upstream_error",
            "upstream produced no events",
        ))
    };
    Ok(crate::net::sse::first_frame_response(receiver, |_| no_events(), no_events).await)
}

pub(super) fn frame_terminal(body: Value) -> Value {
    if body.get("type").is_some() && body.get("response").is_some() {
        return body;
    }
    json!({"type": "response.completed", "response": body})
}

async fn responses_stream_to_chat(
    upstream: reqwest::Response,
    sender: &FrameSender,
    meter: &mut super::Meter,
    id: &str,
    created: i64,
    model: &str,
    original: &Value,
) {
    let mut reader = SseReader::new(upstream);
    let mut collector = Collector::counting();
    let mut finish = "stop".to_string();
    let mut translated_usage: Option<Value> = None;
    let mut machine = ResponsesToChat::new(model, original);
    let mut first_token_at: Option<Instant> = None;

    while let Some(block) = reader.next_block().await {
        let Some(payload) = block.lines().find_map(data_payload) else {
            continue;
        };
        let Ok(parsed) = serde_json::from_str::<Value>(payload) else {
            continue;
        };
        if let Some(usage) = parsed.pointer("/response/usage") {
            apply_responses_usage(&mut collector, usage);
        }
        let Some(mut chunk) = machine.convert(&parsed) else {
            continue;
        };
        chunk["id"] = json!(id);
        chunk["model"] = json!(model);
        chunk["created"] = json!(created);
        if let Some(reason) = chunk
            .pointer("/choices/0/finish_reason")
            .and_then(Value::as_str)
        {
            finish = reason.to_string();
            if let Some(usage) = chunk.get("usage").filter(|usage| usage.is_object()) {
                translated_usage = Some(usage.clone());
            }
            continue;
        }
        if first_token_at.is_none() && is_chat_token_chunk(&chunk) {
            first_token_at = Some(Instant::now());
        }
        send_data_event(sender, &chunk);
    }

    let base = |delta: Value, finish: Value| {
        json!({
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        })
    };
    send_data_event(sender, &base(json!({}), json!(finish)));
    send_data_event(
        sender,
        &json!({
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [],
            "usage": translated_usage
                .or_else(|| collector.usage.as_ref().map(chat_usage_json))
                .unwrap_or(Value::Null),
        }),
    );
    send_done(sender);

    meter.first_byte_maybe(first_token_at.or_else(|| Some(Instant::now())));
    meter.ok(Some(&collector), &finish);
}

fn chat_usage_json(usage: &TokenUsage) -> Value {
    let mut out = json!({
        "prompt_tokens": usage.input_tokens,
        "completion_tokens": usage.output_tokens,
        "total_tokens": usage.total_tokens,
    });
    if usage.input_token_details.cache_read_tokens > 0
        || usage.input_token_details.cache_write_tokens > 0
    {
        out["prompt_tokens_details"] = json!({
            "cached_tokens": usage.input_token_details.cache_read_tokens,
            "cached_creation_tokens": usage.input_token_details.cache_write_tokens,
        });
    }
    if usage.output_token_details.reasoning_tokens > 0 {
        out["completion_tokens_details"] =
            json!({"reasoning_tokens": usage.output_token_details.reasoning_tokens});
    }
    out
}

async fn via_generate(mut ex: Exchange, mut req: ChatRequest) -> Result<Response, Response> {
    req.model = ex.upstream_model().to_string();
    if !req.reasoning_effort.is_empty() {
        eprintln!("effort {}: {}", ex.alias, req.reasoning_effort);
    }
    let work_dir = ex.app.work_dir.clone();
    let generate = build_generate_request(req, &work_dir, Utc::now())
        .map_err(|err| ex.fail(ApiError::bad_request(err)))?;
    let payload = ex.encode(&generate)?;
    let upstream = ex.send(payload).await?;

    let model = ex.alias.clone();
    if ex.stream {
        return Ok(chat_sse::relay(ex.into_meter(), DIALECT, upstream, model, process_line).await);
    }
    let dialect = ex.dialect;
    let mut meter = ex.into_meter();
    match chat_sse::buffer(&mut meter, upstream, &model, process_line).await {
        Ok(response) => Ok(response),
        Err(err) => Err(dialect.error(&err)),
    }
}
