use serde_json::{json, Value};

use crate::translate::chat::types::{ChatMessage, ChatRequest, ChatTool, ChatToolFunction};

use super::normalize_object_schema_properties;
use crate::translate::json::{sampling_temperature_top_p, value_as_string};
use crate::translate::signature::thinking_text;

pub(crate) fn convert_claude_tool_result_content(content: Option<&Value>) -> (Value, bool) {
    let Some(content) = content else {
        return (json!(""), false);
    };

    if let Some(s) = content.as_str() {
        return (json!(s), false);
    }

    if let Some(arr) = content.as_array() {
        let mut parts: Vec<String> = Vec::new();
        let mut content_items: Vec<Value> = Vec::new();
        let mut has_image_part = false;

        for item in arr {
            if let Some(text) = item.as_str() {
                parts.push(text.to_string());
                content_items.push(json!({"type": "text", "text": text}));
            } else if let Some(item_obj) = item.as_object() {
                let item_type = item_obj.get("type").and_then(Value::as_str).unwrap_or("");
                match item_type {
                    "text" => {
                        let text = item_obj.get("text").and_then(Value::as_str).unwrap_or("");
                        parts.push(text.to_string());
                        content_items.push(json!({"type": "text", "text": text}));
                    }
                    "image" => match claude_image_content_part(item) {
                        Some(part) => {
                            content_items.push(part);
                            has_image_part = true;
                        }
                        None => parts.push(raw_json(item)),
                    },
                    _ => {
                        if let Some(text) = item_obj.get("text").and_then(Value::as_str) {
                            parts.push(text.to_string());
                        } else {
                            parts.push(raw_json(item));
                        }
                    }
                }
            } else {
                parts.push(raw_json(item));
            }
        }

        if has_image_part {
            return (json!(content_items), true);
        }

        let joined = parts.join("\n\n");
        if !joined.trim().is_empty() {
            return (json!(joined), false);
        }
        return (json!(raw_json(content)), false);
    }

    if let Some(obj) = content.as_object() {
        if obj.get("type").and_then(Value::as_str) == Some("image") {
            if let Some(part) = claude_image_content_part(content) {
                return (json!([part]), true);
            }
        }
        if let Some(text) = obj.get("text").and_then(Value::as_str) {
            return (json!(text), false);
        }
    }

    (json!(raw_json(content)), false)
}

fn raw_json(value: &Value) -> String {
    serde_json::to_string(value).unwrap_or_default()
}

pub(crate) fn claude_image_content_part(part: &Value) -> Option<Value> {
    let mut image_url = String::new();
    if let Some(source) = part.get("source") {
        match source.get("type").and_then(Value::as_str).unwrap_or("") {
            "base64" => {
                let media_type = source
                    .get("media_type")
                    .and_then(Value::as_str)
                    .filter(|m| !m.is_empty())
                    .unwrap_or("application/octet-stream");
                let data = source.get("data").and_then(Value::as_str).unwrap_or("");
                if !data.is_empty() {
                    image_url = format!("data:{media_type};base64,{data}");
                }
            }
            "url" => {
                image_url = source
                    .get("url")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
            }
            _ => {}
        }
    }
    if image_url.is_empty() {
        image_url = part
            .get("url")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
    }
    if image_url.is_empty() {
        return None;
    }
    Some(json!({"type": "image_url", "image_url": {"url": image_url}}))
}

