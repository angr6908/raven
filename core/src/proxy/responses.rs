use axum::body::Bytes;
use axum::extract::State;
use axum::http::{header, StatusCode};
use axum::response::{IntoResponse, Response};
use axum::Json;
use serde_json::Value;
use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Instant;

use crate::app::App;
use crate::net::error::ApiError;
use crate::net::sse::{
    frame_channel, parse_block, send_data, send_done, FrameSender, SseReader,
};
use crate::translate::responses::via_chat_reply::stream_chat_to_responses;
use crate::translate::responses::relay;
use crate::translate::responses::via_generate_reply;
use crate::translate::responses::via_chat_request::responses_to_chat_request;
use crate::translate::responses::{
    apply_responses_usage, build_completed_event, build_failed_event, chat_completion_to_responses, ensure_responses_usage_details, responses_id, normalize_responses_event,
    set_responses_model, unwrap_terminal_response_event,
};
use crate::translate::summary::{self, SummaryFormat};
use crate::translate::collect::Collector;
use crate::translate::tokens::is_responses_token_event;
use crate::translate::usage::TokenUsage;
use crate::protocol::Protocol;

use super::chat_sse::{self, process_line};
use super::{route, Exchange, Meter};

const PROTOCOL: Protocol = Protocol::Responses;

pub async fn handle(State(app): State<Arc<App>>, body: Bytes) -> Response {
    match run(app, body).await {
        Ok(response) | Err(response) => response,
    }
}

async fn run(app: Arc<App>, body: Bytes) -> Result<Response, Response> {
    let req: Value = serde_json::from_slice(&body)
        .map_err(|err| PROTOCOL.error(&ApiError::bad_request(format!("invalid request: {err}"))))?;
    let alias = req
        .get("model")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();
    if alias.is_empty() {
        return Err(PROTOCOL.error(&ApiError::bad_request("model is required")));
    }
    let stream = req.get("stream").and_then(Value::as_bool).unwrap_or(false);

    let target = route::resolve(&app, "responses", &alias).await;
    let protocol = target.provider.protocol();
    match protocol {
        Protocol::Chat => {
            let chat = responses_to_chat_request(&req, &alias, stream).map_err(|err| {
                PROTOCOL.error(&ApiError::bad_request(format!("build request: {err}")))
            })?;
            let effort = chat.reasoning_effort.clone();
            let ex = Exchange::open(app, PROTOCOL, target, &alias, stream, &effort);
            via_chat(ex, req, chat).await
        }
        Protocol::Responses => {
            let ex = Exchange::open(app, PROTOCOL, target, &alias, stream, "");
            via_responses(ex, req).await
        }
        _ => {
            let chat = responses_to_chat_request(&req, &alias, true).map_err(|err| {
                PROTOCOL.error(&ApiError::bad_request(format!("build request: {err}")))
            })?;
            let effort = chat.reasoning_effort.clone();
            let ex = Exchange::open(app, PROTOCOL, target, &alias, stream, &effort);
            via_generate(ex, req, chat).await
        }
    }
}

async fn via_chat(
    mut ex: Exchange,
    req: Value,
    mut chat: crate::translate::chat::types::ChatRequest,
) -> Result<Response, Response> {
    let model = ex.upstream_model().to_string();
    chat.model = model.clone();
    chat.stream = ex.stream;
    if ex.backend().needs_usage_opt_in() {
        chat.apply_openai_compat_defaults();
    }

    let payload = ex.encode(&chat)?;
    let upstream = ex.send(payload).await?;
    let resp_id = responses_id();

    if !ex.stream {
        let body = ex.read_body(upstream).await?;
        let mut request = req.clone();
        request["model"] = Value::String(model.clone());
        let response = chat_completion_to_responses(&body, &request, &resp_id, &model);

        let usage = body.get("usage").cloned().unwrap_or(Value::Null);
        let at = |pointer: &str| usage.pointer(pointer).and_then(Value::as_i64).unwrap_or(0);
        let counts = TokenUsage::from_counts(
            at("/prompt_tokens"),
            at("/completion_tokens"),
            at("/total_tokens"),
            at("/prompt_tokens_details/cached_tokens"),
            at("/output_tokens_details/reasoning_tokens"),
        );
        let finish = body
            .pointer("/choices/0/finish_reason")
            .and_then(Value::as_str)
            .unwrap_or("stop")
            .to_string();
        ex.meter.ok(Some(&Collector::with_usage(counts)), &finish);
        return Ok((StatusCode::OK, Json(response)).into_response());
    }

    let (sender, receiver) = frame_channel();
    let request_json = serde_json::to_vec(&chat).unwrap_or_default();
    let original_json = serde_json::to_vec(&req).unwrap_or_default();
    let stream_id = resp_id.clone();
    let mut meter = ex.meter;
    tokio::spawn(async move {
        let outcome = stream_chat_to_responses(
            upstream,
            sender,
            stream_id,
            model,
            original_json,
            request_json,
        )
        .await;
        super::messages::settle(&mut meter, outcome);
    });

    Ok(empty_stream(receiver, &resp_id, &ex.alias).await)
}

