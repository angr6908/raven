use serde_json::{json, Value};
use tokio::sync::mpsc;

use crate::net::sse::StreamFrame;

use crate::translate::json::fix_json;

use super::{
    send_message_event, effective_chat_finish_reason, emit_belated_tool_use_start, emit_message_stop,
    emit_tool_use_start, map_chat_finish_to_messages, map_tool_name, message_delta_event,
    message_start_event, sanitize_claude_tool_id, stop_text_block, stop_thinking_block,
    MessagesStream,
};

pub(crate) fn extract_openai_usage(usage: &Value) -> (i64, i64, i64) {
    if usage.is_null() {
        return (0, 0, 0);
    }
    let mut input_tokens = usage
        .get("prompt_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let output_tokens = usage
        .get("completion_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cached_tokens = usage
        .pointer("/prompt_tokens_details/cached_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if cached_tokens > 0 {
        input_tokens = (input_tokens - cached_tokens).max(0);
    }

    (input_tokens, output_tokens, cached_tokens)
}

pub(crate) fn collect_openai_reasoning_texts(node: &Value) -> Vec<String> {
    let mut texts = Vec::new();
    match node {
        Value::Array(arr) => {
            for item in arr {
                texts.extend(collect_openai_reasoning_texts(item));
            }
        }
        Value::String(s) => {
            if !s.is_empty() {
                texts.push(s.clone());
            }
        }
        Value::Object(obj) => {
            if let Some(text) = obj.get("text") {
                let text = text
                    .as_str()
                    .map(str::to_string)
                    .unwrap_or_else(|| text.to_string());
                if !text.is_empty() {
                    texts.push(text);
                }
            }
        }

        Value::Number(_) | Value::Bool(_) => texts.push(node.to_string()),
        Value::Null => {}
    }
    texts
}

pub(crate) fn chat_chunk_to_messages(
    data: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) -> bool {
    let trimmed = data.trim();
    if trimmed == "[DONE]" {
        flush_implicit_think_tail(params, sender);
        stop_thinking_block(params, sender);
        stop_text_block(params, sender);

        if !params.content_blocks_stopped {
            let indexes: Vec<usize> = params.tool_calls_accumulator.keys().copied().collect();
            for index in indexes {
                if !emit_belated_tool_use_start(params, index, sender) {
                    continue;
                }
                let block_index = params.tool_content_block_index(index);
                let args = params
                    .tool_calls_accumulator
                    .get(&index)
                    .map(|a| a.arguments.clone())
                    .unwrap_or_default();
                if !args.is_empty() {
                    let fixed_json = fix_json(&args);
                    send_message_event(
                        sender,
                        "content_block_delta",
                        &json!({
                            "type": "content_block_delta",
                            "index": block_index,
                            "delta": {
                                "type": "input_json_delta",
                                "partial_json": fixed_json,
                            },
                        }),
                    );
                }
                send_message_event(
                    sender,
                    "content_block_stop",
                    &json!({
                        "type": "content_block_stop",
                        "index": block_index,
                    }),
                );
                params.tool_call_block_indexes.remove(&index);
            }
            params.content_blocks_stopped = true;
        }

        if !params.finish_reason.is_empty() && !params.message_delta_sent {
            let stop_reason =
                map_chat_finish_to_messages(effective_chat_finish_reason(params));
            send_message_event(
                sender,
                "message_delta",
                &message_delta_event(stop_reason, 0, 0, 0),
            );
            params.message_delta_sent = true;
        }

        emit_message_stop(params, sender);
        return false;
    }

    let Ok(root) = serde_json::from_str::<Value>(trimmed) else {
        return true;
    };

    if params.message_id.is_empty() {
        if let Some(id) = root.get("id").and_then(Value::as_str) {
            if !id.is_empty() {
                params.message_id = id.to_string();
            }
        }
    }
    if params.model.is_empty() {
        if let Some(m) = root.get("model").and_then(Value::as_str) {
            if !m.is_empty() {
                params.model = m.to_string();
            }
        }
    }

    let choice = root
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first());

    if let Some(choice) = choice {
        if let Some(delta) = choice.get("delta") {
            if !params.message_started {
                send_message_event(
                    sender,
                    "message_start",
                    &message_start_event(&params.message_id, &params.model),
                );
                params.message_started = true;
            }

            if let Some(reasoning) = delta
                .get("reasoning_content")
                .filter(|v| !v.is_null() && v.as_str() != Some(""))
                .or_else(|| delta.get("reasoning"))
            {
                for reasoning_text in collect_openai_reasoning_texts(reasoning) {
                    if reasoning_text.is_empty() {
                        continue;
                    }

                    params.implicit_think_scan = false;
                    emit_thinking_delta(&reasoning_text, params, sender);
                }
            }

            if let Some(content) = delta.get("content").and_then(Value::as_str) {
                if params.implicit_think_scan {
                    emit_implicit_think_content(content, params, sender);
                } else {
                    emit_text_delta(content, params, sender);
                }
            }

            if let Some(tool_calls) = delta.get("tool_calls").and_then(Value::as_array) {
                for tool_call in tool_calls {
                    let index =
                        tool_call.get("index").and_then(Value::as_i64).unwrap_or(0) as usize;
                    let acc = params.tool_calls_accumulator.entry(index).or_default();

                    if let Some(id) = tool_call.get("id").and_then(Value::as_str) {
                        if !id.is_empty() {
                            acc.id = id.to_string();
                        }
                    }

                    if let Some(function) = tool_call.get("function") {
                        if !acc.start_emitted {
                            if let Some(name) = function.get("name").and_then(Value::as_str) {
                                if !name.is_empty() {
                                    acc.name = map_tool_name(params.tool_name_map.as_ref(), name);
                                }
                            }
                        }
                        let args = crate::translate::json::tool_arguments_string(
                            function.get("arguments"),
                        );
                        if !args.is_empty() {
                            acc.arguments.push_str(&args);
                        }
                    }

                    if !acc.start_emitted
                        && !acc.name.is_empty()
                        && !acc.id.is_empty()
                        && !params.content_blocks_stopped
                    {
                        emit_tool_use_start(params, index, sender);
                    }
                }
            }
        }

        if let Some(reason) = choice.get("finish_reason").and_then(Value::as_str) {
            if !reason.is_empty() {
                if reason == "tool_calls" && !params.saw_tool_call {
                    params.finish_reason = "stop".to_string();
                } else {
                    params.finish_reason = reason.to_string();
                }

                flush_implicit_think_tail(params, sender);
                stop_thinking_block(params, sender);
                stop_text_block(params, sender);

                if !params.content_blocks_stopped {
                    let indexes: Vec<usize> =
                        params.tool_calls_accumulator.keys().copied().collect();
                    for index in indexes {
                        if !emit_belated_tool_use_start(params, index, sender) {
                            continue;
                        }
                        let block_index = params.tool_content_block_index(index);
                        let args = params
                            .tool_calls_accumulator
                            .get(&index)
                            .map(|a| a.arguments.clone())
                            .unwrap_or_default();
                        if !args.is_empty() {
                            let fixed_json = fix_json(&args);
                            send_message_event(
                                sender,
                                "content_block_delta",
                                &json!({
                                    "type": "content_block_delta",
                                    "index": block_index,
                                    "delta": {
                                        "type": "input_json_delta",
                                        "partial_json": fixed_json,
                                    },
                                }),
                            );
                        }
                        send_message_event(
                            sender,
                            "content_block_stop",
                            &json!({
                                "type": "content_block_stop",
                                "index": block_index,
                            }),
                        );
                        params.tool_call_block_indexes.remove(&index);
                    }
                    params.content_blocks_stopped = true;
                }
            }
        }
    }

    if !params.finish_reason.is_empty() && !params.message_delta_sent {
        if let Some(usage) = root.get("usage").filter(|u| !u.is_null()) {
            let (in_tok, out_tok, cached_tok) = extract_openai_usage(usage);
            params.input_tokens = in_tok;
            params.output_tokens = out_tok;
            params.cached_tokens = cached_tok;

            let stop_reason =
                map_chat_finish_to_messages(effective_chat_finish_reason(params));
            send_message_event(
                sender,
                "message_delta",
                &message_delta_event(stop_reason, in_tok, out_tok, cached_tok),
            );
            params.message_delta_sent = true;
            emit_message_stop(params, sender);
        }
    }

    true
}

pub(crate) const THINK_CLOSE: &str = "</think>";

pub(crate) const THINK_OPEN: &str = "<think>";

pub(crate) fn emit_thinking_delta(
    text: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if text.is_empty() {
        return;
    }
    params
        .first_token_at
        .get_or_insert_with(std::time::Instant::now);
    stop_text_block(params, sender);
    if !params.thinking_block_started {
        if params.thinking_block_index == -1 {
            params.thinking_block_index = params.next_block_index;
            params.next_block_index += 1;
        }
        send_message_event(
            sender,
            "content_block_start",
            &json!({
                "type": "content_block_start",
                "index": params.thinking_block_index,
                "content_block": {"type": "thinking", "thinking": ""},
            }),
        );
        params.thinking_block_started = true;
    }
    send_message_event(
        sender,
        "content_block_delta",
        &json!({
            "type": "content_block_delta",
            "index": params.thinking_block_index,
            "delta": {"type": "thinking_delta", "thinking": text},
        }),
    );
}

fn emit_text_delta(
    text: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if text.is_empty() {
        return;
    }
    params
        .first_token_at
        .get_or_insert_with(std::time::Instant::now);
    if !params.text_block_started {
        stop_thinking_block(params, sender);
        if params.text_block_index == -1 {
            params.text_block_index = params.next_block_index;
            params.next_block_index += 1;
        }
        send_message_event(
            sender,
            "content_block_start",
            &json!({
                "type": "content_block_start",
                "index": params.text_block_index,
                "content_block": {"type": "text", "text": ""},
            }),
        );
        params.text_block_started = true;
    }
    send_message_event(
        sender,
        "content_block_delta",
        &json!({
            "type": "content_block_delta",
            "index": params.text_block_index,
            "delta": {"type": "text_delta", "text": text},
        }),
    );
}

pub(crate) fn pending_marker_len(buf: &str) -> usize {
    [THINK_CLOSE, THINK_OPEN]
        .iter()
        .map(|marker| pending_prefix_len(buf, marker))
        .max()
        .unwrap_or(0)
}

fn pending_prefix_len(buf: &str, marker: &str) -> usize {
    let marker = marker.as_bytes();
    let bytes = buf.as_bytes();
    let mut n = (marker.len() - 1).min(bytes.len());
    while n > 0 {
        if bytes[bytes.len() - n..] == marker[..n] {
            return n;
        }
        n -= 1;
    }
    0
}

fn emit_implicit_think_content(
    content: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if params.implicit_think_closed {
        emit_implicit_answer(content, params, sender);
        return;
    }

    params.implicit_think_tail.push_str(content);

    let opened_at = params.implicit_think_tail.find(THINK_OPEN);
    let closed_at = params.implicit_think_tail.find(THINK_CLOSE);

    if let Some(open) = opened_at {
        if closed_at.is_none_or(|close| close > open) {
            let buffered = std::mem::take(&mut params.implicit_think_tail);
            params.implicit_think_scan = false;
            emit_pre_marker(&buffered, params, sender);
            return;
        }
    }

    if let Some(at) = closed_at {
        let buffered = std::mem::take(&mut params.implicit_think_tail);
        emit_pre_marker(&buffered[..at], params, sender);
        params.implicit_think_closed = true;
        params.implicit_think_seen = true;
        emit_implicit_answer(&buffered[at + THINK_CLOSE.len()..], params, sender);
        return;
    }

    let pending = pending_marker_len(&params.implicit_think_tail);
    let flush_to = params.implicit_think_tail.len() - pending;
    let flushed = params.implicit_think_tail[..flush_to].to_string();
    params.implicit_think_tail.drain(..flush_to);
    emit_pre_marker(&flushed, params, sender);
}

fn emit_pre_marker(
    text: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if params.implicit_think_open {
        emit_thinking_delta(text, params, sender);
    } else {
        emit_text_delta(text, params, sender);
    }
}

pub(crate) fn flush_implicit_think_tail(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if params.implicit_think_tail.is_empty() {
        return;
    }
    let tail = std::mem::take(&mut params.implicit_think_tail);
    if params.implicit_think_closed {
        emit_implicit_answer(&tail, params, sender);
    } else {
        emit_pre_marker(&tail, params, sender);
    }
}

fn emit_implicit_answer(
    content: &str,
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    let answer = if params.implicit_answer_started || !params.implicit_think_open {
        content
    } else {
        content.trim_start_matches(['\n', '\r'])
    };
    if answer.is_empty() {
        return;
    }
    params.implicit_answer_started = true;
    emit_text_delta(answer, params, sender);
}

pub(crate) fn split_implicit_think_message(
    message: &mut Value,
    known_quirk: bool,
    promote: bool,
) -> bool {
    let truncated = message.get("stop_reason").and_then(Value::as_str) == Some("max_tokens");
    let Some(blocks) = message.get_mut("content").and_then(Value::as_array_mut) else {
        return false;
    };

    if blocks
        .iter()
        .any(|block| block.get("type").and_then(Value::as_str) == Some("thinking"))
    {
        return false;
    }
    let Some(first) = blocks.first() else {
        return false;
    };
    if first.get("type").and_then(Value::as_str) != Some("text") {
        return false;
    }
    let text = first
        .get("text")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let closed_at = text.find(THINK_CLOSE);

    if let Some(open) = text.find(THINK_OPEN) {
        if closed_at.is_none_or(|close| close > open) {
            return false;
        }
    }

    if !promote {
        if let Some(at) = closed_at {
            let stripped = format!("{}{}", &text[..at], &text[at + THINK_CLOSE.len()..]);
            blocks[0] = json!({"type": "text", "text": stripped});
            return true;
        }
        return false;
    }

    let (reasoning, answer, found) = match closed_at {
        Some(at) => (
            &text[..at],
            text[at + THINK_CLOSE.len()..].trim_start_matches(['\n', '\r']),
            true,
        ),

        None if known_quirk && truncated => (text.as_str(), "", false),
        None => return false,
    };

    let mut replacement: Vec<Value> = Vec::with_capacity(2);
    if !reasoning.is_empty() {
        replacement.push(json!({"type": "thinking", "thinking": reasoning}));
    }
    if !answer.is_empty() {
        replacement.push(json!({"type": "text", "text": answer}));
    }
    blocks.splice(0..1, replacement);
    found
}

pub(crate) fn chat_completion_to_messages(
    body: &Value,
    message_id: &str,
    model: &str,
    tool_name_map: Option<&std::collections::HashMap<String, String>>,
) -> Value {
    let mut blocks: Vec<Value> = Vec::new();
    let mut has_tool_call = false;
    let mut stop_reason_set = false;
    let mut stop_reason = Value::Null;

    let tool_use_block = |call: &Value,
                          tool_name_map: Option<&std::collections::HashMap<String, String>>|
     -> Value {
        let raw_id = call.get("id").and_then(Value::as_str).unwrap_or("");
        let name = call
            .get("function")
            .and_then(|f| f.get("name"))
            .and_then(Value::as_str)
            .unwrap_or("");
        let args_str = crate::translate::json::tool_arguments_string(
            call.get("function").and_then(|f| f.get("arguments")),
        );
        let fixed = fix_json(&args_str);
        let input = if fixed.is_empty() {
            json!({})
        } else {
            match serde_json::from_str::<Value>(&fixed) {
                Ok(parsed) if parsed.is_object() => parsed,
                _ => json!({}),
            }
        };
        json!({
            "type": "tool_use",
            "id": sanitize_claude_tool_id(raw_id),
            "name": map_tool_name(tool_name_map, name),
            "input": input,
        })
    };

    if let Some(choice) = body
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|choices| choices.first())
    {
        if let Some(reason) = choice.get("finish_reason") {
            stop_reason = json!(map_chat_finish_to_messages(
                reason.as_str().unwrap_or("")
            ));
            stop_reason_set = true;
        }

        if let Some(message) = choice.get("message") {
            match message.get("content") {
                Some(Value::Array(items)) => {
                    let mut text_builder = String::new();
                    let mut thinking_builder = String::new();

                    macro_rules! flush_text {
                        () => {
                            if !text_builder.is_empty() {
                                blocks.push(json!({"type": "text", "text": text_builder}));
                                text_builder.clear();
                            }
                        };
                    }
                    macro_rules! flush_thinking {
                        () => {
                            if !thinking_builder.is_empty() {
                                blocks.push(
                                    json!({"type": "thinking", "thinking": thinking_builder}),
                                );
                                thinking_builder.clear();
                            }
                        };
                    }

                    for item in items {
                        match item.get("type").and_then(Value::as_str).unwrap_or("") {
                            "text" => {
                                flush_thinking!();
                                text_builder.push_str(
                                    item.get("text").and_then(Value::as_str).unwrap_or(""),
                                );
                            }
                            "tool_calls" => {
                                flush_thinking!();
                                flush_text!();
                                if let Some(calls) =
                                    item.get("tool_calls").and_then(Value::as_array)
                                {
                                    for call in calls {
                                        has_tool_call = true;
                                        blocks.push(tool_use_block(call, tool_name_map));
                                    }
                                }
                            }
                            "reasoning" => {
                                flush_text!();
                                thinking_builder.push_str(
                                    item.get("text").and_then(Value::as_str).unwrap_or(""),
                                );
                            }
                            _ => {
                                flush_thinking!();
                                flush_text!();
                            }
                        }
                    }
                    flush_thinking!();
                    flush_text!();
                }

                Some(Value::String(text)) => {
                    if !text.is_empty() {
                        blocks.push(json!({"type": "text", "text": text}));
                    }
                }
                _ => {}
            }

            if let Some(reasoning) = message
                .get("reasoning_content")
                .filter(|v| !v.is_null() && v.as_str() != Some(""))
                .or_else(|| message.get("reasoning"))
            {
                for text in collect_openai_reasoning_texts(reasoning) {
                    if !text.is_empty() {
                        blocks.push(json!({"type": "thinking", "thinking": text}));
                    }
                }
            }

            if let Some(tool_calls) = message.get("tool_calls").and_then(Value::as_array) {
                for call in tool_calls {
                    has_tool_call = true;
                    blocks.push(tool_use_block(call, tool_name_map));
                }
            }
        }
    }

    let (input_tokens, output_tokens, cached_tokens) = match body.get("usage") {
        Some(usage) => extract_openai_usage(usage),
        None => (0, 0, 0),
    };
    let mut usage_json = json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
    });
    if cached_tokens > 0 {
        usage_json["cache_read_input_tokens"] = json!(cached_tokens);
    }

    if !stop_reason_set {
        stop_reason = if has_tool_call {
            json!("tool_use")
        } else {
            json!("end_turn")
        };
    }

    let id = body
        .get("id")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or(message_id);
    let model = body
        .get("model")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .unwrap_or(model);

    json!({
        "id": id,
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": blocks,
        "stop_reason": stop_reason,
        "stop_sequence": null,
        "usage": usage_json,
    })
}