pub(crate) fn messages_to_chat_request(req: &Value, model: &str, stream: bool) -> ChatRequest {
    let mut messages: Vec<ChatMessage> = Vec::new();

    let mut system_parts: Vec<Value> = Vec::new();
    if let Some(sys) = req.get("system") {
        if let Some(text) = sys.as_str() {
            if !text.is_empty() {
                system_parts.push(json!({"type": "text", "text": text}));
            }
        } else if let Some(items) = sys.as_array() {
            for item in items {
                if let Some(part) = claude_content_part(item) {
                    system_parts.push(part);
                }
            }
        }
    }
    if !system_parts.is_empty() {
        messages.push(ChatMessage {
            role: "system".to_string(),
            content: json!(system_parts),
            tool_calls: Vec::new(),
            tool_call_id: String::new(),
            name: String::new(),
            reasoning_content: String::new(),
        });
    }

    if let Some(raw_messages) = req.get("messages").and_then(Value::as_array) {
        for message in raw_messages {
            let role = message
                .get("role")
                .and_then(Value::as_str)
                .unwrap_or("user");
            let content = message.get("content");

            if role == "system" {
                if let Some(content_val) = content {
                    let mut reminder_text = String::new();
                    if let Some(text) = content_val.as_str() {
                        if !text.is_empty() {
                            reminder_text = text.to_string();
                        }
                    } else if let Some(arr) = content_val.as_array() {
                        let texts: Vec<&str> = arr
                            .iter()
                            .filter_map(|p| {
                                if p.get("type").and_then(Value::as_str) == Some("text") {
                                    p.get("text").and_then(Value::as_str)
                                } else {
                                    None
                                }
                            })
                            .collect();
                        reminder_text = texts.join("\n");
                    }
                    if !reminder_text.trim().is_empty() {
                        let reminder =
                            format!("<system-reminder>\n{}\n</system-reminder>", reminder_text);
                        messages.push(ChatMessage {
                            role: "user".to_string(),
                            content: json!([{"type": "text", "text": reminder}]),
                            tool_calls: Vec::new(),
                            tool_call_id: String::new(),
                            name: String::new(),
                            reasoning_content: String::new(),
                        });
                    }
                }
                continue;
            }

            if let Some(text) = content.and_then(Value::as_str) {
                messages.push(ChatMessage {
                    role: role.to_string(),
                    content: json!(text),
                    tool_calls: Vec::new(),
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                });
                continue;
            }

            let Some(parts) = content.and_then(Value::as_array) else {
                continue;
            };

            let mut content_parts: Vec<Value> = Vec::new();
            let mut tool_calls: Vec<crate::translate::chat::types::ChatToolCall> = Vec::new();
            let mut reasoning_parts: Vec<String> = Vec::new();
            let mut tool_results: Vec<ChatMessage> = Vec::new();

            for part in parts {
                let part_type = part.get("type").and_then(Value::as_str).unwrap_or("");
                match part_type {
                    "text" | "image" => {
                        if let Some(item) = claude_content_part(part) {
                            content_parts.push(item);
                        }
                    }
                    "thinking" => {
                        if role == "assistant" {
                            let text = thinking_text(part);
                            if !text.trim().is_empty() {
                                reasoning_parts.push(text);
                            }
                        }
                    }
                    "redacted_thinking" => {}
                    "tool_use" => {
                        if role == "assistant" {
                            let call_id = part
                                .get("id")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string();
                            let name = part
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string();
                            let arguments = match part.get("input") {
                                Some(Value::String(s)) => s.clone(),
                                Some(other) => serde_json::to_string(other)
                                    .unwrap_or_else(|_| "{}".to_string()),
                                None => "{}".to_string(),
                            };
                            tool_calls.push(crate::translate::chat::types::ChatToolCall {
                                id: call_id,
                                r#type: "function".to_string(),
                                function: crate::translate::chat::types::ChatFunctionCall { name, arguments },
                            });
                        }
                    }
                    "tool_result" => {
                        let tool_use_id = part
                            .get("tool_use_id")
                            .and_then(Value::as_str)
                            .unwrap_or("")
                            .to_string();
                        let (output, _raw) =
                            convert_claude_tool_result_content(part.get("content"));
                        tool_results.push(ChatMessage {
                            role: "tool".to_string(),
                            content: output,
                            tool_calls: Vec::new(),
                            tool_call_id: tool_use_id,
                            name: String::new(),
                            reasoning_content: String::new(),
                        });
                    }
                    _ => {}
                }
            }

            messages.extend(tool_results);

            if role == "assistant" {
                if !content_parts.is_empty()
                    || !reasoning_parts.is_empty()
                    || !tool_calls.is_empty()
                {
                    let content = if content_parts.is_empty() {
                        json!("")
                    } else {
                        json!(content_parts)
                    };
                    messages.push(ChatMessage {
                        role: "assistant".to_string(),
                        content,
                        tool_calls,
                        tool_call_id: String::new(),
                        name: String::new(),
                        reasoning_content: reasoning_parts.join("\n\n"),
                    });
                }
            } else if !content_parts.is_empty() {
                messages.push(ChatMessage {
                    role: role.to_string(),
                    content: json!(content_parts),
                    tool_calls: Vec::new(),
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                });
            }
        }
    }

    let tools: Vec<ChatTool> = req
        .get("tools")
        .and_then(Value::as_array)
        .map(|tools| {
            tools
                .iter()
                .map(|tool| {
                    let mut parameters = tool.get("input_schema").cloned().unwrap_or(Value::Null);
                    if !parameters.is_null() {
                        normalize_object_schema_properties(&mut parameters);
                    }
                    ChatTool {
                        r#type: "function".to_string(),
                        function: ChatToolFunction {
                            name: tool
                                .get("name")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            description: tool
                                .get("description")
                                .and_then(Value::as_str)
                                .unwrap_or("")
                                .to_string(),
                            parameters,
                        },
                    }
                })
                .collect()
        })
        .unwrap_or_default();

    let tool_choice: Option<Value> = req.get("tool_choice").map(|tc| {
        let tc_type = if let Some(s) = tc.as_str() {
            s
        } else {
            tc.get("type").and_then(Value::as_str).unwrap_or("")
        };
        match tc_type {
            "auto" => json!("auto"),
            "any" => json!("required"),
            "tool" => {
                let name = tc.get("name").and_then(Value::as_str).unwrap_or("");
                json!({
                    "type": "function",
                    "function": {
                        "name": name
                    }
                })
            }
            _ => json!("auto"),
        }
    });

    let mut reasoning_effort = String::new();
    if let Some(thinking) = req.get("thinking").filter(|t| t.is_object()) {
        let thinking_type = thinking.get("type").and_then(Value::as_str).unwrap_or("");
        match thinking_type {
            "enabled" => {
                let budget = thinking
                    .get("budget_tokens")
                    .and_then(Value::as_i64)
                    .unwrap_or(-1);
                reasoning_effort = budget_to_effort(budget);
            }
            "adaptive" | "auto" => {
                let effort = req
                    .pointer("/output_config/effort")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim();
                if !effort.is_empty() {
                    reasoning_effort = effort.to_lowercase();
                } else {
                    reasoning_effort = "xhigh".to_string();
                }
            }
            "disabled" => reasoning_effort = budget_to_effort(0),

            _ => {}
        }
    }

    let max_tokens = req.get("max_tokens").and_then(Value::as_i64);
    let (temperature, top_p) = sampling_temperature_top_p(req);
    let stop: Vec<String> = req
        .get("stop_sequences")
        .and_then(Value::as_array)
        .map(|items| items.iter().map(value_as_string).collect())
        .unwrap_or_default();
    let user = req
        .get("user")
        .map(|u| {
            u.as_str()
                .map(str::to_string)
                .unwrap_or_else(|| raw_json(u))
        })
        .unwrap_or_default();

    ChatRequest {
        stream_options: None,

        top_k: None,
        n: None,
        modalities: Vec::new(),
        image_config: None,
        generation_config: None,

        parallel_tool_calls: None,
        response_format: None,
        model: model.to_string(),
        messages,
        tools,
        tool_choice,
        max_tokens,
        max_completion_tokens: None,
        temperature,
        top_p,
        stop,
        user,
        reasoning_effort,
        stream,
    }
}

