use serde_json::{json, Value};

use crate::translate::json::{sampling_temperature_top_p, value_as_string};
use crate::translate::chat::types::{ChatMessage, ChatRequest};

pub(crate) fn responses_to_chat_request(
    req: &Value,
    model: &str,
    stream: bool,
) -> Result<ChatRequest, String> {
    let mut messages: Vec<ChatMessage> = Vec::new();

    if let Some(instructions) = req.get("instructions") {
        let content = value_as_string(instructions);
        if !content.is_empty() {
            messages.push(ChatMessage {
                role: "system".to_string(),
                content: json!(content),
                tool_calls: Vec::new(),
                tool_call_id: String::new(),
                name: String::new(),
                reasoning_content: String::new(),
            });
        }
    }

    match req.get("input") {
        Some(Value::String(text)) if !text.is_empty() => {
            messages.push(user_message(json!(text)));
        }
        Some(Value::Array(items)) => {
            let mut output_call_ids: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            for item in items {
                let item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
                if item_type != "function_call_output" && item_type != "custom_tool_call_output" {
                    continue;
                }
                if let Some(call_id) = item.get("call_id").and_then(Value::as_str) {
                    let call_id = call_id.trim();
                    if !call_id.is_empty() {
                        output_call_ids.insert(call_id.to_string());
                    }
                }
            }

            let mut pending_tool_calls: Vec<crate::translate::chat::types::ChatToolCall> = Vec::new();
            let mut pending_tool_call_ids: Vec<String> = Vec::new();
            let mut pending_reasoning = String::new();
            let mut awaiting_tool_outputs: std::collections::HashSet<String> =
                std::collections::HashSet::new();
            let mut deferred: Vec<ChatMessage> = Vec::new();
            let mut mergeable_assistant_index: Option<usize> = None;

            for item in items {
                let mut item_type = item.get("type").and_then(Value::as_str).unwrap_or("");
                if item_type.is_empty() && item.get("role").is_some() {
                    item_type = "message";
                }

                if item_type != "function_call" && item_type != "custom_tool_call" {
                    flush_pending_tool_calls(
                        &mut messages,
                        &mut pending_tool_calls,
                        &mut pending_tool_call_ids,
                        &mut pending_reasoning,
                        &mut awaiting_tool_outputs,
                        &mut mergeable_assistant_index,
                    );
                }

                match item_type {
                    "message" | "" => {
                        let mut role = item
                            .get("role")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();

                        if role == "developer" {
                            role = "user".to_string();
                        }
                        mergeable_assistant_index = None;
                        if role != "assistant" {
                            append_pending_reasoning_message(
                                &mut messages,
                                &mut deferred,
                                &mut pending_reasoning,
                                &awaiting_tool_outputs,
                                &output_call_ids,
                            );
                        }

                        let content = match item.get("content") {
                            Some(Value::Array(parts)) => {
                                let converted: Vec<Value> =
                                    parts.iter().filter_map(responses_content_part).collect();
                                Value::Array(converted)
                            }
                            Some(Value::String(text)) => json!(text),
                            _ => json!([]),
                        };

                        let mut reasoning_content = String::new();
                        if role == "assistant" {
                            reasoning_content = combine_reasoning(
                                &std::mem::take(&mut pending_reasoning),
                                item.get("reasoning_content")
                                    .and_then(Value::as_str)
                                    .unwrap_or(""),
                            );
                        }

                        let message = ChatMessage {
                            role: role.clone(),
                            content,
                            tool_calls: Vec::new(),
                            tool_call_id: String::new(),
                            name: String::new(),
                            reasoning_content,
                        };
                        let index = append_regular_message(
                            &mut messages,
                            &mut deferred,
                            message,
                            &awaiting_tool_outputs,
                            &output_call_ids,
                        );
                        if role == "assistant" {
                            mergeable_assistant_index = index;
                        }
                    }
                    "reasoning" => {
                        let incoming = collect_reasoning_content(item);
                        pending_reasoning = combine_reasoning(&pending_reasoning, &incoming);
                    }
                    "function_call" | "custom_tool_call" => {
                        pending_reasoning = combine_reasoning(
                            &pending_reasoning,
                            item.get("reasoning_content")
                                .and_then(Value::as_str)
                                .unwrap_or(""),
                        );
                        let call_id = item
                            .get("call_id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        let mut name = item
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        if let Some(namespace) = item.get("namespace").and_then(Value::as_str) {
                            let namespace = namespace.trim();
                            if !namespace.is_empty() {
                                name = format!("{namespace}__{name}");
                            }
                        }

                        let arguments = if item_type == "custom_tool_call" {
                            let input = item.get("input").and_then(Value::as_str).unwrap_or("");
                            serde_json::to_string(&json!({"input": input})).unwrap_or_default()
                        } else {
                            match item.get("arguments") {
                                Some(Value::String(s)) => s.clone(),
                                Some(other) => serde_json::to_string(other).unwrap_or_default(),
                                None => String::new(),
                            }
                        };
                        pending_tool_calls.push(crate::translate::chat::types::ChatToolCall {
                            id: call_id.clone(),
                            r#type: "function".to_string(),
                            function: crate::translate::chat::types::ChatFunctionCall { name, arguments },
                        });
                        if !call_id.trim().is_empty() {
                            pending_tool_call_ids.push(call_id);
                        }
                    }
                    "function_call_output" | "custom_tool_call_output" => {
                        mergeable_assistant_index = None;
                        let call_id = item
                            .get("call_id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .trim()
                            .to_string();
                        let content = match item.get("output") {
                            Some(output) => tool_output_content(output, item_type),
                            None => json!(""),
                        };
                        messages.push(ChatMessage {
                            role: "tool".to_string(),
                            content,
                            tool_calls: Vec::new(),
                            tool_call_id: call_id.clone(),
                            name: String::new(),
                            reasoning_content: String::new(),
                        });
                        if !call_id.is_empty() {
                            awaiting_tool_outputs.remove(&call_id);
                        }
                        if awaiting_tool_outputs.is_empty() && !deferred.is_empty() {
                            messages.append(&mut deferred);
                        }
                    }
                    _ => {
                        mergeable_assistant_index = None;
                    }
                }
            }

            flush_pending_tool_calls(
                &mut messages,
                &mut pending_tool_calls,
                &mut pending_tool_call_ids,
                &mut pending_reasoning,
                &mut awaiting_tool_outputs,
                &mut mergeable_assistant_index,
            );
            append_pending_reasoning_message(
                &mut messages,
                &mut deferred,
                &mut pending_reasoning,
                &awaiting_tool_outputs,
                &output_call_ids,
            );
            messages.append(&mut deferred);
        }
        _ => {}
    }

    let reasoning_effort = req
        .get("reasoning")
        .and_then(|r| r.get("effort"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let max_tokens = req.get("max_output_tokens").and_then(Value::as_i64);
    let (temperature, top_p) = sampling_temperature_top_p(req);
    let user = req
        .get("user")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();

    let tools: Vec<crate::translate::chat::types::ChatTool> =
        crate::translate::responses::tools::responses_request_chat_tools(req)
            .into_iter()
            .map(|tool| crate::translate::chat::types::ChatTool {
                r#type: "function".to_string(),
                function: crate::translate::chat::types::ChatToolFunction {
                    name: tool
                        .pointer("/function/name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    description: tool
                        .pointer("/function/description")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    parameters: tool
                        .pointer("/function/parameters")
                        .cloned()
                        .unwrap_or(json!({})),
                },
            })
            .collect();

    let has_tools = !tools.is_empty();
    let tool_choice = if has_tools {
        req.get("tool_choice").cloned()
    } else {
        None
    };
    let parallel_tool_calls = if has_tools {
        req.get("parallel_tool_calls").and_then(Value::as_bool)
    } else {
        None
    };
    let response_format = req
        .pointer("/text/format")
        .and_then(responses_text_format_to_chat_response_format);

    Ok(ChatRequest {
        stream_options: None,

        top_k: None,
        n: None,
        modalities: Vec::new(),
        image_config: None,
        generation_config: None,
        model: model.to_string(),
        messages,
        tools,
        tool_choice,
        parallel_tool_calls,
        response_format,
        max_tokens,
        max_completion_tokens: None,
        temperature,
        top_p,
        stop: Vec::new(),
        user,
        reasoning_effort,

        stream,
    })
}

pub(crate) fn user_message(content: Value) -> ChatMessage {
    ChatMessage {
        role: "user".to_string(),
        content,
        tool_calls: Vec::new(),
        tool_call_id: String::new(),
        name: String::new(),
        reasoning_content: String::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn converts_responses_to_oai_request() {
        let req = json!({
            "instructions": "be brief",
            "input": [
                {"role": "user", "content": "hi"},
                {"type": "function_call", "call_id": "call_1", "name": "f", "arguments": "{\"a\":1}", "status": "completed"},
                {"type": "function_call_output", "call_id": "call_1", "output": "42"},
            ],
            "tools": [{"type": "function", "function": {
                "name": "f", "description": "do f",
                "parameters": {"type": "object", "properties": {}}
            }}],
            "max_output_tokens": 2048,
            "model": "deepseek/deepseek-v4-flash"
        });
        let oai = responses_to_chat_request(&req, "deepseek/deepseek-v4-flash", true).unwrap();
        assert_eq!(oai.messages[0].role, "system");
        assert_eq!(oai.messages[0].content, json!("be brief"));
        assert_eq!(oai.messages[1].role, "user");
        assert_eq!(oai.messages[2].role, "assistant");
        assert_eq!(oai.messages[2].tool_calls[0].function.name, "f");
        assert_eq!(oai.messages[3].role, "tool");
        assert_eq!(oai.messages[3].tool_call_id, "call_1");
        assert_eq!(oai.tools[0].function.name, "f");
        assert_eq!(oai.max_tokens, Some(2048));
    }
}

pub(crate) fn responses_text_format_to_chat_response_format(text_format: &Value) -> Option<Value> {
    match text_format
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
    {
        format_type @ ("text" | "json_object") => Some(json!({"type": format_type})),
        "json_schema" => {
            let mut json_schema = serde_json::Map::new();
            for field in ["name", "description", "strict"] {
                if let Some(value) = text_format.get(field) {
                    json_schema.insert(field.to_string(), value.clone());
                }
            }
            if let Some(schema) = text_format.get("schema") {
                json_schema.insert("schema".to_string(), schema.clone());
            }
            Some(json!({"type": "json_schema", "json_schema": Value::Object(json_schema)}))
        }
        _ => None,
    }
}

#[cfg(test)]
mod request_field_tests {
    use super::*;

    #[test]
    fn tool_choice_and_parallel_tool_calls_travel_with_tools() {
        let req = json!({
            "input": "hi",
            "tools": [{"type": "function", "name": "f", "parameters": {"type": "object"}}],
            "tool_choice": "required",
            "parallel_tool_calls": false,
        });
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.tool_choice, Some(json!("required")));
        assert_eq!(oai.parallel_tool_calls, Some(false));
    }

    #[test]
    fn tool_choice_is_dropped_without_tools() {
        let req = json!({"input": "hi", "tool_choice": "required", "parallel_tool_calls": true});
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.tool_choice, None);
        assert_eq!(oai.parallel_tool_calls, None);
    }

    #[test]
    fn flat_responses_tools_are_converted() {
        let req = json!({
            "input": "hi",
            "tools": [{"type": "function", "name": "read_file",
                       "description": "Read a file",
                       "parameters": {"type": "object"}}],
        });
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.tools.len(), 1);
        assert_eq!(oai.tools[0].function.name, "read_file");
        assert_eq!(oai.tools[0].function.description, "Read a file");
    }

    #[test]
    fn nested_chat_style_tools_still_work() {
        let req = json!({
            "input": "hi",
            "tools": [{"type": "function",
                       "function": {"name": "nested", "parameters": {"type": "object"}}}],
        });
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.tools[0].function.name, "nested");
    }

    #[test]
    fn text_format_becomes_response_format() {
        let req = json!({"input": "hi", "text": {"format": {"type": "json_object"}}});
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.response_format, Some(json!({"type": "json_object"})));
    }

    #[test]
    fn json_schema_format_carries_its_schema() {
        let req = json!({"input": "hi", "text": {"format": {
            "type": "json_schema", "name": "Out", "strict": true,
            "schema": {"type": "object", "properties": {"a": {"type": "string"}}}
        }}});
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        let rf = oai.response_format.unwrap();
        assert_eq!(rf["type"], "json_schema");
        assert_eq!(rf["json_schema"]["name"], "Out");
        assert_eq!(rf["json_schema"]["strict"], true);
        assert_eq!(rf["json_schema"]["schema"]["type"], "object");
    }

    #[test]
    fn unknown_format_types_are_ignored() {
        let req = json!({"input": "hi", "text": {"format": {"type": "wat"}}});
        let oai = responses_to_chat_request(&req, "m", true).unwrap();
        assert_eq!(oai.response_format, None);
    }
}

fn responses_content_part(part: &Value) -> Option<Value> {
    let mut part_type = part.get("type").and_then(Value::as_str).unwrap_or("");
    if part_type.is_empty() {
        part_type = "input_text";
    }
    match part_type {
        "input_text" | "output_text" => Some(json!({
            "type": "text",
            "text": part.get("text").and_then(Value::as_str).unwrap_or(""),
        })),
        "input_image" => {
            let mut image_url = serde_json::Map::new();
            image_url.insert(
                "url".into(),
                json!(part.get("image_url").and_then(Value::as_str).unwrap_or("")),
            );
            if let Some(detail) = normalize_image_detail(part.get("detail")) {
                image_url.insert("detail".into(), json!(detail));
            }
            Some(json!({"type": "image_url", "image_url": Value::Object(image_url)}))
        }

        _ => None,
    }
}

fn normalize_image_detail(detail: Option<&Value>) -> Option<String> {
    let detail = detail?.as_str()?.trim().to_ascii_lowercase();
    match detail.as_str() {
        "low" | "high" | "auto" => Some(detail),
        _ => None,
    }
}

fn collect_reasoning_content(item: &Value) -> String {
    let mut text = String::new();
    if let Some(summary) = item.get("summary").and_then(Value::as_array) {
        for entry in summary {
            if entry.get("type").and_then(Value::as_str) != Some("summary_text") {
                continue;
            }
            text.push_str(entry.get("text").and_then(Value::as_str).unwrap_or(""));
        }
    }
    if text.is_empty() {
        return "[reasoning unavailable]".to_string();
    }
    text
}

fn combine_reasoning(existing: &str, incoming: &str) -> String {
    const UNAVAILABLE: &str = "[reasoning unavailable]";
    let existing_trimmed = existing.trim();
    let incoming_trimmed = incoming.trim();
    if existing_trimmed.is_empty() {
        return incoming.to_string();
    }
    if incoming_trimmed.is_empty() {
        return existing.to_string();
    }
    if existing_trimmed == UNAVAILABLE {
        return incoming.to_string();
    }
    if incoming_trimmed == UNAVAILABLE || existing_trimmed == incoming_trimmed {
        return existing.to_string();
    }
    format!("{existing}\n\n{incoming}")
}

fn tool_output_content(output: &Value, item_type: &str) -> Value {
    let structured = match output {
        Value::String(text) => serde_json::from_str::<Value>(text).ok(),
        other => Some(other.clone()),
    };
    let has_image = structured
        .as_ref()
        .and_then(Value::as_array)
        .map(|items| {
            items.iter().any(|item| {
                matches!(
                    item.get("type").and_then(Value::as_str),
                    Some("image_url") | Some("input_image")
                )
            })
        })
        .unwrap_or(false);

    if has_image {
        let items = structured.as_ref().and_then(Value::as_array).unwrap();
        let parts: Vec<Value> = items.iter().map(tool_output_part).collect();
        return Value::Array(parts);
    }

    if item_type == "custom_tool_call_output" {
        return json!(responses_tool_output_text(output));
    }
    json!(value_as_string(output))
}

fn tool_output_part(item: &Value) -> Value {
    match item.get("type").and_then(Value::as_str).unwrap_or("") {
        "text" | "input_text" | "output_text" => json!({
            "type": "text",
            "text": item.get("text").and_then(Value::as_str).unwrap_or(""),
        }),
        "image_url" | "input_image" => {
            let url = item
                .get("image_url")
                .and_then(|v| {
                    v.as_str()
                        .map(str::to_string)
                        .or_else(|| v.get("url").and_then(Value::as_str).map(str::to_string))
                })
                .unwrap_or_default();
            if url.is_empty() {
                return json!({"type": "text", "text": value_as_string(item)});
            }
            let mut image_url = serde_json::Map::new();
            image_url.insert("url".into(), json!(url));
            if let Some(detail) = normalize_image_detail(item.get("detail")) {
                image_url.insert("detail".into(), json!(detail));
            }
            json!({"type": "image_url", "image_url": Value::Object(image_url)})
        }
        _ => json!({"type": "text", "text": value_as_string(item)}),
    }
}

fn responses_tool_output_text(output: &Value) -> String {
    match output {
        Value::String(text) => text.clone(),
        Value::Array(items) => items
            .iter()
            .filter_map(|item| item.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join(""),
        other => value_as_string(other),
    }
}

fn append_regular_message(
    messages: &mut Vec<ChatMessage>,
    deferred: &mut Vec<ChatMessage>,
    message: ChatMessage,
    awaiting: &std::collections::HashSet<String>,
    output_call_ids: &std::collections::HashSet<String>,
) -> Option<usize> {
    if awaiting.iter().any(|id| output_call_ids.contains(id)) {
        deferred.push(message);
        return None;
    }
    messages.push(message);
    Some(messages.len() - 1)
}

fn append_pending_reasoning_message(
    messages: &mut Vec<ChatMessage>,
    deferred: &mut Vec<ChatMessage>,
    pending_reasoning: &mut String,
    awaiting: &std::collections::HashSet<String>,
    output_call_ids: &std::collections::HashSet<String>,
) {
    let reasoning = std::mem::take(pending_reasoning);
    if reasoning.is_empty() {
        return;
    }
    append_regular_message(
        messages,
        deferred,
        ChatMessage {
            role: "assistant".to_string(),
            content: json!(""),
            tool_calls: Vec::new(),
            tool_call_id: String::new(),
            name: String::new(),
            reasoning_content: reasoning,
        },
        awaiting,
        output_call_ids,
    );
}

fn flush_pending_tool_calls(
    messages: &mut Vec<ChatMessage>,
    pending_tool_calls: &mut Vec<crate::translate::chat::types::ChatToolCall>,
    pending_tool_call_ids: &mut Vec<String>,
    pending_reasoning: &mut String,
    awaiting: &mut std::collections::HashSet<String>,
    mergeable_assistant_index: &mut Option<usize>,
) {
    if pending_tool_calls.is_empty() {
        return;
    }
    let reasoning = std::mem::take(pending_reasoning);
    let calls = std::mem::take(pending_tool_calls);

    let mut merged = false;
    if let Some(index) = *mergeable_assistant_index {
        if index + 1 == messages.len() {
            let target = &mut messages[index];
            if target.role == "assistant" && target.tool_calls.is_empty() {
                target.tool_calls = calls.clone();
                let combined = combine_reasoning(&target.reasoning_content, &reasoning);
                if !combined.is_empty() {
                    target.reasoning_content = combined;
                }
                merged = true;
            }
        }
    }
    if !merged {
        messages.push(ChatMessage {
            role: "assistant".to_string(),
            content: Value::Null,
            tool_calls: calls,
            tool_call_id: String::new(),
            name: String::new(),
            reasoning_content: reasoning,
        });
    }
    for id in pending_tool_call_ids.drain(..) {
        if !id.trim().is_empty() {
            awaiting.insert(id);
        }
    }
    *mergeable_assistant_index = None;
}
