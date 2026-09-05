pub mod relay;
pub mod stream_state;
pub mod tools;
pub mod via_chat_reply;
pub mod via_chat_request;
pub mod via_generate_reply;

use axum::http::StatusCode;
use serde_json::{json, Value};
use std::collections::HashSet;
use tokio::sync::mpsc;

use crate::net::sse::StreamFrame;
use crate::translate::ids::uuid_v4;
use crate::translate::usage::TokenUsage;
use chrono::Utc;

pub(crate) fn responses_id() -> String {
    format!("resp_{}", uuid_v4().replace('-', ""))
}

pub(crate) fn output_item_id() -> String {
    format!("item_{}", uuid_v4().replace('-', ""))
}

pub(crate) struct ResponsesToolCall<'a> {
    pub call_id: &'a str,
    pub name: &'a str,
    pub arguments: &'a str,
}

pub(crate) fn function_call_output_item(call: &ResponsesToolCall<'_>) -> Value {
    json!({
        "id": format!("fc_{}", call.call_id),
        "type": "function_call",
        "status": "completed",
        "arguments": call.arguments,
        "call_id": call.call_id,
        "name": call.name,
    })
}

pub(crate) fn build_completed_event(
    id: &str,
    model: &str,
    output_text: &str,
    reasoning_text: &str,
    tool_calls: &[ResponsesToolCall<'_>],
    input_tokens: i64,
    output_tokens: i64,
    total_tokens: i64,
    cached_tokens: i64,
    reasoning_tokens: i64,
) -> Value {
    let mut output = Vec::new();
    if !reasoning_text.is_empty() {
        output.push(json!({
            "id": format!("rs_{}", id.strip_prefix("resp_").unwrap_or(id)),
            "type": "reasoning",
            "encrypted_content": "",
            "summary": [{"type": "summary_text", "text": reasoning_text}],
        }));
    }
    if !output_text.is_empty() {
        output.push(json!({
            "id": output_item_id(),
            "type": "message",
            "status": "completed",
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "annotations": [],
                "logprobs": [],
                "text": output_text,
            }],
        }));
    }
    output.extend(tool_calls.iter().map(function_call_output_item));
    json!({
        "type": "response.completed",
        "response": {
            "id": id,
            "object": "response",
            "created_at": Utc::now().timestamp(),

            "status": "completed",
            "model": model,
            "output": output,

            "usage": {
                "input_tokens": input_tokens,
                "output_tokens": output_tokens,
                "total_tokens": total_tokens,
                "input_tokens_details": {"cached_tokens": cached_tokens},
                "output_tokens_details": {"reasoning_tokens": reasoning_tokens},
            },
        },
    })
}

pub(crate) fn build_text_delta(delta: &str, item_id: &str, output_index: usize) -> Value {
    json!({
        "type": "response.output_text.delta",
        "delta": delta,
        "item_id": item_id,
        "output_index": output_index,

        "content_index": 0,
    })
}

pub(crate) fn reasoning_item_id(response_id: &str) -> String {
    format!(
        "rs_{}",
        response_id.strip_prefix("resp_").unwrap_or(response_id)
    )
}

pub(crate) fn build_reasoning_open(item_id: &str, output_index: usize) -> Vec<Value> {
    vec![
        json!({
            "type": "response.output_item.added",
            "output_index": output_index,
            "item": {
                "id": item_id,
                "type": "reasoning",
                "status": "in_progress",
                "encrypted_content": "",
                "summary": [],
            },
        }),
        json!({
            "type": "response.reasoning_summary_part.added",
            "item_id": item_id,
            "output_index": output_index,
            "summary_index": 0,
            "part": {"type": "summary_text", "text": ""},
        }),
    ]
}

pub(crate) fn build_reasoning_delta(delta: &str, item_id: &str, output_index: usize) -> Value {
    json!({
        "type": "response.reasoning_summary_text.delta",
        "delta": delta,
        "item_id": item_id,
        "output_index": output_index,
        "summary_index": 0,
    })
}

pub(crate) fn build_reasoning_close(text: &str, item_id: &str, output_index: usize) -> Vec<Value> {
    vec![
        json!({
            "type": "response.reasoning_summary_text.done",
            "item_id": item_id,
            "output_index": output_index,
            "summary_index": 0,
            "text": text,
        }),
        json!({
            "type": "response.reasoning_summary_part.done",
            "item_id": item_id,
            "output_index": output_index,
            "summary_index": 0,
            "part": {"type": "summary_text", "text": text},
        }),
        json!({
            "type": "response.output_item.done",
            "output_index": output_index,
            "item": {
                "id": item_id,
                "type": "reasoning",
                "status": "completed",
                "encrypted_content": "",
                "summary": [{"type": "summary_text", "text": text}],
            },
        }),
    ]
}

pub(crate) fn build_function_call_events(
    call: &ResponsesToolCall<'_>,
    output_index: usize,
) -> Vec<Value> {
    let item_id = format!("fc_{}", call.call_id);
    let mut item = function_call_output_item(call);
    let opening = {
        let mut opening = item.clone();
        opening["status"] = json!("in_progress");
        opening["arguments"] = json!("");
        opening
    };
    item["status"] = json!("completed");
    vec![
        json!({
            "type": "response.output_item.added",
            "output_index": output_index,
            "item": opening,
        }),
        json!({
            "type": "response.function_call_arguments.delta",
            "item_id": item_id,
            "output_index": output_index,
            "delta": call.arguments,
        }),
        json!({
            "type": "response.function_call_arguments.done",
            "item_id": item_id,
            "output_index": output_index,
            "arguments": call.arguments,
        }),
        json!({
            "type": "response.output_item.done",
            "output_index": output_index,
            "item": item,
        }),
    ]
}

