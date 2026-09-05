use axum::body::Bytes;
use axum::extract::State;
use axum::http::StatusCode;
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::Instant;

use crate::app::App;
use crate::protocol::Protocol;
use crate::net::error::ApiError;
use crate::net::sse::{data_payload, frame_channel, send_done, FrameSender, SseReader};
use crate::translate::messages::via_responses_reply::{responses_to_messages, ResponsesToMessages};
use crate::translate::messages::via_chat_reply::{
    chat_chunk_to_messages, chat_completion_to_messages, split_implicit_think_message,
};
use crate::translate::messages::via_chat_request::messages_to_chat_request;
use crate::translate::messages::{via_generate_reply, via_responses_request};
use crate::translate::messages::{
    send_message_event, new_message_id, effective_chat_finish_reason, finalize_stream,
    message_start_event, tool_name_map, MessagesStream,
};
use crate::translate::messages::input_tokens::spawn_input_token_filter;
use crate::translate::generate::build_generate_request;
use crate::translate::summary::{self, SummaryFormat};
use crate::translate::StreamOutcome;
use crate::translate::collect::Collector;
use crate::translate::tokens::is_claude_token_event;
use crate::translate::usage::TokenUsage;

use super::chat_sse::{self, process_line};
use super::{route, Exchange, Meter};

const DIALECT: Protocol = Protocol::Messages;

pub async fn handle(State(app): State<Arc<App>>, body: Bytes) -> Response {
    match run(app, body).await {
        Ok(response) | Err(response) => response,
    }
}

pub async fn handle_count_tokens(body: Bytes) -> Response {
    if let Err(err) = serde_json::from_slice::<serde::de::IgnoredAny>(&body) {
        return DIALECT.error(&ApiError::bad_request(format!("invalid request: {err}")));
    }
    let estimate = body.len() / 4;
    (StatusCode::OK, Json(json!({ "input_tokens": estimate }))).into_response()
}

async fn run(app: Arc<App>, body: Bytes) -> Result<Response, Response> {
    let req: Value = serde_json::from_slice(&body)
        .map_err(|err| DIALECT.error(&ApiError::bad_request(format!("invalid request: {err}"))))?;
    let alias = req
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if alias.is_empty() {
        return Err(DIALECT.error(&ApiError::bad_request("model is required")));
    }
    let stream = req.get("stream").and_then(Value::as_bool).unwrap_or(false);

    let target = route::resolve(&app, "messages", &alias).await;
    let protocol = target.provider.protocol();
    let upstream_model = target.upstream_model.clone();
    let effort = messages_to_chat_request(&req, &upstream_model, stream).reasoning_effort;
    let exchange = Exchange::open(app, DIALECT, target, &alias, stream, &effort);

    match protocol {
        Protocol::Responses => via_responses(exchange, req).await,
        Protocol::Generate => via_generate(exchange, req).await,
        _ => via_chat(exchange, req).await,
    }
}

async fn via_chat(mut ex: Exchange, req: Value) -> Result<Response, Response> {
    let model = ex.upstream_model().to_string();
    let mut oai = messages_to_chat_request(&req, &model, ex.stream);

    let wants_thinking = matches!(
        req.pointer("/thinking/type").and_then(Value::as_str),
        Some("enabled") | Some("adaptive") | Some("auto")
    );
    let implicit_think_open = wants_thinking && implicit_think_known(&ex.target.name, &model);
    if wants_thinking {
        for message in &mut oai.messages {
            if message.role == "assistant" && message.reasoning_content.trim().is_empty() {
                message.reasoning_content = " ".to_string();
            }
        }
    }
    if ex.backend().needs_usage_opt_in() {
        oai.apply_openai_compat_defaults();
    }

    let payload = ex.encode(&oai)?;
    let upstream = ex.send(payload).await?;
    let message_id = new_message_id();

    if !ex.stream {
        let body = ex.read_body(upstream).await?;
        let tool_names = tool_name_map(&req);
        let mut response =
            chat_completion_to_messages(&body, &message_id, &model, Some(&tool_names));
        if split_implicit_think_message(&mut response, implicit_think_open, wants_thinking) {
            remember_implicit_think(&ex.target.name, &model);
        }
        let usage = TokenUsage::from_openai_chat_usage(body.get("usage").unwrap_or(&Value::Null));
        ex.meter.ok(Some(&Collector::with_usage(usage)), "stop");
        return Ok((StatusCode::OK, Json(response)).into_response());
    }

    let (sender, receiver) = frame_channel();
    let sender = spawn_input_token_filter(sender, &req, false);
    let mut params = MessagesStream::new();
    params.tool_name_map = Some(tool_name_map(&req));
    params.implicit_think_open = implicit_think_open;

    let provider = ex.target.name.clone();
    let quirk_model = model.clone();
    let mut meter = ex.meter;
    tokio::spawn(async move {
        consume_chat_to_messages(upstream, &sender, &mut params).await;
        meter.first_byte_maybe(params.first_token_at);
        if params.implicit_think_seen {
            remember_implicit_think(&provider, &quirk_model);
        }
        let usage = TokenUsage::from_counts(
            params.input_tokens + params.cached_tokens,
            params.output_tokens,
            0,
            params.cached_tokens,
            0,
        );
        meter.ok(
            Some(&Collector::with_usage(usage)),
            effective_chat_finish_reason(&params),
        );
        send_done(&sender);
    });

    Ok(started_stream(DIALECT, receiver, &message_id, &model).await)
}

