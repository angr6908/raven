use serde_json::{json, Value};
use std::collections::HashMap;

use crate::translate::messages::tool_names::{
    resolve_tool_use_name, reverse_short_name_map, shorten_call_id_if_needed,
};
use crate::translate::messages::sanitize_claude_tool_id;

pub type SseEvent = (String, Value);

const THINKING_SUMMARY_PART_SEPARATOR: &str = "\n\n";

#[derive(Debug, Default, Clone)]
struct FunctionCallStream {
    call_id: String,
    name: String,
    block_index: i64,
    arguments: String,
    emitted_arguments_length: usize,
    has_received_arguments_delta: bool,
    emit_initial_empty_delta: bool,
    started: bool,
    done: bool,
    closed: bool,
}

#[derive(Debug, Default)]
pub struct ResponsesToMessages {
    pub has_emitted_tool_use: bool,
    pub block_index: i64,
    pub has_text_delta: bool,
    pub text_block_open: bool,
    pub thinking_block_open: bool,
    pub thinking_signature: String,
    pub thinking_summary_seen: bool,

    web_search_tool_use_ids: std::collections::HashSet<String>,
    web_search_tool_result_ids: std::collections::HashSet<String>,
    last_web_search_tool_use_id: String,

    calls: Vec<FunctionCallStream>,

    call_aliases: HashMap<String, usize>,

    call_queue: Vec<usize>,
    active_call: Option<usize>,
    last_call: Option<usize>,
    deferred_events: Vec<Value>,

    reverse_names: HashMap<String, String>,
}

impl ResponsesToMessages {
    pub fn new(original_request: &Value) -> Self {
        Self {
            reverse_names: reverse_short_name_map(original_request),
            ..Default::default()
        }
    }

    fn start_text_block(&mut self, out: &mut Vec<SseEvent>) {
        if self.text_block_open {
            return;
        }
        out.push((
            "content_block_start".into(),
            json!({
                "type": "content_block_start",
                "index": self.block_index,
                "content_block": {"type": "text", "text": ""},
            }),
        ));
        self.text_block_open = true;
    }

    fn stop_text_block(&mut self, out: &mut Vec<SseEvent>) {
        if !self.text_block_open {
            return;
        }
        out.push((
            "content_block_stop".into(),
            json!({"type": "content_block_stop", "index": self.block_index}),
        ));
        self.text_block_open = false;
        self.block_index += 1;
    }

    fn start_thinking_block(&mut self, out: &mut Vec<SseEvent>) {
        if self.thinking_block_open {
            return;
        }
        out.push((
            "content_block_start".into(),
            json!({
                "type": "content_block_start",
                "index": self.block_index,
                "content_block": {"type": "thinking", "thinking": ""},
            }),
        ));
        self.thinking_block_open = true;
    }

    fn append_thinking_delta(&mut self, out: &mut Vec<SseEvent>, text: &str) {
        if text.is_empty() {
            return;
        }
        out.push((
            "content_block_delta".into(),
            json!({
                "type": "content_block_delta",
                "index": self.block_index,
                "delta": {"type": "thinking_delta", "thinking": text},
            }),
        ));
    }

    fn finalize_thinking_block(&mut self, out: &mut Vec<SseEvent>) {
        if !self.thinking_block_open {
            return;
        }
        if !self.thinking_signature.is_empty() {
            out.push((
                "content_block_delta".into(),
                json!({
                    "type": "content_block_delta",
                    "index": self.block_index,
                    "delta": {"type": "signature_delta", "signature": self.thinking_signature},
                }),
            ));
        }
        out.push((
            "content_block_stop".into(),
            json!({"type": "content_block_stop", "index": self.block_index}),
        ));
        self.block_index += 1;
        self.thinking_block_open = false;
    }

    fn finalize_signature_only_thinking_block(&mut self, out: &mut Vec<SseEvent>) {
        if self.thinking_signature.is_empty() {
            return;
        }
        self.start_thinking_block(out);
        self.finalize_thinking_block(out);
    }

