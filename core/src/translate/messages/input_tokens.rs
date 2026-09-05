use serde_json::Value;

pub fn count_input_tokens(payload: &Value) -> Option<i64> {
    let segments = collect_segments(payload);
    if segments.is_empty() {
        return Some(0);
    }
    Some(tokenizer()?.encode_ordinary(&segments.join("\n")).len() as i64)
}

fn tokenizer() -> Option<&'static tiktoken_rs::CoreBPE> {
    static TOKENIZER: std::sync::OnceLock<Option<tiktoken_rs::CoreBPE>> =
        std::sync::OnceLock::new();
    TOKENIZER
        .get_or_init(|| tiktoken_rs::o200k_base().ok())
        .as_ref()
}

fn collect_segments(root: &Value) -> Vec<String> {
    let mut segments: Vec<String> = Vec::with_capacity(32);
    collect_system(root.get("system"), &mut segments);
    collect_messages(root.get("messages"), &mut segments);
    collect_tools(root.get("tools"), &mut segments);
    collect_tool_choice(root.get("tool_choice"), &mut segments);
    segments
}

fn push_text(segments: &mut Vec<String>, value: &str) {
    let trimmed = value.trim();
    if !trimmed.is_empty() {
        segments.push(trimmed.to_string());
    }
}

fn push_str_field(segments: &mut Vec<String>, node: Option<&Value>) {
    if let Some(text) = node.and_then(Value::as_str) {
        push_text(segments, text);
    }
}

fn push_json(segments: &mut Vec<String>, value: Option<&Value>) {
    let Some(value) = value else { return };
    if let Some(text) = value.as_str() {
        push_text(segments, text);
        return;
    }
    let raw = serde_json::to_string(value).unwrap_or_default();
    push_text(segments, &raw);
}

fn collect_system(system: Option<&Value>, segments: &mut Vec<String>) {
    let Some(system) = system else { return };
    if let Some(text) = system.as_str() {
        push_text(segments, text);
        return;
    }
    let Some(items) = system.as_array() else {
        return;
    };
    for part in items {
        if let Some(text) = part.as_str() {
            push_text(segments, text);
        } else if part.get("type").and_then(Value::as_str) == Some("text") {
            push_str_field(segments, part.get("text"));
        }
    }
}

fn collect_messages(messages: Option<&Value>, segments: &mut Vec<String>) {
    let Some(items) = messages.and_then(Value::as_array) else {
        return;
    };
    for message in items {
        push_str_field(segments, message.get("role"));
        collect_content(message.get("content"), segments);
    }
}

fn collect_content(content: Option<&Value>, segments: &mut Vec<String>) {
    let Some(content) = content else { return };
    if let Some(text) = content.as_str() {
        push_text(segments, text);
        return;
    }
    if let Some(items) = content.as_array() {
        for part in items {
            collect_content(Some(part), segments);
        }
        return;
    }
    if !content.is_object() {
        return;
    }

    match content.get("type").and_then(Value::as_str).unwrap_or("") {
        "text" => push_str_field(segments, content.get("text")),
        "thinking" => push_str_field(segments, content.get("thinking")),
        "document" => collect_document(content, segments),
        "tool_use" | "server_tool_use" | "mcp_tool_use" => {
            push_str_field(segments, content.get("id"));
            push_str_field(segments, content.get("name"));
            push_json(segments, content.get("input"));
        }
        "tool_result"
        | "mcp_tool_result"
        | "web_search_tool_result"
        | "web_fetch_tool_result"
        | "code_execution_tool_result"
        | "bash_code_execution_tool_result"
        | "text_editor_code_execution_tool_result" => {
            push_str_field(segments, content.get("tool_use_id"));
            push_str_field(segments, content.get("tool_call_id"));
            collect_content(content.get("content"), segments);
        }
        "web_search_result" | "search_result" => {
            if let Some(source) = content.get("source").and_then(Value::as_str) {
                push_text(segments, source);
            }
            push_str_field(segments, content.get("title"));
            push_str_field(segments, content.get("url"));
            push_str_field(segments, content.get("page_age"));
            collect_content(content.get("content"), segments);
        }
        "web_fetch_result" => {
            push_str_field(segments, content.get("url"));
            push_str_field(segments, content.get("retrieved_at"));
            collect_content(content.get("content"), segments);
        }
        "code_execution_result"
        | "bash_code_execution_result"
        | "text_editor_code_execution_result" => {
            push_str_field(segments, content.get("stdout"));
            push_str_field(segments, content.get("stderr"));

            push_text(segments, &gjson_string(content.get("return_code")));
            collect_content(content.get("content"), segments);
            collect_content(content.get("output"), segments);
        }
        "tool_reference" => push_str_field(segments, content.get("tool_name")),
        "image" | "input_audio" | "audio" | "video" | "redacted_thinking" => {}

        "" => push_json(segments, Some(content)),
        _ => push_str_field(segments, content.get("text")),
    }
}

