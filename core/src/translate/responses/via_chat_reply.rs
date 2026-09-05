use futures_util::StreamExt;
use serde_json::{json, Value};
use std::time::Instant;
use tokio::sync::mpsc;

use super::stream_state::*;
use super::*;
use crate::net::sse::StreamFrame;
use crate::translate::StreamOutcome;
use crate::translate::collect::Collector;
use crate::translate::tokens::is_responses_token_event;
use crate::translate::usage::TokenUsage;

pub async fn stream_chat_to_responses(
    upstream: reqwest::Response,
    sender: mpsc::UnboundedSender<StreamFrame>,
    resp_id: String,
    model: String,
    original_request_json: Vec<u8>,
    request_json: Vec<u8>,
) -> StreamOutcome {
    let mut st = ResponsesStreamState::new();
    st.response_id = resp_id.clone();
    let request_for_namespace = if !original_request_json.is_empty() {
        &original_request_json
    } else {
        &request_json
    };
    st.custom_tool_names = responses_custom_tool_names(request_for_namespace);

    let mut stream = upstream.bytes_stream();
    let mut buffer: Vec<u8> = Vec::new();
    let mut out: Vec<Value> = Vec::new();
    let mut seen_done = false;
    let mut stream_failed = false;

    let mut seq: u64 = 0;

    let mut first_token_at: Option<Instant> = None;

    let process_frame = |st: &mut ResponsesStreamState, out: &mut Vec<Value>, raw: &[u8]| {
        chat_chunk_to_responses_events(st, out, raw, &model, &original_request_json, &request_json)
    };

    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(chunk) => chunk,
            Err(_) => {
                stream_failed = true;
                break;
            }
        };
        for segment in chunk.split_inclusive(|&byte| byte == b'\n') {
            buffer.extend_from_slice(segment);
            if !segment.ends_with(b"\n") {
                continue;
            }
            let line = String::from_utf8_lossy(&buffer).into_owned();
            buffer.clear();
            let trimmed = line.trim();
            if trimmed.is_empty() {
                continue;
            }
            if let Some(data) = trimmed.strip_prefix("data:") {
                let data = data.trim();
                if data == "[DONE]" {
                    seen_done = true;
                }
                process_frame(&mut st, &mut out, data.as_bytes());
                for frame in out.drain(..) {
                    if first_token_at.is_none() && is_responses_token_event(&frame) {
                        first_token_at = Some(Instant::now());
                    }
                    let event_type = frame
                        .get("type")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    sse_event(&sender, &mut seq, &event_type, &frame);
                }
                continue;
            }
            if trimmed.starts_with("event:")
                || trimmed.starts_with(':')
                || trimmed.starts_with("id:")
                || trimmed.starts_with("retry:")
            {
                continue;
            }
        }
    }

    if !buffer.is_empty() {
        let line = String::from_utf8_lossy(&buffer).into_owned();
        buffer.clear();
        let trimmed = line.trim();
        if let Some(data) = trimmed.strip_prefix("data:") {
            let data = data.trim();
            if data == "[DONE]" {
                seen_done = true;
            }
            process_frame(&mut st, &mut out, data.as_bytes());
            for frame in out.drain(..) {
                if first_token_at.is_none() && is_responses_token_event(&frame) {
                    first_token_at = Some(Instant::now());
                }
                let event_type = frame
                    .get("type")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                sse_event(&sender, &mut seq, &event_type, &frame);
            }
        }
    }

    if !seen_done && !stream_failed && st.started && !st.finish_reason.is_empty() {
        process_frame(&mut st, &mut out, b"[DONE]");
        for frame in out.drain(..) {
            if first_token_at.is_none() && is_responses_token_event(&frame) {
                first_token_at = Some(Instant::now());
            }
            let event_type = frame
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            sse_event(&sender, &mut seq, &event_type, &frame);
        }
        seen_done = true;
    }

    if !seen_done && !stream_failed && st.started {
        let _ = sender.send(StreamFrame::PreFailure(crate::net::error::ApiError::coded(
            StatusCode::BAD_GATEWAY,
            "upstream_stream_error",
            "upstream stream closed before [DONE]",
        )));
        sse_event(
            &sender,
            &mut seq,
            "response.failed",
            &build_failed_event(
                "upstream_stream_error",
                "upstream stream closed before [DONE]",
            ),
        );
        let mut collector = Collector::counting();
        collector.usage = Some(TokenUsage {
            input_tokens: st.prompt_tokens,
            output_tokens: st.completion_tokens,
            total_tokens: if st.total_tokens == 0 {
                st.prompt_tokens + st.completion_tokens
            } else {
                st.total_tokens
            },
            cached_input_tokens: st.cached_tokens,
            ..TokenUsage::default()
        });
        let _ = sender.send(StreamFrame::Done);
        return StreamOutcome {
            first_token_at,
            usage: collector,
            finish: st.finish_reason.clone(),
            error: Some("upstream stream closed before [DONE]".to_string()),
        };
    }

    let mut collector = Collector::counting();
    collector.usage = Some(TokenUsage {
        input_tokens: st.prompt_tokens,
        output_tokens: st.completion_tokens,
        total_tokens: if st.total_tokens == 0 {
            st.prompt_tokens + st.completion_tokens
        } else {
            st.total_tokens
        },
        cached_input_tokens: st.cached_tokens,
        ..TokenUsage::default()
    });
    let _ = sender.send(StreamFrame::Done);
    StreamOutcome {
        first_token_at,
        usage: collector,
        finish: st.finish_reason.clone(),
        error: None,
    }
}