    fn call_keys(root: &Value, item: &Value) -> Vec<String> {
        let mut keys: Vec<String> = Vec::with_capacity(5);
        let mut push = |key: String| {
            if !key.is_empty() && !keys.contains(&key) {
                keys.push(key);
            }
        };
        if let Some(output_index) = root.get("output_index") {
            push(format!("output:{output_index}"));
        }
        if let Some(call_id) = item.get("call_id").and_then(Value::as_str) {
            if !call_id.is_empty() {
                push(format!("call:{call_id}"));
            }
        }
        if let Some(call_id) = root.get("call_id").and_then(Value::as_str) {
            if !call_id.is_empty() {
                push(format!("call:{call_id}"));
            }
        }
        if let Some(item_id) = item.get("id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                push(format!("item:{item_id}"));
            }
        }
        if let Some(item_id) = root.get("item_id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                push(format!("item:{item_id}"));
            }
        }
        keys
    }

    fn call_for_keys(&self, keys: &[String]) -> Option<usize> {
        keys.iter().find_map(|k| self.call_aliases.get(k).copied())
    }

    fn call_for_event(&self, root: &Value, item: &Value) -> Option<usize> {
        let keys = Self::call_keys(root, item);
        if !keys.is_empty() {
            if let Some(index) = self.call_for_keys(&keys) {
                return Some(index);
            }

            return None;
        }
        self.last_call
    }

    fn record_call(&mut self, root: &Value, item: &Value) -> usize {
        let keys = Self::call_keys(root, item);
        let index = match self.call_for_keys(&keys) {
            Some(index) => index,
            None => {
                self.calls.push(FunctionCallStream {
                    block_index: -1,
                    ..Default::default()
                });
                let index = self.calls.len() - 1;
                self.call_queue.push(index);
                index
            }
        };
        for key in keys {
            self.call_aliases.insert(key, index);
        }
        self.last_call = Some(index);
        index
    }

    fn update_call_identity(&mut self, index: usize, root: &Value, item: &Value) {
        if let Some(call_id) = item.get("call_id").and_then(Value::as_str) {
            if !call_id.is_empty() {
                self.calls[index].call_id = call_id.to_string();
            }
        }
        if let Some(name) = item.get("name").and_then(Value::as_str) {
            if !name.is_empty() {
                self.calls[index].name = name.to_string();
            }
        }
        for key in Self::call_keys(root, item) {
            self.call_aliases.insert(key, index);
        }
    }

    fn update_call_arguments(&mut self, index: usize, arguments: &str, delta: bool) {
        if arguments.is_empty() {
            return;
        }
        let call = &mut self.calls[index];
        if delta {
            call.arguments.push_str(arguments);
            call.has_received_arguments_delta = true;
            return;
        }
        if !call.has_received_arguments_delta {
            call.arguments = arguments.to_string();
            return;
        }

        if arguments.starts_with(&call.arguments) {
            call.arguments = arguments.to_string();
        }
    }

    fn flush_call_arguments(&mut self, out: &mut Vec<SseEvent>, index: usize) {
        if self.active_call != Some(index) {
            return;
        }
        let call = &self.calls[index];
        if !call.started || call.closed || call.emitted_arguments_length >= call.arguments.len() {
            return;
        }
        let partial = call.arguments[call.emitted_arguments_length..].to_string();
        let block_index = call.block_index;
        out.push((
            "content_block_delta".into(),
            json!({
                "type": "content_block_delta",
                "index": block_index,
                "delta": {"type": "input_json_delta", "partial_json": partial},
            }),
        ));
        self.calls[index].emitted_arguments_length = self.calls[index].arguments.len();
    }

    fn drain_call_queue(&mut self, out: &mut Vec<SseEvent>) {
        loop {
            if let Some(active) = self.active_call {
                self.flush_call_arguments(out, active);
                if !self.calls[active].done {
                    return;
                }
                let block_index = self.calls[active].block_index;
                out.push((
                    "content_block_stop".into(),
                    json!({"type": "content_block_stop", "index": block_index}),
                ));
                if self.block_index <= block_index {
                    self.block_index = block_index + 1;
                }
                self.calls[active].closed = true;
                self.active_call = None;
                self.call_queue.retain(|i| *i != active);
            }

            while self
                .call_queue
                .first()
                .map(|i| self.calls[*i].closed)
                .unwrap_or(false)
            {
                self.call_queue.remove(0);
            }
            let Some(&index) = self.call_queue.first() else {
                return;
            };
            if self.calls[index].name.is_empty() {
                return;
            }

            self.calls[index].block_index = self.block_index;
            let call_id = self.calls[index].call_id.clone();
            let name = self.calls[index].name.clone();
            let block_index = self.calls[index].block_index;
            out.push((
                "content_block_start".into(),
                json!({
                    "type": "content_block_start",
                    "index": block_index,
                    "content_block": {
                        "type": "tool_use",
                        "id": shorten_call_id_if_needed(&sanitize_claude_tool_id(&call_id)),
                        "name": resolve_tool_use_name(&self.reverse_names, &name),
                        "input": {},
                    },
                }),
            ));
            if self.calls[index].emit_initial_empty_delta {
                out.push((
                    "content_block_delta".into(),
                    json!({
                        "type": "content_block_delta",
                        "index": block_index,
                        "delta": {"type": "input_json_delta", "partial_json": ""},
                    }),
                ));
            }
            self.calls[index].started = true;
            self.active_call = Some(index);
            self.has_emitted_tool_use = true;
            self.flush_call_arguments(out, index);
        }
    }

    fn calls_from_terminal(&mut self, out: &mut Vec<SseEvent>, response_data: &Value) {
        if let Some(output) = response_data.get("output").and_then(Value::as_array) {
            for (position, item) in output.iter().enumerate() {
                if item.get("type").and_then(Value::as_str) != Some("function_call") {
                    continue;
                }
                let mut keys = Self::call_keys(&Value::Null, item);
                if let Some(output_index) = item.get("output_index") {
                    let key = format!("output:{output_index}");
                    if !keys.contains(&key) {
                        keys.push(key);
                    }
                }
                let key = format!("output:{position}");
                if !keys.contains(&key) {
                    keys.push(key);
                }
                let index = match self.call_for_keys(&keys) {
                    Some(index) => index,
                    None => {
                        self.calls.push(FunctionCallStream {
                            block_index: -1,
                            ..Default::default()
                        });
                        let index = self.calls.len() - 1;
                        self.call_queue.push(index);
                        index
                    }
                };
                for key in keys {
                    self.call_aliases.insert(key, index);
                }
                self.update_call_identity(index, &Value::Null, item);
                let args = item
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.update_call_arguments(index, &args, false);
                self.calls[index].done = true;
            }
        }

        let queue = std::mem::take(&mut self.call_queue);
        let mut kept = Vec::with_capacity(queue.len());
        for index in queue {
            if self.calls[index].closed {
                continue;
            }
            if self.calls[index].name.is_empty() {
                self.calls[index].closed = true;
                continue;
            }
            self.calls[index].done = true;
            kept.push(index);
        }
        self.call_queue = kept;
        self.drain_call_queue(out);

        self.call_aliases.clear();
        self.call_queue.clear();
        self.active_call = None;
        self.last_call = None;
    }

    fn web_search_tool_use_id(&mut self, root: &Value, item: &Value) -> String {
        for path in ["id", "output_item_id", "call_id"] {
            for source in [item, root] {
                let value = source
                    .get(path)
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if !value.is_empty() {
                    return value.to_string();
                }
            }
        }
        if !self.last_web_search_tool_use_id.is_empty() {
            return self.last_web_search_tool_use_id.clone();
        }
        for source in [item, root] {
            let value = source
                .get("item_id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if !value.is_empty() {
                return value.to_string();
            }
        }
        let id = format!("web_search_{}", self.block_index);
        self.last_web_search_tool_use_id = id.clone();
        id
    }

    fn append_web_search_server_tool_use(
        &mut self,
        out: &mut Vec<SseEvent>,
        root: &Value,
        item: &Value,
    ) {
        let tool_use_id = self.web_search_tool_use_id(root, item);
        if tool_use_id.is_empty() {
            return;
        }
        let query = web_search_query(root, item);
        let already_started = self.web_search_tool_use_ids.contains(&tool_use_id);
        if already_started && query.is_empty() {
            return;
        }

        if !already_started {
            self.stop_text_block(out);
            self.finalize_thinking_block(out);
            out.push((
                "content_block_start".into(),
                json!({
                    "type": "content_block_start",
                    "index": self.block_index,
                    "content_block": {
                        "type": "server_tool_use",
                        "id": tool_use_id,
                        "name": "web_search",
                        "input": {},
                    },
                }),
            ));
        }

        if !query.is_empty() {
            let partial = serde_json::to_string(&json!({"query": query})).unwrap_or_default();
            out.push((
                "content_block_delta".into(),
                json!({
                    "type": "content_block_delta",
                    "index": self.block_index,
                    "delta": {"type": "input_json_delta", "partial_json": partial},
                }),
            ));
        }

        if !already_started {
            out.push((
                "content_block_stop".into(),
                json!({"type": "content_block_stop", "index": self.block_index}),
            ));
            self.web_search_tool_use_ids.insert(tool_use_id);
            self.block_index += 1;
        }
    }

    fn append_web_search_tool_result(
        &mut self,
        out: &mut Vec<SseEvent>,
        root: &Value,
        item: &Value,
    ) {
        let tool_use_id = self.web_search_tool_use_id(root, item);
        if tool_use_id.is_empty() {
            return;
        }
        self.append_web_search_server_tool_use(out, root, item);
        if self.web_search_tool_result_ids.contains(&tool_use_id) {
            return;
        }
        let content = web_search_result_content(root, item);
        if web_search_query(root, item).is_empty()
            && content.is_none()
            && item.get("action").is_none()
        {
            return;
        }

        let mut content_block = serde_json::Map::new();
        content_block.insert("type".into(), json!("web_search_tool_result"));
        content_block.insert("tool_use_id".into(), json!(tool_use_id));
        content_block.insert("content".into(), content.unwrap_or(json!([])));
        out.push((
            "content_block_start".into(),
            json!({
                "type": "content_block_start",
                "index": self.block_index,
                "content_block": Value::Object(content_block),
            }),
        ));
        out.push((
            "content_block_stop".into(),
            json!({"type": "content_block_stop", "index": self.block_index}),
        ));
        self.web_search_tool_result_ids.insert(tool_use_id.clone());
        self.block_index += 1;
        if tool_use_id == self.last_web_search_tool_use_id {
            self.last_web_search_tool_use_id.clear();
        }
    }

    fn should_defer(&self, type_str: &str, root: &Value) -> bool {
        match type_str {
            "error"
            | "response.completed"
            | "response.incomplete"
            | "response.function_call_arguments.delta"
            | "response.function_call_arguments.done" => false,
            "response.output_item.added" | "response.output_item.done" => {
                root.pointer("/item/type").and_then(Value::as_str) != Some("function_call")
            }
            _ => true,
        }
    }

    pub fn convert(&mut self, root: &Value) -> Vec<SseEvent> {
        let mut out: Vec<SseEvent> = Vec::new();
        let type_str = root
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();

        if self.active_call.is_some() && self.should_defer(&type_str, root) {
            self.deferred_events.push(root.clone());
            return out;
        }

        match type_str.as_str() {
            "error" => out.push(("error".into(), codex_stream_error_to_claude(root))),
            "response.created" => {
                out.push((
                    "message_start".into(),
                    json!({
                        "type": "message_start",
                        "message": {
                            "id": root.pointer("/response/id").and_then(Value::as_str).unwrap_or(""),
                            "type": "message",
                            "role": "assistant",
                            "model": root.pointer("/response/model").and_then(Value::as_str).unwrap_or(""),
                            "stop_sequence": null,
                            "usage": {"input_tokens": 0, "output_tokens": 0},
                            "content": [],
                            "stop_reason": null,
                        },
                    }),
                ));
            }
            "response.reasoning_summary_part.added" => {
                self.stop_text_block(&mut out);

                if self.thinking_block_open {
                    self.append_thinking_delta(&mut out, THINKING_SUMMARY_PART_SEPARATOR);
                } else {
                    self.start_thinking_block(&mut out);
                }
                self.thinking_summary_seen = true;
            }
            "response.reasoning_summary_text.delta" => {
                self.stop_text_block(&mut out);
                self.start_thinking_block(&mut out);
                let delta = root
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.append_thinking_delta(&mut out, &delta);
            }

            "response.reasoning_summary_part.done" => {}
            "response.content_part.added" => {
                self.finalize_thinking_block(&mut out);
                if root.pointer("/part/type").and_then(Value::as_str) == Some("output_text") {
                    self.start_text_block(&mut out);
                }
            }
            "response.output_text.delta" => {
                self.has_text_delta = true;
                self.finalize_thinking_block(&mut out);
                self.start_text_block(&mut out);
                out.push((
                    "content_block_delta".into(),
                    json!({
                        "type": "content_block_delta",
                        "index": self.block_index,
                        "delta": {
                            "type": "text_delta",
                            "text": root.get("delta").and_then(Value::as_str).unwrap_or(""),
                        },
                    }),
                ));
            }
            "response.content_part.done" => {
                if root.pointer("/part/type").and_then(Value::as_str) == Some("output_text") {
                    self.stop_text_block(&mut out);
                }
            }

            "response.web_search_call.searching"
            | "response.web_search_call.completed"
            | "response.web_search_call.in_progress" => {}
            "response.completed" | "response.incomplete" => {
                let response_data = root.get("response").cloned().unwrap_or(Value::Null);
                self.finalize_thinking_block(&mut out);
                self.stop_text_block(&mut out);
                self.calls_from_terminal(&mut out, &response_data);
                self.flush_deferred(&mut out);
                self.finalize_thinking_block(&mut out);
                self.stop_text_block(&mut out);

                let stop_reason = map_codex_stop_reason_to_claude(
                    &codex_stop_reason(&response_data),
                    self.has_emitted_tool_use,
                );
                let (input_tokens, output_tokens, cached_tokens) =
                    extract_responses_usage(response_data.get("usage"));
                let mut delta = serde_json::Map::new();
                delta.insert("stop_reason".into(), json!(stop_reason));
                delta.insert(
                    "stop_sequence".into(),
                    codex_stop_sequence(&response_data).unwrap_or(Value::Null),
                );
                let mut usage = serde_json::Map::new();
                usage.insert("input_tokens".into(), json!(input_tokens));
                usage.insert("output_tokens".into(), json!(output_tokens));
                if cached_tokens > 0 {
                    usage.insert("cache_read_input_tokens".into(), json!(cached_tokens));
                }
                out.push((
                    "message_delta".into(),
                    json!({
                        "type": "message_delta",
                        "delta": Value::Object(delta),
                        "usage": Value::Object(usage),
                    }),
                ));
                out.push(("message_stop".into(), json!({"type": "message_stop"})));
            }
            "response.output_item.added" => {
                let item = root.get("item").cloned().unwrap_or(Value::Null);
                match item.get("type").and_then(Value::as_str).unwrap_or("") {
                    "function_call" => {
                        self.finalize_thinking_block(&mut out);
                        self.stop_text_block(&mut out);
                        let index = self.record_call(root, &item);
                        self.update_call_identity(index, root, &item);
                        if !self.calls[index].name.is_empty() {
                            self.calls[index].emit_initial_empty_delta = true;
                        }
                        self.drain_call_queue(&mut out);
                    }
                    "reasoning" => {
                        self.stop_text_block(&mut out);

                        self.finalize_thinking_block(&mut out);
                        self.thinking_summary_seen = false;

                        self.thinking_signature = item
                            .get("encrypted_content")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                    }

                    _ => {}
                }
            }
            "response.output_item.done" => {
                let item = root.get("item").cloned().unwrap_or(Value::Null);
                match item.get("type").and_then(Value::as_str).unwrap_or("") {
                    "message" => {
                        if self.has_text_delta {
                            return out;
                        }
                        let Some(content) = item.get("content").and_then(Value::as_array) else {
                            return out;
                        };
                        let text: String = content
                            .iter()
                            .filter(|p| {
                                p.get("type").and_then(Value::as_str) == Some("output_text")
                            })
                            .filter_map(|p| p.get("text").and_then(Value::as_str))
                            .collect();
                        if text.is_empty() {
                            return out;
                        }
                        self.finalize_thinking_block(&mut out);
                        self.start_text_block(&mut out);
                        out.push((
                            "content_block_delta".into(),
                            json!({
                                "type": "content_block_delta",
                                "index": self.block_index,
                                "delta": {"type": "text_delta", "text": text},
                            }),
                        ));
                        self.stop_text_block(&mut out);
                        self.has_text_delta = true;
                    }
                    "function_call" => {
                        self.finalize_thinking_block(&mut out);
                        self.stop_text_block(&mut out);
                        let index = match self.call_for_event(root, &item) {
                            Some(index) => index,
                            None => self.record_call(root, &item),
                        };
                        self.update_call_identity(index, root, &item);
                        let args = item
                            .get("arguments")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        self.update_call_arguments(index, &args, false);
                        self.calls[index].done = true;
                        self.drain_call_queue(&mut out);
                    }
                    "reasoning" => {
                        self.stop_text_block(&mut out);
                        if let Some(signature) =
                            item.get("encrypted_content").and_then(Value::as_str)
                        {
                            if !signature.is_empty() {
                                self.thinking_signature = signature.to_string();
                            }
                        }
                        if self.thinking_summary_seen {
                            self.finalize_thinking_block(&mut out);
                        } else {
                            self.finalize_signature_only_thinking_block(&mut out);
                        }
                        self.thinking_signature.clear();
                        self.thinking_summary_seen = false;
                    }
                    "web_search_call" => {
                        let root = root.clone();
                        self.append_web_search_tool_result(&mut out, &root, &item);
                    }
                    _ => {}
                }
            }
            "response.function_call_arguments.delta" => {
                let index = match self.call_for_event(root, &Value::Null) {
                    Some(index) => index,
                    None => self.record_call(root, &Value::Null),
                };
                let delta = root
                    .get("delta")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.update_call_arguments(index, &delta, true);
                self.flush_call_arguments(&mut out, index);
            }
            "response.function_call_arguments.done" => {
                let index = match self.call_for_event(root, &Value::Null) {
                    Some(index) => index,
                    None => self.record_call(root, &Value::Null),
                };
                let args = root
                    .get("arguments")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                self.update_call_arguments(index, &args, false);
                self.flush_call_arguments(&mut out, index);
            }
            _ => {}
        }

        if self.call_queue.is_empty() {
            self.flush_deferred(&mut out);
        }
        out
    }

    fn flush_deferred(&mut self, out: &mut Vec<SseEvent>) {
        if self.deferred_events.is_empty() {
            return;
        }
        let deferred = std::mem::take(&mut self.deferred_events);
        for event in deferred {
            let mut replayed = self.convert(&event);
            out.append(&mut replayed);
        }
    }
}