#[cfg(test)]
mod implicit_think_tests {
    use super::*;
    use crate::net::sse::StreamFrame;

    fn deltas(chunks: &[&str], implicit_think_open: bool) -> Vec<(String, String)> {
        run(chunks, implicit_think_open).0
    }

    fn run(chunks: &[&str], implicit_think_open: bool) -> (Vec<(String, String)>, bool) {
        let (sender, mut receiver) = mpsc::unbounded_channel::<StreamFrame>();
        let mut params = MessagesStream::new();
        params.implicit_think_open = implicit_think_open;
        for content in chunks {
            let chunk = json!({
                "id": "c1",
                "model": "m",
                "choices": [{"delta": {"content": content}}],
            });
            chat_chunk_to_messages(&chunk.to_string(), &mut params, &sender);
        }
        chat_chunk_to_messages("[DONE]", &mut params, &sender);
        drop(sender);
        let seen = params.implicit_think_seen;

        let mut out = Vec::new();
        while let Ok(frame) = receiver.try_recv() {
            let StreamFrame::Data(raw) = frame else {
                continue;
            };
            let raw = String::from_utf8_lossy(&raw).to_string();
            for line in raw.lines() {
                let Some(payload) = line.strip_prefix("data: ") else {
                    continue;
                };
                let Ok(event) = serde_json::from_str::<Value>(payload) else {
                    continue;
                };
                if event.get("type").and_then(Value::as_str) != Some("content_block_delta") {
                    continue;
                }
                let delta = &event["delta"];
                match delta.get("type").and_then(Value::as_str) {
                    Some("thinking_delta") => out.push((
                        "thinking".to_string(),
                        delta["thinking"].as_str().unwrap_or("").to_string(),
                    )),
                    Some("text_delta") => out.push((
                        "text".to_string(),
                        delta["text"].as_str().unwrap_or("").to_string(),
                    )),
                    _ => {}
                }
            }
        }
        (out, seen)
    }

