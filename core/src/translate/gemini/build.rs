use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

use crate::translate::chat::types::{ChatMessage, ChatRequest, ChatTool};
use crate::translate::ids::{now_unix_millis, sha256};
use crate::translate::json::{arguments_to_object, content_text};

use super::schema;
use super::types::{
    Envelope, Plan, Request, Thinking, REQUEST_TYPE_AGENT, ROLE_MODEL, ROLE_USER,
    USER_AGENT_ANTIGRAVITY,
};

const CONTINUATION_BRIDGE: &str = "Continue the active task using the available instructions and context.";
const SYSTEM_BRIDGE: &str = "Apply the active system instructions.";

const DEFAULT_SYSTEM_INSTRUCTION: &str = concat!(
    "You are Antigravity, a powerful agentic AI coding assistant designed by Google DeepMind. ",
    "You are pair programming with a user to solve coding tasks. Be concise, practical, and tool-aware."
);

pub fn build_request(
    req: ChatRequest,
    plan: &Plan,
    signature: &dyn Fn(&str) -> Option<String>,
) -> Result<Envelope, String> {
    let (paired, tool_names) = tool_call_pairs(&req.messages);
    let mut system_parts: Vec<Value> = Vec::new();
    let mut contents: Vec<Value> = Vec::new();
    let mut dropped: HashMap<String, String> = HashMap::new();
    let mut assistant_turns: i64 = 0;

    for message in &req.messages {
        match message.role.as_str() {
            "system" | "developer" => {
                let text = content_text(&message.content);
                if !text.is_empty() {
                    system_parts.push(json!({"text": text}));
                }
            }
            "user" => {
                let parts = user_parts(&message.content)?;
                append_turn(&mut contents, ROLE_USER, parts);
            }
            "assistant" => {
                assistant_turns += 1;
                let parts = assistant_parts(message, &paired, plan, signature, &mut dropped);
                append_turn(&mut contents, ROLE_MODEL, parts);
            }
            "tool" | "function" => {
                if message.tool_call_id.is_empty() || !paired.contains(&message.tool_call_id) {
                    continue;
                }
                let name = tool_names
                    .get(&message.tool_call_id)
                    .cloned()
                    .unwrap_or_else(|| message.name.clone());
                let parts = tool_result_parts(message, &name, plan, &dropped);
                append_turn(&mut contents, ROLE_USER, parts);
            }
            _ => {}
        }
    }

    if system_parts.is_empty() {
        system_parts.push(json!({"text": DEFAULT_SYSTEM_INSTRUCTION}));
    }
    bridge_user_text(&mut contents);

    let request_index = assistant_turns;
    let step = contents.len().max(1) as i64;
    let (conversation_id, trajectory_id) = conversation_ids(&req.messages);

    Ok(Envelope {
        model: plan.runtime_model.clone(),
        request: Request {
            system_instruction: json!({"role": ROLE_USER, "parts": system_parts}),
            generation_config: generation_config(&req, plan),
            tools: tools(&req.tools, &req.tool_choice, plan),
            tool_config: tool_config(&req.tool_choice),
            session_id: session_id(&trajectory_id),
            labels: labels(plan, step, request_index, &trajectory_id),
            contents,
        },
        request_type: REQUEST_TYPE_AGENT,
        user_agent: USER_AGENT_ANTIGRAVITY,
        request_id: format!(
            "agent/{conversation_id}/{}/{trajectory_id}/{step}",
            now_unix_millis()
        ),
    })
}

