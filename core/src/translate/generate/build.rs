use chrono::Utc;
use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use crate::translate::ids::uuid_v4;
use crate::translate::json::{arguments_to_object, content_text};
use crate::translate::chat::types::{ChatMessage, ChatRequest};
use crate::translate::generate::types::{GenerateConfig, GenerateParams, GenerateRequest, GenerateTool};

const MAX_GENERATE_TOKENS: i64 = 64000;
const DEFAULT_TEMPERATURE: f64 = 0.3;

pub fn build_generate_request(
    req: ChatRequest,
    work_dir: &str,
    now: chrono::DateTime<Utc>,
) -> Result<GenerateRequest, String> {
    let max_tokens = resolve_max_tokens(&req);
    let temperature = resolve_temperature(&req);
    let (messages, system) = translate_messages(req.messages)?;
    Ok(GenerateRequest {
        config: GenerateConfig {
            working_dir: work_dir.to_string(),
            date: now.format("%Y-%m-%d").to_string(),
            environment: format!(
                "{}-{}, Rust {}",
                std::env::consts::OS,
                std::env::consts::ARCH,
                env!("CARGO_PKG_VERSION")
            ),

            ..GenerateConfig::default()
        },
        memory: Value::Null,
        taste: Value::Null,
        skills: Value::Null,
        params: GenerateParams {
            model: req.model,
            messages,
            tools: translate_tools(req.tools),
            system,
            reasoning_effort: req.reasoning_effort,
            max_tokens,
            temperature,
            stream: true,
        },
        thread_id: uuid_v4(),
    })
}

fn resolve_max_tokens(req: &ChatRequest) -> i64 {
    let limit = req.max_tokens.or(req.max_completion_tokens).unwrap_or(0);
    if limit <= 0 || limit > MAX_GENERATE_TOKENS {
        MAX_GENERATE_TOKENS
    } else {
        limit
    }
}

fn resolve_temperature(req: &ChatRequest) -> f64 {
    req.temperature.unwrap_or(DEFAULT_TEMPERATURE)
}

fn translate_messages(messages: Vec<ChatMessage>) -> Result<(Vec<Value>, String), String> {
    let (paired, tool_names) = tool_call_pairs(&messages);
    let mut out = Vec::new();
    let mut system_parts = Vec::new();

    for message in messages {
        match message.role.as_str() {
            "system" | "developer" => {
                let text = content_text(&message.content);
                if !text.is_empty() {
                    system_parts.push(text);
                }
            }
            "user" => {
                let content = translate_user_content(message.content)?;
                out.push(json!({"role": "user", "content": content}));
            }
            "assistant" => {
                let mut parts = Vec::new();
                let text = content_text(&message.content);
                if !text.is_empty() {
                    parts.push(json!({"type": "text", "text": text}));
                }
                for call in &message.tool_calls {
                    if !paired.contains(&call.id) {
                        continue;
                    }
                    parts.push(json!({
                        "type": "tool-call",
                        "toolCallId": call.id,
                        "toolName": call.function.name,
                        "input": arguments_to_object(&call.function.arguments),
                    }));
                }
                if !parts.is_empty() {
                    out.push(json!({"role": "assistant", "content": parts}));
                }
            }
            "tool" | "function" => {
                if message.tool_call_id.is_empty() || !paired.contains(&message.tool_call_id) {
                    continue;
                }
                let name = tool_names
                    .get(&message.tool_call_id)
                    .cloned()
                    .unwrap_or(message.name);
                let part = json!({
                    "type": "tool-result",
                    "toolCallId": message.tool_call_id,
                    "toolName": name,
                    "output": {"type": "text", "value": content_text(&message.content)},
                });
                out.push(json!({"role": "tool", "content": [part]}));
            }
            _ => {}
        }
    }

    Ok((out, system_parts.join("\n\n")))
}

fn tool_call_pairs(messages: &[ChatMessage]) -> (HashSet<String>, HashMap<String, String>) {
    let mut calls = HashSet::new();
    let mut names = HashMap::new();
    let mut results = HashSet::new();
    for message in messages {
        for call in &message.tool_calls {
            if call.id.is_empty() {
                continue;
            }
            calls.insert(call.id.clone());
            if !call.function.name.is_empty() {
                names.insert(call.id.clone(), call.function.name.clone());
            }
        }
        if matches!(message.role.as_str(), "tool" | "function") && !message.tool_call_id.is_empty()
        {
            results.insert(message.tool_call_id.clone());
        }
    }
    calls.retain(|id| results.contains(id));
    (calls, names)
}