fn collect_document(document: &Value, segments: &mut Vec<String>) {
    let Some(source) = document.get("source") else {
        return;
    };
    if source.get("type").and_then(Value::as_str) != Some("text") {
        return;
    }
    push_str_field(segments, document.get("title"));
    push_str_field(segments, document.get("context"));
    push_str_field(segments, source.get("data"));
    push_str_field(segments, source.get("content"));
}

fn collect_tools(tools: Option<&Value>, segments: &mut Vec<String>) {
    let Some(items) = tools.and_then(Value::as_array) else {
        return;
    };
    for tool in items {
        push_str_field(segments, tool.get("type"));
        push_str_field(segments, tool.get("name"));
        push_str_field(segments, tool.get("description"));
        push_json(segments, tool.get("input_schema"));
    }
}

fn collect_tool_choice(tool_choice: Option<&Value>, segments: &mut Vec<String>) {
    let Some(tool_choice) = tool_choice else {
        return;
    };
    if let Some(text) = tool_choice.as_str() {
        push_text(segments, text);
        return;
    }
    push_str_field(segments, tool_choice.get("type"));
    push_str_field(segments, tool_choice.get("name"));
}

fn gjson_string(value: Option<&Value>) -> String {
    match value {
        Some(Value::String(text)) => text.clone(),
        Some(Value::Number(number)) => number.to_string(),
        Some(Value::Bool(flag)) => flag.to_string(),
        _ => String::new(),
    }
}

pub struct InputTokenState {
    handled: bool,
    original_request: Value,
}

impl InputTokenState {
    pub fn new(upstream_is_claude: bool, original_request: &Value) -> Self {
        Self {
            handled: upstream_is_claude,
            original_request: original_request.clone(),
        }
    }

    pub fn apply(&mut self, event_name: &str, payload: &mut Value) -> bool {
        if self.handled {
            return false;
        }
        if payload.get("type").and_then(Value::as_str) != Some("message_start") {
            let _ = event_name;
            return false;
        }

        self.handled = true;
        let existing = payload
            .pointer("/message/usage/input_tokens")
            .and_then(Value::as_i64);
        if existing.is_some_and(|tokens| tokens != 0) {
            return false;
        }
        let Some(count) = count_input_tokens(&self.original_request) else {
            return false;
        };
        if count == 0 {
            return false;
        }
        let Some(usage) = payload.pointer_mut("/message/usage") else {
            return false;
        };
        usage["input_tokens"] = Value::from(count);
        true
    }
}

impl InputTokenState {
    pub fn apply_frame(&mut self, frame: &[u8]) -> Option<Vec<u8>> {
        if self.handled {
            return None;
        }
        let text = std::str::from_utf8(frame).ok()?;
        let mut rebuilt = String::with_capacity(text.len() + 16);
        let mut changed = false;
        for (index, line) in text.split_inclusive('\n').enumerate() {
            let _ = index;
            let body = line.trim_end_matches(['\n', '\r']);
            let Some(payload) = body.strip_prefix("data:") else {
                rebuilt.push_str(line);
                continue;
            };
            let payload = payload.trim();
            let Ok(mut parsed) = serde_json::from_str::<Value>(payload) else {
                rebuilt.push_str(line);
                continue;
            };
            if !self.apply("", &mut parsed) {
                rebuilt.push_str(line);
                continue;
            }
            changed = true;
            rebuilt.push_str("data: ");
            rebuilt.push_str(&serde_json::to_string(&parsed).unwrap_or_default());
            rebuilt.push_str(&line[body.len()..]);
        }
        changed.then(|| rebuilt.into_bytes())
    }
}

