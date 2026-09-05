use std::collections::HashMap;

use serde_json::{json, Map, Number, Value};

pub async fn aggregate_response(upstream: reqwest::Response) -> Result<Value, String> {
    let raw = upstream
        .bytes()
        .await
        .map_err(|err| format!("read upstream response: {err}"))?;
    aggregate(&raw).map_err(|err| format!("aggregate upstream stream: {err}"))
}

pub fn aggregate(body: &[u8]) -> Result<Value, String> {
    let text = std::str::from_utf8(body).map_err(|e| format!("invalid utf8: {e}"))?;

    let mut id = String::new();
    let mut model = String::new();
    let mut created: f64 = 0.0;
    let mut content = String::new();
    let mut reasoning = String::new();
    let mut role = "assistant".to_string();
    let mut finish_reason = "stop".to_string();
    let mut usage: Option<Value> = None;
    let mut got_any_content = false;
    let mut tool_calls: HashMap<usize, Map<String, Value>> = HashMap::new();
    let mut tool_order: Vec<usize> = Vec::new();

    for line in text.lines() {
        let line = line.trim();
        if !line.starts_with("data: ") {
            continue;
        }
        let payload = line["data: ".len()..].trim();
        if payload == "[DONE]" {
            continue;
        }
        let Ok(chunk) = serde_json::from_str::<Value>(payload) else {
            continue;
        };

        if let Some(v) = chunk.get("id").and_then(Value::as_str) {
            if id.is_empty() {
                id = v.to_string();
            }
        }
        if let Some(v) = chunk.get("model").and_then(Value::as_str) {
            if model.is_empty() {
                model = v.to_string();
            }
        }
        if let Some(v) = chunk.get("created").and_then(Value::as_f64) {
            if created == 0.0 {
                created = v;
            }
        }
        if chunk.get("usage").is_some() {
            usage = chunk.get("usage").cloned();
        }

        let Some(choices) = chunk.get("choices").and_then(Value::as_array) else {
            continue;
        };
        for choice in choices {
            let Some(c) = choice.as_object() else {
                continue;
            };
            if let Some(Value::String(fr)) = c.get("finish_reason") {
                if !fr.is_empty() {
                    finish_reason = fr.clone();
                }
            }
            if let Some(delta) = c.get("delta").and_then(Value::as_object) {
                if let Some(Value::String(r)) = delta.get("role") {
                    if !r.is_empty() {
                        role = r.clone();
                    }
                }
                if let Some(Value::String(t)) = delta.get("content") {
                    content.push_str(t);
                    got_any_content = true;
                }
                if let Some(Value::String(rc)) = delta.get("reasoning_content") {
                    reasoning.push_str(rc);
                }
                if let Some(tcs) = delta.get("tool_calls").and_then(Value::as_array) {
                    for tc in tcs {
                        let Some(tc) = tc.as_object() else {
                            continue;
                        };
                        let idx = tc.get("index").and_then(Value::as_f64).unwrap_or(0.0) as usize;
                        if !tool_calls.contains_key(&idx) {
                            let mut entry = Map::new();
                            entry.insert("index".to_string(), Number::from(idx).into());
                            tool_calls.insert(idx, entry);
                            tool_order.push(idx);
                        }
                        let merged = tool_calls.get_mut(&idx).expect("just inserted");
                        merge_tool_call_delta(merged, tc);
                    }
                }
            }

            if !got_any_content {
                if let Some(msg) = c.get("message").and_then(Value::as_object) {
                    if let Some(Value::String(t)) = msg.get("content") {
                        content.push_str(t);
                    }
                }
            }
        }
    }

    if id.is_empty() {
        id = crate::translate::collect::completion_id();
    }
    if created == 0.0 {
        created = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs() as f64;
    }

    let mut message = Map::new();
    message.insert("role".to_string(), Value::String(role));
    message.insert("content".to_string(), Value::String(content));
    if !reasoning.is_empty() {
        message.insert("reasoning_content".to_string(), Value::String(reasoning));
    }
    if !tool_order.is_empty() {
        tool_order.sort_unstable();
        let calls: Vec<Value> = tool_order
            .iter()
            .map(|idx| Value::Object(tool_calls.remove(idx).expect("tool call present")))
            .collect();
        message.insert("tool_calls".to_string(), Value::Array(calls));
    }

    let mut resp = Map::new();
    resp.insert("id".to_string(), Value::String(id));
    resp.insert(
        "object".to_string(),
        Value::String("chat.completion".to_string()),
    );
    resp.insert("created".to_string(), Value::from(created as i64));
    resp.insert("model".to_string(), Value::String(model));
    resp.insert(
        "choices".to_string(),
        json!([
            {
                "index": 0,
                "message": message,
                "finish_reason": finish_reason,
            }
        ]),
    );
    if let Some(usage) = usage {
        resp.insert("usage".to_string(), usage);
    }
    Ok(Value::Object(resp))
}