fn assistant_parts(
    message: &ChatMessage,
    paired: &HashSet<String>,
    plan: &Plan,
    signature: &dyn Fn(&str) -> Option<String>,
    dropped: &mut HashMap<String, String>,
) -> Vec<Value> {
    let mut parts: Vec<Value> = Vec::new();
    let text = content_text(&message.content);
    if !text.is_empty() {
        parts.push(json!({"text": text}));
    }

    let calls: Vec<&crate::translate::chat::types::ChatToolCall> = message
        .tool_calls
        .iter()
        .filter(|call| paired.contains(&call.id))
        .collect();
    let signatures: Vec<Option<String>> = calls
        .iter()
        .map(|call| signature(&call.id).filter(|found| is_thought_signature(found)))
        .collect();
    let signed = !calls.is_empty() && signatures.iter().all(Option::is_some);

    for (call, found) in calls.into_iter().zip(signatures) {
        let arguments = arguments_to_object(&call.function.arguments);
        if plan.requires_thought_signature && !signed {
            dropped.insert(call.id.clone(), arguments.to_string());
            continue;
        }
        let mut function_call = Map::new();
        function_call.insert("name".to_string(), json!(call.function.name));
        function_call.insert("args".to_string(), arguments);
        if plan.tool_call_ids {
            function_call.insert(
                "id".to_string(),
                json!(sanitize_tool_call_id(&call.id, &call.function.name)),
            );
        }
        let mut part = Map::new();
        part.insert("functionCall".to_string(), Value::Object(function_call));
        if let Some(found) = found {
            part.insert("thoughtSignature".to_string(), json!(found));
        }
        parts.push(Value::Object(part));
    }
    parts
}

fn tool_result_parts(
    message: &ChatMessage,
    name: &str,
    plan: &Plan,
    dropped: &HashMap<String, String>,
) -> Vec<Value> {
    let text = content_text(&message.content);
    if let Some(arguments) = dropped.get(&message.tool_call_id) {
        let label = match arguments.as_str() {
            "{}" => format!("`{name}`"),
            arguments => format!("`{name}` ({arguments})"),
        };
        return vec![json!({"text": format!("[Observation from {label}:\n{text}]")})];
    }

    let mut response = Map::new();
    response.insert("name".to_string(), json!(name));
    response.insert("response".to_string(), json!({"output": text}));
    if plan.tool_call_ids {
        response.insert(
            "id".to_string(),
            json!(sanitize_tool_call_id(&message.tool_call_id, name)),
        );
    }
    vec![json!({"functionResponse": Value::Object(response)})]
}

fn user_parts(content: &Value) -> Result<Vec<Value>, String> {
    if content.is_null() {
        return Ok(Vec::new());
    }
    if let Some(text) = content.as_str() {
        return Ok(text_part(text));
    }
    let Some(items) = content.as_array() else {
        return Err("unsupported user content".to_string());
    };

    let mut parts = Vec::new();
    for item in items {
        let Some(object) = item.as_object() else {
            continue;
        };
        match object.get("type").and_then(Value::as_str).unwrap_or_default() {
            "text" | "input_text" => {
                let text = object.get("text").and_then(Value::as_str).unwrap_or_default();
                parts.extend(text_part(text));
            }
            "image_url" | "input_image" => {
                let url = object
                    .get("image_url")
                    .and_then(|image| image.get("url").unwrap_or(image).as_str())
                    .unwrap_or_default();
                if let Some(part) = inline_data(url) {
                    parts.push(part);
                }
            }
            _ => {}
        }
    }
    Ok(parts)
}

fn text_part(text: &str) -> Vec<Value> {
    if text.trim().is_empty() {
        return Vec::new();
    }
    vec![json!({"text": text})]
}

fn inline_data(url: &str) -> Option<Value> {
    let rest = url.strip_prefix("data:")?;
    let (mime, data) = rest.split_once(";base64,")?;
    let mime = if mime.is_empty() { "image/png" } else { mime };
    let data = data.trim();
    (!data.is_empty()).then(|| json!({"inlineData": {"mimeType": mime, "data": data}}))
}

fn append_turn(contents: &mut Vec<Value>, role: &str, parts: Vec<Value>) {
    if parts.is_empty() {
        return;
    }
    if let Some(last) = contents.last_mut() {
        if last.get("role").and_then(Value::as_str) == Some(role) {
            if let Some(existing) = last.get_mut("parts").and_then(Value::as_array_mut) {
                existing.extend(parts);
                return;
            }
        }
    }
    contents.push(json!({"role": role, "parts": parts}));
}