fn emit_output_text(st: &mut ResponsesStreamState, out: &mut Vec<Value>, idx: usize, c: &str) {
    if !st.msg_output_ix.contains_key(&idx) {
        let new_index = st.alloc_output_index();
        st.msg_output_ix.insert(idx, new_index);
    }
    let msg_output_index = st.msg_output_ix[&idx];
    if !st.msg_item_added.get(&idx).copied().unwrap_or(false) {
        let mut item = json!({
            "type": "response.output_item.added",
            "output_index": msg_output_index,
            "item": {
                "id": format!("msg_{}_{}", st.response_id, idx),
                "type": "message",
                "status": "in_progress",
                "content": [],
                "role": "assistant",
            },
        });
        let seq = st.next_seq();
        item["sequence_number"] = json!(seq);
        out.push(item);
        st.msg_item_added.insert(idx, true);
    }
    if !st.msg_content_added.get(&idx).copied().unwrap_or(false) {
        let mut part = json!({
            "type": "response.content_part.added",
            "item_id": format!("msg_{}_{}", st.response_id, idx),
            "output_index": msg_output_index,
            "content_index": 0,
            "part": {"type": "output_text", "annotations": [], "logprobs": [], "text": ""},
        });
        let seq = st.next_seq();
        part["sequence_number"] = json!(seq);
        out.push(part);
        st.msg_content_added.insert(idx, true);
    }

    let mut msg = json!({
        "type": "response.output_text.delta",
        "item_id": format!("msg_{}_{}", st.response_id, idx),
        "output_index": msg_output_index,
        "content_index": 0,
        "delta": c,
        "logprobs": [],
    });
    let seq = st.next_seq();
    msg["sequence_number"] = json!(seq);
    out.push(msg);
    st.msg_text_buf.entry(idx).or_default().push_str(c);
}

fn strip_implicit_think_marker(content: &str, st: &mut ResponsesStreamState) -> String {
    use crate::translate::messages::via_chat_reply::{pending_marker_len, THINK_CLOSE, THINK_OPEN};

    if !st.think_scan || st.think_closed {
        if st.think_tail.is_empty() {
            return content.to_string();
        }
        let mut released = std::mem::take(&mut st.think_tail);
        released.push_str(content);
        return released;
    }

    st.think_tail.push_str(content);
    let opened_at = st.think_tail.find(THINK_OPEN);
    let closed_at = st.think_tail.find(THINK_CLOSE);

    if let Some(open) = opened_at {
        if closed_at.is_none_or(|close| close > open) {
            st.think_scan = false;
            return std::mem::take(&mut st.think_tail);
        }
    }

    if let Some(at) = closed_at {
        let buffered = std::mem::take(&mut st.think_tail);
        st.think_closed = true;
        return format!("{}{}", &buffered[..at], &buffered[at + THINK_CLOSE.len()..]);
    }

    let pending = pending_marker_len(&st.think_tail);
    let flush_to = st.think_tail.len() - pending;
    let flushed = st.think_tail[..flush_to].to_string();
    st.think_tail.drain(..flush_to);
    flushed
}