    fn joined(deltas: &[(String, String)], kind: &str) -> String {
        deltas
            .iter()
            .filter(|(block, _)| block == kind)
            .map(|(_, text)| text.as_str())
            .collect()
    }

    #[test]
    fn stream_splits_reasoning_from_answer() {
        let out = deltas(&["Need to", " answer.\n", "</think>", "\n\nOK"], true);
        assert_eq!(joined(&out, "thinking"), "Need to answer.\n");
        assert_eq!(joined(&out, "text"), "OK");

        assert!(!joined(&out, "text").contains(THINK_CLOSE));
    }

    #[test]
    fn stream_reassembles_a_marker_split_across_chunks() {
        let out = deltas(&["think", "</", "thi", "nk>", "answer"], true);
        assert_eq!(joined(&out, "thinking"), "think");
        assert_eq!(joined(&out, "text"), "answer");
    }

    #[test]
    fn stream_keeps_a_later_marker_verbatim_in_the_answer() {
        let out = deltas(&["why", "</think>", "use </think> to close"], true);
        assert_eq!(joined(&out, "thinking"), "why");
        assert_eq!(joined(&out, "text"), "use </think> to close");
    }

    #[test]
    fn stream_holds_back_only_a_real_partial_marker() {
        let out = deltas(&["a<", "x</think>b"], true);
        assert_eq!(joined(&out, "thinking"), "a<x");
        assert_eq!(joined(&out, "text"), "b");
    }