fn web_search_query(root: &Value, item: &Value) -> String {
    for path in ["/action/query", "/query", "/input/query"] {
        for source in [item, root] {
            let value = source
                .pointer(path)
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim();
            if !value.is_empty() {
                return value.to_string();
            }
        }
    }
    String::new()
}

fn web_search_result_content(root: &Value, item: &Value) -> Option<Value> {
    let results = item
        .get("results")
        .and_then(Value::as_array)
        .or_else(|| root.get("results").and_then(Value::as_array))?;
    let mut blocks: Vec<Value> = Vec::new();
    for result in results {
        let url = result
            .get("url")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        if url.is_empty() {
            continue;
        }
        let title = result
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim();
        let title = if title.is_empty() { url } else { title };
        blocks.push(json!({
            "type": "web_search_result",
            "title": title,
            "url": url,
            "page_age": null,
        }));
    }
    Some(json!(blocks))
}

fn web_search_non_stream_blocks(
    blocks: &mut Vec<Value>,
    item: &Value,
    seen: &mut std::collections::HashSet<String>,
) {
    let id = item
        .get("id")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string();
    if id.is_empty() || seen.contains(&id) {
        return;
    }
    let query = web_search_query(&Value::Null, item);
    let result_content = web_search_result_content(&Value::Null, item);
    if query.is_empty() && result_content.is_none() {
        return;
    }

    let mut use_block = serde_json::Map::new();
    use_block.insert("type".into(), json!("server_tool_use"));
    use_block.insert("id".into(), json!(id));
    use_block.insert("name".into(), json!("web_search"));
    use_block.insert(
        "input".into(),
        if query.is_empty() {
            json!({})
        } else {
            json!({"query": query})
        },
    );
    blocks.push(Value::Object(use_block));

    blocks.push(json!({
        "type": "web_search_tool_result",
        "tool_use_id": id,
        "content": result_content.unwrap_or(json!([])),
    }));
    seen.insert(id);
}