pub(crate) fn build_message_open(item_id: &str, output_index: usize) -> Vec<Value> {
    vec![
        json!({
            "type": "response.output_item.added",
            "output_index": output_index,
            "item": {
                "id": item_id,
                "type": "message",
                "status": "in_progress",
                "content": [],
                "role": "assistant",
            },
        }),
        json!({
            "type": "response.content_part.added",
            "item_id": item_id,
            "output_index": output_index,
            "content_index": 0,
            "part": {"type": "output_text", "annotations": [], "logprobs": [], "text": ""},
        }),
    ]
}

pub(crate) fn build_message_close(text: &str, item_id: &str, output_index: usize) -> Vec<Value> {
    vec![
        json!({
            "type": "response.output_text.done",
            "item_id": item_id,
            "output_index": output_index,
            "content_index": 0,
            "text": text,
            "logprobs": [],
        }),
        json!({
            "type": "response.content_part.done",
            "item_id": item_id,
            "output_index": output_index,
            "content_index": 0,
            "part": {"type": "output_text", "annotations": [], "logprobs": [], "text": text},
        }),
        build_output_item_done(output_index, item_id, text),
    ]
}

pub(crate) fn build_output_item_done(output_index: usize, item_id: &str, text: &str) -> Value {
    json!({
        "type": "response.output_item.done",
        "item": {
            "id": item_id,
            "type": "message",
            "role": "assistant",
            "content": [{
                "type": "output_text",
                "text": text,
                "annotations": [],
            }],
            "status": "completed",
        },
        "output_index": output_index,
    })
}

pub(crate) fn build_failed_event(code: &str, message: &str) -> Value {
    let error = json!({"code": code, "message": message});
    json!({
        "type": "response.failed",
        "error": error.clone(),
        "response": {
            "id": responses_id(),
            "object": "response",
            "created_at": Utc::now().timestamp(),
            "status": "failed",
            "model": "",
            "output": [],
            "error": error,
        },
    })
}

pub(crate) fn sse_event(
    sender: &mpsc::UnboundedSender<StreamFrame>,
    seq: &mut u64,
    event_type: &str,
    data: &Value,
) {
    let mut data = data.clone();
    normalize_responses_event(&mut data, seq);
    let data = &data;
    let payload = serde_json::to_string(data).unwrap_or_default();
    let frame = format!("event: {event_type}\ndata: {payload}\n\n");
    let _ = sender.send(StreamFrame::Data(frame.into_bytes()));
}

pub(crate) fn apply_responses_usage(collector: &mut crate::translate::collect::Collector, usage: &Value) {
    collector.usage = Some(TokenUsage::from_responses_usage(usage));
}

pub(crate) fn responses_tool_state_key(output_index: usize, tool_index: usize) -> String {
    format!("{output_index}:{tool_index}")
}

pub(crate) fn request_model_name(original: &[u8], translated: &[u8]) -> String {
    let parse = |raw: &[u8]| serde_json::from_slice::<Value>(raw).unwrap_or(Value::Null);
    tools::request_model_name(&parse(original), &parse(translated))
}

pub(crate) fn incomplete_by_finish_reason(reason: &str) -> (Option<Value>, bool) {
    match reason {
        "length" | "max_tokens" => (Some(json!({"reason": "max_output_tokens"})), true),
        "content_filter" => (Some(json!({"reason": "content_filter"})), true),
        _ => (None, false),
    }
}

pub(crate) fn responses_custom_tool_names(request_json: &[u8]) -> HashSet<String> {
    let Ok(value) = serde_json::from_slice::<Value>(request_json) else {
        return HashSet::new();
    };
    tools::responses_custom_tool_names(&value)
}

pub(crate) fn unwrap_custom_tool_input(arguments: &str) -> Value {
    if let Ok(value) = serde_json::from_str::<Value>(arguments) {
        if let Some(input) = value.get("input") {
            return if input.is_string() {
                input.clone()
            } else {
                input.clone()
            };
        }
    }
    json!(arguments)
}

