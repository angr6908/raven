use std::collections::HashSet;

use serde_json::{json, Value};

#[derive(Debug, Clone)]
pub struct ResponsesToolDeclaration<'a> {
    pub tool: &'a Value,
    pub chat_name: String,
    pub local_name: String,
    pub namespace: String,
    pub custom: bool,
}

pub fn walk_tool_declarations<'a, F>(root: &'a Value, mut visit: F)
where
    F: FnMut(ResponsesToolDeclaration<'a>) -> bool,
{
    let mut proceed = true;

    fn declaration<'a>(tool: &'a Value, namespace: &str) -> Option<ResponsesToolDeclaration<'a>> {
        let custom = match tool
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("")
            .trim()
        {
            "" | "function" => false,
            "custom" => true,
            _ => return None,
        };
        let local_name = responses_tool_name(tool);
        if local_name.is_empty() {
            return None;
        }
        Some(ResponsesToolDeclaration {
            tool,
            chat_name: qualify_responses_namespace_tool_name(namespace, &local_name),
            local_name,
            namespace: namespace.to_string(),
            custom,
        })
    }

    let scan = |tools: Option<&'a Value>, proceed: &mut bool, visit: &mut F| {
        if !*proceed {
            return;
        }
        let Some(tools) = tools.and_then(Value::as_array) else {
            return;
        };
        for tool in tools {
            if !*proceed {
                return;
            }
            if tool
                .get("type")
                .and_then(Value::as_str)
                .unwrap_or("")
                .trim()
                == "namespace"
            {
                if let Some(children) = tool.get("tools").and_then(Value::as_array) {
                    let namespace = tool
                        .get("name")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .trim()
                        .to_string();
                    for child in children {
                        if !*proceed {
                            return;
                        }
                        if let Some(decl) = declaration(child, &namespace) {
                            *proceed = visit(decl);
                        }
                    }
                }
                continue;
            }
            if let Some(decl) = declaration(tool, "") {
                *proceed = visit(decl);
            }
        }
    };

    scan(root.get("tools"), &mut proceed, &mut visit);
    if let Some(input) = root.get("input").and_then(Value::as_array) {
        for item in input {
            if !proceed {
                break;
            }
            if item.get("type").and_then(Value::as_str) == Some("additional_tools") {
                scan(item.get("tools"), &mut proceed, &mut visit);
            }
        }
    }
}

pub fn responses_request_chat_tools(root: &Value) -> Vec<Value> {
    let mut merged = Vec::new();
    let mut seen: HashSet<String> = HashSet::new();
    walk_tool_declarations(root, |declaration| {
        if seen.contains(&declaration.chat_name) {
            return true;
        }
        let converted = if declaration.custom {
            responses_custom_tool_to_chat(declaration.tool, &declaration.chat_name)
        } else {
            responses_function_tool_to_chat(declaration.tool, &declaration.chat_name)
        };
        if let Some(chat_tool) = converted {
            seen.insert(declaration.chat_name.clone());
            merged.push(chat_tool);
        }
        true
    });
    merged
}

pub fn responses_function_tool_to_chat(
    tool: &Value,
    override_name: &str,
) -> Option<Value> {
    let mut name = override_name.trim().to_string();
    if name.is_empty() {
        name = responses_tool_name(tool);
    }
    if name.is_empty() {
        return None;
    }
    let mut chat_tool = json!({
        "type": "function",
        "function": {"name": name, "description": "", "parameters": {}},
    });
    let description = responses_tool_description(tool);
    if !description.is_empty() {
        chat_tool["function"]["description"] = json!(description);
    }
    if let Some(parameters) = responses_tool_parameters(tool) {
        chat_tool["function"]["parameters"] = parameters.clone();
    }
    Some(chat_tool)
}

pub fn responses_custom_tool_to_chat(
    tool: &Value,
    override_name: &str,
) -> Option<Value> {
    let mut name = override_name.trim().to_string();
    if name.is_empty() {
        name = responses_tool_name(tool);
    }
    if name.is_empty() {
        return None;
    }
    let mut chat_tool = json!({
        "type": "function",
        "function": {
            "name": name,
            "description": "",
            "parameters": {
                "type": "object",
                "properties": {"input": {"type": "string"}},
                "required": ["input"],
            },
        },
    });
    let description = responses_tool_description(tool);
    if !description.is_empty() {
        chat_tool["function"]["description"] = json!(description);
    }
    Some(chat_tool)
}

