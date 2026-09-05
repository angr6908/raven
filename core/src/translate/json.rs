use serde_json::{json, Value};

pub fn fix_json(input: &str) -> String {
    let mut out = String::with_capacity(input.len());
    let mut in_double = false;
    let mut in_single = false;
    let mut escaped = false;

    let chars: Vec<char> = input.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let r = chars[i];

        if in_double {
            out.push(r);
            if escaped {
                escaped = false;
                i += 1;
                continue;
            }
            if r == '\\' {
                escaped = true;
                i += 1;
                continue;
            }
            if r == '"' {
                in_double = false;
            }
            i += 1;
            continue;
        }

        if in_single {
            if escaped {
                escaped = false;
                match r {
                    'n' | 'r' | 't' | 'b' | 'f' | '/' | '"' => {
                        out.push('\\');
                        out.push(r);
                    }
                    '\\' => {
                        out.push('\\');
                        out.push('\\');
                    }
                    '\'' => {
                        out.push('\'');
                    }
                    'u' => {
                        out.push('\\');
                        out.push('u');
                        let mut k = 0;
                        while k < 4 && i + 1 < chars.len() {
                            let peek = chars[i + 1];
                            if peek.is_ascii_hexdigit() {
                                out.push(peek);
                                i += 1;
                                k += 1;
                            } else {
                                break;
                            }
                        }
                    }
                    _ => {
                        out.push('\\');
                        out.push(r);
                    }
                }
                i += 1;
                continue;
            }

            if r == '\\' {
                escaped = true;
                i += 1;
                continue;
            }
            if r == '\'' {
                out.push('"');
                in_single = false;
                i += 1;
                continue;
            }
            if r == '"' {
                out.push('\\');
                out.push('"');
            } else {
                out.push(r);
            }
            i += 1;
            continue;
        }

        if r == '"' {
            in_double = true;
            out.push(r);
            i += 1;
            continue;
        }
        if r == '\'' {
            in_single = true;
            out.push('"');
            i += 1;
            continue;
        }
        out.push(r);
        i += 1;
    }

    if in_single {
        out.push('"');
    }

    out
}

pub fn content_text(raw: &Value) -> String {
    if raw.is_null() || raw.as_str() == Some("") {
        return String::new();
    }
    if let Some(text) = raw.as_str() {
        return text.to_string();
    }
    let Some(parts) = raw.as_array() else {
        return String::new();
    };
    parts
        .iter()
        .filter_map(|part| part.get("text").and_then(Value::as_str))
        .filter(|text| !text.is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

pub fn arguments_to_object(arguments: &str) -> Value {
    let trimmed = arguments.trim();
    if trimmed.is_empty() {
        return json!({});
    }
    match serde_json::from_str::<Value>(trimmed) {
        Ok(value) if value.is_object() => value,
        _ => json!({}),
    }
}

pub fn tool_arguments_string(arguments: Option<&Value>) -> String {
    match arguments {
        Some(Value::String(s)) => s.clone(),
        Some(v) if v.is_object() || v.is_array() => v.to_string(),
        _ => String::new(),
    }
}

pub fn value_as_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

pub fn sampling_temperature_top_p(req: &Value) -> (Option<f64>, Option<f64>) {
    let temperature = req.get("temperature").and_then(Value::as_f64);
    let top_p = match temperature {
        Some(_) => None,
        None => req.get("top_p").and_then(Value::as_f64),
    };
    (temperature, top_p)
}

pub fn codex_terminal_response(root: &Value) -> Option<&Value> {
    let event_type = root.get("type").and_then(Value::as_str).unwrap_or("");
    if event_type != "response.completed" && event_type != "response.incomplete" {
        return None;
    }
    root.get("response")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tool_arguments_accepts_string_or_object() {
        assert_eq!(
            tool_arguments_string(Some(&json!("{\"a\":1}"))),
            "{\"a\":1}"
        );
        assert_eq!(tool_arguments_string(Some(&json!({"a": 1}))), "{\"a\":1}");
        assert_eq!(tool_arguments_string(Some(&json!([1, 2]))), "[1,2]");
        assert_eq!(tool_arguments_string(None), "");
        assert_eq!(tool_arguments_string(Some(&Value::Null)), "");
    }
}
