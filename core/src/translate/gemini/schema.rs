use serde_json::{json, Map, Value};

const MAX_DEPTH: usize = 64;
const MAX_NODES: usize = 10_000;

const MAP_KEYWORDS: [&str; 4] = [
    "properties",
    "patternProperties",
    "dependentSchemas",
    "dependencies",
];

const VALUE_KEYWORDS: [&str; 12] = [
    "additionalItems",
    "additionalProperties",
    "contains",
    "contentSchema",
    "else",
    "if",
    "items",
    "not",
    "propertyNames",
    "then",
    "unevaluatedItems",
    "unevaluatedProperties",
];

const ARRAY_KEYWORDS: [&str; 4] = ["allOf", "anyOf", "oneOf", "prefixItems"];

const META_KEYWORDS: [&str; 8] = [
    "$schema",
    "$id",
    "$anchor",
    "$dynamicAnchor",
    "$vocabulary",
    "$comment",
    "$defs",
    "definitions",
];

const CUSTOM_TOOL_ALLOW: [&str; 6] = ["type", "description", "properties", "required", "items", "enum"];

fn is_map_keyword(key: &str) -> bool {
    MAP_KEYWORDS.contains(&key)
}

fn is_schema_keyword(key: &str) -> bool {
    VALUE_KEYWORDS.contains(&key) || ARRAY_KEYWORDS.contains(&key)
}

struct Budget {
    nodes: usize,
    failed: bool,
}

pub fn dereference(schema: &Value) -> Option<Value> {
    let mut budget = Budget {
        nodes: 0,
        failed: false,
    };
    let mut refs: Vec<String> = Vec::new();
    let out = walk(schema, schema, &mut refs, &mut budget, 0);
    (!budget.failed).then_some(out)
}

fn walk(node: &Value, root: &Value, refs: &mut Vec<String>, budget: &mut Budget, depth: usize) -> Value {
    if depth > MAX_DEPTH {
        budget.failed = true;
        return Value::Null;
    }
    budget.nodes += 1;
    if budget.nodes > MAX_NODES {
        budget.failed = true;
        return Value::Null;
    }
    match node {
        Value::Array(items) => Value::Array(
            items
                .iter()
                .map(|item| walk(item, root, refs, budget, depth + 1))
                .collect(),
        ),
        Value::Object(object) => walk_object(object, root, refs, budget, depth),
        other => other.clone(),
    }
}

fn walk_object(
    object: &Map<String, Value>,
    root: &Value,
    refs: &mut Vec<String>,
    budget: &mut Budget,
    depth: usize,
) -> Value {
    if let Some(pointer) = object.get("$ref").and_then(Value::as_str) {
        if refs.iter().any(|seen| seen == pointer) {
            budget.failed = true;
            return Value::Null;
        }
        let Some(target) = resolve_pointer(pointer, root) else {
            budget.failed = true;
            return Value::Null;
        };
        refs.push(pointer.to_string());
        let resolved = walk(&target, root, refs, budget, depth + 1);
        refs.pop();

        let mut siblings = object.clone();
        siblings.remove("$ref");
        let siblings = walk_object(&siblings, root, refs, budget, depth + 1);
        return match (resolved, siblings) {
            (Value::Object(mut base), Value::Object(extra)) => {
                base.extend(extra);
                Value::Object(base)
            }
            (resolved, _) => resolved,
        };
    }

    let mut out = Map::new();
    for (key, value) in object {
        if key == "$defs" || key == "definitions" {
            continue;
        }
        if is_map_keyword(key) {
            out.insert(key.clone(), walk_map(value, root, refs, budget, depth + 1));
        } else if is_schema_keyword(key) {
            out.insert(key.clone(), walk(value, root, refs, budget, depth + 1));
        } else {
            out.insert(key.clone(), value.clone());
        }
    }
    Value::Object(out)
}

fn walk_map(node: &Value, root: &Value, refs: &mut Vec<String>, budget: &mut Budget, depth: usize) -> Value {
    let Some(object) = node.as_object() else {
        return walk(node, root, refs, budget, depth);
    };
    let mut out = Map::new();
    for (key, value) in object {
        out.insert(key.clone(), walk(value, root, refs, budget, depth + 1));
    }
    Value::Object(out)
}

fn resolve_pointer(pointer: &str, root: &Value) -> Option<Value> {
    if pointer == "#" {
        return Some(root.clone());
    }
    let path = pointer.strip_prefix("#/")?;
    let mut current = root;
    for token in path.split('/') {
        let key = token.replace("~1", "/").replace("~0", "~");
        current = match current {
            Value::Array(items) => {
                let index: usize = key.parse().ok()?;
                items.get(index)?
            }
            Value::Object(object) => object.get(&key)?,
            _ => return None,
        };
    }
    Some(current.clone())
}

pub fn ensure_root_object(schema: Value) -> Value {
    let Value::Object(mut object) = schema else {
        return json!({"type": "object", "properties": {}});
    };
    if !object.contains_key("type") {
        object.insert("type".to_string(), json!("object"));
        object
            .entry("properties".to_string())
            .or_insert_with(|| json!({}));
    }
    Value::Object(object)
}

