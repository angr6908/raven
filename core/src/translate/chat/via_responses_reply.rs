use serde_json::{json, Map, Value};
use std::collections::HashMap;

use crate::translate::messages::tool_names::build_short_name_map;

#[derive(Debug, Default, Clone)]
struct ToolCallStreamState {
    index: usize,
    arguments_emitted: bool,
    done: bool,
}

#[derive(Debug, Default)]
pub struct ResponsesToChat {
    pub response_id: String,
    pub created_at: i64,
    pub model: String,

    pub function_call_index: i64,
    tool_call_states: HashMap<String, usize>,
    states: Vec<ToolCallStreamState>,
    current_tool_call: Option<usize>,

    last_image_hash_by_item_id: HashMap<String, [u8; 32]>,
    reverse_names: HashMap<String, String>,
}

fn is_codex_tool_call_type(item_type: &str) -> bool {
    item_type == "function_call" || item_type == "custom_tool_call"
}

fn codex_tool_call_arguments(item: &Value) -> String {
    let field = if item.get("type").and_then(Value::as_str) == Some("custom_tool_call") {
        "input"
    } else {
        "arguments"
    };
    item.get(field)
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

fn mime_type_from_codex_output_format(output_format: &str) -> String {
    if output_format.is_empty() {
        return "image/png".to_string();
    }
    if output_format.contains('/') {
        return output_format.to_string();
    }
    match output_format.to_ascii_lowercase().as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "webp" => "image/webp",
        "gif" => "image/gif",
        _ => "image/png",
    }
    .to_string()
}

pub fn reverse_map_from_openai_request(original_request: &Value) -> HashMap<String, String> {
    let mut rev = HashMap::new();
    let Some(tools) = original_request.get("tools").and_then(Value::as_array) else {
        return rev;
    };
    let mut names: Vec<String> = Vec::new();
    let mut seen: Vec<String> = Vec::new();
    for tool in tools {
        let name = match tool.get("type").and_then(Value::as_str).unwrap_or("") {
            "function" => tool
                .pointer("/function/name")
                .and_then(Value::as_str)
                .unwrap_or(""),
            "custom" => tool.get("name").and_then(Value::as_str).unwrap_or(""),
            _ => "",
        };
        if name.is_empty() || seen.iter().any(|s| s == name) {
            continue;
        }
        seen.push(name.to_string());
        names.push(name.to_string());
    }
    if names.is_empty() {
        return rev;
    }
    for (original, short) in build_short_name_map(&names) {
        rev.insert(short, original);
    }
    rev
}

impl ResponsesToChat {
    pub fn new(model: &str, original_request: &Value) -> Self {
        Self {
            model: model.to_string(),
            function_call_index: -1,
            reverse_names: reverse_map_from_openai_request(original_request),
            ..Default::default()
        }
    }