fn bridge_user_text(contents: &mut Vec<Value>) {
    if contents.is_empty() {
        contents.push(json!({"role": ROLE_USER, "parts": [{"text": SYSTEM_BRIDGE}]}));
        return;
    }
    if has_user_text(contents) {
        return;
    }
    let bridge = json!({"text": CONTINUATION_BRIDGE});
    for turn in contents.iter_mut() {
        if turn.get("role").and_then(Value::as_str) == Some(ROLE_USER) {
            if let Some(parts) = turn.get_mut("parts").and_then(Value::as_array_mut) {
                parts.push(bridge);
                return;
            }
        }
    }
    contents.insert(0, json!({"role": ROLE_USER, "parts": [bridge]}));
}

fn has_user_text(contents: &[Value]) -> bool {
    contents.iter().any(|turn| {
        turn.get("role").and_then(Value::as_str) == Some(ROLE_USER)
            && turn
                .get("parts")
                .and_then(Value::as_array)
                .is_some_and(|parts| {
                    parts.iter().any(|part| {
                        part.get("text")
                            .and_then(Value::as_str)
                            .is_some_and(|text| !text.trim().is_empty())
                    })
                })
    })
}

fn generation_config(req: &ChatRequest, plan: &Plan) -> Value {
    let mut config = Map::new();
    if let Some(temperature) = req.temperature {
        config.insert("temperature".to_string(), json!(temperature));
    }
    if let Some(top_p) = req.top_p {
        config.insert("topP".to_string(), json!(top_p));
    }
    let requested = req.max_tokens.or(req.max_completion_tokens).unwrap_or(0);
    let ceiling = plan.max_output_tokens.max(1);
    let max_output = match requested > 0 {
        true => requested.min(ceiling),
        false => ceiling,
    };
    config.insert("maxOutputTokens".to_string(), json!(max_output));
    if let Some(Thinking {
        include_thoughts,
        budget,
    }) = plan.thinking
    {
        config.insert(
            "thinkingConfig".to_string(),
            json!({"includeThoughts": include_thoughts, "thinkingBudget": budget}),
        );
    }
    Value::Object(config)
}

fn tools(declared: &[ChatTool], tool_choice: &Option<Value>, plan: &Plan) -> Value {
    if declared.is_empty() || tool_choice_mode(tool_choice) == Some("NONE") {
        return Value::Null;
    }
    let declarations: Vec<Value> = declared
        .iter()
        .filter(|tool| !tool.function.name.is_empty())
        .filter_map(|tool| declaration(tool, plan))
        .collect();
    if declarations.is_empty() {
        return Value::Null;
    }
    json!([{"functionDeclarations": declarations}])
}

fn declaration(tool: &ChatTool, plan: &Plan) -> Option<Value> {
    let parameters = match tool.function.parameters.is_null() {
        true => json!({"type": "object", "properties": {}}),
        false => tool.function.parameters.clone(),
    };
    let resolved = schema::dereference(&parameters)?;
    let normalized = schema::strip_meta(&schema::ensure_root_object(resolved));
    let mut out = Map::new();
    out.insert("name".to_string(), json!(tool.function.name));
    out.insert("description".to_string(), json!(tool.function.description));
    match plan.legacy_tool_parameters {
        true => out.insert(
            "parameters".to_string(),
            schema::normalize_custom_tool(&normalized),
        ),
        false => out.insert("parametersJsonSchema".to_string(), normalized),
    };
    Some(Value::Object(out))
}

fn tool_config(tool_choice: &Option<Value>) -> Value {
    match tool_choice_mode(tool_choice) {
        Some(mode) => json!({"functionCallingConfig": {"mode": mode}}),
        None => Value::Null,
    }
}

fn tool_choice_mode(tool_choice: &Option<Value>) -> Option<&'static str> {
    let choice = tool_choice.as_ref()?;
    let named = choice
        .as_str()
        .map(str::to_ascii_lowercase)
        .or_else(|| {
            choice
                .get("type")
                .and_then(Value::as_str)
                .map(str::to_ascii_lowercase)
        })?;
    match named.as_str() {
        "none" => Some("NONE"),
        "required" | "any" | "function" => Some("ANY"),
        _ => None,
    }
}