pub fn codex_stream_error_to_claude(root: &Value) -> Value {
    let error = root.get("error");
    let get = |node: Option<&Value>, key: &str| -> String {
        node.and_then(|n| n.get(key))
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
            .to_string()
    };
    let mut err_type = get(error, "type");
    if err_type.is_empty() {
        err_type = get(Some(root), "error_type");
    }
    if err_type.is_empty() {
        err_type = "api_error".to_string();
    }
    let code = get(error, "code");
    let mut message = get(error, "message");
    if message.is_empty() {
        message = get(Some(root), "message");
    }
    if message.is_empty() {
        message = code.clone();
    }
    if message.is_empty() {
        message = err_type.clone();
    }
    if code == "cyber_policy" || err_type == "invalid_request" {
        err_type = "invalid_request_error".to_string();
    }
    json!({"type": "error", "error": {"type": err_type, "message": message}})
}

fn codex_stop_sequence(response_data: &Value) -> Option<Value> {
    response_data.get("stop_sequence").cloned()
}

pub fn codex_stop_reason(response_data: &Value) -> String {
    let stop_sequence_text = codex_stop_sequence(response_data)
        .and_then(|v| v.as_str().map(str::to_string))
        .unwrap_or_default();
    if let Some(stop_reason) = response_data.get("stop_reason").and_then(Value::as_str) {
        if !stop_reason.is_empty() {
            if stop_reason == "stop" && !stop_sequence_text.is_empty() {
                return "stop_sequence".to_string();
            }
            return stop_reason.to_string();
        }
    }
    if let Some(reason) = response_data
        .pointer("/incomplete_details/reason")
        .and_then(Value::as_str)
    {
        if !reason.is_empty() {
            return reason.to_string();
        }
    }
    if !stop_sequence_text.is_empty() {
        return "stop_sequence".to_string();
    }
    String::new()
}