    fn register_tool_call_state(&mut self, event: &Value, item: &Value, state_index: usize) {
        if let Some(item_id) = event.get("item_id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                self.tool_call_states
                    .insert(format!("item:{item_id}"), state_index);
            }
        }
        if let Some(item_id) = item.get("id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                self.tool_call_states
                    .insert(format!("item:{item_id}"), state_index);
            }
        }
        if let Some(output_index) = event.get("output_index") {
            self.tool_call_states
                .insert(format!("output:{output_index}"), state_index);
        }
        self.current_tool_call = Some(state_index);
    }

    fn find_tool_call_state(&self, event: &Value, item: &Value) -> Option<usize> {
        if let Some(item_id) = event.get("item_id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                if let Some(index) = self.tool_call_states.get(&format!("item:{item_id}")) {
                    return Some(*index);
                }
            }
        }
        if let Some(item_id) = item.get("id").and_then(Value::as_str) {
            if !item_id.is_empty() {
                if let Some(index) = self.tool_call_states.get(&format!("item:{item_id}")) {
                    return Some(*index);
                }
            }
        }
        if let Some(output_index) = event.get("output_index") {
            if let Some(index) = self.tool_call_states.get(&format!("output:{output_index}")) {
                return Some(*index);
            }
        }
        self.current_tool_call
    }

    fn restore_name(&self, name: &str) -> String {
        self.reverse_names
            .get(name)
            .cloned()
            .unwrap_or_else(|| name.to_string())
    }

    fn push_image(
        &mut self,
        template: &mut Value,
        item_id: &str,
        b64: &str,
        output_format: &str,
    ) -> bool {
        if b64.is_empty() {
            return false;
        }
        if !item_id.is_empty() {
            let hash = crate::translate::ids::sha256(b64);
            if self.last_image_hash_by_item_id.get(item_id) == Some(&hash) {
                return false;
            }
            self.last_image_hash_by_item_id
                .insert(item_id.to_string(), hash);
        }
        let mime_type = mime_type_from_codex_output_format(output_format);
        let image_url = format!("data:{mime_type};base64,{b64}");
        let delta = template["choices"][0]["delta"]
            .as_object_mut()
            .expect("delta object");
        if delta.get("images").and_then(Value::as_array).is_none() {
            delta.insert("images".into(), json!([]));
        }
        delta.insert("role".into(), json!("assistant"));
        if let Some(images) = delta.get_mut("images").and_then(Value::as_array_mut) {
            let index = images.len();
            images.push(json!({
                "type": "image_url",
                "image_url": {"url": image_url},
                "index": index,
            }));
        }
        true
    }

    fn tool_call_chunk(template: &mut Value, item: Value) {
        let delta = template["choices"][0]["delta"]
            .as_object_mut()
            .expect("delta object");
        delta.insert("tool_calls".into(), json!([item]));
    }

    pub fn convert(&mut self, root: &Value) -> Option<Value> {
        let data_type = root.get("type").and_then(Value::as_str).unwrap_or("");

        if data_type == "response.created" {
            self.response_id = root
                .pointer("/response/id")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            self.created_at = root
                .pointer("/response/created_at")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            self.model = root
                .pointer("/response/model")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_string();
            return None;
        }

        let mut choice = Map::new();
        choice.insert("index".into(), json!(0));
        choice.insert("delta".into(), Value::Object(Map::new()));
        choice.insert("finish_reason".into(), Value::Null);
        choice.insert("native_finish_reason".into(), Value::Null);

        let mut template = Map::new();
        template.insert("id".into(), json!(self.response_id));
        template.insert("object".into(), json!("chat.completion.chunk"));
        template.insert("created".into(), json!(self.created_at));
        let model = match root.get("model").and_then(Value::as_str) {
            Some(m) => m.to_string(),
            None => self.model.clone(),
        };
        template.insert("model".into(), json!(model));
        template.insert("choices".into(), json!([Value::Object(choice)]));
        let mut template = Value::Object(template);

        if let Some(usage) = root.pointer("/response/usage") {
            let usage_out = codex_usage_to_openai(usage);
            if !usage_out.is_empty() {
                template["usage"] = Value::Object(usage_out);
            }
        }

        match data_type {
            "response.reasoning_summary_text.delta" => {
                let Some(d) = root.get("delta").and_then(Value::as_str) else {
                    return None;
                };
                let delta = template["choices"][0]["delta"].as_object_mut()?;
                delta.insert("role".into(), json!("assistant"));
                delta.insert("reasoning_content".into(), json!(d));
            }
            "response.reasoning_summary_text.done" => {
                let delta = template["choices"][0]["delta"].as_object_mut()?;
                delta.insert("role".into(), json!("assistant"));
                delta.insert("reasoning_content".into(), json!("\n\n"));
            }
            "response.output_text.delta" => {
                let Some(d) = root.get("delta").and_then(Value::as_str) else {
                    return None;
                };
                let delta = template["choices"][0]["delta"].as_object_mut()?;
                delta.insert("role".into(), json!("assistant"));
                delta.insert("content".into(), json!(d));
            }
            "response.image_generation_call.partial_image" => {
                let item_id = root
                    .get("item_id")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let b64 = root
                    .get("partial_image_b64")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let output_format = root
                    .get("output_format")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                if !self.push_image(&mut template, &item_id, &b64, &output_format) {
                    return None;
                }
            }
            "response.completed" | "response.incomplete" => {
                let mut finish_reason = "stop".to_string();
                let mut native_finish_reason = finish_reason.clone();
                if data_type == "response.incomplete" {
                    native_finish_reason = root
                        .pointer("/response/incomplete_details/reason")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    finish_reason = match native_finish_reason.as_str() {
                        "max_tokens" | "max_output_tokens" => "length".to_string(),
                        "content_filter" => "content_filter".to_string(),
                        _ => finish_reason,
                    };
                } else if self.function_call_index != -1 {
                    finish_reason = "tool_calls".to_string();
                    native_finish_reason = finish_reason.clone();
                }
                let choice = template["choices"][0].as_object_mut()?;
                choice.insert("finish_reason".into(), json!(finish_reason));
                choice.insert("native_finish_reason".into(), json!(native_finish_reason));
            }
            "response.output_item.added" => {
                let item = root.get("item").cloned().unwrap_or(Value::Null);
                let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
                if !is_codex_tool_call_type(item_type) {
                    return None;
                }
                self.function_call_index += 1;
                let state_index = self.states.len();
                self.states.push(ToolCallStreamState {
                    index: self.function_call_index as usize,
                    ..Default::default()
                });
                self.register_tool_call_state(root, &item, state_index);

                let name =
                    self.restore_name(item.get("name").and_then(Value::as_str).unwrap_or(""));
                let call_id = item.get("call_id").and_then(Value::as_str).unwrap_or("");
                let delta = template["choices"][0]["delta"].as_object_mut()?;
                delta.insert("role".into(), json!("assistant"));
                delta.insert(
                    "tool_calls".into(),
                    json!([{
                        "index": self.states[state_index].index,
                        "id": call_id,
                        "type": "function",
                        "function": {"name": name, "arguments": ""},
                    }]),
                );
            }
            "response.function_call_arguments.delta" | "response.custom_tool_call_input.delta" => {
                let state_index = self.find_tool_call_state(root, &Value::Null)?;
                let delta_value = root.get("delta").and_then(Value::as_str).unwrap_or("");
                if self.states[state_index].done || delta_value.is_empty() {
                    return None;
                }
                self.states[state_index].arguments_emitted = true;
                let index = self.states[state_index].index;
                Self::tool_call_chunk(
                    &mut template,
                    json!({"index": index, "function": {"arguments": delta_value}}),
                );
            }
            "response.function_call_arguments.done" | "response.custom_tool_call_input.done" => {
                let state_index = self.find_tool_call_state(root, &Value::Null)?;
                if self.states[state_index].done || self.states[state_index].arguments_emitted {
                    return None;
                }
                let field = if data_type == "response.custom_tool_call_input.done" {
                    "input"
                } else {
                    "arguments"
                };
                self.states[state_index].arguments_emitted = true;
                let full_args = root.get(field).and_then(Value::as_str).unwrap_or("");
                if full_args.is_empty() {
                    return None;
                }
                let index = self.states[state_index].index;
                Self::tool_call_chunk(
                    &mut template,
                    json!({"index": index, "function": {"arguments": full_args}}),
                );
            }
            "response.output_item.done" => {
                let item = root.get("item").cloned();
                let item = item.filter(|i| !i.is_null())?;
                let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");

                if item_type == "image_generation_call" {
                    let item_id = item
                        .get("id")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let b64 = item
                        .get("result")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    let output_format = item
                        .get("output_format")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string();
                    if !self.push_image(&mut template, &item_id, &b64, &output_format) {
                        return None;
                    }
                    return Some(template);
                }
                if !is_codex_tool_call_type(item_type) {
                    return None;
                }

                match self.find_tool_call_state(root, &item) {
                    Some(state_index) => {
                        if self.states[state_index].done {
                            return None;
                        }
                        self.states[state_index].done = true;
                        if self.states[state_index].arguments_emitted {
                            return None;
                        }

                        self.states[state_index].arguments_emitted = true;
                        let full_args = codex_tool_call_arguments(&item);
                        if full_args.is_empty() {
                            return None;
                        }
                        let index = self.states[state_index].index;
                        Self::tool_call_chunk(
                            &mut template,
                            json!({"index": index, "function": {"arguments": full_args}}),
                        );
                        return Some(template);
                    }
                    None => {
                        self.function_call_index += 1;
                        let state_index = self.states.len();
                        self.states.push(ToolCallStreamState {
                            index: self.function_call_index as usize,
                            arguments_emitted: true,
                            done: true,
                        });
                        self.register_tool_call_state(root, &item, state_index);

                        let name = self
                            .restore_name(item.get("name").and_then(Value::as_str).unwrap_or(""));
                        let call_id = item.get("call_id").and_then(Value::as_str).unwrap_or("");
                        let index = self.states[state_index].index;
                        let arguments = codex_tool_call_arguments(&item);
                        let delta = template["choices"][0]["delta"].as_object_mut()?;
                        delta.insert("role".into(), json!("assistant"));
                        delta.insert(
                            "tool_calls".into(),
                            json!([{
                                "index": index,
                                "id": call_id,
                                "type": "function",
                                "function": {"name": name, "arguments": arguments},
                            }]),
                        );
                    }
                }
            }
            _ => return None,
        }

        Some(template)
    }
}

