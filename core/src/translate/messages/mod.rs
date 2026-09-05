pub mod input_tokens;
pub mod tool_names;
pub mod via_chat_reply;
pub mod via_chat_request;
pub mod via_generate_reply;
pub mod via_responses_reply;
pub mod via_responses_request;

use serde_json::{json, Value};
use std::time::Instant;
use tokio::sync::mpsc;

use crate::net::sse::{FrameSender, StreamFrame};
use crate::translate::json::fix_json;
use crate::translate::ids::uuid_v4;
pub(crate) fn new_message_id() -> String {
    format!("msg_{}", uuid_v4().replace('-', ""))
}

pub(crate) fn send_message_event(sender: &FrameSender, name: &str, data: &Value) {
    crate::net::sse::send_event(sender, name, data);
}

pub(crate) fn message_start_event(id: &str, model: &str) -> Value {
    json!({
        "type": "message_start",
        "message": {
            "id": id,
            "type": "message",
            "role": "assistant",
            "model": model,
            "content": [],
            "stop_reason": null,
            "stop_sequence": null,
            "usage": {"input_tokens": 0, "output_tokens": 0},
        },
    })
}

pub(crate) fn map_chat_finish_to_messages(reason: &str) -> &'static str {
    match reason {
        "stop" => "end_turn",
        "length" => "max_tokens",
        "tool_calls" => "tool_use",

        "content_filter" => "end_turn",

        "function_call" => "tool_use",
        _ => "end_turn",
    }
}

pub(crate) fn message_delta_event(
    stop_reason: &str,
    input_tokens: i64,
    output_tokens: i64,
    cached_tokens: i64,
) -> Value {
    let mut usage = json!({
        "input_tokens": input_tokens,
        "output_tokens": output_tokens,
    });
    if cached_tokens > 0 {
        usage["cache_read_input_tokens"] = json!(cached_tokens);
    }
    json!({
        "type": "message_delta",
        "delta": {"stop_reason": stop_reason, "stop_sequence": null},
        "usage": usage,
    })
}

static CLAUDE_TOOL_USE_ID_COUNTER: std::sync::atomic::AtomicU64 =
    std::sync::atomic::AtomicU64::new(1);

pub fn sanitize_claude_tool_id(id: &str) -> String {
    let mut s = String::with_capacity(id.len());
    for c in id.chars() {
        if c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            s.push(c);
        } else {
            s.push('_');
        }
    }
    if s.is_empty() {
        let counter = CLAUDE_TOOL_USE_ID_COUNTER.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let nanos = crate::translate::ids::now_unix_nanos();
        s = format!("toolu_{nanos}_{counter}");
    }
    s
}

pub fn canonical_tool_name(name: &str) -> String {
    let canonical = name.trim();
    let canonical = canonical.trim_start_matches('_');
    canonical.to_lowercase()
}

pub fn tool_name_map(req: &Value) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    if let Some(tools) = req.get("tools").and_then(Value::as_array) {
        for tool in tools {
            let mut name = tool
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if name.is_empty() {
                name = tool
                    .pointer("/function/name")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
            }
            if name.is_empty() {
                continue;
            }
            let key = canonical_tool_name(name);
            if !key.is_empty() {
                map.entry(key).or_insert_with(|| name.to_string());
            }
        }
    }
    map
}

pub fn map_tool_name<'a>(
    tool_name_map: Option<&'a std::collections::HashMap<String, String>>,
    name: &'a str,
) -> String {
    if name.is_empty() {
        return String::new();
    }
    if let Some(map) = tool_name_map {
        let key = canonical_tool_name(name);
        if let Some(mapped) = map.get(&key) {
            if !mapped.is_empty() {
                return mapped.clone();
            }
        }
    }
    name.to_string()
}

pub fn normalize_object_schema_properties(schema: &mut Value) {
    match schema {
        Value::Object(map) => {
            if map.get("type").and_then(Value::as_str) == Some("object") {
                if !map.contains_key("properties") {
                    map.insert("properties".to_string(), json!({}));
                }
            }
            for (_key, child) in map.iter_mut() {
                normalize_object_schema_properties(child);
            }
        }
        Value::Array(arr) => {
            for child in arr.iter_mut() {
                normalize_object_schema_properties(child);
            }
        }
        _ => {}
    }
}

