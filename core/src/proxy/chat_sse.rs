use axum::http::StatusCode;
use axum::response::Response;
use chrono::Utc;
use serde_json::{json, Value};
use std::time::Instant;

use crate::net::error::{ApiError, ErrorEnvelope};
use crate::protocol::Protocol;
use crate::net::sse::{frame_channel, SseReader, StreamFrame};
use tokio::sync::mpsc;
use crate::translate::finish::{map_finish_reason, normalize_chat_finish_reason};
use crate::translate::chat::types::{
    ChatChoice, ChatCompletion, ChatDelta, ChatToolCall, ChatToolCallDelta,
    ChatToolCallDeltaFunction, ChatUsage,
};
use crate::translate::generate::types::GenerateEvent;

use crate::translate::collect::Collector;
use super::Meter;

pub struct StreamError {
    pub message: String,
    pub started: bool,
}

pub struct SseSink {
    sender: mpsc::UnboundedSender<StreamFrame>,
    id: String,
    model: String,
    created: i64,
    started: bool,
    first_byte: Option<Instant>,
    first_token: Option<Instant>,
}

impl SseSink {
    pub fn new(
        sender: mpsc::UnboundedSender<StreamFrame>,
        id: String,
        model: String,
        created: i64,
    ) -> Self {
        Self {
            sender,
            id,
            model,
            created,
            started: false,
            first_byte: None,
            first_token: None,
        }
    }

    pub fn started(&self) -> bool {
        self.started
    }

    pub fn effective_first_byte(&self) -> Option<Instant> {
        self.first_token.or(self.first_byte)
    }

    fn start(&mut self) {
        if self.started {
            return;
        }
        self.started = true;
        self.first_byte = Some(Instant::now());
    }

    fn write_json(&mut self, payload: &impl serde::Serialize) -> Result<(), String> {
        let mut frame = Vec::with_capacity(256);
        frame.extend_from_slice(b"data: ");
        serde_json::to_writer(&mut frame, payload)
            .map_err(|err| format!("marshal sse payload: {err}"))?;
        frame.extend_from_slice(b"\n\n");
        self.send_frame(frame)
    }

    fn write_raw(&mut self, data: &str) -> Result<(), String> {
        self.send_frame(format!("data: {data}\n\n").into_bytes())
    }

    fn send_frame(&mut self, frame: Vec<u8>) -> Result<(), String> {
        self.start();
        self.sender
            .send(StreamFrame::Data(frame))
            .map_err(|_| "response stream closed".to_string())
    }

    fn base_chunk(&self, choices: Vec<ChatChoice>, usage: Option<ChatUsage>) -> ChatCompletion {
        ChatCompletion {
            id: self.id.clone(),
            object: "chat.completion.chunk".to_string(),
            created: self.created,
            model: self.model.clone(),
            choices,
            usage,
        }
    }

    pub fn chunk(
        &mut self,
        mut delta: Option<ChatDelta>,
        finish: Option<String>,
    ) -> Result<(), String> {
        if !self.started {
            if let Some(delta) = delta.as_mut() {
                delta.role = "assistant".to_string();
            }
            self.start();
        }

        if self.first_token.is_none()
            && (finish.as_deref().is_some_and(|reason| !reason.is_empty())
                || delta.as_ref().is_some_and(|d| {
                    d.content.as_deref().is_some_and(|t| !t.is_empty())
                        || d.reasoning_content
                            .as_deref()
                            .is_some_and(|t| !t.is_empty())
                        || d.tool_calls.iter().any(|call| {
                            !call.function.name.is_empty() || !call.function.arguments.is_empty()
                        })
                }))
        {
            self.first_token = Some(Instant::now());
        }
        self.write_json(&self.base_chunk(
            vec![ChatChoice {
                index: 0,
                delta,
                message: None,
                finish_reason: finish,
            }],
            None,
        ))
    }

    pub fn on_content(&mut self, delta: String) -> Result<(), String> {
        self.chunk(
            Some(ChatDelta {
                content: Some(delta),
                ..ChatDelta::default()
            }),
            None,
        )
    }

    pub fn on_reasoning(&mut self, delta: String) -> Result<(), String> {
        self.chunk(
            Some(ChatDelta {
                reasoning_content: Some(delta),
                ..ChatDelta::default()
            }),
            None,
        )
    }