pub fn responses_to_chat_completion(root: &Value, original_request: &Value) -> Option<Value> {
    let response = crate::translate::json::codex_terminal_response(root)?;
    let rev = reverse_map_from_openai_request(original_request);

    let mut message = Map::new();
    message.insert("role".into(), json!("assistant"));
    message.insert("content".into(), Value::Null);
    message.insert("reasoning_content".into(), Value::Null);
    message.insert("tool_calls".into(), Value::Null);

    let mut content_text = String::new();
    let mut reasoning_text = String::new();
    let mut tool_calls: Vec<Value> = Vec::new();
    let mut images: Vec<Value> = Vec::new();

    if let Some(output) = response.get("output").and_then(Value::as_array) {
        for item in output {
            match item.get("type").and_then(Value::as_str).unwrap_or("") {
                "reasoning" => {
                    if let Some(summary) = item.get("summary").and_then(Value::as_array) {
                        for part in summary {
                            if part.get("type").and_then(Value::as_str) == Some("summary_text") {
                                if let Some(text) = part.get("text").and_then(Value::as_str) {
                                    reasoning_text.push_str(text);
                                }
                                break;
                            }
                        }
                    }
                }
                "message" => {
                    if let Some(content) = item.get("content").and_then(Value::as_array) {
                        for part in content {
                            if part.get("type").and_then(Value::as_str) == Some("output_text") {
                                if let Some(text) = part.get("text").and_then(Value::as_str) {
                                    content_text.push_str(text);
                                }
                                break;
                            }
                        }
                    }
                }
                "function_call" | "custom_tool_call" => {
                    let raw_name = item.get("name").and_then(Value::as_str).unwrap_or("");
                    let name = rev
                        .get(raw_name)
                        .cloned()
                        .unwrap_or_else(|| raw_name.to_string());
                    tool_calls.push(json!({
                        "id": item.get("call_id").and_then(Value::as_str).unwrap_or(""),
                        "type": "function",
                        "function": {
                            "name": name,
                            "arguments": codex_tool_call_arguments(item),
                        },
                    }));
                }
                "image_generation_call" => {
                    let b64 = item.get("result").and_then(Value::as_str).unwrap_or("");
                    if b64.is_empty() {
                        continue;
                    }
                    let mime_type = mime_type_from_codex_output_format(
                        item.get("output_format")
                            .and_then(Value::as_str)
                            .unwrap_or(""),
                    );
                    images.push(json!({
                        "type": "image_url",
                        "image_url": {"url": format!("data:{mime_type};base64,{b64}")},
                        "index": images.len(),
                    }));
                }
                _ => {}
            }
        }
    }

    if !content_text.is_empty() {
        message.insert("content".into(), json!(content_text));
    }
    if !reasoning_text.is_empty() {
        message.insert("reasoning_content".into(), json!(reasoning_text));
    }
    if !tool_calls.is_empty() {
        message.insert("tool_calls".into(), json!(tool_calls));
    }
    if !images.is_empty() {
        message.insert("images".into(), json!(images));
    }

    let mut choice = Map::new();
    choice.insert("index".into(), json!(0));
    choice.insert("message".into(), Value::Object(message));
    let mut finish_reason = Value::Null;
    let mut native_finish_reason = Value::Null;
    if let Some(status) = response.get("status").and_then(Value::as_str) {
        match status {
            "completed" => {
                let reason = if tool_calls.is_empty() {
                    "stop"
                } else {
                    "tool_calls"
                };
                finish_reason = json!(reason);
                native_finish_reason = json!(reason);
            }
            "incomplete" => {
                let native = response
                    .pointer("/incomplete_details/reason")
                    .and_then(Value::as_str)
                    .unwrap_or("");
                native_finish_reason = json!(native);
                finish_reason = json!(match native {
                    "max_tokens" | "max_output_tokens" => "length",
                    "content_filter" => "content_filter",
                    _ => "stop",
                });
            }
            _ => {}
        }
    }
    choice.insert("finish_reason".into(), finish_reason);
    choice.insert("native_finish_reason".into(), native_finish_reason);

    let mut out = Map::new();
    out.insert(
        "id".into(),
        json!(response.get("id").and_then(Value::as_str).unwrap_or("")),
    );
    out.insert("object".into(), json!("chat.completion"));
    out.insert(
        "created".into(),
        json!(response
            .get("created_at")
            .and_then(Value::as_i64)
            .unwrap_or_else(|| chrono::Utc::now().timestamp())),
    );
    out.insert(
        "model".into(),
        json!(response
            .get("model")
            .and_then(Value::as_str)
            .unwrap_or("model")),
    );
    out.insert("choices".into(), json!([Value::Object(choice)]));

    if let Some(usage) = response.get("usage") {
        let usage_out = codex_usage_to_openai(usage);
        if !usage_out.is_empty() {
            out.insert("usage".into(), Value::Object(usage_out));
        }
    }

    Some(Value::Object(out))
}