async fn via_responses(mut ex: Exchange, req: Value) -> Result<Response, Response> {
    let model = ex.upstream_model().to_string();
    let mut body = via_responses_request::messages_to_responses_request(&req, &model, false);
    summary::relay(
        &req,
        SummaryFormat::Claude,
        &mut body,
        SummaryFormat::Responses,
    );

    let payload = ex.encode(&body)?;
    let upstream = ex.send(payload).await?;
    let message_id = new_message_id();

    if !ex.stream {
        let body = ex.read_body(upstream).await?;
        let framed = super::chat::frame_terminal(body);
        let Some(mut response) = responses_to_messages(&framed, &req) else {
            return Err(ex.gateway("upstream produced no terminal response"));
        };
        fill_blank(&mut response, "id", &message_id);
        fill_blank(&mut response, "model", &model);

        let stop = response
            .get("stop_reason")
            .and_then(Value::as_str)
            .unwrap_or("end_turn")
            .to_string();
        let usage =
            TokenUsage::from_messages_usage(response.get("usage").unwrap_or(&Value::Null));
        ex.meter.ok(Some(&Collector::with_usage(usage)), &stop);
        return Ok((StatusCode::OK, Json(response)).into_response());
    }

    let (sender, receiver) = frame_channel();
    let sender = spawn_input_token_filter(sender, &req, false);
    let mut params = MessagesStream::new();
    params.model = model.clone();
    let original = req.clone();
    let mut meter = ex.meter;
    tokio::spawn(async move {
        let first_token_at =
            consume_responses_to_messages(upstream, &sender, &mut params, &original).await;
        meter.first_byte_maybe(first_token_at);
        let usage = TokenUsage::from_counts(
            params.input_tokens + params.cached_tokens,
            params.output_tokens,
            0,
            params.cached_tokens,
            0,
        );
        meter.ok(Some(&Collector::with_usage(usage)), &params.finish_reason);
    });

    Ok(started_stream(DIALECT, receiver, &message_id, &model).await)
}

async fn via_generate(mut ex: Exchange, req: Value) -> Result<Response, Response> {
    let model = ex.upstream_model().to_string();
    let oai = messages_to_chat_request(&req, &ex.alias, ex.stream);
    let work_dir = ex.app.work_dir.clone();
    let generate = build_generate_request(oai, &work_dir, chrono::Utc::now())
        .map_err(|err| ex.fail(ApiError::bad_request(format!("build cc request: {err}"))))?;
    let payload = ex.encode(&generate)?;
    let upstream = ex.send(payload).await?;
    let message_id = new_message_id();
    let client_model = ex.alias.clone();

    if !ex.stream {
        let mut collector = Collector::buffering();
        let mut meter = ex.meter;
        if let Err(err) = chat_sse::consume(upstream, &mut collector, None, process_line).await {
            let finish = collector.finish_reason();
            meter.fail_with(
                Some(&collector),
                StatusCode::BAD_GATEWAY.as_u16(),
                &err.message,
            );
            let _ = finish;
            return Err(DIALECT.error(&ApiError::gateway("upstream_error", err.message)));
        }
        let finish = collector.finish_reason();
        let body = via_generate_reply::message_from_collector(&collector, &message_id, &client_model);
        meter.ok(Some(&collector), &finish);
        return Ok((StatusCode::OK, Json(body)).into_response());
    }

    let (sender, receiver) = frame_channel();
    let mut meter = ex.meter;
    let stream_id = message_id.clone();
    let stream_model = model.clone();
    tokio::spawn(async move {
        let outcome =
            via_generate_reply::stream_to_messages(upstream, &sender, &stream_id, &stream_model).await;
        settle(&mut meter, outcome);
        send_done(&sender);
    });

    Ok(started_stream(DIALECT, receiver, &message_id, &model).await)
}