fn merge_tool_call_delta(merged: &mut Map<String, Value>, delta: &Map<String, Value>) {
    if let Some(Value::String(v)) = delta.get("id") {
        if !v.is_empty() {
            merged.insert("id".to_string(), Value::String(v.clone()));
        }
    }
    if let Some(Value::String(v)) = delta.get("type") {
        if !v.is_empty() {
            merged.insert("type".to_string(), Value::String(v.clone()));
        }
    }
    let Some(df) = delta.get("function").and_then(Value::as_object) else {
        return;
    };
    if !merged.contains_key("function") {
        merged.insert("function".to_string(), Value::Object(Map::new()));
    }
    let mf = merged
        .get_mut("function")
        .and_then(Value::as_object_mut)
        .expect("just ensured");
    if let Some(Value::String(v)) = df.get("name") {
        if !v.is_empty() {
            mf.insert("name".to_string(), Value::String(v.clone()));
        }
    }
    if let Some(Value::String(v)) = df.get("arguments") {
        if !v.is_empty() {
            let prev = mf
                .get("arguments")
                .and_then(Value::as_str)
                .unwrap_or_default();
            mf.insert("arguments".to_string(), Value::String(format!("{prev}{v}")));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(id: &str, content: &str, _index: usize) -> String {
        format!(
            "data: {{\"id\":\"{id}\",\"model\":\"m\",\"created\":1700000000,\
             \"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\
             \"content\":\"{content}\"}},\"finish_reason\":null}}]}}"
        )
    }

    #[test]
    fn aggregates_simple_stream() {
        let mut body = String::new();
        body.push_str(&chunk("cmpl-1", "Hel", 0));
        body.push('\n');
        body.push_str(&chunk("cmpl-1", "lo", 0));
        body.push('\n');
        body.push_str(&chunk("cmpl-1", "", 0));
        body.push('\n');
        body.push_str("data: {\"id\":\"cmpl-1\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}");
        body.push('\n');
        body.push_str("data: [DONE]");
        body.push('\n');

        let out = aggregate(body.as_bytes()).unwrap();
        assert_eq!(out["id"], "cmpl-1");
        assert_eq!(out["choices"][0]["message"]["content"], "Hello");
        assert_eq!(out["choices"][0]["finish_reason"], "stop");
        assert_eq!(out["object"], "chat.completion");
    }

    #[test]
    fn merges_tool_calls_by_index() {
        let body = "data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"weather\",\"arguments\":\"{\\\"city\\\":\\\"\"}}]}}]}\n\
                    data: {\"choices\":[{\"index\":0,\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"SF\\\"}\"}}]}}]}\n\
                    data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\
                    data: [DONE]\n";
        let out = aggregate(body.as_bytes()).unwrap();
        let msg = &out["choices"][0]["message"];
        assert_eq!(msg["tool_calls"][0]["id"], "call_1");
        assert_eq!(msg["tool_calls"][0]["function"]["name"], "weather");
        assert_eq!(
            msg["tool_calls"][0]["function"]["arguments"],
            "{\"city\":\"SF\"}"
        );
        assert_eq!(out["choices"][0]["finish_reason"], "tool_calls");
    }

    #[test]
    fn usage_is_carried_through() {
        let body = "data: {\"id\":\"x\",\"usage\":{\"prompt_tokens\":1,\"completion_tokens\":2,\"total_tokens\":3}}\n\
                    data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"hi\"}}]}\n\
                    data: [DONE]\n";
        let out = aggregate(body.as_bytes()).unwrap();
        assert_eq!(out["usage"]["total_tokens"], 3);
    }
}