pub fn responses_tool_name(tool: &Value) -> String {
    let direct = tool
        .get("name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim();
    if !direct.is_empty() {
        return direct.to_string();
    }
    tool.pointer("/function/name")
        .and_then(Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string()
}

pub fn responses_tool_description(tool: &Value) -> String {
    if let Some(description) = tool.get("description").and_then(Value::as_str) {
        if !description.is_empty() {
            return description.to_string();
        }
    }
    tool.pointer("/function/description")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string()
}

pub fn responses_tool_parameters(tool: &Value) -> Option<&Value> {
    for path in [
        "/parameters",
        "/parametersJsonSchema",
        "/input_schema",
        "/function/parameters",
        "/function/parametersJsonSchema",
    ] {
        if let Some(parameters) = tool.pointer(path) {
            return Some(parameters);
        }
    }
    None
}

pub fn qualify_responses_namespace_tool_name(namespace: &str, child_name: &str) -> String {
    let child_name = child_name.trim();
    if child_name.is_empty() || namespace.is_empty() || child_name.starts_with("mcp__") {
        return child_name.to_string();
    }
    if child_name.starts_with(namespace) {
        return child_name.to_string();
    }
    if namespace.ends_with("__") {
        return format!("{namespace}{child_name}");
    }
    format!("{namespace}__{child_name}")
}

pub fn responses_custom_tool_names(request: &Value) -> HashSet<String> {
    let mut names = HashSet::new();
    let mut seen: HashSet<String> = HashSet::new();
    walk_tool_declarations(request, |declaration| {
        if seen.contains(&declaration.chat_name) {
            return true;
        }
        seen.insert(declaration.chat_name.clone());
        if declaration.custom {
            names.insert(declaration.chat_name);
        }
        true
    });
    names
}

pub fn responses_single_custom_tool_name(request: &Value) -> Option<(String, bool)> {
    let custom = responses_custom_tool_names(request);
    if custom.len() != 1 {
        return None;
    }
    let tool_count = responses_request_chat_tools(request).len();
    custom
        .into_iter()
        .next()
        .map(|name| (name, tool_count == 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merges_top_level_and_additional_tools_first_wins() {
        let root = json!({
            "tools": [{"type": "function", "name": "read_file", "description": "top",
                       "parameters": {"type": "object"}}],
            "input": [
                {"type": "additional_tools", "tools": [
                    {"type": "function", "name": "read_file", "description": "dup"},
                    {"type": "function", "name": "write_file", "parameters": {"type": "object"}},
                ]},
            ],
        });
        let merged = responses_request_chat_tools(&root);
        assert_eq!(merged.len(), 2);
        assert_eq!(merged[0]["function"]["name"], "read_file");
        assert_eq!(merged[0]["function"]["description"], "top");
        assert_eq!(merged[1]["function"]["name"], "write_file");
    }

    #[test]
    fn custom_tool_becomes_a_freeform_input_function() {
        let root = json!({"tools": [
            {"type": "custom", "name": "apply_patch", "description": "patch",
             "format": {"type": "grammar"}},
        ]});
        let merged = responses_request_chat_tools(&root);
        assert_eq!(merged.len(), 1);
        assert_eq!(
            merged[0]["function"]["parameters"],
            json!({"type": "object", "properties": {"input": {"type": "string"}},
                   "required": ["input"]})
        );
        assert_eq!(merged[0]["function"]["description"], "patch");
    }

    #[test]
    fn namespace_children_are_qualified() {
        let root = json!({"tools": [
            {"type": "namespace", "name": "editor", "tools": [
                {"type": "function", "name": "apply_patch"},
                {"type": "function", "name": "editor__already"},
                {"type": "function", "name": "mcp__keep"},
            ]},
        ]});
        let merged = responses_request_chat_tools(&root);
        let names: Vec<&str> = merged
            .iter()
            .map(|tool| tool["function"]["name"].as_str().unwrap())
            .collect();
        assert_eq!(
            names,
            vec!["editor__apply_patch", "editor__already", "mcp__keep"]
        );
    }

    #[test]
    fn unknown_tool_types_are_skipped() {
        let root = json!({"tools": [
            {"type": "web_search"},
            {"type": "function", "name": "f"},
        ]});
        let merged = responses_request_chat_tools(&root);
        assert_eq!(merged.len(), 1);
        assert_eq!(merged[0]["function"]["name"], "f");
    }

    #[test]
    fn nested_chat_shape_and_alternate_schema_keys_are_accepted() {
        let root = json!({"tools": [
            {"type": "function", "function": {"name": "nested", "description": "d",
                                              "parametersJsonSchema": {"type": "object"}}},
            {"type": "function", "name": "schema", "input_schema": {"type": "object"}},
        ]});
        let merged = responses_request_chat_tools(&root);
        assert_eq!(merged[0]["function"]["name"], "nested");
        assert_eq!(merged[0]["function"]["description"], "d");
        assert_eq!(
            merged[0]["function"]["parameters"],
            json!({"type": "object"})
        );
        assert_eq!(
            merged[1]["function"]["parameters"],
            json!({"type": "object"})
        );
    }

    #[test]
    fn single_custom_tool_detection_dedupes_by_name() {
        let root = json!({
            "tools": [{"type": "custom", "name": "apply_patch"}],
            "input": [{"type": "additional_tools", "tools": [
                {"type": "custom", "name": "apply_patch"},
            ]}],
        });
        assert_eq!(
            responses_single_custom_tool_name(&root),
            Some(("apply_patch".to_string(), true))
        );
        let two = json!({"tools": [
            {"type": "custom", "name": "apply_patch"},
            {"type": "function", "name": "read_file"},
        ]});
        assert_eq!(
            responses_single_custom_tool_name(&two),
            Some(("apply_patch".to_string(), false))
        );
    }
}

pub fn resolve_responses_qualified_tool_identity(
    root: &Value,
    qualified_name: &str,
) -> Option<(String, String)> {
    let mut found: Option<(String, String)> = None;
    walk_tool_declarations(root, |declaration| {
        if declaration.chat_name != qualified_name {
            return true;
        }
        found = Some((
            declaration.local_name.clone(),
            declaration.namespace.clone(),
        ));
        false
    });
    found
}

pub fn split_responses_qualified_function_call_from_request(
    request: &Value,
    qualified_name: &str,
) -> (String, String) {
    let qualified_name = qualified_name.trim();
    if qualified_name.is_empty() {
        return (String::new(), String::new());
    }
    resolve_responses_qualified_tool_identity(request, qualified_name)
        .unwrap_or_else(|| (qualified_name.to_string(), String::new()))
}

#[cfg(test)]
mod identity_tests {
    use super::*;

    #[test]
    fn namespace_children_resolve_back_to_their_parts() {
        let root = json!({"tools": [
            {"type": "namespace", "name": "mcp__node_repl", "tools": [
                {"type": "function", "name": "js"},
            ]},
            {"type": "function", "name": "read_file"},
        ]});
        assert_eq!(
            split_responses_qualified_function_call_from_request(&root, "mcp__node_repl__js"),
            ("js".to_string(), "mcp__node_repl".to_string())
        );
        assert_eq!(
            split_responses_qualified_function_call_from_request(&root, "read_file"),
            ("read_file".to_string(), String::new())
        );
        assert_eq!(
            split_responses_qualified_function_call_from_request(&root, "unknown__tool"),
            ("unknown__tool".to_string(), String::new())
        );
    }

    #[test]
    fn a_flat_tool_wins_over_a_later_namespace_child() {
        let root = json!({"tools": [
            {"type": "function", "name": "editor__apply_patch"},
            {"type": "namespace", "name": "editor", "tools": [
                {"type": "function", "name": "apply_patch"},
            ]},
        ]});
        assert_eq!(
            split_responses_qualified_function_call_from_request(&root, "editor__apply_patch"),
            ("editor__apply_patch".to_string(), String::new())
        );
    }
}

pub fn set_responses_tool_call_identity(
    item: &mut Value,
    name: &str,
    namespace: &str,
    item_path: &str,
) {
    let target = if item_path.is_empty() {
        Some(item)
    } else {
        item.get_mut(item_path)
    };
    let Some(Value::Object(map)) = target else {
        return;
    };
    map.insert("name".into(), Value::String(name.to_string()));
    if namespace.is_empty() {
        map.remove("namespace");
    } else {
        map.insert("namespace".into(), Value::String(namespace.to_string()));
    }
}

pub fn request_model_name(original_request: &Value, upstream_request: &Value) -> String {
    for raw in [original_request, upstream_request] {
        for path in ["/model", "/request/model"] {
            if let Some(model) = raw.pointer(path).and_then(Value::as_str) {
                if !model.trim().is_empty() {
                    return model.to_string();
                }
            }
        }
    }
    String::new()
}