pub(crate) fn responses_single_custom_tool_name(request_json: &[u8]) -> Option<String> {
    let value = serde_json::from_slice::<Value>(request_json).ok()?;
    match tools::responses_single_custom_tool_name(&value) {
        Some((name, true)) => Some(name),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn responses_usage_carries_cache_reads_and_writes() {
        let mut collector = crate::translate::collect::Collector::counting();
        apply_responses_usage(
            &mut collector,
            &serde_json::json!({
                "input_tokens": 1000,
                "output_tokens": 20,
                "total_tokens": 1020,
                "input_tokens_details": {"cached_tokens": 900, "cache_write_tokens": 50},
                "output_tokens_details": {"reasoning_tokens": 8},
            }),
        );

        assert_eq!(collector.usage_input(), 1000);
        assert_eq!(collector.cached_tokens(), 900);
        assert_eq!(collector.cache_write_tokens(), 50);
        assert_eq!(collector.usage_output(), 20);
    }

    #[test]
    fn responses_usage_without_details_reports_no_cache() {
        let mut collector = crate::translate::collect::Collector::counting();
        apply_responses_usage(
            &mut collector,
            &serde_json::json!({"input_tokens": 10, "output_tokens": 2}),
        );
        assert_eq!(collector.usage_input(), 10);
        assert_eq!(collector.cached_tokens(), 0);
        assert_eq!(collector.cache_write_tokens(), 0);

        assert_eq!(collector.total_tokens(), 12);
    }

    #[test]
    pub(crate) fn builds_completed_event() {
        let event = build_completed_event(
            "resp_1",
            "gemini-3-pro",
            "hello",
            "hmm",
            &[],
            10,
            5,
            15,
            0,
            3,
        );
        assert_eq!(event["type"], "response.completed");
        assert_eq!(event["response"]["id"], "resp_1");

        assert_eq!(event["response"]["output"][0]["type"], "reasoning");
        assert_eq!(event["response"]["output"][0]["summary"][0]["text"], "hmm");
        assert_eq!(event["response"]["output"][1]["type"], "message");
        assert_eq!(
            event["response"]["output"][1]["content"][0]["text"],
            "hello"
        );
        assert_eq!(event["response"]["usage"]["input_tokens"], 10);
        assert_eq!(
            event["response"]["usage"]["input_tokens_details"]["cached_tokens"],
            0
        );

        assert_eq!(event["response"]["status"], "completed");
        assert_eq!(
            event["response"]["usage"]["output_tokens_details"]["reasoning_tokens"],
            3
        );
    }

    #[test]
    pub(crate) fn a_completed_event_reports_its_tool_calls() {
        let calls = [ResponsesToolCall {
            call_id: "call_1",
            name: "read_file",
            arguments: "{\"path\":\"a.rs\"}",
        }];
        let event = build_completed_event("resp_1", "m", "", "", &calls, 0, 0, 0, 0, 0);
        assert_eq!(event["response"]["output"][0]["type"], "function_call");
        assert_eq!(event["response"]["output"][0]["call_id"], "call_1");
        assert_eq!(event["response"]["output"][0]["name"], "read_file");
        assert_eq!(
            event["response"]["output"][0]["arguments"],
            "{\"path\":\"a.rs\"}"
        );
    }

    #[test]
    pub(crate) fn an_empty_completed_event_still_carries_an_output_list() {
        let event = build_completed_event("resp_1", "m", "", "", &[], 0, 0, 0, 0, 0);
        assert_eq!(event["response"]["output"], json!([]));
    }

    #[test]
    pub(crate) fn a_failed_event_carries_a_response_envelope() {
        let event = build_failed_event("upstream_error", "boom");
        assert_eq!(event["response"]["status"], "failed");
        assert_eq!(event["response"]["output"], json!([]));
        assert_eq!(event["response"]["error"]["message"], "boom");

        assert_eq!(event["error"]["code"], "upstream_error");
    }

    #[test]
    pub(crate) fn function_call_events_open_with_an_output_item() {
        let call = ResponsesToolCall {
            call_id: "call_9",
            name: "bash",
            arguments: "{}",
        };
        let events = build_function_call_events(&call, 2);
        let types: Vec<&str> = events
            .iter()
            .map(|e| e["type"].as_str().unwrap_or_default())
            .collect();
        assert_eq!(
            types,
            vec![
                "response.output_item.added",
                "response.function_call_arguments.delta",
                "response.function_call_arguments.done",
                "response.output_item.done",
            ]
        );
        assert_eq!(events[0]["item"]["type"], "function_call");
        assert_eq!(events[0]["item"]["call_id"], "call_9");
        assert_eq!(events[0]["item"]["name"], "bash");

        assert!(events.iter().all(|e| e["output_index"] == 2));
    }

    #[test]
    pub(crate) fn events_are_numbered_in_order() {
        let mut seq = 0u64;
        let mut first = json!({"type": "response.output_text.delta", "delta": "a"});
        normalize_responses_event(&mut first, &mut seq);
        assert_eq!(first["sequence_number"], 0);

        let mut assigned = json!({"type": "response.output_text.delta", "sequence_number": 7});
        normalize_responses_event(&mut assigned, &mut seq);
        assert_eq!(assigned["sequence_number"], 7);

        let mut after = json!({"type": "response.output_text.delta", "delta": "b"});
        normalize_responses_event(&mut after, &mut seq);
        assert_eq!(after["sequence_number"], 8);
    }

    fn required_fields(event_type: &str) -> Option<&'static [&'static str]> {
        Some(match event_type {
            "response.created"
            | "response.in_progress"
            | "response.completed"
            | "response.incomplete"
            | "response.failed"
            | "response.queued" => &["sequence_number", "response"],
            "response.output_item.added" | "response.output_item.done" => {
                &["sequence_number", "output_index", "item"]
            }
            "response.content_part.added" | "response.content_part.done" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "content_index",
                "part",
            ],
            "response.output_text.delta" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "content_index",
                "delta",
            ],
            "response.output_text.done" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "content_index",
                "text",
            ],
            "response.function_call_arguments.delta" => {
                &["sequence_number", "item_id", "output_index", "delta"]
            }
            "response.function_call_arguments.done" => {
                &["sequence_number", "item_id", "output_index", "arguments"]
            }
            "response.reasoning_summary_part.added" | "response.reasoning_summary_part.done" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "summary_index",
                "part",
            ],
            "response.reasoning_summary_text.delta" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "summary_index",
                "delta",
            ],
            "response.reasoning_summary_text.done" => &[
                "sequence_number",
                "item_id",
                "output_index",
                "summary_index",
                "text",
            ],
            "response.custom_tool_call_input.delta" => {
                &["sequence_number", "output_index", "item_id", "delta"]
            }
            "response.custom_tool_call_input.done" => {
                &["sequence_number", "output_index", "item_id", "input"]
            }
            _ => return None,
        })
    }

    pub(crate) fn assert_event_is_wire_valid(event: &Value) {
        let event_type = event["type"].as_str().unwrap_or_default();
        let required = required_fields(event_type).unwrap_or_else(|| {
            panic!("{event_type}: not an event type the Responses API defines — a client that parses events against the schema rejects the whole stream over one it cannot name")
        });
        for key in required {
            assert!(
                event.get(*key).is_some(),
                "{event_type}: missing required `{key}` in {event}"
            );
        }
        if let Some(response) = event.get("response") {
            for key in ["created_at", "id", "model", "object", "output", "status"] {
                assert!(
                    response.get(key).is_some(),
                    "{event_type}: response missing required `{key}` in {event}"
                );
            }
            assert!(
                response["output"].is_array(),
                "{event_type}: output must be a list"
            );
            if let Some(usage) = response.get("usage").filter(|u| u.is_object()) {
                for key in ["input_tokens", "output_tokens", "total_tokens"] {
                    assert!(
                        usage.get(key).is_some(),
                        "{event_type}: usage missing `{key}`"
                    );
                }
                assert!(usage["input_tokens_details"]["cached_tokens"].is_number());
                assert!(usage["output_tokens_details"]["reasoning_tokens"].is_number());
            }
            for item in response["output"].as_array().into_iter().flatten() {
                assert_output_item_is_wire_valid(item, event_type);
            }
        }
        if let Some(item) = event.get("item") {
            assert_output_item_is_wire_valid(item, event_type);
        }
    }

    fn assert_output_item_is_wire_valid(item: &Value, event_type: &str) {
        let keys: &[&str] = match item["type"].as_str().unwrap_or_default() {
            "reasoning" => &["id", "summary"],
            "message" => &["content", "id", "role", "status"],
            "function_call" => &["arguments", "call_id", "name"],
            "custom_tool_call" => &["call_id", "input", "name"],
            _ => &[],
        };
        for key in keys {
            assert!(
                item.get(*key).is_some(),
                "{event_type}: {} item missing `{key}` in {item}",
                item["type"]
            );
        }
        for part in item["content"].as_array().into_iter().flatten() {
            if part["type"] == "output_text" {
                assert!(
                    part.get("annotations").is_some(),
                    "{event_type}: output_text missing annotations"
                );
                assert!(
                    part.get("text").is_some(),
                    "{event_type}: output_text missing text"
                );
            }
        }
    }

    #[test]
    pub(crate) fn the_hand_built_event_sequence_is_wire_valid() {
        let mut seq = 0u64;
        let call = ResponsesToolCall {
            call_id: "call_1",
            name: "run_terminal_command",
            arguments: "{\"command\":\"ls\"}",
        };
        let mut events: Vec<Value> = Vec::new();
        events.extend(build_reasoning_open("rs_1", 0));
        events.push(build_reasoning_delta("thinking", "rs_1", 0));
        events.extend(build_reasoning_close("thinking", "rs_1", 0));
        events.extend(build_message_open("item_1", 1));
        events.push(build_text_delta("hello", "item_1", 1));
        events.extend(build_message_close("hello", "item_1", 1));
        events.extend(build_function_call_events(&call, 2));
        events.push(build_completed_event(
            "resp_1",
            "m",
            "hello",
            "thinking",
            &[call],
            1,
            2,
            3,
            0,
            0,
        ));
        events.push(build_failed_event("upstream_error", "boom"));
        for mut event in events {
            normalize_responses_event(&mut event, &mut seq);
            assert_event_is_wire_valid(&event);
        }
    }

    #[test]
    pub(crate) fn a_normalized_envelope_carries_output_and_status() {
        let mut event = json!({"type": "response.completed", "response": {"id": "r"}});
        let mut seq = 0u64;
        normalize_responses_event(&mut event, &mut seq);
        assert_eq!(event["response"]["output"], json!([]));
        assert_eq!(event["response"]["status"], "completed");
        assert_eq!(event["response"]["object"], "response");

        let mut created = json!({"type": "response.created", "response": {"id": "r"}});
        normalize_responses_event(&mut created, &mut seq);
        assert_eq!(created["response"]["status"], "in_progress");

        let mut incomplete =
            json!({"type": "response.completed", "response": {"status": "incomplete"}});
        normalize_responses_event(&mut incomplete, &mut seq);
        assert_eq!(incomplete["response"]["status"], "incomplete");
    }

    #[test]
    pub(crate) fn a_completed_event_reports_its_cached_tokens() {
        let event = build_completed_event("resp_1", "m", "hi", "", &[], 1000, 5, 1005, 900, 0);

        assert_eq!(event["response"]["usage"]["input_tokens"], 1000);
        assert_eq!(
            event["response"]["usage"]["input_tokens_details"]["cached_tokens"],
            900
        );
    }

}