fn codex_usage_to_openai(usage: &Value) -> Map<String, Value> {
    let mut usage_out = Map::new();
    let mut set = |key: &str, path: &str| {
        if let Some(v) = usage.pointer(path).and_then(Value::as_i64) {
            usage_out.insert(key.to_string(), json!(v));
        }
    };
    set("completion_tokens", "/output_tokens");
    set("total_tokens", "/total_tokens");
    set("prompt_tokens", "/input_tokens");
    let cached = usage
        .pointer("/input_tokens_details/cached_tokens")
        .and_then(Value::as_i64);
    let cache_write = usage
        .pointer("/input_tokens_details/cache_write_tokens")
        .and_then(Value::as_i64);
    if cached.is_some() || cache_write.is_some() {
        let mut details = Map::new();
        if let Some(v) = cached {
            details.insert("cached_tokens".into(), json!(v));
        }
        if let Some(v) = cache_write {
            details.insert("cached_creation_tokens".into(), json!(v));
        }
        usage_out.insert("prompt_tokens_details".into(), Value::Object(details));
    }
    if let Some(v) = usage
        .pointer("/output_tokens_details/reasoning_tokens")
        .and_then(Value::as_i64)
    {
        usage_out.insert(
            "completion_tokens_details".into(),
            json!({"reasoning_tokens": v}),
        );
    }
    usage_out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn params() -> ResponsesToChat {
        let mut p = ResponsesToChat::new("gpt-5", &Value::Null);
        p.convert(&json!({
            "type": "response.created",
            "response": {"id": "resp_1", "created_at": 1700, "model": "gpt-5-codex"}
        }));
        p
    }

    #[test]
    fn created_primes_state_and_emits_nothing() {
        let mut p = ResponsesToChat::new("gpt-5", &Value::Null);
        assert!(p
            .convert(&json!({
                "type": "response.created",
                "response": {"id": "r", "created_at": 7, "model": "m"}
            }))
            .is_none());
        assert_eq!(p.response_id, "r");
        assert_eq!(p.created_at, 7);
        assert_eq!(p.model, "m");
    }

    #[test]
    fn text_delta_becomes_a_content_chunk() {
        let mut p = params();
        let out = p
            .convert(&json!({"type": "response.output_text.delta", "delta": "Hi"}))
            .unwrap();
        assert_eq!(out["id"], "resp_1");
        assert_eq!(out["created"], 1700);
        assert_eq!(out["model"], "gpt-5-codex");
        assert_eq!(out["choices"][0]["delta"]["content"], "Hi");
        assert_eq!(out["choices"][0]["delta"]["role"], "assistant");
    }

    #[test]
    fn reasoning_delta_and_done_separator() {
        let mut p = params();
        let out = p
            .convert(&json!({"type": "response.reasoning_summary_text.delta", "delta": "why"}))
            .unwrap();
        assert_eq!(out["choices"][0]["delta"]["reasoning_content"], "why");
        let out = p
            .convert(&json!({"type": "response.reasoning_summary_text.done"}))
            .unwrap();
        assert_eq!(out["choices"][0]["delta"]["reasoning_content"], "\n\n");
    }

    #[test]
    fn tool_call_added_then_argument_deltas() {
        let mut p = params();
        let added = p
            .convert(&json!({
                "type": "response.output_item.added",
                "output_index": 0,
                "item": {"type": "function_call", "id": "i1", "call_id": "c1", "name": "get_weather"}
            }))
            .unwrap();
        let call = &added["choices"][0]["delta"]["tool_calls"][0];
        assert_eq!(call["index"], 0);
        assert_eq!(call["id"], "c1");
        assert_eq!(call["function"]["name"], "get_weather");
        assert_eq!(call["function"]["arguments"], "");

        let d = p
            .convert(&json!({
                "type": "response.function_call_arguments.delta",
                "item_id": "i1", "delta": "{\"city\":"
            }))
            .unwrap();
        assert_eq!(
            d["choices"][0]["delta"]["tool_calls"][0]["function"]["arguments"],
            "{\"city\":"
        );

        assert!(d["choices"][0]["delta"]["tool_calls"][0]
            .get("id")
            .is_none());
    }

    #[test]
    fn arguments_done_is_skipped_when_deltas_already_streamed() {
        let mut p = params();
        p.convert(&json!({
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "function_call", "id": "i1", "call_id": "c1", "name": "f"}
        }));
        p.convert(&json!({
            "type": "response.function_call_arguments.delta", "item_id": "i1", "delta": "{}"
        }));
        assert!(p
            .convert(&json!({
                "type": "response.function_call_arguments.done",
                "item_id": "i1", "arguments": "{}"
            }))
            .is_none());
    }

    #[test]
    fn arguments_done_emits_once_when_no_delta_arrived() {
        let mut p = params();
        p.convert(&json!({
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "function_call", "id": "i1", "call_id": "c1", "name": "f"}
        }));
        let out = p
            .convert(&json!({
                "type": "response.function_call_arguments.done",
                "item_id": "i1", "arguments": "{\"a\":1}"
            }))
            .unwrap();
        assert_eq!(
            out["choices"][0]["delta"]["tool_calls"][0]["function"]["arguments"],
            "{\"a\":1}"
        );
    }

    #[test]
    fn output_item_done_without_added_emits_the_whole_call() {
        let mut p = params();
        let out = p
            .convert(&json!({
                "type": "response.output_item.done",
                "output_index": 3,
                "item": {"type": "function_call", "id": "i9", "call_id": "c9",
                         "name": "solo", "arguments": "{\"x\":2}"}
            }))
            .unwrap();
        let call = &out["choices"][0]["delta"]["tool_calls"][0];
        assert_eq!(call["id"], "c9");
        assert_eq!(call["function"]["name"], "solo");
        assert_eq!(call["function"]["arguments"], "{\"x\":2}");
    }

    #[test]
    fn custom_tool_call_input_uses_the_input_field() {
        let mut p = params();
        p.convert(&json!({
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "custom_tool_call", "id": "i2", "call_id": "c2", "name": "sh"}
        }));
        let out = p
            .convert(&json!({
                "type": "response.custom_tool_call_input.done",
                "item_id": "i2", "input": "ls -la"
            }))
            .unwrap();
        assert_eq!(
            out["choices"][0]["delta"]["tool_calls"][0]["function"]["arguments"],
            "ls -la"
        );
    }

    #[test]
    fn completed_sets_tool_calls_finish_reason_after_a_call() {
        let mut p = params();
        p.convert(&json!({
            "type": "response.output_item.added", "output_index": 0,
            "item": {"type": "function_call", "id": "i", "call_id": "c", "name": "f"}
        }));
        let out = p
            .convert(&json!({"type": "response.completed", "response": {"usage": {"input_tokens": 4, "output_tokens": 2}}}))
            .unwrap();
        assert_eq!(out["choices"][0]["finish_reason"], "tool_calls");
        assert_eq!(out["usage"]["prompt_tokens"], 4);
    }

    #[test]
    fn incomplete_maps_the_native_reason() {
        let mut p = params();
        let out = p
            .convert(&json!({
                "type": "response.incomplete",
                "response": {"incomplete_details": {"reason": "max_output_tokens"}}
            }))
            .unwrap();
        assert_eq!(out["choices"][0]["finish_reason"], "length");
        assert_eq!(
            out["choices"][0]["native_finish_reason"],
            "max_output_tokens"
        );
    }

    #[test]
    fn repeated_partial_images_are_deduplicated() {
        let mut p = params();
        let first = p.convert(&json!({
            "type": "response.image_generation_call.partial_image",
            "item_id": "img1", "partial_image_b64": "AAAA", "output_format": "png"
        }));
        assert!(first.is_some());
        let repeat = p.convert(&json!({
            "type": "response.image_generation_call.partial_image",
            "item_id": "img1", "partial_image_b64": "AAAA", "output_format": "png"
        }));
        assert!(repeat.is_none());
    }

    #[test]
    fn unknown_events_emit_nothing() {
        let mut p = params();
        assert!(p
            .convert(&json!({"type": "response.in_progress"}))
            .is_none());
    }

    #[test]
    fn shortened_tool_names_are_restored() {
        let long = format!("mcp__{}__leaf", "z".repeat(80));
        let request = json!({"tools": [{"type": "function", "function": {"name": long}}]});
        let short = build_short_name_map(&[long.clone()])[&long].clone();
        let mut p = ResponsesToChat::new("m", &request);
        p.convert(&json!({"type": "response.created", "response": {"id": "r"}}));
        let out = p
            .convert(&json!({
                "type": "response.output_item.added", "output_index": 0,
                "item": {"type": "function_call", "id": "i", "call_id": "c", "name": short}
            }))
            .unwrap();
        assert_eq!(
            out["choices"][0]["delta"]["tool_calls"][0]["function"]["name"],
            long
        );
    }

    #[test]
    fn non_stream_builds_a_chat_completion() {
        let root = json!({
            "type": "response.completed",
            "response": {
                "id": "resp_9", "created_at": 99, "model": "gpt-5", "status": "completed",
                "output": [
                    {"type": "reasoning", "summary": [{"type": "summary_text", "text": "think"}]},
                    {"type": "message", "content": [{"type": "output_text", "text": "hello"}]},
                    {"type": "function_call", "call_id": "c1", "name": "f", "arguments": "{\"a\":1}"}
                ],
                "usage": {"input_tokens": 5, "output_tokens": 3, "total_tokens": 8,
                          "output_tokens_details": {"reasoning_tokens": 2}}
            }
        });
        let out = responses_to_chat_completion(&root, &Value::Null).unwrap();
        assert_eq!(out["object"], "chat.completion");
        assert_eq!(out["id"], "resp_9");
        assert_eq!(out["created"], 99);
        let msg = &out["choices"][0]["message"];
        assert_eq!(msg["content"], "hello");
        assert_eq!(msg["reasoning_content"], "think");
        assert_eq!(msg["tool_calls"][0]["function"]["arguments"], "{\"a\":1}");
        assert_eq!(out["choices"][0]["finish_reason"], "tool_calls");
        assert_eq!(
            out["usage"]["completion_tokens_details"]["reasoning_tokens"],
            2
        );
    }

    #[test]
    fn non_stream_incomplete_maps_length() {
        let root = json!({
            "type": "response.incomplete",
            "response": {"status": "incomplete",
                         "incomplete_details": {"reason": "max_tokens"},
                         "output": []}
        });
        let out = responses_to_chat_completion(&root, &Value::Null).unwrap();
        assert_eq!(out["choices"][0]["finish_reason"], "length");
        assert_eq!(out["choices"][0]["native_finish_reason"], "max_tokens");
    }

    #[test]
    fn non_terminal_events_yield_nothing() {
        assert!(responses_to_chat_completion(
            &json!({"type": "response.output_text.delta"}),
            &Value::Null
        )
        .is_none());
    }
}
