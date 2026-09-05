use serde_json::{json, Value};
use std::time::Instant;

use crate::net::sse::{data_payload, FrameSender, SseReader};
use crate::translate::finish::map_finish_reason;
use crate::translate::ids::uuid_v4;
use crate::translate::StreamOutcome;
use crate::translate::collect::Collector;
use crate::translate::generate::types::GenerateEvent;
use crate::translate::usage::TokenUsage;

use super::{
    effective_chat_finish_reason, emit_message_delta, is_truncating_finish_reason,
    map_chat_finish_to_messages, message_start_event, send_message_event, stop_text_block,
    stop_thinking_block, MessagesStream,
};

pub fn message_from_collector(collector: &Collector, message_id: &str, model: &str) -> Value {
    let reason = collector.finish_reason();
    let mut content: Vec<Value> = Vec::new();
    if !collector.reasoning.is_empty() {
        content.push(json!({"type": "thinking", "thinking": collector.reasoning}));
    }
    if !collector.content.is_empty() {
        content.push(json!({"type": "text", "text": collector.content}));
    }

    let chat_reason = map_finish_reason(&reason);
    let truncated = is_truncating_finish_reason(&chat_reason);
    let mut stop_reason = map_chat_finish_to_messages(&chat_reason).to_string();
    for call in &collector.tool_calls {
        let input =
            serde_json::from_str::<Value>(&call.function.arguments).unwrap_or_else(|_| json!({}));
        content.push(json!({
            "type": "tool_use",
            "id": call.id,
            "name": call.function.name,
            "input": input,
        }));
        if !truncated {
            stop_reason = "tool_use".to_string();
        }
    }

    let cached = collector.cached_tokens();
    let mut usage = json!({
        "input_tokens": (collector.usage_input() - cached).max(0),
        "output_tokens": collector.usage_output(),
    });
    if cached > 0 {
        usage["cache_read_input_tokens"] = json!(cached);
    }

    json!({
        "id": message_id,
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": content,
        "stop_reason": stop_reason,
        "stop_sequence": null,
        "usage": usage,
    })
}

pub async fn stream_to_messages(
    upstream: reqwest::Response,
    sender: &FrameSender,
    message_id: &str,
    model: &str,
) -> StreamOutcome {
    let mut reader = SseReader::new(upstream);
    let mut params = MessagesStream::new();
    params.message_id = message_id.to_string();
    params.model = model.to_string();

    send_message_event(
        sender,
        "message_start",
        &message_start_event(&params.message_id, &params.model),
    );
    params.message_started = true;

    let mut finish = "stop".to_string();
    let mut tool_call_count: usize = 0;

    while let Some(line) = reader.next_line().await {
        let Some(payload) = data_payload(&line).filter(|payload| *payload != "[DONE]") else {
            continue;
        };
        let Ok(cc_event) = serde_json::from_str::<GenerateEvent>(payload) else {
            continue;
        };

                    match cc_event.r#type.as_str() {
                "text-delta" => {
                    if cc_event.text.is_empty() {
                        continue;
                    }
                    params.first_token_at.get_or_insert_with(Instant::now);
                    if !params.text_block_started {
                        if params.text_block_index == -1 {
                            params.text_block_index = params.next_block_index;
                            params.next_block_index += 1;
                        }
                        send_message_event(
                            sender,
                            "content_block_start",
                            &json!({
                                "type": "content_block_start",
                                "index": params.text_block_index,
                                "content_block": {"type": "text", "text": ""},
                            }),
                        );
                        params.text_block_started = true;
                    }
                    send_message_event(
                        sender,
                        "content_block_delta",
                        &json!({
                            "type": "content_block_delta",
                            "index": params.text_block_index,
                            "delta": {"type": "text_delta", "text": cc_event.text},
                        }),
                    );
                }
                "reasoning-delta" => {
                    if cc_event.text.is_empty() {
                        continue;
                    }
                    params.first_token_at.get_or_insert_with(Instant::now);
                    if !params.thinking_block_started {
                        if params.thinking_block_index == -1 {
                            params.thinking_block_index = params.next_block_index;
                            params.next_block_index += 1;
                        }
                        send_message_event(
                            sender,
                            "content_block_start",
                            &json!({
                                "type": "content_block_start",
                                "index": params.thinking_block_index,
                                "content_block": {"type": "thinking", "thinking": ""},
                            }),
                        );
                        params.thinking_block_started = true;
                    }
                    send_message_event(
                        sender,
                        "content_block_delta",
                        &json!({
                            "type": "content_block_delta",
                            "index": params.thinking_block_index,
                            "delta": {"type": "thinking_delta", "thinking": cc_event.text},
                        }),
                    );
                }
                "tool-call" => {
                    params.first_token_at.get_or_insert_with(Instant::now);
                    stop_thinking_block(&mut params, sender);
                    stop_text_block(&mut params, sender);
                    let block_index = params.tool_block_index(tool_call_count);
                    tool_call_count += 1;
                    let id = if cc_event.tool_call_id.is_empty() {
                        format!("toolu_{}", uuid_v4().replace('-', ""))
                    } else {
                        cc_event.tool_call_id.clone()
                    };
                    let args =
                        serde_json::to_string(&cc_event.input).unwrap_or_else(|_| "{}".to_string());
                    send_message_event(
                        sender,
                        "content_block_start",
                        &json!({
                            "type": "content_block_start",
                            "index": block_index,
                            "content_block": {
                                "type": "tool_use",
                                "id": id,
                                "name": cc_event.tool_name,
                                "input": {},
                            },
                        }),
                    );
                    if !args.is_empty() {
                        send_message_event(
                            sender,
                            "content_block_delta",
                            &json!({
                                "type": "content_block_delta",
                                "index": block_index,
                                "delta": {"type": "input_json_delta", "partial_json": args},
                            }),
                        );
                    }
                    send_message_event(
                        sender,
                        "content_block_stop",
                        &json!({"type": "content_block_stop", "index": block_index}),
                    );
                    params.saw_tool_call = true;
                }
                "finish" => {
                    finish = cc_event.finish_reason.clone();
                    if let Some(usage) = &cc_event.total_usage {
                        params.output_tokens = usage.output_tokens;
                        let cached = if usage.input_token_details.cache_read_tokens != 0 {
                            usage.input_token_details.cache_read_tokens
                        } else {
                            usage.cached_input_tokens
                        };
                        if cached > 0 || params.cached_tokens == 0 {
                            params.cached_tokens = cached;
                        }

                        params.input_tokens = (usage.input_tokens - params.cached_tokens).max(0);
                    }
                }
                "error" => {
                    let message = cc_event
                        .error
                        .as_ref()
                        .and_then(Value::as_str)
                        .unwrap_or("upstream error")
                        .to_string();
                    send_message_event(
                        sender,
                        "error",
                        &json!({
                            "type": "error",
                            "error": {"type": "upstream_error", "message": message},
                        }),
                    );
                    return StreamOutcome::failed(params.first_token_at, message);
                }
                _ => {}
            }
    }

    stop_thinking_block(&mut params, sender);
    stop_text_block(&mut params, sender);
    params.content_blocks_stopped = true;

    params.finish_reason = map_finish_reason(&finish);
    emit_message_delta(&mut params, sender);

    StreamOutcome {
        first_token_at: params.first_token_at,
        usage: Collector::with_usage(TokenUsage::from_counts(
            params.input_tokens + params.cached_tokens,
            params.output_tokens,
            0,
            params.cached_tokens,
            0,
        )),
        finish: effective_chat_finish_reason(&params).to_string(),
        error: None,
    }
}