pub fn spawn_input_token_filter(
    outer: tokio::sync::mpsc::UnboundedSender<crate::net::sse::StreamFrame>,
    original_request: &Value,
    upstream_is_claude: bool,
) -> tokio::sync::mpsc::UnboundedSender<crate::net::sse::StreamFrame> {
    let (inner, mut receiver) = tokio::sync::mpsc::unbounded_channel();
    let mut state = InputTokenState::new(upstream_is_claude, original_request);
    tokio::spawn(async move {
        while let Some(frame) = receiver.recv().await {
            let frame = match frame {
                crate::net::sse::StreamFrame::Data(bytes) => {
                    let rewritten = state.apply_frame(&bytes);
                    crate::net::sse::StreamFrame::Data(rewritten.unwrap_or(bytes))
                }
                other => other,
            };
            if outer.send(frame).is_err() {
                break;
            }
        }
    });
    inner
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn segments_follow_the_reference_walk() {
        let request = json!({
            "system": [{"type": "text", "text": " hello "}, {"type": "image"}],
            "messages": [
                {"role": "user", "content": "hi"},
                {"role": "assistant", "content": [
                    {"type": "thinking", "thinking": "hmm"},
                    {"type": "tool_use", "id": "t1", "name": "Bash", "input": {"cmd": "ls"}},
                    {"type": "image", "source": {"data": "ignored"}},
                ]},
                {"role": "user", "content": [
                    {"type": "tool_result", "tool_use_id": "t1", "content": "ok"},
                ]},
            ],
            "tools": [{"name": "Bash", "description": "run", "input_schema": {"type": "object"}}],
            "tool_choice": {"type": "auto"},
        });
        assert_eq!(
            collect_segments(&request),
            vec![
                "hello",
                "user",
                "hi",
                "assistant",
                "hmm",
                "t1",
                "Bash",
                r#"{"cmd":"ls"}"#,
                "user",
                "t1",
                "ok",
                "Bash",
                "run",
                r#"{"type":"object"}"#,
                "auto",
            ]
        );
    }

    #[test]
    fn fills_message_start_once() {
        let request = json!({"messages": [{"role": "user", "content": "hello world"}]});
        let mut state = InputTokenState::new(false, &request);
        let mut event = json!({
            "type": "message_start",
            "message": {"usage": {"input_tokens": 0, "output_tokens": 0}},
        });
        assert!(state.apply("message_start", &mut event));
        assert!(event["message"]["usage"]["input_tokens"].as_i64().unwrap() > 0);

        let mut again = json!({
            "type": "message_start",
            "message": {"usage": {"input_tokens": 0, "output_tokens": 0}},
        });
        assert!(!state.apply("message_start", &mut again));
    }

    #[test]
    fn leaves_a_reported_count_alone() {
        let request = json!({"messages": [{"role": "user", "content": "hello"}]});
        let mut state = InputTokenState::new(false, &request);
        let mut event = json!({
            "type": "message_start",
            "message": {"usage": {"input_tokens": 42, "output_tokens": 0}},
        });
        assert!(!state.apply("message_start", &mut event));
        assert_eq!(event["message"]["usage"]["input_tokens"], 42);
    }

    #[test]
    fn claude_upstreams_are_inactive() {
        let request = json!({"messages": [{"role": "user", "content": "hello"}]});
        let mut state = InputTokenState::new(true, &request);
        let mut event = json!({
            "type": "message_start",
            "message": {"usage": {"input_tokens": 0, "output_tokens": 0}},
        });
        assert!(!state.apply("message_start", &mut event));
    }
}