    pub fn on_tool_call(&mut self, index: usize, call: &ChatToolCall) -> Result<(), String> {
        self.chunk(
            Some(ChatDelta {
                tool_calls: vec![ChatToolCallDelta {
                    index,
                    id: call.id.clone(),
                    r#type: "function".to_string(),
                    function: ChatToolCallDeltaFunction {
                        name: call.function.name.clone(),
                        arguments: call.function.arguments.clone(),
                    },
                }],
                ..ChatDelta::default()
            }),
            None,
        )
    }

    pub fn finalize(&mut self, reason: String, usage: Option<ChatUsage>) -> Result<(), String> {
        self.chunk(Some(ChatDelta::default()), Some(reason))?;
        if let Some(usage) = usage {
            self.write_json(&self.base_chunk(Vec::new(), Some(usage)))?;
        }
        self.write_raw("[DONE]")
    }

    pub fn write_stream_error(&mut self, message: &str) -> Result<(), String> {
        self.write_json(&ErrorEnvelope::new(message, "upstream_error", ""))?;
        self.write_raw("[DONE]")
    }
}

pub async fn consume<F, T>(
    response: reqwest::Response,
    collector: &mut Collector,
    mut sink: Option<&mut SseSink>,
    mut process: F,
) -> Result<(), StreamError>
where
    F: FnMut(&str, &mut Collector, Option<&mut SseSink>) -> Result<T, StreamError>,
{
    let started = |sink: &Option<&mut SseSink>| sink.as_ref().is_some_and(|sink| sink.started());
    let mut reader = SseReader::new(response);
    while let Some(line) = reader.next_line().await {
        process(&line, collector, sink.as_deref_mut())?;
    }
    if let Some(message) = reader.error() {
        return Err(StreamError {
            message: message.to_string(),
            started: started(&sink),
        });
    }
    if let Some(sink) = sink {
        sink.finalize(collector.finish_reason(), collector.openai_usage())
            .map_err(|message| StreamError {
                message,
                started: true,
            })?;
    }
    Ok(())
}

pub async fn relay<F, T>(
    mut meter: Meter,
    dialect: Protocol,
    response: reqwest::Response,
    model: String,
    process: F,
) -> Response
where
    F: FnMut(&str, &mut Collector, Option<&mut SseSink>) -> Result<T, StreamError> + Send + 'static,
    T: 'static,
{
    let (sender, receiver) = frame_channel();
    let mut sink = SseSink::new(sender.clone(), completion_id(), model, Utc::now().timestamp());

    let task = tokio::spawn(async move {
        let mut collector = Collector::counting();
        let result = consume(response, &mut collector, Some(&mut sink), process).await;
        meter.first_byte_maybe(sink.effective_first_byte());
        let finish = collector.finish_reason();
        match result {
            Ok(()) => {
                meter.ok(Some(&collector), &finish);
                let _ = sender.send(StreamFrame::Done);
            }
            Err(err) if err.started => {
                meter.fail_with(Some(&collector), StatusCode::OK.as_u16(), &err.message);
                let _ = sender.send(StreamFrame::Done);
            }
            Err(err) => {
                meter.fail_with(
                    Some(&collector),
                    StatusCode::BAD_GATEWAY.as_u16(),
                    &err.message,
                );
                let _ = sender.send(StreamFrame::PreFailure(ApiError::gateway(
                    "upstream_error",
                    err.message,
                )));
            }
        }
    });

    match crate::net::sse::first_frame(receiver).await {
        Ok(response) => response,
        Err(failure) => {
            let _ = task.await;
            dialect.error(&failure.unwrap_or_else(|| {
                ApiError::gateway("upstream_error", "upstream stream ended without output")
            }))
        }
    }
}

