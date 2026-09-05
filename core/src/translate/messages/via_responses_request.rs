use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

use crate::translate::messages::tool_names::{
    base_candidate, build_short_name_map, shorten_call_id_if_needed, tool_names,
};
use crate::translate::messages::via_chat_request::budget_to_effort;
use crate::translate::signature::{
    is_valid_gpt_reasoning_signature, signature_payload_without_provider_prefix,
};

fn map_name(tool_name_map: &HashMap<String, String>, name: &str) -> String {
    match tool_name_map.get(name) {
        Some(short) => short.clone(),
        None => base_candidate(name),
    }
}

fn is_claude_web_search_tool_type(tool_type: &str) -> bool {
    tool_type == "web_search_20250305" || tool_type == "web_search_20260209"
}

fn web_search_tool_names(tools: Option<&Value>) -> HashSet<String> {
    let mut names = HashSet::new();
    let Some(tools) = tools.and_then(Value::as_array) else {
        return names;
    };
    for tool in tools {
        if !is_claude_web_search_tool_type(tool.get("type").and_then(Value::as_str).unwrap_or("")) {
            continue;
        }
        if let Some(name) = tool.get("name").and_then(Value::as_str) {
            if !name.is_empty() {
                names.insert(name.to_string());
            }
        }
    }
    names
}

fn web_search_tool_to_codex(tool: &Value) -> Value {
    let mut out = Map::new();
    out.insert("type".into(), json!("web_search"));
    if let Some(allowed) = tool.get("allowed_domains").filter(|v| v.is_array()) {
        out.insert("filters".into(), json!({"allowed_domains": allowed}));
    }
    if let Some(location) = tool.get("user_location").filter(|v| v.is_object()) {
        out.insert("user_location".into(), location.clone());
    }
    Value::Object(out)
}

fn tool_choice_to_codex(
    tool_choice: Option<&Value>,
    tool_name_map: &HashMap<String, String>,
    web_search_names: &HashSet<String>,
) -> Value {
    let Some(tool_choice) = tool_choice.filter(|v| !v.is_null()) else {
        return json!("auto");
    };
    let choice_type = match tool_choice.get("type").and_then(Value::as_str) {
        Some(t) if !t.is_empty() => t.to_string(),
        _ => tool_choice.as_str().unwrap_or("").to_string(),
    };
    match choice_type.as_str() {
        "auto" | "" => json!("auto"),
        "any" => json!("required"),
        "none" => json!("none"),
        "tool" => {
            let name = tool_choice
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("");
            if web_search_names.contains(name) {
                return json!({"type": "web_search"});
            }
            let mapped = map_name(tool_name_map, name);
            if mapped.is_empty() {
                return json!("auto");
            }
            json!({"type": "function", "name": mapped})
        }
        _ => json!("auto"),
    }
}

fn normalize_tool_parameters(schema: Option<&Value>) -> Value {
    let Some(schema) = schema.filter(|s| !s.is_null()) else {
        return json!({"type": "object", "properties": {}});
    };
    let mut out = match schema.as_object() {
        Some(map) => map.clone(),
        None => return json!({"type": "object", "properties": {}}),
    };
    let schema_type = out
        .get("type")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let schema_type = if schema_type.is_empty() {
        out.insert("type".into(), json!("object"));
        "object".to_string()
    } else {
        schema_type
    };
    if schema_type == "object" && !out.contains_key("properties") {
        out.insert("properties".into(), json!({}));
    }
    Value::Object(out)
}

fn normalize_service_tier(value: Option<&Value>) -> String {
    let Some(text) = value.and_then(Value::as_str) else {
        return String::new();
    };
    match text.trim().to_ascii_lowercase().as_str() {
        "fast" | "priority" => "priority".to_string(),
        _ => String::new(),
    }
}

fn target_accepts_grok_signature(model_name: &str) -> bool {
    model_name.trim().to_ascii_lowercase().contains("grok")
}

