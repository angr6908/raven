use serde_json::{Map, Value};

use super::sanitize::sanitize_messages;

pub fn prepare_body_opt(src: &[u8], sanitize: bool) -> Vec<u8> {
    if src.is_empty() {
        return src.to_vec();
    }
    let mut obj: Value = match serde_json::from_slice(src) {
        Ok(value) => value,
        Err(_) => return src.to_vec(),
    };
    let Some(map) = obj.as_object_mut() else {
        return src.to_vec();
    };
    map.insert("stream".to_string(), Value::Bool(true));
    normalize_tool_choice(map);
    if sanitize {
        if let Some(messages) = map.get_mut("messages").and_then(Value::as_array_mut) {
            sanitize_messages(messages);
        }
    }
    match serde_json::to_vec(&obj) {
        Ok(out) => out,
        Err(_) => src.to_vec(),
    }
}

fn normalize_tool_choice(obj: &mut Map<String, Value>) {
    let Some(tool_choice) = obj.get("tool_choice").cloned() else {
        return;
    };
    match tool_choice {
        Value::String(s) => {
            if s.trim().eq_ignore_ascii_case("none") {
                obj.remove("tool_choice");
                obj.remove("tools");
                obj.remove("functions");
            }
        }
        Value::Object(v) => {
            let typ = v
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .trim()
                .to_ascii_lowercase();
            match typ.as_str() {
                "none" => {
                    obj.remove("tool_choice");
                    obj.remove("tools");
                    obj.remove("functions");
                }
                "auto" | "required" => {
                    obj.insert("tool_choice".to_string(), Value::String(typ));
                }
                "function" => {
                    let mut name = v
                        .get("function")
                        .and_then(Value::as_object)
                        .and_then(|f| f.get("name"))
                        .and_then(Value::as_str)
                        .unwrap_or_default()
                        .to_string();
                    if name.is_empty() {
                        name = v
                            .get("name")
                            .and_then(Value::as_str)
                            .unwrap_or_default()
                            .to_string();
                    }
                    let name = name.trim().to_string();
                    obj.insert(
                        "tool_choice".to_string(),
                        Value::String(if name.is_empty() {
                            "auto".to_string()
                        } else {
                            name
                        }),
                    );
                }
                _ => {
                    obj.remove("tool_choice");
                }
            }
        }
        _ => {
            obj.remove("tool_choice");
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn normalized(src: &str) -> serde_json::Value {
        let bytes = prepare_body_opt(src.as_bytes(), false);
        serde_json::from_slice(&bytes).unwrap()
    }

    #[test]
    fn stream_is_forced_true() {
        let v = normalized(r#"{"stream":false,"messages":[]}"#);
        assert_eq!(v["stream"], true);
    }

    #[test]
    fn none_string_removes_tools() {
        let v = normalized(r#"{"tool_choice":"none","tools":[{"type":"function"}]}"#);
        assert!(v.get("tool_choice").is_none());
        assert!(v.get("tools").is_none());
    }

    #[test]
    fn object_none_removes_tools_and_functions() {
        let v = normalized(r#"{"tool_choice":{"type":"none"},"tools":[],"functions":[]}"#);
        assert!(v.get("tool_choice").is_none());
        assert!(v.get("tools").is_none());
        assert!(v.get("functions").is_none());
    }

    #[test]
    fn auto_object_becomes_string() {
        let v = normalized(r#"{"tool_choice":{"type":"auto"}}"#);
        assert_eq!(v["tool_choice"], "auto");
    }

    #[test]
    fn required_object_becomes_string() {
        let v = normalized(r#"{"tool_choice":{"type":"required"}}"#);
        assert_eq!(v["tool_choice"], "required");
    }

    #[test]
    fn function_object_becomes_name_string() {
        let v =
            normalized(r#"{"tool_choice":{"type":"function","function":{"name":"get_weather"}}}"#);
        assert_eq!(v["tool_choice"], "get_weather");
    }

    #[test]
    fn function_object_with_empty_name_becomes_auto() {
        let v = normalized(r#"{"tool_choice":{"type":"function"}}"#);
        assert_eq!(v["tool_choice"], "auto");
    }

    #[test]
    fn unknown_object_deletes_tool_choice() {
        let v = normalized(r#"{"tool_choice":{"type":"custom"}}"#);
        assert!(v.get("tool_choice").is_none());
    }

    #[test]
    fn non_scalar_deletes_tool_choice() {
        let v = normalized(r#"{"tool_choice":[1,2]}"#);
        assert!(v.get("tool_choice").is_none());
    }

    #[test]
    fn sanitize_rewrites_fingerprinted_content() {
        let src = r#"{"messages":[{"role":"system","content":"You are Claude Code, Anthropic's official CLI for Claude."}]}"#;
        let out = prepare_body_opt(src.as_bytes(), true);
        let v: serde_json::Value = serde_json::from_slice(&out).unwrap();
        let content = v["messages"][0]["content"].as_str().unwrap();
        assert_eq!(
            content,
            "You are Claude Code, Anthropic's official CLI tool for Claude."
        );
    }
}