pub(crate) fn apply_responses_function_call_namespace_fields(
    item: &mut Value,
    request_json: &Value,
    qualified_name: &str,
    item_path: &str,
) {
    let (name, namespace) = tools::split_responses_qualified_function_call_from_request(
        request_json,
        qualified_name,
    );
    crate::translate::responses::tools::set_responses_tool_call_identity(
        item, &name, &namespace, item_path,
    );
}

pub(crate) fn chat_completion_to_responses(
    body: &Value,
    request_json: &Value,
    fallback_id: &str,
    fallback_model: &str,
) -> Value {
    let finish_reason = body
        .pointer("/choices/0/finish_reason")
        .and_then(Value::as_str)
        .unwrap_or("");
    let (incomplete_details, is_incomplete) = incomplete_by_finish_reason(finish_reason);

    let mut resp = serde_json::Map::new();
    let id = {
        let raw = body.get("id").and_then(Value::as_str).unwrap_or("");
        if raw.is_empty() {
            fallback_id.to_string()
        } else {
            raw.to_string()
        }
    };
    resp.insert("id".into(), json!(id));
    resp.insert("object".into(), json!("response"));
    let created = match body.get("created").and_then(Value::as_i64) {
        Some(v) if v != 0 => v,
        _ => chrono::Utc::now().timestamp(),
    };
    resp.insert("created_at".into(), json!(created));
    resp.insert(
        "status".into(),
        json!(if is_incomplete {
            "incomplete"
        } else {
            "completed"
        }),
    );
    resp.insert("background".into(), Value::Bool(false));
    resp.insert("error".into(), Value::Null);
    resp.insert(
        "incomplete_details".into(),
        incomplete_details.unwrap_or(Value::Null),
    );

    if request_json.is_object() {
        for key in [
            "instructions",
            "previous_response_id",
            "prompt_cache_key",
            "safety_identifier",
            "service_tier",
            "truncation",
        ] {
            if let Some(v) = request_json.get(key).and_then(Value::as_str) {
                resp.insert(key.into(), json!(v));
            }
        }
        match request_json
            .get("max_output_tokens")
            .and_then(Value::as_i64)
        {
            Some(v) => {
                resp.insert("max_output_tokens".into(), json!(v));
            }

            None => {
                if let Some(v) = request_json.get("max_tokens").and_then(Value::as_i64) {
                    resp.insert("max_output_tokens".into(), json!(v));
                }
            }
        }
        for key in ["max_tool_calls", "top_logprobs"] {
            if let Some(v) = request_json.get(key).and_then(Value::as_i64) {
                resp.insert(key.into(), json!(v));
            }
        }
        match request_json.get("model").and_then(Value::as_str) {
            Some(v) => {
                resp.insert("model".into(), json!(v));
            }
            None => {
                let model = body
                    .get("model")
                    .and_then(Value::as_str)
                    .unwrap_or(fallback_model);
                resp.insert("model".into(), json!(model));
            }
        }
        for key in ["parallel_tool_calls", "store"] {
            if let Some(v) = request_json.get(key).and_then(Value::as_bool) {
                resp.insert(key.into(), json!(v));
            }
        }
        for key in ["temperature", "top_p"] {
            if let Some(v) = request_json.get(key).and_then(Value::as_f64) {
                resp.insert(key.into(), json!(v));
            }
        }
        for key in [
            "reasoning",
            "text",
            "tool_choice",
            "tools",
            "user",
            "metadata",
        ] {
            if let Some(v) = request_json.get(key) {
                resp.insert(key.into(), v.clone());
            }
        }
    } else if let Some(v) = body.get("model").and_then(Value::as_str) {
        resp.insert("model".into(), json!(v));
    }

    let mut output_items: Vec<Value> = Vec::new();

    let mut rc_text = body
        .pointer("/choices/0/message/reasoning_content")
        .and_then(Value::as_str)
        .unwrap_or("");
    if rc_text.is_empty() {
        rc_text = body
            .pointer("/choices/0/message/reasoning")
            .and_then(Value::as_str)
            .unwrap_or("");
    }
    let include_reasoning = !rc_text.is_empty()
        || (request_json.is_object() && request_json.get("reasoning").is_some());
    if include_reasoning {
        let bare_id = id.strip_prefix("resp_").unwrap_or(&id);
        let mut item = serde_json::Map::new();
        item.insert("id".into(), json!(format!("rs_{bare_id}")));
        item.insert("type".into(), json!("reasoning"));
        item.insert("encrypted_content".into(), json!(""));
        if rc_text.is_empty() {
            item.insert("summary".into(), json!([]));
        } else {
            item.insert(
                "summary".into(),
                json!([{"type": "summary_text", "text": rc_text}]),
            );
        }
        output_items.push(Value::Object(item));
    }

    let item_status = if is_incomplete {
        "incomplete"
    } else {
        "completed"
    };
    let custom_tool_names = match serde_json::to_vec(request_json) {
        Ok(bytes) => responses_custom_tool_names(&bytes),
        Err(_) => Default::default(),
    };

    if let Some(choices) = body.get("choices").and_then(Value::as_array) {
        for choice in choices {
            let Some(message) = choice.get("message") else {
                continue;
            };
            let choice_index = choice.get("index").and_then(Value::as_i64).unwrap_or(0);

            if let Some(content) = message.get("content").and_then(Value::as_str) {
                if !content.is_empty() {
                    output_items.push(json!({
                        "id": format!("msg_{id}_{choice_index}"),
                        "type": "message",
                        "status": item_status,
                        "content": [{
                            "type": "output_text",
                            "annotations": [],
                            "logprobs": [],
                            "text": content,
                        }],
                        "role": "assistant",
                    }));
                }
            }

            if let Some(tool_calls) = message.get("tool_calls").and_then(Value::as_array) {
                for (tc_index, tc) in tool_calls.iter().enumerate() {
                    let mut call_id = tc
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    if call_id.is_empty() {
                        call_id = format!("call_{id}_{choice_index}_{tc_index}");
                    }
                    let name = tc
                        .pointer("/function/name")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let args = crate::translate::json::tool_arguments_string(
                        tc.pointer("/function/arguments"),
                    );

                    let mut item = if custom_tool_names.contains(name) {
                        json!({
                            "id": format!("ctc_{call_id}"),
                            "type": "custom_tool_call",
                            "status": item_status,
                            "input": unwrap_custom_tool_input(&args),
                            "call_id": call_id,
                            "name": "",
                        })
                    } else {
                        json!({
                            "id": format!("fc_{call_id}"),
                            "type": "function_call",
                            "status": item_status,
                            "arguments": args,
                            "call_id": call_id,
                            "name": "",
                        })
                    };
                    apply_responses_function_call_namespace_fields(
                        &mut item,
                        request_json,
                        name,
                        "",
                    );
                    output_items.push(item);
                }
            }
        }
    }

    if !output_items.is_empty() {
        resp.insert("output".into(), Value::Array(output_items));
    }

    if let Some(usage) = body.get("usage") {
        let has_known = usage.get("prompt_tokens").is_some()
            || usage.get("completion_tokens").is_some()
            || usage.get("total_tokens").is_some();
        if has_known {
            let get = |k: &str| usage.get(k).and_then(Value::as_i64).unwrap_or(0);
            let mut usage_out = serde_json::Map::new();
            usage_out.insert("input_tokens".into(), json!(get("prompt_tokens")));
            if let Some(cached) = usage
                .pointer("/prompt_tokens_details/cached_tokens")
                .and_then(Value::as_i64)
            {
                usage_out.insert(
                    "input_tokens_details".into(),
                    json!({"cached_tokens": cached}),
                );
            }
            usage_out.insert("output_tokens".into(), json!(get("completion_tokens")));
            if let Some(reasoning) = usage
                .pointer("/output_tokens_details/reasoning_tokens")
                .and_then(Value::as_i64)
            {
                usage_out.insert(
                    "output_tokens_details".into(),
                    json!({"reasoning_tokens": reasoning}),
                );
            }
            usage_out.insert("total_tokens".into(), json!(get("total_tokens")));
            resp.insert("usage".into(), Value::Object(usage_out));
        } else {
            resp.insert("usage".into(), usage.clone());
        }
    }

    Value::Object(resp)
}

