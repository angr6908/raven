use axum::body::Bytes;
use serde_json::{json, Value};
use std::sync::Arc;

use crate::net::sse::{data_payload, SseReader};
use crate::translate::ids::uuid_v4_simple;

use super::signatures::Signatures;

#[derive(Default)]
pub struct Decoder {
    tool_calls: usize,
    finish_reason: String,
    usage: Option<Value>,
    saw_chunk: bool,
    failed: bool,
}

impl Decoder {
    pub fn push(&mut self, line: &str, signatures: &Signatures) -> Vec<Value> {
        if self.failed {
            return Vec::new();
        }
        let Some(payload) = data_payload(line).filter(|payload| *payload != "[DONE]") else {
            return Vec::new();
        };
        let Ok(chunk) = serde_json::from_str::<Value>(payload) else {
            return Vec::new();
        };
        self.saw_chunk = true;

        if let Some(message) = error_message(&chunk) {
            self.failed = true;
            return vec![error_event(&message)];
        }

        let data = chunk.get("response").unwrap_or(&chunk);
        let mut events = Vec::new();
        let parts = data
            .pointer("/candidates/0/content/parts")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();

        for part in &parts {
            if let Some(text) = part.get("text").and_then(Value::as_str) {
                if !text.is_empty() {
                    let thought = part.get("thought").and_then(Value::as_bool) == Some(true);
                    let kind = match thought {
                        true => "reasoning-delta",
                        false => "text-delta",
                    };
                    events.push(json!({"type": kind, "text": text}));
                }
            }
            let Some(call) = part.get("functionCall") else {
                continue;
            };
            let name = call.get("name").and_then(Value::as_str).unwrap_or_default();
            let id = call
                .get("id")
                .and_then(Value::as_str)
                .filter(|id| !id.is_empty())
                .map(str::to_string)
                .unwrap_or_else(|| format!("call_{}", uuid_v4_simple()));
            if let Some(signature) = part.get("thoughtSignature").and_then(Value::as_str) {
                signatures.remember(&id, signature);
            }
            self.tool_calls += 1;
            events.push(json!({
                "type": "tool-call",
                "toolCallId": id,
                "toolName": name,
                "input": call.get("args").cloned().unwrap_or_else(|| json!({})),
            }));
        }

        if let Some(reason) = data
            .pointer("/candidates/0/finishReason")
            .and_then(Value::as_str)
            .filter(|reason| !reason.is_empty())
        {
            self.finish_reason = reason.to_string();
        }
        if let Some(usage) = data.get("usageMetadata") {
            self.usage = Some(token_usage(usage));
        }
        events
    }

    pub fn finish(&self) -> Vec<Value> {
        if self.failed {
            return Vec::new();
        }
        if !self.saw_chunk {
            return vec![error_event("upstream returned an empty response")];
        }
        let reason = match (self.tool_calls > 0, self.finish_reason.as_str()) {
            (true, _) => "tool-calls",
            (false, "MAX_TOKENS") => "length",
            _ => "stop",
        };
        let mut event = json!({"type": "finish", "finishReason": reason});
        if let Some(usage) = &self.usage {
            event["totalUsage"] = usage.clone();
        }
        vec![event]
    }
}

fn error_event(message: &str) -> Value {
    json!({"type": "error", "error": {"message": message}})
}

fn error_message(chunk: &Value) -> Option<String> {
    let error = chunk.get("error")?;
    if let Some(message) = error.get("message").and_then(Value::as_str) {
        return Some(message.to_string());
    }
    error
        .as_str()
        .map(str::to_string)
        .or_else(|| Some(error.to_string()))
}

fn token_usage(usage: &Value) -> Value {
    let at = |key: &str| usage.get(key).and_then(Value::as_i64).unwrap_or(0);
    let cached = at("cachedContentTokenCount");
    let thoughts = at("thoughtsTokenCount");
    let prompt = at("promptTokenCount");
    let candidates = at("candidatesTokenCount");
    let total = match at("totalTokenCount") {
        0 => prompt + candidates + thoughts,
        found => found,
    };
    json!({
        "inputTokens": prompt,
        "outputTokens": candidates + thoughts,
        "totalTokens": total,
        "cachedInputTokens": cached,
        "inputTokenDetails": {"cacheReadTokens": cached, "cacheWriteTokens": 0},
        "outputTokenDetails": {"reasoningTokens": thoughts},
    })
}

