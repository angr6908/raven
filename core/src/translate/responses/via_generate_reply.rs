use serde_json::Value;
use std::time::Instant;

use crate::net::sse::{data_payload, FrameSender, SseReader};
use crate::translate::StreamOutcome;
use crate::translate::collect::Collector;
use crate::translate::generate::types::GenerateEvent;
use crate::translate::usage::TokenUsage;

use super::{
    build_completed_event, build_failed_event, build_function_call_events, build_reasoning_delta,
    build_text_delta, sse_event, ResponsesToolCall,
};

pub fn completed_from_collector(collector: &Collector, resp_id: &str, model: &str) -> Value {
    let tool_calls: Vec<(String, String, String)> = collector
        .tool_calls
        .iter()
        .map(|call| {
            (
                call.id.clone(),
                call.function.name.clone(),
                call.function.arguments.clone(),
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

fn borrow_tool_calls(calls: &[(String, String, String)]) -> Vec<ResponsesToolCall<'_>> {
    calls
        .iter()
        .map(|(call_id, name, arguments)| ResponsesToolCall {
            call_id,
            name,
            arguments,
        })
        .collect()
}

pub async fn stream_to_responses(
    upstream: reqwest::Response,
    sender: &FrameSender,
    resp_id: &str,
    model: &str,
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

    let mut tool_calls: Vec<(String, String, String)> = Vec::new();

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
                    let call = ResponsesToolCall {
                        call_id: &cc_event.tool_call_id,
                        name: &cc_event.tool_name,
                        arguments: &args,
                    };
                    for frame in build_function_call_events(&call, call_index) {
                        let event_type = frame.get("type").and_then(Value::as_str).unwrap_or("");
                        sse_event(sender, &mut seq, event_type, &frame);
                    }
                    tool_calls.push((
                        cc_event.tool_call_id.clone(),
                        cc_event.tool_name.clone(),
                        args,
                    ));
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