pub fn map_codex_stop_reason_to_claude(stop_reason: &str, has_tool_call: bool) -> String {
    let truncated = matches!(
        stop_reason,
        "max_tokens" | "max_output_tokens" | "model_context_window_exceeded"
    );
    if has_tool_call && !truncated {
        return "tool_use".to_string();
    }
    match stop_reason {
        "" | "stop" | "completed" => "end_turn".to_string(),
        "max_tokens" | "max_output_tokens" => "max_tokens".to_string(),

        "tool_use" | "tool_calls" | "function_call" => "end_turn".to_string(),
        "end_turn"
        | "stop_sequence"
        | "pause_turn"
        | "refusal"
        | "model_context_window_exceeded" => stop_reason.to_string(),
        "content_filter" => "refusal".to_string(),
        _ => "end_turn".to_string(),
    }
}

pub fn extract_responses_usage(usage: Option<&Value>) -> (i64, i64, i64) {
    let Some(usage) = usage.filter(|u| !u.is_null()) else {
        return (0, 0, 0);
    };
    let mut input_tokens = usage
        .get("input_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let output_tokens = usage
        .get("output_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    let cached_tokens = usage
        .pointer("/input_tokens_details/cached_tokens")
        .and_then(Value::as_i64)
        .unwrap_or(0);
    if cached_tokens > 0 {
        input_tokens = if input_tokens >= cached_tokens {
            input_tokens - cached_tokens
        } else {
            0
        };
    }
    (input_tokens, output_tokens, cached_tokens)
}

pub fn responses_to_messages(root: &Value, original_request: &Value) -> Option<Value> {
    let response_data = crate::translate::json::codex_terminal_response(root)?;
    let rev_names = reverse_short_name_map(original_request);

    let (input_tokens, output_tokens, cached_tokens) =
        extract_responses_usage(response_data.get("usage"));

    let mut has_tool_call = false;
    let mut blocks: Vec<Value> = Vec::new();
    let mut web_search_seen: std::collections::HashSet<String> = std::collections::HashSet::new();

    if let Some(output) = response_data.get("output").and_then(Value::as_array) {
        for item in output {
            match item.get("type").and_then(Value::as_str).unwrap_or("") {
                "reasoning" => {
                    let signature = item
                        .get("encrypted_content")
                        .and_then(Value::as_str)
                        .unwrap_or("");
                    let mut thinking = collect_text_like(item.get("summary"));
                    if thinking.is_empty() {
                        thinking = collect_text_like(item.get("content"));
                    }
                    if !thinking.is_empty() || !signature.is_empty() {
                        let mut block = serde_json::Map::new();
                        block.insert("type".into(), json!("thinking"));
                        block.insert("thinking".into(), json!(thinking));
                        if !signature.is_empty() {
                            block.insert("signature".into(), json!(signature));
                        }
                        blocks.push(Value::Object(block));
                    }
                }
                "message" => match item.get("content") {
                    Some(Value::Array(parts)) => {
                        for part in parts {
                            if part.get("type").and_then(Value::as_str) != Some("output_text") {
                                continue;
                            }
                            let text = part.get("text").and_then(Value::as_str).unwrap_or("");
                            if !text.is_empty() {
                                blocks.push(json!({"type": "text", "text": text}));
                            }
                        }
                    }
                    Some(Value::String(text)) if !text.is_empty() => {
                        blocks.push(json!({"type": "text", "text": text}));
                    }
                    _ => {}
                },
                "web_search_call" => {
                    web_search_non_stream_blocks(&mut blocks, item, &mut web_search_seen);
                }
                "function_call" => {
                    has_tool_call = true;
                    let name = item.get("name").and_then(Value::as_str).unwrap_or("");
                    let call_id = item.get("call_id").and_then(Value::as_str).unwrap_or("");
                    let args_str = item.get("arguments").and_then(Value::as_str).unwrap_or("");
                    let input = match serde_json::from_str::<Value>(args_str) {
                        Ok(parsed) if parsed.is_object() => parsed,
                        _ => json!({}),
                    };
                    blocks.push(json!({
                        "type": "tool_use",
                        "id": shorten_call_id_if_needed(&sanitize_claude_tool_id(call_id)),
                        "name": resolve_tool_use_name(&rev_names, name),
                        "input": input,
                    }));
                }
                _ => {}
            }
        }
    }

    let mut out = serde_json::Map::new();
    out.insert(
        "id".into(),
        json!(response_data
            .get("id")
            .and_then(Value::as_str)
            .unwrap_or("")),
    );
    out.insert("type".into(), json!("message"));
    out.insert("role".into(), json!("assistant"));
    out.insert(
        "model".into(),
        json!(response_data
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("")),
    );
    out.insert("content".into(), json!(blocks));
    out.insert(
        "stop_reason".into(),
        json!(map_codex_stop_reason_to_claude(
            &codex_stop_reason(response_data),
            has_tool_call
        )),
    );
    out.insert(
        "stop_sequence".into(),
        codex_stop_sequence(response_data).unwrap_or(Value::Null),
    );
    let mut usage = serde_json::Map::new();
    usage.insert("input_tokens".into(), json!(input_tokens));
    usage.insert("output_tokens".into(), json!(output_tokens));
    if cached_tokens > 0 {
        usage.insert("cache_read_input_tokens".into(), json!(cached_tokens));
    }
    out.insert("usage".into(), Value::Object(usage));
    Some(Value::Object(out))
}

fn collect_text_like(node: Option<&Value>) -> String {
    match node {
        Some(Value::Array(parts)) => parts
            .iter()
            .map(|part| match part.get("text").and_then(Value::as_str) {
                Some(text) => text.to_string(),
                None => part.as_str().unwrap_or("").to_string(),
            })
            .collect(),
        Some(Value::String(text)) => text.clone(),
        _ => String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn names(events: &[SseEvent]) -> Vec<&str> {
        events.iter().map(|(n, _)| n.as_str()).collect()
    }

    #[test]
    fn created_emits_message_start() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let out = p.convert(&json!({
            "type": "response.created",
            "response": {"id": "resp_1", "model": "gpt-5"}
        }));
        assert_eq!(names(&out), vec!["message_start"]);
        assert_eq!(out[0].1["message"]["id"], "resp_1");
        assert_eq!(out[0].1["message"]["model"], "gpt-5");
    }

    #[test]
    fn text_deltas_open_and_close_one_block() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let mut all = p.convert(&json!({"type": "response.output_text.delta", "delta": "Hel"}));
        all.extend(p.convert(&json!({"type": "response.output_text.delta", "delta": "lo"})));
        all.extend(p.convert(
            &json!({"type": "response.content_part.done", "part": {"type": "output_text"}}),
        ));
        assert_eq!(
            names(&all),
            vec![
                "content_block_start",
                "content_block_delta",
                "content_block_delta",
                "content_block_stop"
            ]
        );
        assert_eq!(all[1].1["delta"]["text"], "Hel");
    }

    #[test]
    fn reasoning_summary_parts_share_one_block_separated_by_blank_line() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let mut all = p.convert(&json!({"type": "response.reasoning_summary_part.added"}));
        all.extend(
            p.convert(&json!({"type": "response.reasoning_summary_text.delta", "delta": "first"})),
        );
        all.extend(p.convert(&json!({"type": "response.reasoning_summary_part.added"})));
        all.extend(
            p.convert(&json!({"type": "response.reasoning_summary_text.delta", "delta": "second"})),
        );

        assert_eq!(
            names(&all)
                .iter()
                .filter(|n| **n == "content_block_start")
                .count(),
            1
        );
        let separators: Vec<&Value> = all
            .iter()
            .filter(|(n, v)| n == "content_block_delta" && v["delta"]["thinking"] == "\n\n")
            .map(|(_, v)| v)
            .collect();
        assert_eq!(separators.len(), 1);
    }

    #[test]
    fn reasoning_signature_is_emitted_then_the_block_closes() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        p.convert(&json!({"type": "response.reasoning_summary_part.added"}));
        p.convert(&json!({"type": "response.reasoning_summary_text.delta", "delta": "why"}));
        let out = p.convert(&json!({
            "type": "response.output_item.done",
            "item": {"type": "reasoning", "encrypted_content": "sig-x"}
        }));
        assert_eq!(
            names(&out),
            vec!["content_block_delta", "content_block_stop"]
        );
        assert_eq!(out[0].1["delta"]["type"], "signature_delta");
        assert_eq!(out[0].1["delta"]["signature"], "sig-x");
    }

    #[test]
    fn signature_only_reasoning_still_produces_a_replayable_block() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        p.convert(&json!({
            "type": "response.output_item.added",
            "item": {"type": "reasoning", "encrypted_content": "sig-y"}
        }));
        let out = p.convert(&json!({
            "type": "response.output_item.done",
            "item": {"type": "reasoning", "encrypted_content": "sig-y"}
        }));
        assert_eq!(
            names(&out),
            vec![
                "content_block_start",
                "content_block_delta",
                "content_block_stop"
            ]
        );
        assert_eq!(out[1].1["delta"]["signature"], "sig-y");
    }

    #[test]
    fn function_call_streams_arguments_incrementally() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let mut all = p.convert(&json!({
            "type": "response.output_item.added",
            "output_index": 0,
            "item": {"type": "function_call", "call_id": "call_1", "name": "get_weather"}
        }));
        all.extend(p.convert(&json!({
            "type": "response.function_call_arguments.delta",
            "output_index": 0, "delta": "{\"city\":"
        })));
        all.extend(p.convert(&json!({
            "type": "response.function_call_arguments.delta",
            "output_index": 0, "delta": "\"NYC\"}"
        })));
        all.extend(p.convert(&json!({
            "type": "response.output_item.done",
            "output_index": 0,
            "item": {"type": "function_call", "call_id": "call_1", "name": "get_weather",
                     "arguments": "{\"city\":\"NYC\"}"}
        })));
        let start = all
            .iter()
            .find(|(n, _)| n == "content_block_start")
            .unwrap();
        assert_eq!(start.1["content_block"]["type"], "tool_use");
        assert_eq!(start.1["content_block"]["name"], "get_weather");
        assert_eq!(start.1["content_block"]["id"], "call_1");
        let partials: String = all
            .iter()
            .filter(|(n, v)| n == "content_block_delta" && v["delta"]["type"] == "input_json_delta")
            .map(|(_, v)| v["delta"]["partial_json"].as_str().unwrap().to_string())
            .collect();
        assert_eq!(partials, "{\"city\":\"NYC\"}");
        assert!(all.iter().any(|(n, _)| n == "content_block_stop"));
        assert!(p.has_emitted_tool_use);
    }

    #[test]
    fn completed_emits_message_delta_and_stop_with_net_usage() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let out = p.convert(&json!({
            "type": "response.completed",
            "response": {
                "stop_reason": "stop",
                "usage": {"input_tokens": 100, "output_tokens": 7,
                          "input_tokens_details": {"cached_tokens": 40}}
            }
        }));
        assert_eq!(names(&out), vec!["message_delta", "message_stop"]);
        assert_eq!(out[0].1["delta"]["stop_reason"], "end_turn");

        assert_eq!(out[0].1["usage"]["input_tokens"], 60);
        assert_eq!(out[0].1["usage"]["cache_read_input_tokens"], 40);
    }

    #[test]
    fn tool_use_wins_the_stop_reason() {
        assert_eq!(map_codex_stop_reason_to_claude("stop", true), "tool_use");

        assert_eq!(
            map_codex_stop_reason_to_claude("max_tokens", true),
            "max_tokens"
        );
        assert_eq!(
            map_codex_stop_reason_to_claude("max_output_tokens", true),
            "max_tokens"
        );
        assert_eq!(
            map_codex_stop_reason_to_claude("model_context_window_exceeded", true),
            "model_context_window_exceeded"
        );

        assert_eq!(
            map_codex_stop_reason_to_claude("tool_calls", false),
            "end_turn"
        );
        assert_eq!(
            map_codex_stop_reason_to_claude("content_filter", false),
            "refusal"
        );
        assert_eq!(
            map_codex_stop_reason_to_claude("max_output_tokens", false),
            "max_tokens"
        );
    }

    #[test]
    fn non_stream_builds_blocks_in_output_order() {
        let root = json!({
            "type": "response.completed",
            "response": {
                "id": "resp_9", "model": "gpt-5",
                "output": [
                    {"type": "reasoning", "summary": [{"text": "think"}], "encrypted_content": "s"},
                    {"type": "message", "content": [{"type": "output_text", "text": "hi"}]},
                    {"type": "function_call", "call_id": "c1", "name": "f",
                     "arguments": "{\"a\":1}"}
                ],
                "usage": {"input_tokens": 5, "output_tokens": 2}
            }
        });
        let out = responses_to_messages(&root, &Value::Null).unwrap();
        let kinds: Vec<&str> = out["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, vec!["thinking", "text", "tool_use"]);
        assert_eq!(out["content"][0]["signature"], "s");
        assert_eq!(out["content"][2]["input"]["a"], 1);
        assert_eq!(out["stop_reason"], "tool_use");
        assert_eq!(out["usage"]["input_tokens"], 5);
    }

    #[test]
    fn non_terminal_events_are_not_non_stream_bodies() {
        assert!(responses_to_messages(
            &json!({"type": "response.output_text.delta"}),
            &Value::Null
        )
        .is_none());
    }

    #[test]
    fn stream_error_maps_to_claude_error_shape() {
        let err = codex_stream_error_to_claude(&json!({
            "type": "error",
            "error": {"code": "cyber_policy", "message": "blocked"}
        }));
        assert_eq!(err["error"]["type"], "invalid_request_error");
        assert_eq!(err["error"]["message"], "blocked");
    }
}