pub(crate) fn chat_chunk_to_responses_events(
    st: &mut ResponsesStreamState,
    out: &mut Vec<Value>,
    raw: &[u8],
    model: &str,
    original_request_json: &[u8],
    request_json: &[u8],
) {
    let request_for_namespace: &[u8] = if !original_request_json.is_empty() {
        original_request_json
    } else {
        request_json
    };
    let raw = std::str::from_utf8(raw).unwrap_or("").trim();
    if raw.is_empty() {
        return;
    }
    let is_done = raw == "[DONE]";
    if is_done && (!st.started || st.completed_emitted) {
        return;
    }

    if !is_done {
        if let Ok(root) = serde_json::from_str::<Value>(raw) {
            if let Some(obj) = root.get("object").and_then(Value::as_str) {
                if !obj.is_empty() && obj != "chat.completion.chunk" {
                    return;
                }
            }
            if !root.get("choices").and_then(Value::as_array).is_some() {
                return;
            }
        }
    }

    if let Ok(root) = serde_json::from_str::<Value>(raw) {
        if let Some(usage) = root.get("usage") {
            if let Some(v) = usage.get("prompt_tokens").and_then(Value::as_i64) {
                st.prompt_tokens = v;
                st.usage_seen = true;
            }
            if let Some(v) = usage
                .get("prompt_tokens_details")
                .and_then(|d| d.get("cached_tokens"))
                .and_then(Value::as_i64)
            {
                st.cached_tokens = v;
                st.usage_seen = true;
            }
            if let Some(v) = usage.get("completion_tokens").and_then(Value::as_i64) {
                st.completion_tokens = v;
                st.usage_seen = true;
            } else if let Some(v) = usage.get("output_tokens").and_then(Value::as_i64) {
                st.completion_tokens = v;
                st.usage_seen = true;
            }
            if let Some(v) = usage
                .get("output_tokens_details")
                .and_then(|d| d.get("reasoning_tokens"))
                .and_then(Value::as_i64)
            {
                st.reasoning_tokens = v;
                st.usage_seen = true;
            } else if let Some(v) = usage
                .get("completion_tokens_details")
                .and_then(|d| d.get("reasoning_tokens"))
                .and_then(Value::as_i64)
            {
                st.reasoning_tokens = v;
                st.usage_seen = true;
            }
            if let Some(v) = usage.get("total_tokens").and_then(Value::as_i64) {
                st.total_tokens = v;
                st.usage_seen = true;
            }
        }
    }

    if !st.started {
        if let Ok(root) = serde_json::from_str::<Value>(raw) {
            let upstream_id = root.get("id").and_then(Value::as_str).unwrap_or("");
            if !upstream_id.is_empty() {
                st.response_id = upstream_id.to_string();
            }
            st.created = root.get("created").and_then(Value::as_i64).unwrap_or(0);
        }
        st.reset_for_new_response();
        st.custom_tool_names = responses_custom_tool_names(request_for_namespace);

        let request_model = request_model_name(original_request_json, request_json);
        let request_model = if request_model.is_empty() {
            model.to_string()
        } else {
            request_model
        };

        let mut created = json!({
            "type": "response.created",
            "response": {
                "id": st.response_id,
                "object": "response",
                "created_at": st.created,
                "status": "in_progress",
                "background": false,
                "error": null,
                "output": [],
            },
        });
        let seq = st.next_seq();
        created["sequence_number"] = json!(seq);
        if !request_model.is_empty() {
            created["response"]["model"] = json!(request_model);
        }
        out.push(created);

        let mut inprog = json!({
            "type": "response.in_progress",
            "response": {
                "id": st.response_id,
                "object": "response",
                "created_at": st.created,
                "status": "in_progress",
                "output": [],
            },
        });
        let seq = st.next_seq();
        inprog["sequence_number"] = json!(seq);
        if !request_model.is_empty() {
            inprog["response"]["model"] = json!(request_model);
        }
        out.push(inprog);
        st.started = true;
    }

    if is_done {
        finalize_open_items(st, out, request_for_namespace);
        let mut has_active_unfinished_tool = false;
        for key in st.func_item_added.keys() {
            if !st.func_item_done.get(key).copied().unwrap_or(false) {
                has_active_unfinished_tool = true;
                break;
            }
        }
        if has_active_unfinished_tool
            || (st.msg_item_added.is_empty() && st.func_item_added.is_empty())
        {
            return;
        }
        st.completed_emitted = true;
        out.push(build_completed_event_from_state(st, request_for_namespace));
        return;
    }

    let Ok(root) = serde_json::from_str::<Value>(raw) else {
        return;
    };
    let Some(choices) = root.get("choices").and_then(Value::as_array) else {
        return;
    };
    for choice in choices {
        let idx = choice.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
        let Some(delta) = choice.get("delta") else {
            continue;
        };

        if let Some(c) = delta.get("content").and_then(Value::as_str) {
            let c = strip_implicit_think_marker(c, st);
            let c = c.as_str();
            if !c.is_empty() {
                if !st.reasoning_id.is_empty() {
                    stop_reasoning(st, out);
                    st.reasoning_buf.clear();
                }
                emit_output_text(st, out, idx, c);
            }
        }

        let mut rc = delta.get("reasoning_content").and_then(Value::as_str);
        if rc.is_none() || rc == Some("") {
            rc = delta.get("reasoning").and_then(Value::as_str);
        }
        if let Some(rc) = rc {
            if !rc.is_empty() {
                if st.reasoning_id.is_empty() {
                    st.reasoning_id = format!("rs_{}_{}", st.response_id, idx);
                    st.reasoning_index = st.alloc_output_index();
                    let mut item = json!({
                        "type": "response.output_item.added",
                        "output_index": st.reasoning_index,
                        "item": {
                            "id": st.reasoning_id,
                            "type": "reasoning",
                            "status": "in_progress",
                            "summary": [],
                        },
                    });
                    let seq = st.next_seq();
                    item["sequence_number"] = json!(seq);
                    out.push(item);
                    let mut part = json!({
                        "type": "response.reasoning_summary_part.added",
                        "item_id": st.reasoning_id,
                        "output_index": st.reasoning_index,
                        "summary_index": 0,
                        "part": {"type": "summary_text", "text": ""},
                    });
                    let seq = st.next_seq();
                    part["sequence_number"] = json!(seq);
                    out.push(part);
                }
                st.reasoning_buf.push_str(rc);
                let mut msg = json!({
                    "type": "response.reasoning_summary_text.delta",
                    "item_id": st.reasoning_id,
                    "output_index": st.reasoning_index,
                    "summary_index": 0,
                    "delta": rc,
                });
                let seq = st.next_seq();
                msg["sequence_number"] = json!(seq);
                out.push(msg);
            }
        }

        if let Some(tcs) = delta.get("tool_calls").and_then(Value::as_array) {
            if !tcs.is_empty() {
                if !st.reasoning_id.is_empty() {
                    stop_reasoning(st, out);
                    st.reasoning_buf.clear();
                }
                emit_message_item_done(st, out, idx);

                for tc in tcs {
                    let tool_index = tc.get("index").and_then(Value::as_u64).unwrap_or(0) as usize;
                    let key = responses_tool_state_key(idx, tool_index);
                    if !st.func_args_buf.contains_key(&key) {
                        st.func_args_buf.insert(key.clone(), String::new());
                        let new_index = st.alloc_output_index();
                        st.func_output_ix.insert(key.clone(), new_index);
                    }
                    if let Some(new_call_id) = tc.get("id").and_then(Value::as_str) {
                        if !new_call_id.is_empty() && !st.func_call_ids.contains_key(&key) {
                            st.func_call_ids
                                .insert(key.clone(), new_call_id.to_string());
                        }
                    }
                    let name_chunk = tc
                        .get("function")
                        .and_then(|f| f.get("name"))
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    if !name_chunk.is_empty()
                        && !st.func_item_added.get(&key).copied().unwrap_or(false)
                    {
                        st.func_names.insert(key.clone(), name_chunk.to_string());
                    }
                    let args = crate::translate::json::tool_arguments_string(
                        tc.get("function").and_then(|f| f.get("arguments")),
                    );
                    if !args.is_empty() {
                        st.func_args_buf
                            .entry(key.clone())
                            .or_default()
                            .push_str(&args);
                    }
                    emit_tool_item(st, out, &key, false, request_for_namespace);
                    emit_pending_function_args(st, out, &key);
                }
            }
        }

        if let Some(fr) = choice.get("finish_reason").and_then(Value::as_str) {
            if !fr.is_empty() {
                st.finish_reason = fr.to_string();

                if !st.think_tail.is_empty() {
                    let tail = std::mem::take(&mut st.think_tail);
                    emit_output_text(st, out, idx, &tail);
                }
                finalize_open_items(st, out, request_for_namespace);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn namespace_wrapped_custom_tool_streams_as_custom_tool_call() {
        let request = serde_json::to_vec(&json!({
            "model": "m",
            "input": [
                {"type": "additional_tools", "tools": [
                    {"type": "namespace", "name": "functions", "tools": [
                        {"type": "custom", "name": "exec", "description": "run js"},
                        {"type": "function", "name": "wait", "parameters": {"type": "object"}},
                    ]},
                ]},
                {"type": "message", "role": "user", "content": [{"type": "input_text", "text": "hi"}]},
            ],
        }))
        .unwrap();

        let mut st = ResponsesStreamState::new();
        let mut out = Vec::new();
        let chunk = json!({
            "id": "chat1", "object": "chat.completion.chunk", "created": 1,
            "choices": [{"index": 0, "delta": {"tool_calls": [{
                "index": 0, "id": "call_a",
                "function": {"name": "functions__exec", "arguments": "{\"input\":\"text(1+1)\"}"},
            }]}, "finish_reason": null}],
        });
        let finish = json!({
            "id": "chat1", "object": "chat.completion.chunk", "created": 1,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls"}],
        });
        for raw in [chunk.to_string(), finish.to_string(), "[DONE]".to_string()] {
            chat_chunk_to_responses_events(
                &mut st,
                &mut out,
                raw.as_bytes(),
                "m",
                &request,
                &request,
            );
        }

        let added = out
            .iter()
            .find(|e| {
                e["type"] == "response.output_item.added" && e["item"]["type"] == "custom_tool_call"
            })
            .expect("custom_tool_call item added");
        assert_eq!(added["item"]["name"], "exec");
        assert_eq!(added["item"]["namespace"], "functions");
        assert_eq!(added["item"]["call_id"], "call_a");
        assert!(
            !out.iter().any(|e| e["item"]["type"] == "function_call"),
            "custom exec must not surface as a function_call"
        );

        let input_done = out
            .iter()
            .find(|e| e["type"] == "response.custom_tool_call_input.done")
            .expect("custom_tool_call_input.done");
        assert_eq!(input_done["input"], "text(1+1)");

        let item_done = out
            .iter()
            .find(|e| {
                e["type"] == "response.output_item.done" && e["item"]["type"] == "custom_tool_call"
            })
            .expect("custom_tool_call item done");
        assert_eq!(item_done["item"]["name"], "exec");
        assert_eq!(item_done["item"]["namespace"], "functions");
        assert_eq!(item_done["item"]["input"], "text(1+1)");

        let completed = out
            .iter()
            .find(|e| e["type"] == "response.completed")
            .expect("response.completed");
        let output = completed["response"]["output"].as_array().unwrap();
        let call = output
            .iter()
            .find(|i| i["type"] == "custom_tool_call")
            .unwrap();
        assert_eq!(call["name"], "exec");
        assert_eq!(call["namespace"], "functions");
        assert_eq!(call["input"], "text(1+1)");
        assert_eq!(call["call_id"], "call_a");
    }

    #[test]
    fn namespace_wrapped_function_tool_stays_a_function_call() {
        let request = serde_json::to_vec(&json!({
            "model": "m",
            "input": [{"type": "additional_tools", "tools": [
                {"type": "namespace", "name": "functions", "tools": [
                    {"type": "custom", "name": "exec"},
                    {"type": "function", "name": "wait", "parameters": {"type": "object"}},
                ]},
            ]}],
        }))
        .unwrap();

        let mut st = ResponsesStreamState::new();
        let mut out = Vec::new();
        let chunk = json!({
            "id": "chat1", "object": "chat.completion.chunk", "created": 1,
            "choices": [{"index": 0, "delta": {"tool_calls": [{
                "index": 0, "id": "call_w",
                "function": {"name": "functions__wait", "arguments": "{\"cell_id\":\"0\"}"},
            }]}, "finish_reason": "tool_calls"}],
        });
        for raw in [chunk.to_string(), "[DONE]".to_string()] {
            chat_chunk_to_responses_events(
                &mut st,
                &mut out,
                raw.as_bytes(),
                "m",
                &request,
                &request,
            );
        }

        let item_done = out
            .iter()
            .find(|e| {
                e["type"] == "response.output_item.done" && e["item"]["type"] == "function_call"
            })
            .expect("function_call item done");
        assert_eq!(item_done["item"]["name"], "wait");
        assert_eq!(item_done["item"]["namespace"], "functions");
        assert_eq!(item_done["item"]["arguments"], "{\"cell_id\":\"0\"}");
    }
}
