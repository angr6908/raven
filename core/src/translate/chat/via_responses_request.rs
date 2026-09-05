use serde_json::{json, Value};

use crate::translate::chat::types::ChatRequest;
use crate::translate::json::content_text;

pub fn chat_request_to_responses_body(oai: &ChatRequest) -> Value {
    let mut instructions: Vec<String> = Vec::new();
    let mut input: Vec<Value> = Vec::with_capacity(oai.messages.len());
    for message in &oai.messages {
        match message.role.as_str() {
            "system" | "developer" => {
                let text = content_text(&message.content);
                if !text.is_empty() {
                    instructions.push(text);
                }
            }
            "assistant" => {
                let text = content_text(&message.content);
                if !text.is_empty() {
                    input.push(json!({"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": text}]}));
                }
                for call in &message.tool_calls {
                    input.push(json!({
                        "type": "function_call",
                        "call_id": call.id,
                        "name": call.function.name,
                        "arguments": call.function.arguments,
                    }));
                }
            }
            "tool" | "function" => {
                let text = content_text(&message.content);
                input.push(json!({
                    "type": "function_call_output",
                    "call_id": message.tool_call_id,
                    "output": text,
                }));
            }
            _ => {
                let text = content_text(&message.content);
                input.push(json!({"type": "message", "role": "user", "content": [
                    {"type": "input_text", "text": text}
                ]}));
            }
        }
    }

    let mut body = json!({
        "model": oai.model,
        "input": input,
        "stream": oai.stream,
    });
    if !instructions.is_empty() {
        body["instructions"] = json!(instructions.join("\n\n"));
    }
    if let Some(limit) = oai.max_completion_tokens.or(oai.max_tokens) {
        body["max_output_tokens"] = json!(limit);
    }
    if !oai.reasoning_effort.is_empty() && oai.reasoning_effort != "none" {
        let normalized = match oai.reasoning_effort.as_str() {
            "none" | "minimal" => "low",
            "xhigh" | "max" => "high",
            other => other,
        };
        body["reasoning"] = json!({"effort": normalized});
    }
    if !oai.tools.is_empty() {
        let tools: Vec<Value> = oai
            .tools
            .iter()
            .map(|tool| {
                json!({
                    "type": "function",
                    "name": tool.function.name,
                    "description": tool.function.description,
                    "parameters": tool.function.parameters,
                })
            })
            .collect();
        body["tools"] = json!(tools);
    }
    body
}