#[cfg(test)]
mod chat_to_responses_non_stream_tests {
    use super::*;

    fn chat_body(message: Value, finish_reason: &str) -> Value {
        json!({
            "id": "chatcmpl-1",
            "created": 1700000000,
            "model": "some-model",
            "choices": [{"index": 0, "finish_reason": finish_reason, "message": message}],
            "usage": {"prompt_tokens": 10, "completion_tokens": 3, "total_tokens": 13},
        })
    }

    #[test]
    fn text_becomes_a_message_item() {
        let out = chat_completion_to_responses(
            &chat_body(json!({"role": "assistant", "content": "Hello"}), "stop"),
            &Value::Null,
            "resp_fallback",
            "fallback-model",
        );
        assert_eq!(out["object"], "response");
        assert_eq!(out["status"], "completed");
        assert_eq!(out["id"], "chatcmpl-1");
        assert_eq!(out["created_at"], 1700000000);
        assert_eq!(out["output"][0]["type"], "message");
        assert_eq!(out["output"][0]["content"][0]["text"], "Hello");
        assert_eq!(out["usage"]["input_tokens"], 10);
        assert_eq!(out["usage"]["total_tokens"], 13);
    }

    #[test]
    fn tool_calls_become_function_call_items() {
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "tool_calls": [
                    {"id": "call_1", "function": {"name": "get_weather", "arguments": "{\"city\":\"NYC\"}"}}
                ]}),
                "tool_calls",
            ),
            &Value::Null,
            "resp_fallback",
            "fallback-model",
        );
        let item = &out["output"][0];
        assert_eq!(item["type"], "function_call");
        assert_eq!(item["id"], "fc_call_1");
        assert_eq!(item["call_id"], "call_1");
        assert_eq!(item["name"], "get_weather");

        assert_eq!(item["arguments"], "{\"city\":\"NYC\"}");
        assert_eq!(item["status"], "completed");
    }

    #[test]
    fn missing_tool_call_id_is_synthesized() {
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "tool_calls": [
                    {"function": {"name": "f", "arguments": "{}"}}
                ]}),
                "tool_calls",
            ),
            &Value::Null,
            "resp_fallback",
            "fallback-model",
        );
        let call_id = out["output"][0]["call_id"].as_str().unwrap();
        assert_eq!(call_id, "call_chatcmpl-1_0_0");
    }

    #[test]
    fn length_finish_reason_marks_the_response_incomplete() {
        let out = chat_completion_to_responses(
            &chat_body(json!({"role": "assistant", "content": "cut"}), "length"),
            &Value::Null,
            "resp_fallback",
            "fallback-model",
        );
        assert_eq!(out["status"], "incomplete");
        assert_eq!(out["incomplete_details"]["reason"], "max_output_tokens");

        assert_eq!(out["output"][0]["status"], "incomplete");
    }

    #[test]
    fn content_filter_maps_to_its_own_reason() {
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "content": "x"}),
                "content_filter",
            ),
            &Value::Null,
            "r",
            "m",
        );
        assert_eq!(out["incomplete_details"]["reason"], "content_filter");
    }

    #[test]
    fn reasoning_content_becomes_a_leading_reasoning_item() {
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "content": "answer", "reasoning_content": "why"}),
                "stop",
            ),
            &Value::Null,
            "r",
            "m",
        );
        assert_eq!(out["output"][0]["type"], "reasoning");
        assert_eq!(out["output"][0]["summary"][0]["text"], "why");
        assert_eq!(out["output"][1]["type"], "message");
    }

    #[test]
    fn reasoning_falls_back_to_the_reasoning_field() {
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "content": "a", "reasoning": "alt"}),
                "stop",
            ),
            &Value::Null,
            "r",
            "m",
        );
        assert_eq!(out["output"][0]["summary"][0]["text"], "alt");
    }

    #[test]
    fn qualified_tool_names_split_into_name_and_namespace() {
        let request = json!({
            "model": "m",
            "tools": [{"type": "namespace", "name": "fs", "tools": [
                {"type": "function", "name": "read_file"},
            ]}],
        });
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "tool_calls": [
                    {"id": "c", "function": {"name": "fs__read_file", "arguments": "{}"}}
                ]}),
                "tool_calls",
            ),
            &request,
            "r",
            "m",
        );
        assert_eq!(out["output"][0]["name"], "read_file");
        assert_eq!(out["output"][0]["namespace"], "fs");
    }

    #[test]
    fn custom_tools_become_custom_tool_call_items() {
        let request = json!({
            "model": "m",
            "tools": [{"type": "custom", "name": "run_shell"}],
        });
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "tool_calls": [
                    {"id": "c1", "function": {"name": "run_shell", "arguments": "{\"input\":\"ls\"}"}}
                ]}),
                "tool_calls",
            ),
            &request,
            "r",
            "m",
        );
        assert_eq!(out["output"][0]["type"], "custom_tool_call");
        assert_eq!(out["output"][0]["id"], "ctc_c1");
        assert_eq!(out["output"][0]["input"], "ls");
    }

    #[test]
    fn namespace_wrapped_custom_tools_become_custom_tool_call_items() {
        let request = json!({
            "model": "m",
            "input": [{"type": "additional_tools", "tools": [
                {"type": "namespace", "name": "functions", "tools": [
                    {"type": "custom", "name": "exec"},
                ]},
            ]}],
        });
        let out = chat_completion_to_responses(
            &chat_body(
                json!({"role": "assistant", "tool_calls": [
                    {"id": "c1", "function": {"name": "functions__exec", "arguments": "{\"input\":\"text(1+1)\"}"}}
                ]}),
                "tool_calls",
            ),
            &request,
            "r",
            "m",
        );
        assert_eq!(out["output"][0]["type"], "custom_tool_call");
        assert_eq!(out["output"][0]["name"], "exec");
        assert_eq!(out["output"][0]["namespace"], "functions");
        assert_eq!(out["output"][0]["input"], "text(1+1)");
    }

    #[test]
    fn unknown_usage_shape_passes_through_verbatim() {
        let mut body = chat_body(json!({"role": "assistant", "content": "x"}), "stop");
        body["usage"] = json!({"weird_counter": 5});
        let out = chat_completion_to_responses(&body, &Value::Null, "r", "m");
        assert_eq!(out["usage"]["weird_counter"], 5);
    }

    #[test]
    fn request_fields_are_echoed() {
        let request = json!({
            "model": "requested-model",
            "instructions": "be brief",
            "max_tokens": 256,
            "temperature": 0.5,
            "store": false,
        });
        let out = chat_completion_to_responses(
            &chat_body(json!({"role": "assistant", "content": "x"}), "stop"),
            &request,
            "r",
            "m",
        );
        assert_eq!(out["model"], "requested-model");
        assert_eq!(out["instructions"], "be brief");

        assert_eq!(out["max_output_tokens"], 256);
        assert_eq!(out["temperature"], 0.5);
        assert_eq!(out["store"], false);
    }
}