pub fn transcode(upstream: reqwest::Response, signatures: Arc<Signatures>) -> reqwest::Response {
    let stream = async_stream::stream! {
        let mut reader = SseReader::new(upstream);
        let mut decoder = Decoder::default();

        while let Some(line) = reader.next_line().await {
            for event in decoder.push(&line, &signatures) {
                yield Ok::<Bytes, std::io::Error>(frame(&event));
            }
        }
        if let Some(message) = reader.error() {
            yield Ok(frame(&error_event(message)));
        } else {
            for event in decoder.finish() {
                yield Ok(frame(&event));
            }
        }
        yield Ok(Bytes::from_static(b"data: [DONE]\n\n"));
    };

    let body = reqwest::Body::wrap_stream(stream);
    reqwest::Response::from(axum::http::Response::new(body))
}

fn frame(event: &Value) -> Bytes {
    let mut out = Vec::with_capacity(128);
    out.extend_from_slice(b"data: ");
    let _ = serde_json::to_writer(&mut out, event);
    out.extend_from_slice(b"\n\n");
    Bytes::from(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(chunk: Value) -> String {
        format!("data: {chunk}\n")
    }

    #[test]
    fn text_and_thought_parts_split_into_content_and_reasoning() {
        let signatures = Signatures::new();
        let mut decoder = Decoder::default();
        let events = decoder.push(
            &line(json!({"response": {"candidates": [{"content": {"parts": [
                {"text": "thinking", "thought": true},
                {"text": "answer"},
            ]}}]}}),),
            &signatures,
        );
        assert_eq!(events[0]["type"], "reasoning-delta");
        assert_eq!(events[0]["text"], "thinking");
        assert_eq!(events[1]["type"], "text-delta");
        assert_eq!(events[1]["text"], "answer");
    }

    #[test]
    fn function_calls_become_tool_calls_and_bank_their_signature() {
        let signatures = Signatures::new();
        let mut decoder = Decoder::default();
        let events = decoder.push(
            &line(json!({"candidates": [{"content": {"parts": [{
                "functionCall": {"id": "fc-1", "name": "bash", "args": {"command": "ls"}},
                "thoughtSignature": "c2ln",
            }]}}]})),
            &signatures,
        );
        assert_eq!(events[0]["type"], "tool-call");
        assert_eq!(events[0]["toolCallId"], "fc-1");
        assert_eq!(events[0]["toolName"], "bash");
        assert_eq!(events[0]["input"], json!({"command": "ls"}));
        assert_eq!(signatures.get("fc-1").as_deref(), Some("c2ln"));

        let finish = decoder.finish();
        assert_eq!(finish[0]["finishReason"], "tool-calls");
    }

    #[test]
    fn a_call_without_an_id_still_gets_one_to_track_its_signature() {
        let signatures = Signatures::new();
        let mut decoder = Decoder::default();
        let events = decoder.push(
            &line(json!({"candidates": [{"content": {"parts": [{
                "functionCall": {"name": "read", "args": {}},
                "thoughtSignature": "c2ln",
            }]}}]})),
            &signatures,
        );
        let id = events[0]["toolCallId"].as_str().expect("generated id");
        assert!(id.starts_with("call_"));
        assert_eq!(signatures.get(id).as_deref(), Some("c2ln"));
    }

    #[test]
    fn usage_metadata_maps_onto_the_generate_usage_shape() {
        let signatures = Signatures::new();
        let mut decoder = Decoder::default();
        decoder.push(
            &line(json!({"response": {
                "candidates": [{"finishReason": "MAX_TOKENS"}],
                "usageMetadata": {
                    "promptTokenCount": 100,
                    "cachedContentTokenCount": 40,
                    "candidatesTokenCount": 20,
                    "thoughtsTokenCount": 5,
                    "totalTokenCount": 125,
                },
            }})),
            &signatures,
        );
        let finish = decoder.finish();
        assert_eq!(finish[0]["finishReason"], "length");
        let usage = &finish[0]["totalUsage"];
        assert_eq!(usage["inputTokens"], 100);
        assert_eq!(usage["outputTokens"], 25);
        assert_eq!(usage["cachedInputTokens"], 40);
        assert_eq!(usage["inputTokenDetails"]["cacheReadTokens"], 40);
        assert_eq!(usage["outputTokenDetails"]["reasoningTokens"], 5);
        assert_eq!(usage["totalTokens"], 125);
    }

    #[test]
    fn an_upstream_error_chunk_stops_the_stream() {
        let signatures = Signatures::new();
        let mut decoder = Decoder::default();
        let events = decoder.push(
            &line(json!({"error": {"message": "quota reached"}})),
            &signatures,
        );
        assert_eq!(events[0]["type"], "error");
        assert_eq!(events[0]["error"]["message"], "quota reached");
        assert!(decoder
            .push(&line(json!({"candidates": []})), &signatures)
            .is_empty());
        assert!(decoder.finish().is_empty());
    }

    #[test]
    fn a_silent_stream_reports_an_empty_response() {
        let decoder = Decoder::default();
        let finish = decoder.finish();
        assert_eq!(finish[0]["type"], "error");
    }
}