#[cfg(test)]
mod web_search_tests {
    use super::*;

    fn names(events: &[SseEvent]) -> Vec<&str> {
        events.iter().map(|(n, _)| n.as_str()).collect()
    }

    #[test]
    fn a_web_search_call_emits_server_tool_use_then_its_result() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let out = p.convert(&json!({
            "type": "response.output_item.done",
            "item": {
                "type": "web_search_call", "id": "ws_1",
                "action": {"query": "rust async"},
                "results": [
                    {"url": "https://a.example", "title": "A"},
                    {"url": "https://b.example"}
                ]
            }
        }));
        assert_eq!(
            names(&out),
            vec![
                "content_block_start",
                "content_block_delta",
                "content_block_stop",
                "content_block_start",
                "content_block_stop"
            ]
        );
        assert_eq!(out[0].1["content_block"]["type"], "server_tool_use");
        assert_eq!(out[0].1["content_block"]["name"], "web_search");
        assert_eq!(
            out[1].1["delta"]["partial_json"],
            "{\"query\":\"rust async\"}"
        );
        let result = &out[3].1["content_block"];
        assert_eq!(result["type"], "web_search_tool_result");
        assert_eq!(result["tool_use_id"], "ws_1");
        assert_eq!(result["content"][0]["title"], "A");