    #[test]
    fn stream_without_the_marker_is_all_reasoning() {
        let out = deltas(&["cut off mid-thou", "</thi"], true);
        assert_eq!(joined(&out, "thinking"), "cut off mid-thou</thi");
        assert_eq!(joined(&out, "text"), "");
    }

    #[test]
    fn first_encounter_strips_the_marker_and_learns_the_quirk() {
        let (out, seen) = run(&["why", "</think>", "\n\nOK"], false);
        assert_eq!(joined(&out, "thinking"), "");
        assert_eq!(joined(&out, "text"), "why\n\nOK");
        assert!(seen);
    }

    #[test]
    fn a_matched_think_pair_is_left_verbatim() {
        let (out, seen) = run(&["<think>why", "</think>", "OK"], false);
        assert_eq!(joined(&out, "thinking"), "");
        assert_eq!(joined(&out, "text"), "<think>why</think>OK");
        assert!(!seen);
    }

    #[test]
    fn reported_reasoning_disables_the_scan() {
        let (sender, mut receiver) = mpsc::unbounded_channel::<StreamFrame>();
        let mut params = MessagesStream::new();
        for chunk in [
            json!({"id": "c", "model": "m", "choices": [{"delta": {"reasoning_content": "why"}}]}),
            json!({"id": "c", "model": "m", "choices": [{"delta": {"content": "a</think>b"}}]}),
        ] {
            chat_chunk_to_messages(&chunk.to_string(), &mut params, &sender);
        }
        chat_chunk_to_messages("[DONE]", &mut params, &sender);
        drop(sender);
        let mut text = String::new();
        while let Ok(StreamFrame::Data(raw)) = receiver.try_recv() {
            let raw = String::from_utf8_lossy(&raw).to_string();
            for line in raw.lines() {
                let Some(payload) = line.strip_prefix("data: ") else {
                    continue;
                };
                let Ok(event) = serde_json::from_str::<Value>(payload) else {
                    continue;
                };
                if event["delta"].get("type").and_then(Value::as_str) == Some("text_delta") {
                    text.push_str(event["delta"]["text"].as_str().unwrap_or(""));
                }
            }
        }
        assert_eq!(text, "a</think>b");
        assert!(!params.implicit_think_seen);
    }