async fn via_responses(mut ex: Exchange, req: Value) -> Result<Response, Response> {
    let mut body = req.clone();
    body["model"] = Value::String(ex.upstream_model().to_string());
    relay::shape_for_codex(&mut body);
    summary::relay(
        &req,
        SummaryFormat::Responses,
        &mut body,
        SummaryFormat::Responses,
    );

    let payload = ex.encode(&body)?;
    let upstream = ex.send(payload).await?;

    let content_type = upstream
        .headers()
        .get(header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or_default()
        .to_string();

    if !ex.stream || !content_type.contains("text/event-stream") {
        let bytes = match upstream.bytes().await {
            Ok(bytes) => bytes,
            Err(err) => return Err(ex.gateway(format!("read: {err}"))),
        };
        let parsed: Value = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
        let kind = parsed.get("type").and_then(Value::as_str).unwrap_or("");
        if kind == "response.failed" || kind == "error" {
            return Err(ex.gateway(terminal_error_message(&parsed)));
        }

        let mut body = parsed
            .is_object()
            .then(|| unwrap_terminal_response_event(&parsed))
            .flatten();
        let mut collector = Collector::counting();
        if let Some(body) = body.as_mut() {
            ensure_responses_usage_details(body);
        }
        if let Some(usage) = body.as_ref().unwrap_or(&parsed).get("usage") {
            apply_responses_usage(&mut collector, usage);
        }
        ex.meter.ok(Some(&collector), "stop");
        return Ok(match body {
            Some(body) => (StatusCode::OK, Json(body)).into_response(),
            None => (StatusCode::OK, [(header::CONTENT_TYPE, content_type)], bytes).into_response(),
        });
    }

    let (sender, receiver) = frame_channel();
    let alias = ex.alias.clone();
    let mut meter = ex.meter;
    tokio::spawn(async move {
        relay_responses(upstream, &sender, &mut meter, &alias).await;
        send_done(&sender);
    });

    let no_events = || {
        PROTOCOL.error(&ApiError::gateway(
            "upstream_error",
            "upstream produced no events",
        ))
    };
    Ok(crate::net::sse::first_frame_response(receiver, |_| no_events(), no_events).await)
}

async fn via_generate(
    mut ex: Exchange,
    req: Value,
    chat: crate::translate::chat::types::ChatRequest,
) -> Result<Response, Response> {
    let identities = crate::translate::responses::tools::ToolIdentities::new(&req);
    let payload = ex.encode_generate(chat)?;
    let upstream = ex.send(payload).await?;
    let resp_id = responses_id();
    let model = ex.alias.clone();

    if !ex.stream {
        let mut collector = Collector::buffering();
        let mut meter = ex.meter;
        if let Err(err) = chat_sse::consume(upstream, &mut collector, None, process_line).await {
            meter.fail_with(
                Some(&collector),
                StatusCode::BAD_GATEWAY.as_u16(),
                &err.message,
            );
            return Err((
                StatusCode::BAD_GATEWAY,
                Json(build_failed_event("upstream_error", &err.message)),
            )
                .into_response());
        }
        let finish = collector.finish_reason();
        let body =
            via_generate_reply::completed_from_collector(&collector, &resp_id, &model, &identities);
        meter.ok(Some(&collector), &finish);
        return Ok((StatusCode::OK, Json(body)).into_response());
    }

    let (sender, receiver) = frame_channel();
    let mut meter = ex.meter;
    let stream_id = resp_id.clone();
    let stream_model = model.clone();
    tokio::spawn(async move {
        let outcome = via_generate_reply::stream_to_responses(
            upstream,
            &sender,
            &stream_id,
            &stream_model,
            &identities,
        )
        .await;
        super::messages::settle(&mut meter, outcome);
        send_done(&sender);
    });

    Ok(empty_stream(receiver, &resp_id, &model).await)
}

async fn empty_stream(
    receiver: crate::net::sse::FrameReceiver,
    resp_id: &str,
    model: &str,
) -> Response {
    let empty = build_completed_event(resp_id, model, "", "", &[], 0, 0, 0, 0, 0);
    crate::net::sse::first_frame_response(
        receiver,
        |err| PROTOCOL.error(&err),
        move || (StatusCode::OK, Json(empty)).into_response(),
    )
    .await
}

fn terminal_error_message(event: &Value) -> String {
    for pointer in ["/error/message", "/response/error/message"] {
        if let Some(message) = event
            .pointer(pointer)
            .and_then(Value::as_str)
            .filter(|message| !message.trim().is_empty())
        {
            return message.to_string();
        }
    }
    "upstream stream failed without error details".to_string()
}

async fn relay_responses(
    upstream: reqwest::Response,
    sender: &FrameSender,
    meter: &mut Meter,
    model: &str,
) {
    let mut reader = SseReader::new(upstream);
    let mut collector = Collector::counting();
    let mut seq: u64 = 0;
    let mut first_token_at: Option<Instant> = None;
    let mut terminal = false;
    let mut failure: Option<String> = None;
    let mut items_by_index: BTreeMap<i64, Value> = BTreeMap::new();
    let mut loose_items: Vec<Value> = Vec::new();

    while let Some(block) = reader.next_block().await {
        let (event_name, parsed) = parse_block(&block);
        let Some(mut parsed) = parsed else {
            send_data(sender, block.into_bytes());
            continue;
        };
        let kind = parsed
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();

        match kind.as_str() {
            "error" | "response.failed" => {
                terminal = true;
                failure = Some(terminal_error_message(&parsed));
            }
            "response.output_item.done" => {
                collect_item(&parsed, &mut items_by_index, &mut loose_items)
            }
            "response.completed" | "response.incomplete" => {
                terminal = true;
                hydrate_output(&mut parsed, &items_by_index, &loose_items);
                if let Some(usage) = parsed.pointer("/response/usage") {
                    apply_responses_usage(&mut collector, usage);
                }
            }
            _ => {}
        }

        if first_token_at.is_none() && is_responses_token_event(&parsed) {
            first_token_at = Some(Instant::now());
        }
        normalize_responses_event(&mut parsed, &mut seq);
        set_responses_model(&mut parsed, model);

        let name = event_name.unwrap_or(kind);
        let data = serde_json::to_string(&parsed).unwrap_or_default();
        let frame = match name.is_empty() {
            true => format!("data: {data}\n\n"),
            false => format!("event: {name}\ndata: {data}\n\n"),
        };
        send_data(sender, frame);

        if terminal {
            break;
        }
    }

    if !terminal {
        let message = "stream error: stream disconnected before completion: stream closed before response.completed";
        failure = Some(message.to_string());
        let mut payload = build_failed_event("upstream_error", message);
        normalize_responses_event(&mut payload, &mut seq);
        let data = serde_json::to_string(&payload).unwrap_or_default();
        send_data(sender, format!("event: response.failed\ndata: {data}\n\n"));
    }

    meter.first_byte_maybe(first_token_at);
    match failure {
        Some(message) => {
            let status = match terminal {
                true => StatusCode::BAD_GATEWAY,
                false => StatusCode::REQUEST_TIMEOUT,
            };
            meter.fail_with(Some(&collector), status.as_u16(), &message);
        }
        None => meter.ok(Some(&collector), "stop"),
    }
}

fn collect_item(event: &Value, by_index: &mut BTreeMap<i64, Value>, loose: &mut Vec<Value>) {
    let Some(item) = event.get("item").filter(|item| item.is_object()) else {
        return;
    };
    match event.get("output_index").and_then(Value::as_i64) {
        Some(index) => {
            by_index.insert(index, item.clone());
        }
        None => loose.push(item.clone()),
    }
}

fn hydrate_output(event: &mut Value, by_index: &BTreeMap<i64, Value>, loose: &[Value]) {
    let Some(response) = event.get_mut("response").and_then(Value::as_object_mut) else {
        return;
    };
    let existing: Vec<Value> = response
        .get("output")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !existing.is_empty() {
        let hydrated = existing
            .into_iter()
            .enumerate()
            .map(|(index, mut item)| {
                let has_id = item
                    .get("id")
                    .and_then(Value::as_str)
                    .is_some_and(|id| !id.trim().is_empty());
                if has_id {
                    return item;
                }
                if let Some(id) = by_index
                    .get(&(index as i64))
                    .and_then(|collected| collected.get("id"))
                    .and_then(Value::as_str)
                    .filter(|id| !id.trim().is_empty())
                {
                    item["id"] = Value::String(id.to_string());
                }
                item
            })
            .collect();
        response.insert("output".into(), Value::Array(hydrated));
        return;
    }
    if by_index.is_empty() && loose.is_empty() {
        return;
    }
    let mut rebuilt: Vec<Value> = by_index.values().cloned().collect();
    rebuilt.extend(loose.iter().cloned());
    response.insert("output".into(), Value::Array(rebuilt));
}