pub async fn buffer<F, T>(
    meter: &mut Meter,
    response: reqwest::Response,
    model: &str,
    process: F,
) -> Result<Response, ApiError>
where
    F: FnMut(&str, &mut Collector, Option<&mut SseSink>) -> Result<T, StreamError>,
{
    use axum::response::IntoResponse;
    let mut collector = Collector::buffering();
    if let Err(err) = consume(response, &mut collector, None, process).await {
        let finish = collector.finish_reason();
        meter.fail_with(
            Some(&collector),
            StatusCode::BAD_GATEWAY.as_u16(),
            &err.message,
        );
        let _ = finish;
        return Err(ApiError::gateway("upstream_error", err.message));
    }
    let finish = collector.finish_reason();
    let completion = ChatCompletion {
        id: completion_id(),
        object: "chat.completion".to_string(),
        created: Utc::now().timestamp(),
        model: model.to_string(),
        choices: vec![ChatChoice {
            index: 0,
            delta: None,
            message: Some(crate::translate::chat::types::ChatMessageOut {
                role: "assistant".to_string(),
                content: collector.content.clone(),
                reasoning_content: collector.reasoning.clone(),
                tool_calls: collector.tool_calls.clone(),
            }),
            finish_reason: Some(finish.clone()),
        }],
        usage: collector.openai_usage(),
    };
    meter.ok(Some(&collector), &finish);
    Ok((StatusCode::OK, axum::Json(completion)).into_response())
}

pub fn completion_id() -> String {
    crate::translate::collect::completion_id()
}

