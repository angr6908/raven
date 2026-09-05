use serde_json::Value;

fn non_empty_str(value: Option<&Value>) -> bool {
    value
        .and_then(Value::as_str)
        .is_some_and(|text| !text.is_empty())
}

pub fn is_chat_token_chunk(chunk: &Value) -> bool {
    let Some(choices) = chunk.get("choices").and_then(Value::as_array) else {
        return false;
    };
    for choice in choices {
        for side in ["delta", "message"] {
            let Some(part) = choice.get(side) else {
                continue;
            };
            if non_empty_str(part.get("content"))
                || non_empty_str(part.get("reasoning_content"))
                || non_empty_str(part.get("reasoning"))
                || non_empty_str(part.get("refusal"))
            {
                return true;
            }

            if part
                .get("tool_calls")
                .and_then(Value::as_array)
                .is_some_and(|calls| {
                    calls.iter().any(|call| {
                        non_empty_str(call.pointer("/function/name"))
                            || non_empty_str(call.pointer("/function/arguments"))
                            || non_empty_str(call.pointer("/custom/input"))
                    })
                })
            {
                return true;
            }
        }

        if non_empty_str(choice.get("finish_reason")) {
            return true;
        }
    }
    false
}

pub fn is_claude_token_event(name: &str, payload: &Value) -> bool {
    match name {
        "content_block_delta" => {
            let delta = payload.get("delta");
            non_empty_str(delta.and_then(|d| d.get("text")))
                || non_empty_str(delta.and_then(|d| d.get("thinking")))
                || non_empty_str(delta.and_then(|d| d.get("partial_json")))
                || non_empty_str(delta.and_then(|d| d.get("signature")))
        }
        "content_block_start" => {
            let block = payload.get("content_block");
            non_empty_str(block.and_then(|b| b.get("text")))
                || non_empty_str(block.and_then(|b| b.get("thinking")))
        }
        "message_delta" => non_empty_str(payload.pointer("/delta/stop_reason")),
        "message_stop" | "error" => true,
        _ => false,
    }
}

pub fn is_responses_token_event(event: &Value) -> bool {
    let Some(kind) = event.get("type").and_then(Value::as_str) else {
        return false;
    };
    match kind {
        "response.output_text.delta"
        | "response.text.delta"
        | "response.refusal.delta"
        | "response.reasoning_summary_text.delta"
        | "response.reasoning.delta"
        | "response.reasoning_text.delta"
        | "response.function_call_arguments.delta"
        | "response.custom_tool_call_input.delta"
        | "response.mcp_call_arguments.delta"
        | "response.code_interpreter_call_code.delta"
        | "response.shell_call_command.delta"
        | "response.audio_transcript.delta"
        | "response.audio.transcript.delta" => non_empty_str(event.get("delta")),

        "response.audio.delta" => {
            non_empty_str(event.get("delta")) || non_empty_str(event.get("data"))
        }
        "response.image_generation_call.partial_image" => {
            non_empty_str(event.get("partial_image_b64"))
        }

        "response.shell_call_command.added" => non_empty_str(event.get("command")),
        "response.output_text.done"
        | "response.reasoning_summary_text.done"
        | "response.reasoning_text.done" => non_empty_str(event.get("text")),
        "response.refusal.done" => non_empty_str(event.get("refusal")),
        "response.function_call_arguments.done" | "response.mcp_call_arguments.done" => {
            non_empty_str(event.get("arguments"))
        }
        "response.custom_tool_call_input.done" => non_empty_str(event.get("input")),
        "response.code_interpreter_call_code.done" => non_empty_str(event.get("code")),
        "response.shell_call_command.done" => non_empty_str(event.get("command")),
        "response.reasoning_summary_part.done" => non_empty_str(event.pointer("/part/text")),
        "response.content_part.done" => {
            non_empty_str(event.pointer("/part/text"))
                || non_empty_str(event.pointer("/part/refusal"))
        }

        "response.output_item.done" => match event.pointer("/item/type").and_then(Value::as_str) {
            Some("function_call") => non_empty_str(event.pointer("/item/arguments")),
            Some("custom_tool_call") => non_empty_str(event.pointer("/item/input")),
            Some("message") => event
                .pointer("/item/content")
                .and_then(Value::as_array)
                .is_some_and(|parts| {
                    parts.iter().any(|part| {
                        non_empty_str(part.get("text")) || non_empty_str(part.get("refusal"))
                    })
                }),
            _ => false,
        },
        "response.completed"
        | "response.done"
        | "response.incomplete"
        | "response.failed"
        | "error" => true,
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_token_predicate_ignores_handshake_frames() {
        assert!(!is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {"role": "assistant"}}]})
        ));
        assert!(!is_chat_token_chunk(
            &serde_json::json!({"choices": [], "usage": {"prompt_tokens": 1}})
        ));

        assert!(is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {"content": "hi"}}]})
        ));
        assert!(is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {"reasoning": "step"}}]})
        ));
        assert!(is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {"tool_calls": [{"index": 0, "function": {"name": "read"}}]}}]})
        ));

        assert!(!is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {"tool_calls": [{"index": 0}]}}]})
        ));

        assert!(is_chat_token_chunk(
            &serde_json::json!({"choices": [{"delta": {}, "finish_reason": "stop"}]})
        ));
    }

    #[test]
    fn claude_token_predicate_ignores_message_start() {
        assert!(!is_claude_token_event(
            "message_start",
            &serde_json::json!({"type": "message_start"})
        ));
        assert!(!is_claude_token_event(
            "content_block_delta",
            &serde_json::json!({"delta": {"type": "text_delta", "text": ""}})
        ));
        assert!(is_claude_token_event(
            "content_block_delta",
            &serde_json::json!({"delta": {"type": "text_delta", "text": "x"}})
        ));
        assert!(is_claude_token_event(
            "content_block_delta",
            &serde_json::json!({"delta": {"type": "input_json_delta", "partial_json": "{\"a\""}})
        ));
    }

    #[test]
    fn responses_token_predicate_ignores_lifecycle_events() {
        assert!(!is_responses_token_event(
            &serde_json::json!({"type": "response.created"})
        ));
        assert!(!is_responses_token_event(
            &serde_json::json!({"type": "response.output_item.added"})
        ));
        assert!(!is_responses_token_event(
            &serde_json::json!({"type": "response.output_text.delta", "delta": ""})
        ));
        assert!(is_responses_token_event(
            &serde_json::json!({"type": "response.output_text.delta", "delta": "hi"})
        ));
        assert!(is_responses_token_event(
            &serde_json::json!({"type": "response.completed"})
        ));
    }
}