    #[test]
    fn no_marker_means_no_quirk_learned() {
        let (out, seen) = run(&["a plain answer"], false);
        assert_eq!(joined(&out, "text"), "a plain answer");
        assert!(!seen);
    }

    #[test]
    fn openrouter_reasoning_field_becomes_thinking() {
        let (sender, mut receiver) = mpsc::unbounded_channel::<StreamFrame>();
        let mut params = MessagesStream::new();
        for chunk in [
            json!({"id": "c", "model": "m", "choices": [{"delta": {"reasoning": "step one"}}]}),
            json!({"id": "c", "model": "m", "choices": [{"delta": {"content": "answer"}}]}),
        ] {
            chat_chunk_to_messages(&chunk.to_string(), &mut params, &sender);
        }
        chat_chunk_to_messages("[DONE]", &mut params, &sender);
        drop(sender);
        let (mut thinking, mut text) = (String::new(), String::new());
        while let Ok(StreamFrame::Data(raw)) = receiver.try_recv() {
            let raw = String::from_utf8_lossy(&raw).to_string();
            for line in raw.lines() {
                let Some(payload) = line.strip_prefix("data: ") else {
                    continue;
                };
                let Ok(event) = serde_json::from_str::<Value>(payload) else {
                    continue;
                };
                match event["delta"].get("type").and_then(Value::as_str) {
                    Some("thinking_delta") => {
                        thinking.push_str(event["delta"]["thinking"].as_str().unwrap_or(""))
                    }
                    Some("text_delta") => {
                        text.push_str(event["delta"]["text"].as_str().unwrap_or(""))
                    }
                    _ => {}
                }
            }
        }
        assert_eq!(thinking, "step one");
        assert_eq!(text, "answer");
    }

