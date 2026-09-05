use serde_json::Value;
use std::time::Instant;

use crate::net::sse::{data_payload, FrameSender, SseReader};
use crate::translate::StreamOutcome;
use crate::translate::collect::Collector;
use crate::translate::generate::types::GenerateEvent;
use crate::translate::usage::TokenUsage;

use super::tools::ToolIdentities;
use super::{
    build_completed_event, build_failed_event, build_function_call_events, build_reasoning_delta,
    build_text_delta, sse_event, ResponsesToolCall,
};

struct ResolvedCall {
    call_id: String,
    name: String,
    arguments: String,
    namespace: String,
    custom: bool,
}

fn resolve(
    identities: &ToolIdentities,
    call_id: &str,
    upstream_name: &str,
    arguments: &str,
) -> ResolvedCall {
    let (name, namespace, custom) = identities.resolve(upstream_name);
    ResolvedCall {
        call_id: call_id.to_string(),
        name,
        arguments: arguments.to_string(),
        namespace,
        custom,
    }
}

pub fn completed_from_collector(
    collector: &Collector,
    resp_id: &str,
    model: &str,
    identities: &ToolIdentities,
) -> Value {
    let tool_calls: Vec<ResolvedCall> = collector
        .tool_calls
        .iter()
        .map(|call| {
            resolve(
                identities,
                &call.id,
                &call.function.name,
                &call.function.arguments,
            )
        })
        .collect();
    build_completed_event(
        resp_id,
        model,
        &collector.content,
        &collector.reasoning,
        &borrow_tool_calls(&tool_calls),
        collector.usage_input(),
        collector.usage_output(),
        collector.total_tokens(),
        collector.cached_tokens(),
        collector.reasoning_tokens(),
    )
}

fn borrow_tool_calls(calls: &[ResolvedCall]) -> Vec<ResponsesToolCall<'_>> {
    calls
        .iter()
        .map(|call| ResponsesToolCall {
            call_id: &call.call_id,
            name: &call.name,
            arguments: &call.arguments,
            namespace: &call.namespace,
            custom: call.custom,
        })
        .collect()
}