fn translate_user_content(raw: Value) -> Result<Value, String> {
    if raw.is_null() {
        return Ok(Value::String(String::new()));
    }
    if raw.is_string() {
        return Ok(raw);
    }

    let Some(parts) = raw.as_array() else {
        return Err("unsupported user content".to_string());
    };
    let mut out = Vec::new();
    for part in parts {
        let Some(object) = part.as_object() else {
            continue;
        };
        match object
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or_default()
        {
            "text" | "input_text" => {
                let text = object
                    .get("text")
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                out.push(json!({"type": "text", "text": text}));
            }
            "image_url" | "input_image" => {
                let url = object
                    .get("image_url")
                    .and_then(Value::as_object)
                    .and_then(|image| image.get("url"))
                    .and_then(Value::as_str)
                    .unwrap_or_default();
                if !url.is_empty() {
                    out.push(json!({"type": "image", "image": url}));
                }
            }
            _ => {}
        }
    }
    Ok(Value::Array(out))
}

fn translate_tools(tools: Vec<crate::translate::chat::types::ChatTool>) -> Vec<GenerateTool> {
    tools
        .into_iter()
        .map(|tool| GenerateTool {
            r#type: "function".to_string(),
            name: tool.function.name,
            description: tool.function.description,
            input_schema: if tool.function.parameters.is_null() {
                json!({"type": "object", "properties": {}})
            } else {
                tool.function.parameters
            },
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::translate::chat::types::{ChatFunctionCall, ChatToolCall};

    #[test]
    fn pairs_tool_calls_and_hoists_system_messages() {
        let req = ChatRequest {
            stream_options: None,
            top_k: None,
            n: None,
            modalities: Vec::new(),
            image_config: None,
            generation_config: None,
            parallel_tool_calls: None,
            response_format: None,
            model: "vendor/model-one".to_string(),
            messages: vec![
                ChatMessage {
                    role: "system".to_string(),
                    content: json!("be brief"),
                    tool_calls: vec![],
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
                ChatMessage {
                    role: "assistant".to_string(),
                    content: json!(""),
                    tool_calls: vec![ChatToolCall {
                        id: "call_1".to_string(),
                        r#type: "function".to_string(),
                        function: ChatFunctionCall {
                            name: "lookup".to_string(),
                            arguments: r#"{"q":"x"}"#.to_string(),
                        },
                    }],
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
                ChatMessage {
                    role: "tool".to_string(),
                    content: json!("result"),
                    tool_calls: vec![],
                    tool_call_id: "call_1".to_string(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
            ],
            tools: vec![],
            tool_choice: None,
            max_tokens: None,
            max_completion_tokens: None,
            temperature: None,
            top_p: None,
            stop: Vec::new(),
            user: String::new(),
            reasoning_effort: String::new(),
            stream: true,
        };
        let request = build_generate_request(req, "/tmp/work", Utc::now()).unwrap();
        assert_eq!(request.params.system, "be brief");
        assert_eq!(request.params.messages.len(), 2);
        assert_eq!(
            request.params.messages[0]["content"][0]["toolName"],
            "lookup"
        );
    }

    #[test]
    fn builds_tool_result_and_user_content_parts() {
        let req = ChatRequest {
            stream_options: None,
            top_k: None,
            n: None,
            modalities: Vec::new(),
            image_config: None,
            generation_config: None,
            parallel_tool_calls: None,
            response_format: None,
            model: "vendor/model-one".to_string(),
            messages: vec![
                ChatMessage {
                    role: "assistant".to_string(),
                    content: json!("thinking"),
                    tool_calls: vec![ChatToolCall {
                        id: "call_1".to_string(),
                        r#type: "function".to_string(),
                        function: ChatFunctionCall {
                            name: "lookup".to_string(),
                            arguments: r#"{"q":"x"}"#.to_string(),
                        },
                    }],
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
                ChatMessage {
                    role: "tool".to_string(),
                    content: json!("42"),
                    tool_calls: vec![],
                    tool_call_id: "call_1".to_string(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
                ChatMessage {
                    role: "user".to_string(),
                    content: json!([
                        {"type": "text", "text": "look at this"},
                        {"type": "image_url", "image_url": {"url": "https://e.x/i.png"}},
                    ]),
                    tool_calls: vec![],
                    tool_call_id: String::new(),
                    name: String::new(),
                    reasoning_content: String::new(),
                },
            ],
            tools: vec![],
            tool_choice: None,
            max_tokens: None,
            max_completion_tokens: None,
            temperature: None,
            top_p: None,
            stop: Vec::new(),
            user: String::new(),
            reasoning_effort: String::new(),
            stream: false,
        };
        let request = build_generate_request(req, "/tmp/work", Utc::now()).unwrap();
        let messages = &request.params.messages;

        assert_eq!(messages[0]["content"][0]["type"], "text");
        assert_eq!(messages[0]["content"][0]["text"], "thinking");
        assert_eq!(messages[0]["content"][1]["toolCallId"], "call_1");

        let result = &messages[1]["content"][0];
        assert_eq!(result["type"], "tool-result");
        assert_eq!(result["toolCallId"], "call_1");
        assert_eq!(result["toolName"], "lookup");
        assert_eq!(result["output"], json!({"type": "text", "value": "42"}));

        assert_eq!(
            messages[2]["content"][0],
            json!({"type": "text", "text": "look at this"})
        );
        assert_eq!(
            messages[2]["content"][1],
            json!({"type": "image", "image": "https://e.x/i.png"})
        );
    }
}