    #[test]
    fn empty_reasoning_content_falls_through_to_reasoning() {
        let mut message = json!({
            "role": "assistant",
            "content": "answer",
            "reasoning_content": "",
            "reasoning": "the real reasoning",
        });
        let body = json!({"choices": [{"message": message.take(), "finish_reason": "stop"}]});
        let out = chat_completion_to_messages(&body, "id", "m", None);
        let blocks = out["content"].as_array().unwrap();
        let thinking = blocks.iter().find(|b| b["type"] == "thinking");
        assert_eq!(
            thinking.map(|b| b["thinking"].clone()),
            Some(json!("the real reasoning"))
        );
    }

    #[test]
    fn nonstream_splits_reasoning_from_answer() {
        let mut message = json!({
            "content": [{"type": "text", "text": "why\n</think>\n\nOK"}],
            "stop_reason": "end_turn",
        });
        assert!(split_implicit_think_message(&mut message, false, true));
        assert_eq!(
            message["content"],
            json!([
                {"type": "thinking", "thinking": "why\n"},
                {"type": "text", "text": "OK"},
            ])
        );
    }

    #[test]
    fn nonstream_leaves_an_unmarked_answer_alone() {
        let mut message = json!({
            "content": [{"type": "text", "text": "OK"}],
            "stop_reason": "end_turn",
        });
        assert!(!split_implicit_think_message(&mut message, false, true));
        assert_eq!(message["content"], json!([{"type": "text", "text": "OK"}]));
    }