pub async fn stream_to_responses(
    upstream: reqwest::Response,
    sender: &FrameSender,
    resp_id: &str,
    model: &str,
    identities: &ToolIdentities,
) -> StreamOutcome {
    let mut reader = SseReader::new(upstream);
    let mut output_text = String::new();
    let mut reasoning_text = String::new();
    let mut input_tokens: i64 = 0;
    let mut output_tokens: i64 = 0;
    let mut total_tokens: i64 = 0;
    let mut cached_tokens: i64 = 0;
    let mut reasoning_tokens: i64 = 0;
    let mut finish = "stop".to_string();

    let message_item_id = super::output_item_id();
    let reasoning_id = super::reasoning_item_id(resp_id);
    let mut reasoning_opened = false;

    let mut seq: u64 = 0;

    let mut next_output_index: usize = 0;
    let mut reasoning_index: usize = 0;
    let mut message_index: usize = 0;
    let mut message_opened = false;

    let mut tool_calls: Vec<ResolvedCall> = Vec::new();

    let mut first_token_at: Option<Instant> = None;

    while let Some(line) = reader.next_line().await {
        {
            let Some(data) = data_payload(&line).filter(|data| *data != "[DONE]") else {
                continue;
            };
            let Ok(cc_event) = serde_json::from_str::<GenerateEvent>(data) else {
                continue;
            };

            match cc_event.r#type.as_str() {
                "text-delta" => {
                    if cc_event.text.is_empty() {
                        continue;
                    }
                    first_token_at.get_or_insert_with(Instant::now);
                    if !message_opened {
                        message_opened = true;
                        message_index = next_output_index;
                        next_output_index += 1;
                        for opener in super::build_message_open(
                            &message_item_id,
                            message_index,
                        ) {
                            let name = opener.get("type").and_then(Value::as_str).unwrap_or("");
                            sse_event(sender, &mut seq, name, &opener);
                        }
                    }
                    output_text.push_str(&cc_event.text);
                    sse_event(
                        sender,
                        &mut seq,
                        "response.output_text.delta",
                        &build_text_delta(&cc_event.text, &message_item_id, message_index),
                    );
                }
                "reasoning-delta" => {
                    if cc_event.text.is_empty() {
                        continue;
                    }
                    first_token_at.get_or_insert_with(Instant::now);
                    if !reasoning_opened {
                        reasoning_opened = true;
                        reasoning_index = next_output_index;
                        next_output_index += 1;
                        for opener in super::build_reasoning_open(
                            &reasoning_id,
                            reasoning_index,
                        ) {
                            let name = opener.get("type").and_then(Value::as_str).unwrap_or("");
                            sse_event(sender, &mut seq, name, &opener);
                        }
                    }
                    reasoning_text.push_str(&cc_event.text);
                    sse_event(
                        sender,
                        &mut seq,
                        "response.reasoning_summary_text.delta",
                        &build_reasoning_delta(&cc_event.text, &reasoning_id, reasoning_index),
                    );
                }
                "tool-call" => {
                    first_token_at.get_or_insert_with(Instant::now);
                    let args =
                        serde_json::to_string(&cc_event.input).unwrap_or_else(|_| "{}".to_string());
                    let call_index = next_output_index;
                    next_output_index += 1;
                    let resolved = resolve(
                        identities,
                        &cc_event.tool_call_id,
                        &cc_event.tool_name,
                        &args,
                    );
                    let call = ResponsesToolCall {
                        call_id: &resolved.call_id,
                        name: &resolved.name,
                        arguments: &resolved.arguments,
                        namespace: &resolved.namespace,
                        custom: resolved.custom,
                    };
                    for frame in build_function_call_events(&call, call_index) {
                        let event_type = frame.get("type").and_then(Value::as_str).unwrap_or("");
                        sse_event(sender, &mut seq, event_type, &frame);
                    }
                    tool_calls.push(resolved);
                }
                "finish" => {
                    finish = cc_event.finish_reason.clone();
                    if let Some(usage) = &cc_event.total_usage {
                        input_tokens = usage.input_tokens;
                        output_tokens = usage.output_tokens;
                        total_tokens = usage.total_tokens;
                        cached_tokens = if usage.input_token_details.cache_read_tokens != 0 {
                            usage.input_token_details.cache_read_tokens
                        } else {
                            usage.cached_input_tokens
                        };
                        reasoning_tokens = usage.output_token_details.reasoning_tokens;
                    }
                    if reasoning_opened {
                        for closer in super::build_reasoning_close(
                            &reasoning_text,
                            &reasoning_id,
                            reasoning_index,
                        ) {
                            let name = closer.get("type").and_then(Value::as_str).unwrap_or("");
                            sse_event(sender, &mut seq, name, &closer);
                        }
                    }
                    if message_opened {
                        for closer in super::build_message_close(
                            &output_text,
                            &message_item_id,
                            message_index,
                        ) {
                            let name = closer.get("type").and_then(Value::as_str).unwrap_or("");
                            sse_event(sender, &mut seq, name, &closer);
                        }
                    }
                    sse_event(
                        sender,
                        &mut seq,
                        "response.completed",
                        &build_completed_event(
                            resp_id,
                            model,
                            &output_text,
                            &reasoning_text,
                            &borrow_tool_calls(&tool_calls),
                            input_tokens,
                            output_tokens,
                            total_tokens,
                            cached_tokens,
                            reasoning_tokens,
                        ),
                    );
                    return StreamOutcome {
                        first_token_at,
                        usage: Collector::with_usage(TokenUsage::from_counts(
                            input_tokens,
                            output_tokens,
                            total_tokens,
                            cached_tokens,
                            reasoning_tokens,
                        )),
                        finish,
                        error: None,
                    };
                }
                "error" => {
                    let message = cc_event
                        .error
                        .as_ref()
                        .and_then(Value::as_str)
                        .unwrap_or("upstream error")
                        .to_string();

                    sse_event(
                        sender,
                        &mut seq,
                        "response.failed",
                        &build_failed_event("upstream_error", &message),
                    );
                    return StreamOutcome::failed(first_token_at, message);
                }
                _ => {}
            }
        }
    }

    if reasoning_opened {
        for closer in super::build_reasoning_close(
            &reasoning_text,
            &reasoning_id,
            reasoning_index,
        ) {
            let name = closer.get("type").and_then(Value::as_str).unwrap_or("");
            sse_event(sender, &mut seq, name, &closer);
        }
    }
    if message_opened {
        for closer in super::build_message_close(
            &output_text,
            &message_item_id,
            message_index,
        ) {
            let name = closer.get("type").and_then(Value::as_str).unwrap_or("");
            sse_event(sender, &mut seq, name, &closer);
        }
    }
    sse_event(
        sender,
        &mut seq,
        "response.completed",
        &build_completed_event(
            resp_id,
            model,
            &output_text,
            &reasoning_text,
            &borrow_tool_calls(&tool_calls),
            input_tokens,
            output_tokens,
            total_tokens,
            cached_tokens,
            reasoning_tokens,
        ),
    );
    StreamOutcome {
        first_token_at,
        usage: Collector::with_usage(TokenUsage::from_counts(
            input_tokens,
            output_tokens,
            total_tokens,
            cached_tokens,
            reasoning_tokens,
        )),
        finish,
        error: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::sse::{frame_channel, StreamFrame};
    use crate::translate::chat::types::{ChatFunctionCall, ChatToolCall};
    use serde_json::json;

    fn codex_identities() -> ToolIdentities {
        ToolIdentities::new(&json!({"tools": [
            {"type": "namespace", "name": "functions", "tools": [
                {"type": "custom", "name": "exec", "description": "run a command"},
                {"type": "function", "name": "read", "parameters": {"type": "object"}},
            ]},
        ]}))
    }

    fn upstream(body: &'static str) -> reqwest::Response {
        reqwest::Response::from(axum::http::Response::new(reqwest::Body::from(body)))
    }

    fn drain(mut receiver: crate::net::sse::FrameReceiver) -> Vec<Value> {
        let mut events = Vec::new();
        while let Ok(StreamFrame::Data(frame)) = receiver.try_recv() {
            let text = String::from_utf8_lossy(&frame).to_string();
            if let Some(payload) = text.lines().find_map(crate::net::sse::data_payload) {
                if let Ok(parsed) = serde_json::from_str::<Value>(payload) {
                    events.push(parsed);
                }
            }
        }
        events
    }

    const CUSTOM_TOOL_STREAM: &str = concat!(
        "data: {\"type\":\"tool-call\",\"toolCallId\":\"c1\",\"toolName\":\"functions__exec\",",
        "\"input\":{\"input\":\"ls -la\"}}\n",
        "data: {\"type\":\"finish\",\"finishReason\":\"tool-calls\"}\n",
    );

    #[tokio::test]
    async fn a_namespaced_custom_tool_streams_back_as_a_custom_tool_call() {
        let (sender, receiver) = frame_channel();
        stream_to_responses(
            upstream(CUSTOM_TOOL_STREAM),
            &sender,
            "resp_1",
            "gemini-3.8-flash",
            &codex_identities(),
        )
        .await;
        let events = drain(receiver);

        let added = events
            .iter()
            .find(|event| {
                event["type"] == "response.output_item.added"
                    && event["item"]["type"] == "custom_tool_call"
            })
            .expect("the custom tool opens as a custom_tool_call");
        assert_eq!(added["item"]["name"], "exec");
        assert_eq!(added["item"]["namespace"], "functions");
        assert_eq!(added["item"]["call_id"], "c1");

        let done = events
            .iter()
            .find(|event| event["type"] == "response.custom_tool_call_input.done")
            .expect("freeform input is reported on the custom channel");
        assert_eq!(done["input"], "ls -la");

        let completed = events
            .iter()
            .find(|event| event["type"] == "response.completed")
            .expect("the response completes");
        let item = &completed["response"]["output"][0];
        assert_eq!(item["type"], "custom_tool_call");
        assert_eq!(item["name"], "exec");
        assert_eq!(item["namespace"], "functions");
        assert_eq!(item["input"], "ls -la");
    }

    const FUNCTION_TOOL_STREAM: &str = concat!(
        "data: {\"type\":\"tool-call\",\"toolCallId\":\"c2\",\"toolName\":\"functions__read\",",
        "\"input\":{\"path\":\"a.txt\"}}\n",
        "data: {\"type\":\"finish\",\"finishReason\":\"tool-calls\"}\n",
    );

    #[tokio::test]
    async fn a_namespaced_function_tool_keeps_its_arguments_and_gains_a_namespace() {
        let (sender, receiver) = frame_channel();
        stream_to_responses(
            upstream(FUNCTION_TOOL_STREAM),
            &sender,
            "resp_2",
            "gemini-3.8-flash",
            &codex_identities(),
        )
        .await;
        let events = drain(receiver);

        let added = events
            .iter()
            .find(|event| event["type"] == "response.output_item.added")
            .expect("the function tool opens as a function_call");
        assert_eq!(added["item"]["type"], "function_call");
        assert_eq!(added["item"]["name"], "read");
        assert_eq!(added["item"]["namespace"], "functions");

        let done = events
            .iter()
            .find(|event| event["type"] == "response.function_call_arguments.done")
            .expect("arguments stay on the function channel");
        assert_eq!(done["arguments"], json!({"path": "a.txt"}).to_string());
    }

    const UNDECLARED_TOOL_STREAM: &str = concat!(
        "data: {\"type\":\"tool-call\",\"toolCallId\":\"c3\",\"toolName\":\"web_search\",",
        "\"input\":{\"q\":\"eth\"}}\n",
        "data: {\"type\":\"finish\",\"finishReason\":\"tool-calls\"}\n",
    );

    #[tokio::test]
    async fn an_undeclared_tool_passes_through_without_a_namespace() {
        let (sender, receiver) = frame_channel();
        stream_to_responses(
            upstream(UNDECLARED_TOOL_STREAM),
            &sender,
            "resp_3",
            "gemini-3.8-flash",
            &codex_identities(),
        )
        .await;
        let events = drain(receiver);
        let added = events
            .iter()
            .find(|event| event["type"] == "response.output_item.added")
            .expect("the call still opens");
        assert_eq!(added["item"]["name"], "web_search");
        assert!(added["item"].get("namespace").is_none());
    }

    #[test]
    fn the_buffered_reply_resolves_identities_the_same_way() {
        let mut collector = Collector::buffering();
        collector.tool_calls = vec![ChatToolCall {
            id: "c1".into(),
            r#type: "function".into(),
            function: ChatFunctionCall {
                name: "functions__exec".into(),
                arguments: json!({"input": "ls -la"}).to_string(),
            },
        }];
        let body = completed_from_collector(&collector, "resp_4", "m", &codex_identities());
        let item = &body["response"]["output"][0];
        assert_eq!(item["type"], "custom_tool_call");
        assert_eq!(item["name"], "exec");
        assert_eq!(item["namespace"], "functions");
        assert_eq!(item["input"], "ls -la");
    }
}