fn labels(plan: &Plan, step: i64, request_index: i64, trajectory_id: &str) -> Value {
    let runtime = plan.runtime_model.as_str();
    let claude = runtime.starts_with("claude-");
    let non_gemini = claude || !runtime.starts_with("gemini-");
    let mut labels = Map::new();
    labels.insert(
        "last_step_index".to_string(),
        json!((step - 1).max(0).to_string()),
    );
    labels.insert(
        "request_id".to_string(),
        json!(format!("{trajectory_id}-{request_index}")),
    );
    labels.insert("trajectory_id".to_string(), json!(trajectory_id));
    labels.insert("used_claude".to_string(), json!(claude.to_string()));
    labels.insert(
        "used_claude_conservative".to_string(),
        json!(claude.to_string()),
    );
    labels.insert(
        "used_non_gemini_model".to_string(),
        json!(non_gemini.to_string()),
    );
    if !plan.model_enum.is_empty() {
        labels.insert("model_enum".to_string(), json!(plan.model_enum));
    }
    Value::Object(labels)
}

fn conversation_ids(messages: &[ChatMessage]) -> (String, String) {
    let seed = messages
        .first()
        .map(|message| {
            format!(
                "{}:{}",
                message.role,
                content_text(&message.content).chars().take(256).collect::<String>()
            )
        })
        .unwrap_or_default();
    (
        stable_uuid(&format!("antigravity:conv:{seed}")),
        stable_uuid(&format!("antigravity:traj:{seed}")),
    )
}

fn session_id(trajectory_id: &str) -> String {
    let digest = sha256(trajectory_id);
    let mut bytes = [0u8; 8];
    bytes.copy_from_slice(&digest[..8]);
    i64::from_le_bytes(bytes).to_string()
}

fn stable_uuid(seed: &str) -> String {
    let digest = sha256(seed);
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
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
        if matches!(message.role.as_str(), "tool" | "function") && !message.tool_call_id.is_empty() {
            results.insert(message.tool_call_id.clone());
        }
    }
    calls.retain(|id| results.contains(id));
    (calls, names)
}

pub fn sanitize_tool_call_id(id: &str, fallback: &str) -> String {
    let cleaned: String = id
        .chars()
        .map(|c| match c.is_ascii_alphanumeric() || c == '_' || c == '-' {
            true => c,
            false => '_',
        })
        .take(64)
        .collect();
    match cleaned.is_empty() {
        true => format!("{}_call", fallback_slug(fallback)),
        false => cleaned,
    }
}

fn fallback_slug(name: &str) -> String {
    let slug: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
        .take(48)
        .collect();
    match slug.is_empty() {
        true => "tool".to_string(),
        false => slug,
    }
}