pub(crate) fn claude_content_part(part: &Value) -> Option<Value> {
    match part.get("type").and_then(Value::as_str).unwrap_or("") {
        "text" => {
            let text = part.get("text").and_then(Value::as_str).unwrap_or("");
            if text.trim().is_empty() {
                return None;
            }
            Some(json!({"type": "text", "text": text}))
        }
        "image" => claude_image_content_part(part),
        _ => None,
    }
}

pub(crate) fn budget_to_effort(budget: i64) -> String {
    match budget {
        b if b < -1 => String::new(),
        -1 => "auto".to_string(),
        0 => "none".to_string(),
        1..=512 => "minimal".to_string(),
        513..=1024 => "low".to_string(),
        1025..=8192 => "medium".to_string(),
        8193..=24576 => "high".to_string(),
        _ => "xhigh".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use base64::engine::general_purpose::URL_SAFE;
    use base64::Engine;
    use serde_json::json;

    fn valid_gpt_reasoning_signature() -> String {
        let mut raw = vec![0u8; 1 + 8 + 16 + 16 + 32];
        raw[0] = 0x80;
        raw[8] = 1;
        for (index, byte) in raw.iter_mut().enumerate().skip(9) {
            *byte = index as u8;
        }
        URL_SAFE.encode(raw)
    }

    #[test]
    fn assistant_thinking_replays_regardless_of_signature() {
        for signature in [
            None,
            Some(""),
            Some("claude#EjQ="),
            Some("not-a-provider-signature"),
        ] {
            let mut thinking = json!({"type": "thinking", "thinking": "provider state"});
            if let Some(sig) = signature {
                thinking["signature"] = json!(sig);
            }
            let req = json!({
                "model": "x",
                "messages": [{"role": "assistant", "content": [
                    {"type": "text", "text": "hi"},
                    thinking,
                ]}],
            });
            let oai = messages_to_chat_request(&req, "x", false);
            assert_eq!(
                oai.messages[0].reasoning_content, "provider state",
                "signature {signature:?}"
            );
        }
    }

    #[test]
    fn unsigned_thinking_only_assistant_message_still_replays() {
        let req = json!({
            "model": "x",
            "messages": [{"role": "assistant", "content": [
                {"type": "thinking", "thinking": "Let me calculate: 2+2=4"},
            ]}],
        });
        let oai = messages_to_chat_request(&req, "x", false);
        assert_eq!(oai.messages[0].reasoning_content, "Let me calculate: 2+2=4");
    }

    #[test]
    fn whitespace_only_thinking_is_skipped() {
        let req = json!({
            "model": "x",
            "messages": [{"role": "assistant", "content": [
                {"type": "text", "text": "hi"},
                {"type": "thinking", "thinking": "   "},
            ]}],
        });
        let oai = messages_to_chat_request(&req, "x", false);
        assert_eq!(oai.messages[0].reasoning_content, "");
    }

    #[test]
    fn maps_sampling_and_stop_and_user() {
        let req = json!({
            "model": "x",
            "top_p": 0.25,
            "stop_sequences": ["STOP", "HALT"],
            "user": "u-1",
            "messages": [{"role": "user", "content": "hi"}],
        });
        let oai = messages_to_chat_request(&req, "x", false);

        assert_eq!(oai.temperature, None);
        assert_eq!(oai.top_p, Some(0.25));
        assert_eq!(oai.stop, vec!["STOP".to_string(), "HALT".to_string()]);
        assert_eq!(oai.user, "u-1");

        let with_temp = json!({
            "model": "x",
            "temperature": 0.7,
            "top_p": 0.25,
            "messages": [{"role": "user", "content": "hi"}],
        });
        let oai = messages_to_chat_request(&with_temp, "x", false);
        assert_eq!(oai.temperature, Some(0.7));

        assert_eq!(oai.top_p, None);
    }

    #[test]
    fn system_image_blocks_survive() {
        let req = json!({
            "model": "x",
            "system": [
                {"type": "text", "text": "rules"},
                {"type": "image", "source": {"type": "url", "url": "https://e/x.png"}},
            ],
            "messages": [{"role": "user", "content": "hi"}],
        });
        let oai = messages_to_chat_request(&req, "x", false);
        assert_eq!(oai.messages[0].role, "system");
        assert_eq!(oai.messages[0].content[1]["type"], "image_url");
    }

    #[test]
    fn maps_claude_to_oai_request() {
        let req = json!({
            "model": "deepseek-v4-flash@BAI",
            "max_tokens": 1024,
            "stream": true,
            "system": "You are helpful.",
            "messages": [
                {"role": "user", "content": [{"type": "text", "text": "hi"}]},
                {"role": "assistant", "content": [
                    {"type": "thinking", "thinking": "let me think", "signature": valid_gpt_reasoning_signature()},
                    {"type": "text", "text": "hello"},
                ]},
            ],
            "tools": [{"name": "f", "description": "do f", "input_schema": {"type": "object", "properties": {}}}],
        });
        let oai = messages_to_chat_request(&req, "deepseek-v4-flash", true);
        assert_eq!(oai.model, "deepseek-v4-flash");
        assert_eq!(oai.messages[0].role, "system");
        assert_eq!(oai.messages[1].role, "user");
        assert_eq!(oai.messages[2].role, "assistant");
        assert_eq!(
            oai.messages[2].content,
            json!([{"type": "text", "text": "hello"}])
        );
        assert_eq!(oai.messages[2].reasoning_content, "let me think");
        assert_eq!(oai.tools[0].function.name, "f");
        assert_eq!(oai.max_tokens, Some(1024));
        assert!(oai.stream);
    }

    #[test]
    fn converts_tool_result() {
        let req = json!({
            "model": "x",
            "messages": [
                {"role": "assistant", "content": [
                    {"type": "tool_use", "id": "tu_1", "name": "f", "input": {"a": 1}},
                ]},
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "tu_1", "content": "42"},
                ]},
            ],
        });
        let oai = messages_to_chat_request(&req, "x", false);
        assert_eq!(oai.messages[0].role, "assistant");
        assert_eq!(oai.messages[0].tool_calls[0].function.name, "f");
        assert_eq!(oai.messages[1].role, "tool");
        assert_eq!(oai.messages[1].tool_call_id, "tu_1");
        assert_eq!(oai.messages[1].content, json!("42"));
    }
}
