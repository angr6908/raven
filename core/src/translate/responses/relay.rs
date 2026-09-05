use serde_json::{json, Value};

fn sanitize_reasoning_encrypted_content(req: &mut Value) {
    let store_true = req.get("store").and_then(Value::as_bool).unwrap_or(false);
    let Some(input) = req.get_mut("input").and_then(Value::as_array_mut) else {
        return;
    };
    for item in input.iter_mut() {
        if item.get("type").and_then(Value::as_str) != Some("reasoning") {
            continue;
        }
        let Some(map) = item.as_object_mut() else {
            continue;
        };
        let invalid = match map.get("encrypted_content") {
            None => false,
            Some(Value::String(text)) => {
                text.is_empty() || text.trim() != text
            }
            Some(_) => true,
        };
        if invalid {
            map.remove("encrypted_content");
        }
        if !store_true && !map.contains_key("encrypted_content") {
            map.remove("id");
        }
    }
}

pub fn shape_for_codex(req: &mut Value) {
    if let Some(text) = req.get("input").and_then(Value::as_str) {
        let text = text.to_string();
        req["input"] = json!([{
            "type": "message",
            "role": "user",
            "content": [{"type": "input_text", "text": text}],
        }]);
    }

    let instructions_missing = match req.get("instructions") {
        None => true,
        Some(Value::Null) => true,
        Some(_) => false,
    };
    if instructions_missing {
        req["instructions"] = json!("");
    }

    if let Some(map) = req.as_object_mut() {
        for field in [
            "prompt_cache_retention",
            "prompt_cache_options",
            "safety_identifier",
        ] {
            map.remove(field);
        }
    }

    let has_tools = req
        .get("tools")
        .and_then(Value::as_array)
        .map(|tools| !tools.is_empty())
        .unwrap_or(false);
    if !has_tools {
        if let Some(map) = req.as_object_mut() {
            map.remove("parallel_tool_calls");
        }
    }

    sanitize_reasoning_encrypted_content(req);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_string_input_becomes_a_user_message() {
        let mut req = json!({"model": "gpt-5", "input": "hello"});
        shape_for_codex(&mut req);
        assert_eq!(req["input"][0]["type"], "message");
        assert_eq!(req["input"][0]["role"], "user");
        assert_eq!(req["input"][0]["content"][0]["type"], "input_text");
        assert_eq!(req["input"][0]["content"][0]["text"], "hello");
    }

    #[test]
    fn client_fields_are_preserved() {
        let mut req = json!({"input": [], "stream": false, "store": true,
                             "max_output_tokens": 100, "temperature": 0.7,
                             "top_p": 0.9, "truncation": "auto", "user": "u1",
                             "include": ["reasoning.encrypted_content"]});
        shape_for_codex(&mut req);
        assert_eq!(req["stream"], false);
        assert_eq!(req["store"], true);
        assert_eq!(req["max_output_tokens"], 100);
        assert_eq!(req["temperature"], 0.7);
        assert_eq!(req["top_p"], 0.9);
        assert_eq!(req["truncation"], "auto");
        assert_eq!(req["user"], "u1");
        assert_eq!(req["include"], json!(["reasoning.encrypted_content"]));
    }

    #[test]
    fn missing_or_null_instructions_become_an_empty_string() {
        let mut req = json!({"input": []});
        shape_for_codex(&mut req);
        assert_eq!(req["instructions"], "");

        let mut req = json!({"input": [], "instructions": null});
        shape_for_codex(&mut req);
        assert_eq!(req["instructions"], "");

        let mut req = json!({"input": [], "instructions": "be brief"});
        shape_for_codex(&mut req);
        assert_eq!(req["instructions"], "be brief");
    }

    #[test]
    fn cache_and_safety_fields_are_removed() {
        let mut req = json!({"input": [], "prompt_cache_retention": "24h",
                             "prompt_cache_options": {"a": 1}, "safety_identifier": "s"});
        shape_for_codex(&mut req);
        assert!(req.get("prompt_cache_retention").is_none());
        assert!(req.get("prompt_cache_options").is_none());
        assert!(req.get("safety_identifier").is_none());
    }

    #[test]
    fn parallel_tool_calls_without_tools_is_dropped() {
        let mut req = json!({"input": [], "parallel_tool_calls": true});
        shape_for_codex(&mut req);
        assert!(req.get("parallel_tool_calls").is_none());

        let mut req = json!({"input": [], "parallel_tool_calls": true,
                             "tools": [{"type": "function", "name": "f"}]});
        shape_for_codex(&mut req);
        assert_eq!(req["parallel_tool_calls"], true);
    }

    #[test]
    fn reasoning_items_keep_valid_encrypted_content() {
        let mut req = json!({"input": [{
            "type": "reasoning", "id": "rs_1", "encrypted_content": "opaque-payload",
            "summary": []
        }]});
        shape_for_codex(&mut req);
        assert_eq!(req["input"][0]["encrypted_content"], "opaque-payload");
        assert_eq!(req["input"][0]["id"], "rs_1");
    }

    #[test]
    fn invalid_encrypted_content_and_orphan_ids_are_dropped() {
        let mut req = json!({"input": [
            {"type": "reasoning", "id": "rs_1", "encrypted_content": "", "summary": []},
            {"type": "reasoning", "id": "rs_2", "encrypted_content": null, "summary": []},
            {"type": "reasoning", "id": "rs_3", "summary": []},
        ]});
        shape_for_codex(&mut req);
        for item in req["input"].as_array().unwrap() {
            assert!(item.get("encrypted_content").is_none());
            assert!(item.get("id").is_none());
        }
    }

    #[test]
    fn ids_survive_when_store_is_true() {
        let mut req = json!({"store": true, "input": [
            {"type": "reasoning", "id": "rs_3", "summary": []},
        ]});
        shape_for_codex(&mut req);
        assert_eq!(req["input"][0]["id"], "rs_3");
    }

    #[test]
    fn an_array_input_is_left_structurally_intact() {
        let mut req = json!({"input": [
            {"type": "function_call", "call_id": "c", "name": "f", "arguments": "{}"}
        ]});
        shape_for_codex(&mut req);
        assert_eq!(req["input"][0]["type"], "function_call");
        assert_eq!(req["input"][0]["call_id"], "c");
    }
}