        assert_eq!(result["content"][1]["title"], "https://b.example");
    }

    #[test]
    fn a_repeat_event_re_emits_only_the_query_delta() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        let event = json!({
            "type": "response.output_item.done",
            "item": {"type": "web_search_call", "id": "ws_2",
                     "action": {"query": "q"}, "results": []}
        });
        let first = p.convert(&event);
        assert_eq!(
            names(&first),
            vec![
                "content_block_start",
                "content_block_delta",
                "content_block_stop",
                "content_block_start",
                "content_block_stop"
            ]
        );

        let second = p.convert(&event);
        assert_eq!(names(&second), vec!["content_block_delta"]);
        assert_eq!(second[0].1["delta"]["type"], "input_json_delta");
    }

    #[test]
    fn block_indexes_advance_past_the_search_blocks() {
        let mut p = ResponsesToMessages::new(&Value::Null);
        p.convert(&json!({
            "type": "response.output_item.done",
            "item": {"type": "web_search_call", "id": "ws_3", "action": {"query": "q"}}
        }));

        assert_eq!(p.block_index, 2);
    }

    #[test]
    fn non_stream_web_search_becomes_two_content_blocks() {
        let root = json!({
            "type": "response.completed",
            "response": {
                "status": "completed",
                "output": [{
                    "type": "web_search_call", "id": "ws_9",
                    "action": {"query": "weather"},
                    "results": [{"url": "https://w.example", "title": "W"}]
                }]
            }
        });
        let out = responses_to_messages(&root, &Value::Null).unwrap();
        let kinds: Vec<&str> = out["content"]
            .as_array()
            .unwrap()
            .iter()
            .map(|b| b["type"].as_str().unwrap())
            .collect();
        assert_eq!(kinds, vec!["server_tool_use", "web_search_tool_result"]);
        assert_eq!(out["content"][0]["input"]["query"], "weather");
        assert_eq!(out["content"][1]["content"][0]["url"], "https://w.example");
    }

    #[test]
    fn a_search_with_neither_query_nor_results_is_skipped() {
        let root = json!({
            "type": "response.completed",
            "response": {"status": "completed",
                         "output": [{"type": "web_search_call", "id": "ws_x"}]}
        });
        let out = responses_to_messages(&root, &Value::Null).unwrap();
        assert_eq!(out["content"].as_array().unwrap().len(), 0);
    }
}