fn message_system_reminder_text(content: Option<&Value>) -> Option<String> {
    let content = content?;
    let mut parts: Vec<&str> = Vec::new();
    if let Some(text) = content.as_str() {
        if text.is_empty() {
            return None;
        }
        parts.push(text);
    } else if let Some(items) = content.as_array() {
        for item in items {
            if item.get("type").and_then(Value::as_str) != Some("text") {
                continue;
            }
            if let Some(text) = item.get("text").and_then(Value::as_str) {
                if !text.is_empty() {
                    parts.push(text);
                }
            }
        }
    } else {
        return None;
    }
    let text = parts.join("\n");
    if text.trim().is_empty() {
        return None;
    }
    Some(format!("<system-reminder>\n{text}\n</system-reminder>"))
}

fn data_url(source: &Value, default_media_type: &str) -> Option<String> {
    let data = source
        .get("data")
        .and_then(Value::as_str)
        .filter(|d| !d.is_empty())
        .or_else(|| source.get("base64").and_then(Value::as_str))
        .filter(|d| !d.is_empty())?;
    let media_type = source
        .get("media_type")
        .and_then(Value::as_str)
        .filter(|m| !m.is_empty())
        .or_else(|| source.get("mime_type").and_then(Value::as_str))
        .filter(|m| !m.is_empty())
        .unwrap_or(default_media_type);
    Some(format!("data:{media_type};base64,{data}"))
}