    #[test]
    fn nonstream_leaves_a_truncated_run_alone_until_the_quirk_is_known() {
        let mut message = json!({
            "content": [{"type": "text", "text": "still reasoning"}],
            "stop_reason": "max_tokens",
        });
        assert!(!split_implicit_think_message(&mut message, false, true));
        assert_eq!(
            message["content"],
            json!([{"type": "text", "text": "still reasoning"}])
        );
    }

    #[test]
    fn nonstream_labels_a_truncated_reasoning_run_as_thinking() {
        let mut message = json!({
            "content": [{"type": "text", "text": "still reasoning"}],
            "stop_reason": "max_tokens",
        });
        assert!(!split_implicit_think_message(&mut message, true, true));
        assert_eq!(
            message["content"],
            json!([{"type": "thinking", "thinking": "still reasoning"}])
        );
    }

    #[test]
    fn nonstream_ignores_a_leading_tool_use_block() {
        let blocks = json!([
            {"type": "tool_use", "id": "t1", "name": "Bash", "input": {}},
            {"type": "text", "text": "a</think>b"},
        ]);
        let mut message = json!({"content": blocks.clone(), "stop_reason": "tool_use"});
        assert!(!split_implicit_think_message(&mut message, false, true));
        assert_eq!(message["content"], blocks);
    }