#[derive(Default)]
pub(crate) struct ToolCallAccumulator {
    pub(crate) id: String,
    pub(crate) name: String,
    pub(crate) arguments: String,
    pub(crate) start_emitted: bool,
}

pub(crate) struct MessagesStream {
    pub(crate) message_id: String,
    pub(crate) model: String,
    pub(crate) tool_name_map: Option<std::collections::HashMap<String, String>>,
    pub(crate) message_started: bool,
    pub(crate) text_block_started: bool,
    pub(crate) text_block_index: i64,
    pub(crate) thinking_block_started: bool,
    pub(crate) thinking_block_index: i64,
    pub(crate) tool_calls_accumulator: std::collections::BTreeMap<usize, ToolCallAccumulator>,
    pub(crate) tool_call_block_indexes: std::collections::HashMap<usize, i64>,
    pub(crate) next_block_index: i64,
    pub(crate) finish_reason: String,
    pub(crate) saw_tool_call: bool,
    pub(crate) content_blocks_stopped: bool,
    pub(crate) message_delta_sent: bool,
    pub(crate) message_stop_sent: bool,
    pub(crate) input_tokens: i64,
    pub(crate) output_tokens: i64,
    pub(crate) cached_tokens: i64,

    pub(crate) implicit_think_open: bool,

    pub(crate) implicit_think_scan: bool,

    pub(crate) implicit_think_seen: bool,

    pub(crate) implicit_think_closed: bool,

    pub(crate) implicit_answer_started: bool,

    pub(crate) implicit_think_tail: String,

    pub(crate) first_token_at: Option<Instant>,
}

impl MessagesStream {
    pub(crate) fn new() -> Self {
        Self {
            message_id: String::new(),
            model: String::new(),
            tool_name_map: None,
            message_started: false,
            text_block_started: false,
            text_block_index: -1,
            thinking_block_started: false,
            thinking_block_index: -1,
            tool_calls_accumulator: std::collections::BTreeMap::new(),
            tool_call_block_indexes: std::collections::HashMap::new(),
            next_block_index: 0,
            finish_reason: String::new(),
            saw_tool_call: false,
            content_blocks_stopped: false,
            message_delta_sent: false,
            message_stop_sent: false,
            input_tokens: 0,
            output_tokens: 0,
            cached_tokens: 0,
            implicit_think_open: false,
            implicit_think_scan: true,
            implicit_think_seen: false,
            implicit_think_closed: false,
            implicit_answer_started: false,
            implicit_think_tail: String::new(),
            first_token_at: None,
        }
    }

    pub(crate) fn tool_content_block_index(&mut self, openai_index: usize) -> i64 {
        if let Some(index) = self.tool_call_block_indexes.get(&openai_index) {
            return *index;
        }
        let index = self.next_block_index;
        self.next_block_index += 1;
        self.tool_call_block_indexes.insert(openai_index, index);
        index
    }

    pub(crate) fn tool_block_index(&mut self, openai_index: usize) -> i64 {
        self.tool_content_block_index(openai_index)
    }
}

pub(crate) fn stop_text_block(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if !params.text_block_started {
        return;
    }
    send_message_event(
        sender,
        "content_block_stop",
        &json!({"type": "content_block_stop", "index": params.text_block_index}),
    );
    params.text_block_started = false;
    params.text_block_index = -1;
}

pub(crate) fn stop_thinking_block(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if !params.thinking_block_started {
        return;
    }
    send_message_event(
        sender,
        "content_block_stop",
        &json!({"type": "content_block_stop", "index": params.thinking_block_index}),
    );
    params.thinking_block_started = false;
    params.thinking_block_index = -1;
}

pub(crate) fn emit_message_stop(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if params.message_stop_sent {
        return;
    }
    send_message_event(sender, "message_stop", &json!({"type": "message_stop"}));
    params.message_stop_sent = true;
}