pub(crate) fn set_responses_model(event: &mut Value, request_model_name: &str) -> bool {
    let event_type = event.get("type").and_then(Value::as_str).unwrap_or("");
    if event_type != "response.created" && event_type != "response.in_progress" {
        return false;
    }
    if event.pointer("/response/model").is_some() {
        return false;
    }
    if request_model_name.is_empty() {
        return false;
    }
    let Some(response) = event.get_mut("response").and_then(Value::as_object_mut) else {
        return false;
    };
    response.insert(
        "model".into(),
        Value::String(request_model_name.to_string()),
    );
    true
}

pub(crate) fn unwrap_terminal_response_event(body: &Value) -> Option<Value> {
    match body.get("type").and_then(Value::as_str) {
        Some("response.completed") | Some("response.incomplete") => body.get("response").cloned(),

        Some(_) => None,
        None => Some(body.clone()),
    }
}

#[cfg(test)]
mod passthrough_tests {
    use super::*;

    #[test]
    fn created_without_a_model_is_filled_in() {
        let mut event = json!({"type": "response.created", "response": {"id": "r"}});
        assert!(set_responses_model(&mut event, "gpt-5"));
        assert_eq!(event["response"]["model"], "gpt-5");
    }

    #[test]
    fn an_existing_model_is_left_alone() {
        let mut event = json!({"type": "response.created",
                               "response": {"id": "r", "model": "upstream-model"}});
        assert!(!set_responses_model(&mut event, "gpt-5"));
        assert_eq!(event["response"]["model"], "upstream-model");
    }