    #[test]
    fn nonstream_only_strips_the_marker_when_thinking_was_not_requested() {
        let mut message = json!({
            "content": [{"type": "text", "text": "why\n</think>\n\nOK"}],
            "stop_reason": "end_turn",
        });
        assert!(split_implicit_think_message(&mut message, false, false));
        assert_eq!(
            message["content"],
            json!([{"type": "text", "text": "why\n\n\nOK"}])
        );
    }

    #[test]
    fn nonstream_leaves_reported_reasoning_alone() {
        let blocks = json!([
            {"type": "thinking", "thinking": "why"},
            {"type": "text", "text": "a</think>b"},
        ]);
        let mut message = json!({"content": blocks.clone(), "stop_reason": "end_turn"});
        assert!(!split_implicit_think_message(&mut message, false, true));
        assert_eq!(message["content"], blocks);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn maps_chat_completion_to_messages() {
        let body = json!({
            "id": "chatcmpl-1",
            "model": "deepseek-v4-flash",
            "choices": [{
                "finish_reason": "stop",
                "message": {
                    "role": "assistant",
                    "content": "Hello there",
                },
            }],
            "usage": {"prompt_tokens": 10, "completion_tokens": 5},
        });
        let out = chat_completion_to_messages(&body, "msg_1", "deepseek-v4-flash", None);

        assert_eq!(out["id"], "chatcmpl-1");
        assert_eq!(out["type"], "message");
        assert_eq!(out["content"][0]["type"], "text");
        assert_eq!(out["content"][0]["text"], "Hello there");
        assert_eq!(out["stop_reason"], "end_turn");
        assert_eq!(out["usage"]["input_tokens"], 10);
    }

    #[test]
    fn array_content_interleaves_text_thinking_and_tool_use() {
        let body = json!({
            "choices": [{"message": {"content": [
                {"type": "reasoning", "text": "think a"},
                {"type": "text", "text": "visible"},
                {"type": "tool_calls", "tool_calls": [
                    {"id": "call_1", "function": {"name": "f", "arguments": "{\"a\":1}"}}
                ]},
            ]}}]
        });
        let out = chat_completion_to_messages(&body, "m", "mdl", None);
        let kinds: Vec<&str> = out["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, vec!["thinking", "text", "tool_use"]);
        assert_eq!(out["content"][2]["input"]["a"], 1);

        assert_eq!(out["stop_reason"], "tool_use");
    }

    #[test]
    fn content_blocks_precede_reasoning_and_message_tool_calls() {
        let body = json!({
            "choices": [{"message": {
                "content": "hello",
                "reasoning_content": "why",
                "tool_calls": [{"id": "c", "function": {"name": "g", "arguments": "{}"}}],
            }}]
        });
        let out = chat_completion_to_messages(&body, "m", "mdl", None);
        let kinds: Vec<&str> = out["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, vec!["text", "thinking", "tool_use"]);
    }

    #[test]
    fn missing_finish_reason_without_tools_is_end_turn() {
        let body = json!({"choices": [{"message": {"content": "hi"}}]});
        let out = chat_completion_to_messages(&body, "m", "mdl", None);
        assert_eq!(out["stop_reason"], "end_turn");
    }

    #[test]
    fn tool_names_are_restored_through_the_map() {
        let mut map = std::collections::HashMap::new();
        map.insert("my_tool".to_string(), "My-Tool".to_string());
        let body = json!({
            "choices": [{"message": {"tool_calls": [
                {"id": "c", "function": {"name": "my_tool", "arguments": "{}"}}
            ]}}]
        });
        let out = chat_completion_to_messages(&body, "m", "mdl", Some(&map));
        assert_eq!(out["content"][0]["name"], "My-Tool");
    }

    #[test]
    fn maps_finish_reasons() {
        assert_eq!(map_chat_finish_to_messages("stop"), "end_turn");
        assert_eq!(map_chat_finish_to_messages("length"), "max_tokens");
        assert_eq!(map_chat_finish_to_messages("tool_calls"), "tool_use");
    }
}