pub(crate) fn is_truncating_finish_reason(reason: &str) -> bool {
    matches!(
        reason,
        "length" | "max_tokens" | "max-tokens" | "max_output_tokens"
    )
}

pub(crate) fn effective_chat_finish_reason(params: &MessagesStream) -> &str {
    if is_truncating_finish_reason(&params.finish_reason) {
        return "length";
    }
    if params.saw_tool_call {
        return "tool_calls";
    }
    &params.finish_reason
}

pub(crate) fn emit_message_delta(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    if params.message_delta_sent {
        return;
    }
    let stop_reason = map_chat_finish_to_messages(effective_chat_finish_reason(params));
    send_message_event(
        sender,
        "message_delta",
        &message_delta_event(
            stop_reason,
            params.input_tokens,
            params.output_tokens,
            params.cached_tokens,
        ),
    );
    params.message_delta_sent = true;
    emit_message_stop(params, sender);
}

pub(crate) fn emit_tool_use_start(
    params: &mut MessagesStream,
    openai_index: usize,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    stop_thinking_block(params, sender);
    stop_text_block(params, sender);

    let block_index = params.tool_content_block_index(openai_index);
    let (call_id, call_name) = {
        let acc = params
            .tool_calls_accumulator
            .get_mut(&openai_index)
            .unwrap();
        acc.start_emitted = true;
        (sanitize_claude_tool_id(&acc.id), acc.name.clone())
    };
    params.saw_tool_call = true;
    params.first_token_at.get_or_insert_with(Instant::now);

    send_message_event(
        sender,
        "content_block_start",
        &json!({
            "type": "content_block_start",
            "index": block_index,
            "content_block": {
                "type": "tool_use",
                "id": call_id,
                "name": call_name,
                "input": {},
            },
        }),
    );
}

pub(crate) fn emit_belated_tool_use_start(
    params: &mut MessagesStream,
    openai_index: usize,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) -> bool {
    let acc = match params.tool_calls_accumulator.get_mut(&openai_index) {
        Some(a) => a,
        None => return false,
    };
    if acc.start_emitted {
        return true;
    }
    if acc.name.is_empty() && acc.id.is_empty() && acc.arguments.is_empty() {
        return false;
    }
    if acc.name.is_empty() {
        acc.name = format!("tool_{openai_index}");
    }
    emit_tool_use_start(params, openai_index, sender);
    true
}

pub(crate) fn finalize_stream(
    params: &mut MessagesStream,
    sender: &mpsc::UnboundedSender<StreamFrame>,
) {
    via_chat_reply::flush_implicit_think_tail(params, sender);
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
    if params.finish_reason.is_empty() {
        params.finish_reason = "stop".to_string();
    }
    emit_message_delta(params, sender);
}

#[cfg(test)]
mod tests {
    use super::*;


    #[test]
    fn truncation_outranks_the_tool_call_override() {
        for reason in ["length", "max_tokens", "max-tokens", "max_output_tokens"] {
            let mut params = MessagesStream::new();
            params.saw_tool_call = true;
            params.finish_reason = reason.to_string();
            assert_eq!(
                effective_chat_finish_reason(&params),
                "length",
                "{reason}"
            );
            assert_eq!(
                map_chat_finish_to_messages(effective_chat_finish_reason(&params)),
                "max_tokens",
                "{reason}"
            );
        }
    }

    #[test]
    fn a_completed_tool_call_still_reports_tool_use() {
        let mut params = MessagesStream::new();
        params.saw_tool_call = true;
        params.finish_reason = "stop".to_string();
        assert_eq!(effective_chat_finish_reason(&params), "tool_calls");
        assert_eq!(
            map_chat_finish_to_messages(effective_chat_finish_reason(&params)),
            "tool_use"
        );
    }

    #[test]
    fn truncation_without_a_tool_call_is_unchanged() {
        let mut params = MessagesStream::new();
        params.finish_reason = "length".to_string();
        assert_eq!(
            map_chat_finish_to_messages(effective_chat_finish_reason(&params)),
            "max_tokens"
        );
    }
}