    #[test]
    fn other_event_types_are_untouched() {
        let mut event = json!({"type": "response.output_text.delta", "delta": "x"});
        assert!(!set_responses_model(&mut event, "gpt-5"));
        assert!(event.get("response").is_none());
    }

    #[test]
    fn in_progress_is_also_filled_in() {
        let mut event = json!({"type": "response.in_progress", "response": {"id": "r"}});
        assert!(set_responses_model(&mut event, "m"));
        assert_eq!(event["response"]["model"], "m");
    }

    #[test]
    fn terminal_events_unwrap_to_their_response() {
        let body = json!({"type": "response.completed",
                          "response": {"id": "r", "status": "completed"}});
        let out = unwrap_terminal_response_event(&body).unwrap();
        assert_eq!(out["id"], "r");
        assert!(out.get("type").is_none());
    }

    #[test]
    fn a_bare_response_body_passes_through() {
        let body = json!({"id": "r", "object": "response", "status": "completed"});
        assert_eq!(unwrap_terminal_response_event(&body).unwrap(), body);
    }

    #[test]
    fn a_non_terminal_event_is_not_a_response_body() {
        let body = json!({"type": "response.output_text.delta"});
        assert!(unwrap_terminal_response_event(&body).is_none());
    }
}

pub fn ensure_usage_details_at(payload: &mut Value, path: &str) {
    let Some(usage) = payload.pointer(path) else {
        return;
    };
    if !usage.is_object() {
        return;
    }
    let output_details = usage.get("output_tokens_details").cloned();
    let input_details = usage.get("input_tokens_details").cloned();
    let Some(usage) = payload.pointer_mut(path) else {
        return;
    };

    match output_details {
        None => {
            usage["output_tokens_details"] = json!({"reasoning_tokens": 0});
        }
        Some(details) if !details.is_object() => {
            usage["output_tokens_details"] = json!({"reasoning_tokens": 0});
        }
        Some(details) => {
            let reasoning = details.get("reasoning_tokens");
            if reasoning.is_none() || reasoning == Some(&Value::Null) {
                usage["output_tokens_details"]["reasoning_tokens"] = json!(0);
            }
        }
    }

    match input_details {
        None => {
            usage["input_tokens_details"] = json!({"cached_tokens": 0});
        }
        Some(details) if !details.is_object() => {
            usage["input_tokens_details"] = json!({"cached_tokens": 0});
        }
        Some(details) => {
            let cached = details.get("cached_tokens");
            if cached.is_none() || cached == Some(&Value::Null) {
                usage["input_tokens_details"]["cached_tokens"] = json!(0);
            }
        }
    }
}