pub fn messages_to_responses_request(
    req: &Value,
    model_name: &str,
    preserve_empty_thinking_blocks: bool,
) -> Value {
    let tool_name_map = build_short_name_map(&tool_names(req));
    let mut input_items: Vec<Value> = Vec::new();

    if let Some(system) = req.get("system") {
        let mut content_items: Vec<Value> = Vec::new();
        let append_system_text = |text: &str, items: &mut Vec<Value>| {
            if text.is_empty() {
                return;
            }
            items.push(json!({"type": "input_text", "text": text}));
        };
        if let Some(text) = system.as_str() {
            append_system_text(text, &mut content_items);
        } else if let Some(parts) = system.as_array() {
            for part in parts {
                if part.get("type").and_then(Value::as_str) == Some("text") {
                    let text = part.get("text").and_then(Value::as_str).unwrap_or("");
                    append_system_text(text, &mut content_items);
                }
            }
        }
        if !content_items.is_empty() {
            input_items.push(json!({
                "type": "message",
                "role": "developer",
                "content": content_items,
            }));
        }
    }

    if let Some(messages) = req.get("messages").and_then(Value::as_array) {
        for message in messages {
            let role = message.get("role").and_then(Value::as_str).unwrap_or("");
            if role == "system" {
                if let Some(reminder) = message_system_reminder_text(message.get("content")) {
                    input_items.push(json!({
                        "type": "message",
                        "role": "user",
                        "content": [{"type": "input_text", "text": reminder}],
                    }));
                }
                continue;
            }

            let mut content_items: Vec<Value> = Vec::new();
            let text_part_type = if role == "assistant" {
                "output_text"
            } else {
                "input_text"
            };

            macro_rules! flush_message {
                () => {
                    if !content_items.is_empty() {
                        input_items.push(json!({
                            "type": "message",
                            "role": role,
                            "content": std::mem::take(&mut content_items),
                        }));
                    }
                };
            }

            match message.get("content") {
                Some(Value::Array(parts)) => {
                    for part in parts {
                        match part.get("type").and_then(Value::as_str).unwrap_or("") {
                            "text" => {
                                content_items.push(json!({
                                    "type": text_part_type,
                                    "text": part.get("text").and_then(Value::as_str).unwrap_or(""),
                                }));
                            }
                            "thinking" => {
                                if role != "assistant" {
                                    continue;
                                }
                                let raw_signature =
                                    part.get("signature").and_then(Value::as_str).unwrap_or("");

                                let payload =
                                    signature_payload_without_provider_prefix(raw_signature);
                                let signature = if is_valid_gpt_reasoning_signature(payload) {
                                    Some(payload.to_string())
                                } else if preserve_empty_thinking_blocks
                                    && raw_signature.trim().is_empty()
                                {
                                    Some(raw_signature.to_string())
                                } else if target_accepts_grok_signature(model_name)
                                    && !raw_signature.trim().is_empty()
                                {
                                    Some(raw_signature.to_string())
                                } else {
                                    None
                                };
                                let Some(signature) = signature else { continue };
                                flush_message!();
                                input_items.push(json!({
                                    "type": "reasoning",
                                    "summary": [],
                                    "content": null,
                                    "encrypted_content": signature,
                                }));
                            }
                            "image" => {
                                if let Some(source) = part.get("source") {
                                    if let Some(url) = data_url(source, "application/octet-stream")
                                    {
                                        content_items
                                            .push(json!({"type": "input_image", "image_url": url}));
                                    }
                                }
                            }
                            "document" => {
                                let Some(source) = part.get("source") else {
                                    continue;
                                };
                                if source.get("type").and_then(Value::as_str) != Some("base64") {
                                    continue;
                                }
                                let media_type = source
                                    .get("media_type")
                                    .and_then(Value::as_str)
                                    .unwrap_or("")
                                    .trim();
                                if !media_type.eq_ignore_ascii_case("application/pdf") {
                                    continue;
                                }
                                if let Some(url) = data_url(source, media_type) {
                                    content_items.push(json!({
                                        "type": "input_file",
                                        "file_data": url,
                                        "filename": "document.pdf",
                                    }));
                                }
                            }
                            "tool_use" => {
                                flush_message!();
                                let name = map_name(
                                    &tool_name_map,
                                    part.get("name").and_then(Value::as_str).unwrap_or(""),
                                );
                                let arguments = part
                                    .get("input")
                                    .map(|v| serde_json::to_string(v).unwrap_or_default())
                                    .unwrap_or_default();
                                input_items.push(json!({
                                    "type": "function_call",
                                    "call_id": shorten_call_id_if_needed(
                                        part.get("id").and_then(Value::as_str).unwrap_or("")
                                    ),
                                    "name": name,
                                    "arguments": arguments,
                                }));
                            }
                            "tool_result" => {
                                flush_message!();
                                let call_id = shorten_call_id_if_needed(
                                    part.get("tool_use_id")
                                        .and_then(Value::as_str)
                                        .unwrap_or(""),
                                );
                                let mut output: Option<Value> = None;
                                if let Some(parts) = part.get("content").and_then(Value::as_array) {
                                    let mut items: Vec<Value> = Vec::new();
                                    for item in parts {
                                        match item.get("type").and_then(Value::as_str).unwrap_or("")
                                        {
                                            "image" => {
                                                if let Some(source) = item.get("source") {
                                                    if let Some(url) =
                                                        data_url(source, "application/octet-stream")
                                                    {
                                                        items.push(json!({
                                                            "type": "input_image",
                                                            "image_url": url,
                                                        }));
                                                    }
                                                }
                                            }
                                            "text" => items.push(json!({
                                                "type": "input_text",
                                                "text": item
                                                    .get("text")
                                                    .and_then(Value::as_str)
                                                    .unwrap_or(""),
                                            })),
                                            _ => {}
                                        }
                                    }
                                    if !items.is_empty() {
                                        output = Some(Value::Array(items));
                                    }
                                }

                                let output = output.unwrap_or_else(|| {
                                    json!(match part.get("content") {
                                        Some(Value::String(s)) => s.clone(),
                                        Some(other) =>
                                            serde_json::to_string(other).unwrap_or_default(),
                                        None => String::new(),
                                    })
                                });
                                input_items.push(json!({
                                    "type": "function_call_output",
                                    "call_id": call_id,
                                    "output": output,
                                }));
                            }
                            _ => {}
                        }
                    }
                    flush_message!();
                }
                Some(Value::String(text)) => {
                    content_items.push(json!({"type": text_part_type, "text": text}));
                    flush_message!();
                }
                _ => {}
            }
        }
    }

    let mut out = Map::new();
    out.insert("model".into(), json!(model_name));
    out.insert("instructions".into(), json!(""));
    out.insert("input".into(), json!([]));

    let tools_value = req.get("tools").filter(|t| t.is_array());
    let mut tool_items: Vec<Value> = Vec::new();
    if let Some(tools) = tools_value.and_then(Value::as_array) {
        let web_search_names = web_search_tool_names(tools_value);
        out.insert(
            "tool_choice".into(),
            tool_choice_to_codex(req.get("tool_choice"), &tool_name_map, &web_search_names),
        );
        for tool in tools {
            if is_claude_web_search_tool_type(
                tool.get("type").and_then(Value::as_str).unwrap_or(""),
            ) {
                tool_items.push(web_search_tool_to_codex(tool));
                continue;
            }
            let mut item = match tool.as_object() {
                Some(map) => map.clone(),
                None => continue,
            };
            item.insert("type".into(), json!("function"));
            if let Some(name) = tool.get("name").and_then(Value::as_str) {
                item.insert("name".into(), json!(map_name(&tool_name_map, name)));
            }
            item.insert(
                "parameters".into(),
                normalize_tool_parameters(tool.get("input_schema")),
            );
            item.remove("input_schema");
            item.remove("cache_control");
            item.remove("defer_loading");
            if let Some(Value::Object(params)) = item.get_mut("parameters") {
                params.remove("$schema");
            }
            item.insert("strict".into(), Value::Bool(false));
            tool_items.push(Value::Object(item));
        }
    }

    let parallel_tool_calls = req
        .pointer("/tool_choice/disable_parallel_tool_use")
        .and_then(Value::as_bool)
        .map(|disabled| !disabled)
        .unwrap_or(true);
    out.insert("parallel_tool_calls".into(), json!(parallel_tool_calls));

    let mut reasoning_effort = "medium".to_string();
    if let Some(thinking) = req.get("thinking").filter(|t| t.is_object()) {
        match thinking.get("type").and_then(Value::as_str).unwrap_or("") {
            "enabled" => {
                if let Some(budget) = thinking.get("budget_tokens").and_then(Value::as_i64) {
                    let effort = budget_to_effort(budget);
                    if !effort.is_empty() {
                        reasoning_effort = effort;
                    }
                }
            }
            "adaptive" | "auto" => {
                let effort = req
                    .pointer("/output_config/effort")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_ascii_lowercase();
                reasoning_effort = if effort.is_empty() {
                    "xhigh".to_string()
                } else {
                    effort
                };
            }
            "disabled" => {
                let effort = budget_to_effort(0);
                if !effort.is_empty() {
                    reasoning_effort = effort;
                }
            }
            _ => {}
        }
    }
    out.insert("reasoning".into(), json!({"effort": reasoning_effort}));

    let mut service_tier = normalize_service_tier(req.get("service_tier"));
    if req.get("speed").and_then(Value::as_str) == Some("fast") {
        service_tier = "priority".to_string();
    }
    if !service_tier.is_empty() {
        out.insert("service_tier".into(), json!(service_tier));
    }

    out.insert("stream".into(), Value::Bool(true));
    out.insert("store".into(), Value::Bool(false));
    out.insert("include".into(), json!(["reasoning.encrypted_content"]));
    if tools_value.is_some() {
        out.insert("tools".into(), Value::Array(tool_items));
    }
    out.insert("input".into(), Value::Array(input_items));

    Value::Object(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn gpt_signature() -> String {
        use base64::engine::general_purpose::URL_SAFE_NO_PAD;
        use base64::Engine;
        let mut raw = vec![0u8; 1 + 8 + 16 + 16 + 32];
        raw[0] = 0x80;
        for (index, byte) in raw.iter_mut().enumerate().skip(1) {
            *byte = index as u8;
        }
        format!("gAAAA{}", &URL_SAFE_NO_PAD.encode(&raw)[5..])
    }

    #[test]
    fn system_becomes_a_developer_message() {
        let req = json!({"system": "be brief", "messages": []});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"][0]["role"], "developer");
        assert_eq!(out["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(out["input"][0]["content"][0]["text"], "be brief");
    }

    #[test]
    fn assistant_text_uses_output_text() {
        let req = json!({"messages": [
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "hello"}
        ]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(out["input"][1]["content"][0]["type"], "output_text");
    }

    #[test]
    fn a_signed_thinking_block_becomes_a_reasoning_item() {
        let sig = gpt_signature();
        let req = json!({"messages": [{"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm", "signature": sig}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"][0]["type"], "reasoning");
        assert_eq!(out["input"][0]["encrypted_content"], sig);
    }

    #[test]
    fn an_unsigned_thinking_block_is_dropped_by_default() {
        let req = json!({"messages": [{"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm"}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn compat_mode_preserves_an_unsigned_thinking_block() {
        let req = json!({"messages": [{"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm", "signature": ""}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", true);
        assert_eq!(out["input"][0]["type"], "reasoning");
        assert_eq!(out["input"][0]["encrypted_content"], "");
    }

    #[test]
    fn a_grok_target_accepts_its_own_signature() {
        let req = json!({"messages": [{"role": "assistant", "content": [
            {"type": "thinking", "thinking": "hmm", "signature": "grok-native-blob"}
        ]}]});
        let out = messages_to_responses_request(&req, "grok-4-fast", false);
        assert_eq!(out["input"][0]["encrypted_content"], "grok-native-blob");

        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn tool_use_and_tool_result_become_codex_items() {
        let req = json!({"messages": [
            {"role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_1", "name": "get_weather",
                 "input": {"city": "NYC"}}
            ]},
            {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_1",
                 "content": [{"type": "text", "text": "sunny"}]}
            ]}
        ]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"][0]["type"], "function_call");
        assert_eq!(out["input"][0]["call_id"], "toolu_1");
        assert_eq!(out["input"][0]["name"], "get_weather");
        assert_eq!(out["input"][0]["arguments"], "{\"city\":\"NYC\"}");
        assert_eq!(out["input"][1]["type"], "function_call_output");
        assert_eq!(out["input"][1]["call_id"], "toolu_1");
        assert_eq!(out["input"][1]["output"][0]["type"], "input_text");
        assert_eq!(out["input"][1]["output"][0]["text"], "sunny");
    }

    #[test]
    fn images_and_pdfs_convert_to_data_urls() {
        let req = json!({"messages": [{"role": "user", "content": [
            {"type": "image", "source": {"type": "base64", "media_type": "image/png",
                                         "data": "AAA"}},
            {"type": "document", "source": {"type": "base64",
                                            "media_type": "application/pdf", "data": "BBB"}}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        let parts = out["input"][0]["content"].as_array().unwrap();
        assert_eq!(parts[0]["type"], "input_image");
        assert_eq!(parts[0]["image_url"], "data:image/png;base64,AAA");
        assert_eq!(parts[1]["type"], "input_file");
        assert_eq!(parts[1]["file_data"], "data:application/pdf;base64,BBB");
        assert_eq!(parts[1]["filename"], "document.pdf");
    }

    #[test]
    fn non_pdf_documents_are_skipped() {
        let req = json!({"messages": [{"role": "user", "content": [
            {"type": "document", "source": {"type": "base64",
                                            "media_type": "text/plain", "data": "BBB"}}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn tools_get_parameters_and_strict_false() {
        let req = json!({"messages": [], "tools": [
            {"name": "read_file", "description": "Read",
             "input_schema": {"type": "object", "properties": {"p": {"type": "string"}},
                              "$schema": "http://json-schema.org/draft-07/schema#"},
             "cache_control": {"type": "ephemeral"}}
        ]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        let tool = &out["tools"][0];
        assert_eq!(tool["type"], "function");
        assert_eq!(tool["name"], "read_file");
        assert_eq!(tool["parameters"]["type"], "object");
        assert!(tool["parameters"].get("$schema").is_none());
        assert!(tool.get("input_schema").is_none());
        assert!(tool.get("cache_control").is_none());
        assert_eq!(tool["strict"], false);
    }

    #[test]
    fn a_missing_schema_becomes_an_empty_object_schema() {
        let req = json!({"messages": [], "tools": [{"name": "f"}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(
            out["tools"][0]["parameters"],
            json!({"type": "object", "properties": {}})
        );
    }

    #[test]
    fn claude_web_search_tools_become_codex_web_search() {
        let req = json!({"messages": [], "tools": [
            {"type": "web_search_20250305", "name": "web_search",
             "allowed_domains": ["example.com"],
             "user_location": {"type": "approximate", "city": "NYC"}}
        ]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["tools"][0]["type"], "web_search");
        assert_eq!(
            out["tools"][0]["filters"]["allowed_domains"][0],
            "example.com"
        );
        assert_eq!(out["tools"][0]["user_location"]["city"], "NYC");
    }

    #[test]
    fn tool_choice_maps_to_codex_forms() {
        let base = json!({"messages": [], "tools": [{"name": "f"}]});
        let with = |choice: Value| {
            let mut req = base.clone();
            req["tool_choice"] = choice;
            messages_to_responses_request(&req, "gpt-5", false)["tool_choice"].clone()
        };
        assert_eq!(with(json!({"type": "auto"})), json!("auto"));
        assert_eq!(with(json!({"type": "any"})), json!("required"));
        assert_eq!(with(json!({"type": "none"})), json!("none"));
        assert_eq!(
            with(json!({"type": "tool", "name": "f"})),
            json!({"type": "function", "name": "f"})
        );

        let out = messages_to_responses_request(&base, "gpt-5", false);
        assert_eq!(out["tool_choice"], json!("auto"));
    }

    #[test]
    fn tool_choice_for_a_web_search_tool_selects_web_search() {
        let req = json!({"messages": [],
                         "tools": [{"type": "web_search_20250305", "name": "ws"}],
                         "tool_choice": {"type": "tool", "name": "ws"}});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["tool_choice"], json!({"type": "web_search"}));
    }

    #[test]
    fn disable_parallel_tool_use_is_honored() {
        let req = json!({"messages": [], "tool_choice": {"type": "auto",
                                                         "disable_parallel_tool_use": true}});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["parallel_tool_calls"], false);
    }

    #[test]
    fn thinking_budget_becomes_reasoning_effort() {
        let req = json!({"messages": [],
                         "thinking": {"type": "enabled", "budget_tokens": 1024}});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["reasoning"]["effort"], "low");

        let out = messages_to_responses_request(&json!({"messages": []}), "gpt-5", false);
        assert_eq!(out["reasoning"]["effort"], "medium");
    }

    #[test]
    fn adaptive_thinking_uses_output_config_effort_or_xhigh() {
        let req = json!({"messages": [], "thinking": {"type": "adaptive"},
                         "output_config": {"effort": "HIGH"}});
        assert_eq!(
            messages_to_responses_request(&req, "gpt-5", false)["reasoning"]["effort"],
            "high"
        );
        let req = json!({"messages": [], "thinking": {"type": "adaptive"}});
        assert_eq!(
            messages_to_responses_request(&req, "gpt-5", false)["reasoning"]["effort"],
            "xhigh"
        );
    }

    #[test]
    fn service_tier_and_speed_map_to_priority() {
        let req = json!({"messages": [], "service_tier": "fast"});
        assert_eq!(
            messages_to_responses_request(&req, "gpt-5", false)["service_tier"],
            "priority"
        );
        let req = json!({"messages": [], "speed": "fast"});
        assert_eq!(
            messages_to_responses_request(&req, "gpt-5", false)["service_tier"],
            "priority"
        );

        let req = json!({"messages": [], "service_tier": "default"});
        assert!(messages_to_responses_request(&req, "gpt-5", false)
            .get("service_tier")
            .is_none());
    }

    #[test]
    fn the_codex_envelope_fields_are_forced() {
        let out = messages_to_responses_request(&json!({"messages": []}), "gpt-5", false);
        assert_eq!(out["stream"], true);
        assert_eq!(out["store"], false);
        assert_eq!(out["include"], json!(["reasoning.encrypted_content"]));
        assert_eq!(out["model"], "gpt-5");
        assert_eq!(out["instructions"], "");
    }

    #[test]
    fn long_tool_names_are_shortened_consistently_in_calls_and_declarations() {
        let long = format!("mcp__{}__leaf", "z".repeat(80));
        let req = json!({
            "messages": [{"role": "assistant", "content": [
                {"type": "tool_use", "id": "t1", "name": long, "input": {}}
            ]}],
            "tools": [{"name": long, "input_schema": {"type": "object"}}]
        });
        let out = messages_to_responses_request(&req, "gpt-5", false);
        let declared = out["tools"][0]["name"].as_str().unwrap();
        let called = out["input"][0]["name"].as_str().unwrap();
        assert_eq!(declared, called);
        assert!(declared.len() <= 64);
    }

    #[test]
    fn long_call_ids_are_shortened() {
        let long_id = "t".repeat(100);
        let req = json!({"messages": [{"role": "assistant", "content": [
            {"type": "tool_use", "id": long_id, "name": "f", "input": {}}
        ]}]});
        let out = messages_to_responses_request(&req, "gpt-5", false);
        assert_eq!(out["input"][0]["call_id"].as_str().unwrap().len(), 64);
    }
}