pub(super) fn settle(meter: &mut Meter, outcome: StreamOutcome) {
    meter.first_byte_maybe(outcome.first_token_at);
    match outcome.error {
        Some(message) => {
            meter.fail_with(None, StatusCode::BAD_GATEWAY.as_u16(), &message);
        }
        None => meter.ok(Some(&outcome.usage), &outcome.finish),
    }
}

async fn started_stream(
    dialect: Protocol,
    receiver: crate::net::sse::FrameReceiver,
    message_id: &str,
    model: &str,
) -> Response {
    let empty = message_start_event(message_id, model);
    crate::net::sse::first_frame_response(
        receiver,
        move |err| dialect.error(&err),
        move || (StatusCode::OK, Json(empty)).into_response(),
    )
    .await
}

fn fill_blank(value: &mut Value, key: &str, fallback: &str) {
    let blank = value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .is_empty();
    if blank {
        value[key] = json!(fallback);
    }
}

pub(crate) async fn consume_chat_to_messages(
    upstream: reqwest::Response,
    sender: &FrameSender,
    params: &mut MessagesStream,
) {
    let mut reader = SseReader::new(upstream);
    while let Some(line) = reader.next_line().await {
        let Some(payload) = data_payload(&line) else {
            continue;
        };
        if !chat_chunk_to_messages(payload, params, sender) {
            return;
        }
    }
    finalize_stream(params, sender);
}

pub(crate) async fn consume_responses_to_messages(
    upstream: reqwest::Response,
    sender: &FrameSender,
    params: &mut MessagesStream,
    original: &Value,
) -> Option<Instant> {
    let mut reader = SseReader::new(upstream);
    let mut machine = ResponsesToMessages::new(original);
    let mut first_token_at: Option<Instant> = None;

    while let Some(line) = reader.next_line().await {
        let Some(payload) = data_payload(&line).filter(|payload| *payload != "[DONE]") else {
            continue;
        };
        let Ok(event) = serde_json::from_str::<Value>(payload) else {
            continue;
        };
        for (name, body) in machine.convert(&event) {
            match name.as_str() {
                "message_start" => params.message_started = true,
                "message_delta" => {
                    params.message_delta_sent = true;
                    if let Some(reason) = body.pointer("/delta/stop_reason").and_then(Value::as_str)
                    {
                        params.finish_reason = reason.to_string();
                    }
                    let at = |key: &str| {
                        body.get("usage")
                            .and_then(|usage| usage.get(key))
                            .and_then(Value::as_i64)
                            .unwrap_or(0)
                    };
                    params.input_tokens = at("input_tokens");
                    params.output_tokens = at("output_tokens");
                    params.cached_tokens = at("cache_read_input_tokens");
                }
                "message_stop" => params.message_stop_sent = true,
                _ => {}
            }
            if first_token_at.is_none() && is_claude_token_event(&name, &body) {
                first_token_at = Some(Instant::now());
            }
            send_message_event(sender, &name, &body);
        }
    }
    first_token_at
}

static IMPLICIT_THINK: OnceLock<Mutex<HashSet<String>>> = OnceLock::new();

fn quirk_key(provider: &str, model: &str) -> String {
    format!("{provider}\u{1f}{model}")
}

fn implicit_think_known(provider: &str, model: &str) -> bool {
    IMPLICIT_THINK
        .get_or_init(Default::default)
        .lock()
        .map(|seen| seen.contains(&quirk_key(provider, model)))
        .unwrap_or(false)
}

fn remember_implicit_think(provider: &str, model: &str) {
    if let Ok(mut seen) = IMPLICIT_THINK.get_or_init(Default::default).lock() {
        seen.insert(quirk_key(provider, model));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn implicit_think_is_scoped_to_one_provider_and_model() {
        assert!(!implicit_think_known("InferX-test", "qwen"));
        remember_implicit_think("InferX-test", "qwen");
        assert!(implicit_think_known("InferX-test", "qwen"));
        assert!(!implicit_think_known("Other-test", "qwen"));
    }
}

const _: Option<HashMap<String, String>> = None;