pub fn ensure_responses_usage_details(payload: &mut Value) {
    if payload.get("object").and_then(Value::as_str) == Some("response.compaction") {
        return;
    }
    ensure_usage_details_at(payload, "/response/usage");
    ensure_usage_details_at(payload, "/usage");
}

fn envelope_status_for(event_type: &str) -> Option<&'static str> {
    match event_type {
        "response.created" | "response.in_progress" | "response.queued" => Some("in_progress"),
        "response.completed" => Some("completed"),
        "response.incomplete" => Some("incomplete"),
        "response.failed" => Some("failed"),
        _ => None,
    }
}

pub(crate) fn normalize_responses_event(payload: &mut Value, seq: &mut u64) {
    if payload.get("object").and_then(Value::as_str) == Some("response.compaction") {
        return;
    }
    ensure_responses_usage_details(payload);

    let event_type = payload
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let status = envelope_status_for(&event_type);
    if let Some(response) = payload.get_mut("response").and_then(Value::as_object_mut) {
        if !response.get("output").map(Value::is_array).unwrap_or(false) {
            response.insert("output".into(), Value::Array(Vec::new()));
        }
        if let Some(status) = status {
            let known = response
                .get("status")
                .and_then(Value::as_str)
                .map(|s| !s.is_empty())
                .unwrap_or(false);
            if !known {
                response.insert("status".into(), json!(status));
            }
        }
        if !response
            .get("object")
            .map(Value::is_string)
            .unwrap_or(false)
        {
            response.insert("object".into(), json!("response"));
        }
    }

    match payload.get("sequence_number").and_then(Value::as_u64) {
        Some(assigned) => *seq = (*seq).max(assigned + 1),
        None => {
            payload["sequence_number"] = json!(*seq);
            *seq += 1;
        }
    }
}

#[cfg(test)]
mod usage_details_tests {
    use super::*;

    #[test]
    fn missing_details_are_filled_with_zeros() {
        let mut event = json!({
            "type": "response.completed",
            "response": {"usage": {"input_tokens": 5, "output_tokens": 7}},
        });
        ensure_responses_usage_details(&mut event);
        assert_eq!(
            event["response"]["usage"]["output_tokens_details"]["reasoning_tokens"],
            0
        );
        assert_eq!(
            event["response"]["usage"]["input_tokens_details"]["cached_tokens"],
            0
        );
    }

    #[test]
    fn reported_values_are_kept() {
        let mut event = json!({"usage": {
            "output_tokens_details": {"reasoning_tokens": 12},
            "input_tokens_details": {"cached_tokens": 3},
        }});
        ensure_responses_usage_details(&mut event);
        assert_eq!(
            event["usage"]["output_tokens_details"]["reasoning_tokens"],
            12
        );
        assert_eq!(event["usage"]["input_tokens_details"]["cached_tokens"], 3);
    }

    #[test]
    fn a_null_details_object_is_replaced() {
        let mut event = json!({"usage": {"output_tokens_details": null}});
        ensure_responses_usage_details(&mut event);
        assert_eq!(
            event["usage"]["output_tokens_details"],
            json!({"reasoning_tokens": 0})
        );
    }

    #[test]
    fn compaction_payloads_are_untouched() {
        let mut event = json!({"object": "response.compaction", "usage": {}});
        ensure_responses_usage_details(&mut event);
        assert!(event["usage"].get("output_tokens_details").is_none());
    }
}