pub(crate) fn process_openai_line(
    line: &str,
    state: &mut Collector,
    mut sink: Option<&mut SseSink>,
) -> Result<bool, StreamError> {
    if state.stream_done {
        return Ok(true);
    }
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with(':') || trimmed.starts_with("event:") {
        return Ok(false);
    }
    let payload = if let Some(after) = trimmed.strip_prefix("data:") {
        after.trim()
    } else {
        trimmed
    };
    if payload.is_empty() {
        return Ok(false);
    }
    if payload == "[DONE]" {
        state.stream_done = true;
        return Ok(true);
    }
    let Ok(mut event) = serde_json::from_str::<Value>(payload) else {
        return Ok(false);
    };
    let started = sink.as_ref().is_some_and(|sink| sink.started());
    let wrap = move |message: String| StreamError { message, started };

    if event
        .pointer("/choices/0")
        .is_some_and(|choice| choice.get("delta").is_none() && choice.get("message").is_some())
    {
        if let Some(choice) = event
            .get_mut("choices")
            .and_then(Value::as_array_mut)
            .and_then(|choices| choices.first_mut())
        {
            if let Some(message) = choice.get("message").cloned() {
                let mut delta = message;

                if let Some(calls) = delta.get_mut("tool_calls").and_then(Value::as_array_mut) {
                    for (position, call) in calls.iter_mut().enumerate() {
                        if call.get("index").is_none() {
                            call["index"] = json!(position);
                        }
                    }
                }
                choice["message"] = delta.clone();
                choice["delta"] = delta;
            }
        }
    }

    let choice = event
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first());

    if let Some(text) = choice
        .and_then(|c| c.get("delta"))
        .and_then(|delta| delta.get("content"))
        .and_then(Value::as_str)
    {
        if !text.is_empty() {
            if state.collect_body {
                state.content.push_str(text);
            }
            if let Some(sink) = sink.as_deref_mut() {
                sink.on_content(text.to_string()).map_err(wrap)?;
            }
        }
    }

    if let Some(reasoning) = choice
        .and_then(|c| c.get("delta"))
        .and_then(|delta| {
            delta
                .get("reasoning_content")
                .filter(|v| !v.as_str().unwrap_or("").is_empty())
                .or_else(|| delta.get("reasoning"))
        })
        .and_then(Value::as_str)
    {
        if !reasoning.is_empty() {
            if state.collect_body {
                state.reasoning.push_str(reasoning);
            }
            if let Some(sink) = sink.as_deref_mut() {
                sink.on_reasoning(reasoning.to_string()).map_err(wrap)?;
            }
        }
    }

    if let Some(tool_calls) = choice
        .and_then(|c| c.get("delta"))
        .and_then(|delta| delta.get("tool_calls"))
        .and_then(Value::as_array)
    {
        for call in tool_calls {
            let id = call
                .get("id")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let name = call
                .get("function")
                .and_then(|f| f.get("name"))
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string();
            let arguments = crate::translate::json::tool_arguments_string(
                call.get("function").and_then(|f| f.get("arguments")),
            );
            let index = call.get("index").and_then(Value::as_i64).unwrap_or(0) as usize;
            let oai_call = ChatToolCall {
                id: id.clone(),
                r#type: "function".to_string(),
                function: crate::translate::chat::types::ChatFunctionCall { name, arguments },
            };
            if state.collect_body {
                state.tool_calls.push(oai_call.clone());
            }
            state.tool_call_count = state.tool_call_count.max(index + 1);
            if let Some(sink) = sink.as_deref_mut() {
                sink.on_tool_call(index, &oai_call).map_err(wrap)?;
            }
        }
    }

    if let Some(reason) = choice
        .and_then(|c| c.get("finish_reason"))
        .and_then(Value::as_str)
    {
        state.finish = normalize_chat_finish_reason(reason);
    }

    if event.get("usage").is_some() {
        let prompt = event
            .get("usage")
            .and_then(|u| u.get("prompt_tokens"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let completion = event
            .get("usage")
            .and_then(|u| u.get("completion_tokens"))
            .and_then(Value::as_i64)
            .unwrap_or(0);
        let total = event
            .get("usage")
            .and_then(|u| u.get("total_tokens"))
            .and_then(Value::as_i64)
            .unwrap_or(prompt + completion);
        state.usage = Some(crate::translate::usage::TokenUsage {
            input_tokens: prompt,
            output_tokens: completion,
            total_tokens: total,
            cached_input_tokens: event
                .get("usage")
                .and_then(|u| u.get("prompt_tokens_details"))
                .and_then(|d| d.get("cached_tokens"))
                .and_then(Value::as_i64)
                .unwrap_or(0),
            input_token_details: crate::translate::usage::InputTokenDetails {
                cache_read_tokens: 0,

                cache_write_tokens: event
                    .get("usage")
                    .and_then(|u| u.get("prompt_tokens_details"))
                    .and_then(|d| d.get("cached_creation_tokens"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
            },

            output_token_details: crate::translate::usage::OutputTokenDetails {
                reasoning_tokens: event
                    .get("usage")
                    .and_then(|u| u.get("completion_tokens_details"))
                    .and_then(|d| d.get("reasoning_tokens"))
                    .and_then(Value::as_i64)
                    .unwrap_or(0),
            },
        });
    }
    Ok(false)
}

pub(crate) fn process_line(
    line: &str,
    state: &mut Collector,
    sink: Option<&mut SseSink>,
) -> Result<(), StreamError> {
    let Some(event) = parse_event_line(line) else {
        return Ok(());
    };
    let started = sink.as_ref().is_some_and(|sink| sink.started());
    let wrap = move |message: String| StreamError { message, started };
    match event.r#type.as_str() {
        "text-delta" => {
            if event.text.is_empty() {
                return Ok(());
            }
            if state.collect_body {
                state.content.push_str(&event.text);
            }
            if let Some(sink) = sink {
                sink.on_content(event.text).map_err(wrap)?;
            }
            Ok(())
        }
        "reasoning-delta" => {
            if event.text.is_empty() {
                return Ok(());
            }
            if state.collect_body {
                state.reasoning.push_str(&event.text);
            }
            if let Some(sink) = sink {
                sink.on_reasoning(event.text).map_err(wrap)?;
            }
            Ok(())
        }
        "tool-call" => {
            let call = ChatToolCall {
                id: event.tool_call_id,
                r#type: "function".to_string(),
                function: crate::translate::chat::types::ChatFunctionCall {
                    name: event.tool_name,
                    arguments: serde_json::to_string(&input_to_arguments(event.input))
                        .unwrap_or_else(|_| "{}".to_string()),
                },
            };
            let index = state.tool_call_count;
            state.tool_call_count += 1;
            if state.collect_body {
                state.tool_calls.push(call.clone());
            }
            if let Some(sink) = sink {
                sink.on_tool_call(index, &call).map_err(wrap)?;
            }
            Ok(())
        }
        "finish" => {
            state.finish = map_finish_reason(&event.finish_reason);
            if let Some(usage) = event.total_usage {
                state.usage = Some(usage);
            }
            Ok(())
        }
        "error" => {
            let message = error_event_message(event.error.as_ref());

            if let Some(sink) = sink.filter(|sink| sink.started()) {
                sink.write_stream_error(&message).map_err(wrap)?;
            }
            Err(wrap(message))
        }
        _ => Ok(()),
    }
}

fn parse_event_line(line: &str) -> Option<GenerateEvent> {
    let trimmed = line.trim();
    if trimmed.is_empty() || trimmed.starts_with(':') || trimmed.starts_with("event:") {
        return None;
    }
    let trimmed = if let Some(after) = trimmed.strip_prefix("data:") {
        after.trim()
    } else {
        trimmed
    };
    if trimmed.is_empty() || trimmed == "[DONE]" {
        return None;
    }
    serde_json::from_str::<GenerateEvent>(trimmed).ok()
}

fn error_event_message(raw: Option<&Value>) -> String {
    let Some(raw) = raw else {
        return "upstream stream error".to_string();
    };
    if let Some(text) = raw.as_str() {
        if !text.is_empty() {
            return text.to_string();
        }
    }
    if let Some(message) = raw.get("message").and_then(Value::as_str) {
        if !message.is_empty() {
            return message.to_string();
        }
    }
    raw.to_string()
}

fn input_to_arguments(input: Value) -> Value {
    if input.is_null() {
        json!({})
    } else {
        input
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    
    use serde_json::json;

    #[test]
    fn content_after_done_is_dropped() {
        let mut collector = Collector::buffering();
        process_openai_line(
            "data: {\"choices\":[{\"delta\":{\"content\":\"before\"}}]}",
            &mut collector,
            None,
        )
        .ok();
        assert_eq!(collector.content, "before");

        let terminal = process_openai_line("data: [DONE]", &mut collector, None)
            .ok()
            .unwrap();
        assert!(terminal);

        process_openai_line(
            "data: {\"choices\":[{\"delta\":{\"content\":\"after\"}}]}",
            &mut collector,
            None,
        )
        .ok();
        assert_eq!(collector.content, "before");
    }

    #[test]
    fn buffered_completion_is_rewritten_into_stream_shape() {
        let mut collector = Collector::buffering();
        let line = format!(
            "{}",
            serde_json::json!({
                "id": "chatcmpl-1", "object": "chat.completion",
                "choices": [{"index": 0, "message": {"role": "assistant", "content": "hello",
                    "tool_calls": [
                        {"id": "c1", "type": "function", "function": {"name": "bash", "arguments": {"command": "ls"}}},
                        {"id": "c2", "type": "function", "function": {"name": "read", "arguments": {"path": "a"}}}]},
                    "finish_reason": "tool_calls"}],
                "usage": {"prompt_tokens": 7, "completion_tokens": 4,
                          "completion_tokens_details": {"reasoning_tokens": 2}},
            })
        );
        process_openai_line(&line, &mut collector, None).ok();
        assert_eq!(collector.content, "hello");

        assert_eq!(collector.tool_calls.len(), 2);
        assert_eq!(collector.tool_calls[0].function.name, "bash");
        assert_eq!(
            collector.tool_calls[0].function.arguments,
            json!({"command": "ls"}).to_string()
        );
        assert_eq!(collector.tool_calls[1].function.name, "read");
        assert_eq!(collector.finish, "tool_calls");
        let usage = collector.usage.expect("usage parsed");
        assert_eq!(usage.input_tokens, 7);
        assert_eq!(usage.output_token_details.reasoning_tokens, 2);
    }

    #[test]
    fn sink_ttft_prefers_first_token_over_first_byte() {
        let (sender, _receiver) = mpsc::unbounded_channel::<StreamFrame>();
        let mut sink = SseSink::new(sender, "chatcmpl-x".into(), "m".into(), 0);

        sink.chunk(Some(ChatDelta::default()), None).unwrap();
        assert!(sink.first_token.is_none());
        assert_eq!(sink.effective_first_byte(), sink.first_byte);

        let byte = sink.first_byte.unwrap();
        sink.on_content("hi".into()).unwrap();
        let token = sink
            .first_token
            .expect("content delta stamped the token time");
        assert!(token >= byte);
        assert_eq!(sink.effective_first_byte(), Some(token));
    }

    #[test]
    fn normal_streams_are_unaffected() {
        let mut collector = Collector::buffering();
        for part in ["Hel", "lo"] {
            process_openai_line(
                &format!("data: {{\"choices\":[{{\"delta\":{{\"content\":\"{part}\"}}}}]}}"),
                &mut collector,
                None,
            )
            .ok();
        }
        assert_eq!(collector.content, "Hello");
    }
}