pub fn is_thought_signature(signature: &str) -> bool {
    !signature.is_empty()
        && signature.len().is_multiple_of(4)
        && signature
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'+' || b == b'/' || b == b'=')
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::translate::chat::types::{ChatFunctionCall, ChatMessage, ChatToolCall, ChatToolFunction};
    use serde_json::json;

    fn message(role: &str, content: Value) -> ChatMessage {
        ChatMessage {
            role: role.to_string(),
            content,
            tool_calls: Vec::new(),
            tool_call_id: String::new(),
            name: String::new(),
            reasoning_content: String::new(),
        }
    }

    fn call(id: &str, name: &str, arguments: &str) -> ChatToolCall {
        ChatToolCall {
            id: id.to_string(),
            r#type: "function".to_string(),
            function: ChatFunctionCall {
                name: name.to_string(),
                arguments: arguments.to_string(),
            },
        }
    }

    fn request(messages: Vec<ChatMessage>, tools: Vec<ChatTool>) -> ChatRequest {
        ChatRequest {
            model: "gemini-3.8-flash".to_string(),
            messages,
            tools,
            tool_choice: None,
            parallel_tool_calls: None,
            response_format: None,
            stream_options: None,
            top_k: None,
            n: None,
            modalities: Vec::new(),
            image_config: None,
            generation_config: None,
            max_tokens: None,
            max_completion_tokens: None,
            temperature: None,
            top_p: None,
            stop: Vec::new(),
            user: String::new(),
            reasoning_effort: String::new(),
            stream: true,
        }
    }

    fn gemini_plan() -> Plan {
        Plan {
            runtime_model: "gemini-3.8-flash-low".to_string(),
            model_enum: "MODEL_PLACEHOLDER_M320".to_string(),
            max_output_tokens: 65_536,
            thinking: Some(Thinking {
                include_thoughts: true,
                budget: 1_000,
            }),
            tool_call_ids: false,
            legacy_tool_parameters: false,
            requires_thought_signature: true,
        }
    }

    fn none(_: &str) -> Option<String> {
        None
    }

    fn body(envelope: &Envelope) -> Value {
        serde_json::to_value(&envelope.request).expect("request serializes")
    }

    #[test]
    fn system_messages_become_the_system_instruction() {
        let envelope = build_request(
            request(
                vec![
                    message("system", json!("be brief")),
                    message("user", json!("hello")),
                ],
                vec![],
            ),
            &gemini_plan(),
            &none,
        )
        .unwrap();
        let request = body(&envelope);
        assert_eq!(request["systemInstruction"]["parts"][0]["text"], "be brief");
        assert_eq!(request["contents"][0]["role"], "user");
        assert_eq!(request["contents"][0]["parts"][0]["text"], "hello");
        assert_eq!(envelope.model, "gemini-3.8-flash-low");
        assert_eq!(envelope.request_type, "agent");
        assert_eq!(envelope.user_agent, "antigravity");
        assert!(envelope.request_id.starts_with("agent/"));
    }

    #[test]
    fn generation_config_caps_output_and_carries_the_thinking_budget() {
        let mut req = request(vec![message("user", json!("hi"))], vec![]);
        req.max_tokens = Some(200_000);
        req.temperature = Some(0.4);
        let request = body(&build_request(req, &gemini_plan(), &none).unwrap());
        assert_eq!(request["generationConfig"]["maxOutputTokens"], 65_536);
        assert_eq!(request["generationConfig"]["temperature"], 0.4);
        assert_eq!(
            request["generationConfig"]["thinkingConfig"],
            json!({"includeThoughts": true, "thinkingBudget": 1_000})
        );
    }

    #[test]
    fn signed_tool_calls_round_trip_as_function_calls() {
        let mut assistant = message("assistant", json!(""));
        assistant.tool_calls = vec![call("call_1", "bash", r#"{"command":"ls"}"#)];
        let mut result = message("tool", json!("a.txt"));
        result.tool_call_id = "call_1".to_string();

        let envelope = build_request(
            request(
                vec![message("user", json!("list files")), assistant, result],
                vec![],
            ),
            &gemini_plan(),
            &|id| (id == "call_1").then(|| "c2lnbmF0dXJl".to_string()),
        )
        .unwrap();
        let request = body(&envelope);
        assert_eq!(request["contents"][1]["role"], "model");
        let part = &request["contents"][1]["parts"][0];
        assert_eq!(part["functionCall"]["name"], "bash");
        assert_eq!(part["functionCall"]["args"], json!({"command": "ls"}));
        assert_eq!(part["thoughtSignature"], "c2lnbmF0dXJl");
        assert!(part["functionCall"].get("id").is_none());

        let response = &request["contents"][2]["parts"][0]["functionResponse"];
        assert_eq!(request["contents"][2]["role"], "user");
        assert_eq!(response["name"], "bash");
        assert_eq!(response["response"], json!({"output": "a.txt"}));
    }

    #[test]
    fn unsigned_gemini_tool_calls_are_folded_into_a_user_observation() {
        let mut assistant = message("assistant", json!(""));
        assistant.tool_calls = vec![call("call_1", "bash", r#"{"command":"ls"}"#)];
        let mut result = message("tool", json!("a.txt"));
        result.tool_call_id = "call_1".to_string();

        let request = body(
            &build_request(
                request(
                    vec![message("user", json!("list files")), assistant, result],
                    vec![],
                ),
                &gemini_plan(),
                &none,
            )
            .unwrap(),
        );
        assert_eq!(request["contents"].as_array().expect("turns").len(), 1);
        let text = request["contents"][0]["parts"][1]["text"]
            .as_str()
            .expect("observation text");
        assert!(text.starts_with("[Observation from `bash` ({\"command\":\"ls\"}):"));
        assert!(text.contains("a.txt"));
    }

    #[test]
    fn claude_runtimes_keep_tool_call_ids_and_the_legacy_schema_field() {
        let mut assistant = message("assistant", json!(""));
        assistant.tool_calls = vec![call("call:1", "bash", "{}")];
        let mut result = message("tool", json!("done"));
        result.tool_call_id = "call:1".to_string();

        let plan = Plan {
            runtime_model: "claude-sonnet-4-6".to_string(),
            tool_call_ids: true,
            legacy_tool_parameters: true,
            requires_thought_signature: false,
            max_output_tokens: 64_000,
            ..Plan::default()
        };
        let tools = vec![ChatTool {
            r#type: "function".to_string(),
            function: ChatToolFunction {
                name: "bash".to_string(),
                description: "run".to_string(),
                parameters: json!({
                    "$schema": "https://json-schema.org/draft/2020-12/schema",
                    "type": "object",
                    "properties": {"command": {"type": "string", "format": "shell"}},
                    "required": ["command"],
                }),
            },
        }];
        let request = body(
            &build_request(
                request(vec![message("user", json!("go")), assistant, result], tools),
                &plan,
                &none,
            )
            .unwrap(),
        );
        assert_eq!(
            request["contents"][1]["parts"][0]["functionCall"]["id"],
            "call_1"
        );
        assert_eq!(
            request["contents"][2]["parts"][0]["functionResponse"]["id"],
            "call_1"
        );
        let declaration = &request["tools"][0]["functionDeclarations"][0];
        assert_eq!(declaration["name"], "bash");
        assert_eq!(
            declaration["parameters"]["properties"]["command"],
            json!({"type": "string"})
        );
        assert!(declaration.get("parametersJsonSchema").is_none());
        assert_eq!(request["labels"]["used_claude"], "true");
        assert_eq!(request["labels"]["used_non_gemini_model"], "true");
    }

    #[test]
    fn gemini_runtimes_send_tools_as_json_schema() {
        let tools = vec![ChatTool {
            r#type: "function".to_string(),
            function: ChatToolFunction {
                name: "bash".to_string(),
                description: "run".to_string(),
                parameters: json!({"type": "object", "properties": {"a": {"type": ["string", "null"]}}}),
            },
        }];
        let request = body(
            &build_request(
                request(vec![message("user", json!("go"))], tools),
                &gemini_plan(),
                &none,
            )
            .unwrap(),
        );
        let declaration = &request["tools"][0]["functionDeclarations"][0];
        assert_eq!(
            declaration["parametersJsonSchema"]["properties"]["a"]["type"],
            json!(["string", "null"])
        );
        assert!(request["toolConfig"].is_null());
        assert_eq!(request["labels"]["used_claude"], "false");
        assert_eq!(request["labels"]["model_enum"], "MODEL_PLACEHOLDER_M320");
    }

    #[test]
    fn tool_choice_none_drops_the_tools_and_forces_the_mode() {
        let tools = vec![ChatTool {
            r#type: "function".to_string(),
            function: ChatToolFunction {
                name: "bash".to_string(),
                description: "run".to_string(),
                parameters: json!({"type": "object"}),
            },
        }];
        let mut req = request(vec![message("user", json!("go"))], tools.clone());
        req.tool_choice = Some(json!("none"));
        let request = body(&build_request(req, &gemini_plan(), &none).unwrap());
        assert!(request["tools"].is_null());
        assert_eq!(request["toolConfig"]["functionCallingConfig"]["mode"], "NONE");

        let mut req = request_with_choice(tools, json!("required"));
        req.reasoning_effort = "high".to_string();
        let request = body(&build_request(req, &gemini_plan(), &none).unwrap());
        assert_eq!(request["toolConfig"]["functionCallingConfig"]["mode"], "ANY");
        assert!(!request["tools"].is_null());
    }

    fn request_with_choice(tools: Vec<ChatTool>, choice: Value) -> ChatRequest {
        let mut req = request(vec![message("user", json!("go"))], tools);
        req.tool_choice = Some(choice);
        req
    }

    #[test]
    fn a_tool_only_turn_still_carries_natural_language_for_the_backend() {
        let mut assistant = message("assistant", json!(""));
        assistant.tool_calls = vec![call("call_1", "bash", "{}")];
        let mut result = message("tool", json!("done"));
        result.tool_call_id = "call_1".to_string();

        let plan = Plan {
            runtime_model: "claude-sonnet-4-6".to_string(),
            tool_call_ids: true,
            max_output_tokens: 64_000,
            ..Plan::default()
        };
        let request = body(
            &build_request(request(vec![assistant, result], vec![]), &plan, &none).unwrap(),
        );
        let user = request["contents"]
            .as_array()
            .expect("turns")
            .iter()
            .find(|turn| turn["role"] == "user")
            .expect("a user turn exists");
        assert!(user["parts"]
            .as_array()
            .expect("parts")
            .iter()
            .any(|part| part["text"] == CONTINUATION_BRIDGE));
    }

    #[test]
    fn data_url_images_travel_as_inline_data() {
        let content = json!([
            {"type": "text", "text": "look"},
            {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,QUJD"}},
            {"type": "image_url", "image_url": {"url": "https://example.com/i.png"}},
        ]);
        let request = body(
            &build_request(
                request(vec![message("user", content)], vec![]),
                &gemini_plan(),
                &none,
            )
            .unwrap(),
        );
        let parts = request["contents"][0]["parts"].as_array().expect("parts");
        assert_eq!(parts.len(), 2);
        assert_eq!(parts[1]["inlineData"]["mimeType"], "image/jpeg");
        assert_eq!(parts[1]["inlineData"]["data"], "QUJD");
    }

    #[test]
    fn conversation_ids_are_stable_for_the_same_opening_message() {
        let first = build_request(
            request(vec![message("user", json!("hello"))], vec![]),
            &gemini_plan(),
            &none,
        )
        .unwrap();
        let again = build_request(
            request(
                vec![message("user", json!("hello")), message("assistant", json!("hi"))],
                vec![],
            ),
            &gemini_plan(),
            &none,
        )
        .unwrap();
        let trajectory = |envelope: &Envelope| envelope.request.labels["trajectory_id"].clone();
        assert_eq!(trajectory(&first), trajectory(&again));
        assert_eq!(first.request.session_id, again.request.session_id);
        assert_eq!(
            again.request.labels["request_id"],
            json!(format!("{}-1", trajectory(&again).as_str().unwrap()))
        );
        assert_eq!(
            first.request.labels["request_id"],
            json!(format!("{}-0", trajectory(&first).as_str().unwrap()))
        );
    }

    #[test]
    fn a_tool_call_without_its_result_is_dropped() {
        let mut assistant = message("assistant", json!("working"));
        assistant.tool_calls = vec![call("call_1", "bash", "{}")];
        let plan = Plan {
            runtime_model: "claude-sonnet-4-6".to_string(),
            tool_call_ids: true,
            ..Plan::default()
        };
        let request = body(
            &build_request(
                request(vec![message("user", json!("go")), assistant], vec![]),
                &plan,
                &none,
            )
            .unwrap(),
        );
        let parts = request["contents"][1]["parts"].as_array().expect("parts");
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0]["text"], "working");
    }
}