pub fn strip_meta(schema: &Value) -> Value {
    match schema {
        Value::Array(items) => Value::Array(items.iter().map(strip_meta).collect()),
        Value::Object(object) => {
            let mut out = Map::new();
            for (key, value) in object {
                if META_KEYWORDS.contains(&key.as_str()) {
                    continue;
                }
                if is_map_keyword(key) {
                    out.insert(key.clone(), strip_meta_map(value));
                } else if is_schema_keyword(key) {
                    out.insert(key.clone(), strip_meta(value));
                } else {
                    out.insert(key.clone(), value.clone());
                }
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn strip_meta_map(node: &Value) -> Value {
    let Some(object) = node.as_object() else {
        return strip_meta(node);
    };
    Value::Object(
        object
            .iter()
            .map(|(key, value)| (key.clone(), strip_meta(value)))
            .collect(),
    )
}

pub fn normalize_custom_tool(schema: &Value) -> Value {
    match schema {
        Value::Array(items) => Value::Array(items.iter().map(normalize_custom_tool).collect()),
        Value::Object(object) => {
            let mut out = Map::new();
            for (key, value) in object {
                if !CUSTOM_TOOL_ALLOW.contains(&key.as_str()) {
                    continue;
                }
                match key.as_str() {
                    "type" => {
                        if let Some(scalar) = scalar_type(value) {
                            out.insert("type".to_string(), Value::String(scalar));
                        }
                    }
                    "properties" => {
                        let Some(properties) = value.as_object() else {
                            continue;
                        };
                        out.insert(
                            "properties".to_string(),
                            Value::Object(
                                properties
                                    .iter()
                                    .map(|(name, schema)| {
                                        (name.clone(), normalize_custom_tool(schema))
                                    })
                                    .collect(),
                            ),
                        );
                    }
                    "enum" => {
                        let all_strings = value
                            .as_array()
                            .is_some_and(|items| items.iter().all(Value::is_string));
                        if all_strings {
                            out.insert("enum".to_string(), value.clone());
                        }
                    }
                    _ => {
                        out.insert(key.clone(), normalize_custom_tool(value));
                    }
                }
            }
            Value::Object(out)
        }
        other => other.clone(),
    }
}

fn scalar_type(value: &Value) -> Option<String> {
    if let Some(name) = value.as_str() {
        return Some(name.to_string());
    }
    value
        .as_array()?
        .iter()
        .filter_map(Value::as_str)
        .find(|name| *name != "null")
        .map(str::to_string)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_refs_are_inlined_and_definitions_dropped() {
        let schema = json!({
            "type": "object",
            "$defs": {"leaf": {"type": "string", "description": "d"}},
            "properties": {
                "a": {"$ref": "#/$defs/leaf"},
                "if": {"type": "number"},
            },
        });
        let out = dereference(&schema).expect("resolvable");
        assert_eq!(out["properties"]["a"]["type"], "string");
        assert_eq!(out["properties"]["a"]["description"], "d");
        assert_eq!(out["properties"]["if"]["type"], "number");
        assert!(out.get("$defs").is_none());
    }

    #[test]
    fn circular_and_missing_refs_are_rejected() {
        let circular = json!({"$defs": {"a": {"$ref": "#/$defs/a"}}, "properties": {"x": {"$ref": "#/$defs/a"}}});
        assert!(dereference(&circular).is_none());
        let missing = json!({"properties": {"x": {"$ref": "#/$defs/nope"}}});
        assert!(dereference(&missing).is_none());
    }

    #[test]
    fn custom_tool_schema_keeps_only_the_bridge_allowlist() {
        let schema = json!({
            "type": ["string", "null"],
            "format": "uri",
            "nullable": true,
            "description": "d",
        });
        let out = normalize_custom_tool(&schema);
        assert_eq!(out, json!({"type": "string", "description": "d"}));

        let object = json!({
            "type": "object",
            "properties": {"format": {"type": "string", "anyOf": []}},
            "required": ["format"],
        });
        let out = normalize_custom_tool(&object);
        assert_eq!(out["properties"]["format"], json!({"type": "string"}));
        assert_eq!(out["required"], json!(["format"]));
    }

    #[test]
    fn meta_keywords_are_stripped_but_property_names_survive() {
        let schema = json!({
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "properties": {"$id": {"type": "string", "$comment": "x"}},
        });
        let out = strip_meta(&schema);
        assert!(out.get("$schema").is_none());
        assert_eq!(out["properties"]["$id"]["type"], "string");
    }

    #[test]
    fn a_typeless_root_becomes_an_object() {
        assert_eq!(
            ensure_root_object(json!({"properties": {"a": {}}}))["type"],
            "object"
        );
        assert_eq!(ensure_root_object(json!(null))["type"], "object");
        assert_eq!(ensure_root_object(json!({"type": "string"}))["type"], "string");
    }
}
