use serde_json::{json, Value};
use std::collections::{HashMap, HashSet};

use super::{
    incomplete_by_finish_reason, responses_single_custom_tool_name, unwrap_custom_tool_input,
};

pub(crate) struct ResponsesStreamReasoning {
    pub(crate) reasoning_id: String,
    pub(crate) reasoning_data: String,
    pub(crate) output_index: usize,
}

pub(crate) struct ResponsesStreamState {
    pub(crate) seq: i64,
    pub(crate) response_id: String,
    pub(crate) created: i64,
    pub(crate) started: bool,
    pub(crate) completed_emitted: bool,
    pub(crate) reasoning_id: String,
    pub(crate) reasoning_index: usize,
    pub(crate) reasonings: Vec<ResponsesStreamReasoning>,

    pub(crate) msg_text_buf: HashMap<usize, String>,
    pub(crate) reasoning_buf: String,
    pub(crate) func_args_buf: HashMap<String, String>,
    pub(crate) func_names: HashMap<String, String>,
    pub(crate) func_call_ids: HashMap<String, String>,
    pub(crate) func_output_ix: HashMap<String, usize>,
    pub(crate) func_args_sent: HashMap<String, usize>,
    pub(crate) msg_output_ix: HashMap<usize, usize>,
    pub(crate) next_output_ix: usize,

    pub(crate) msg_item_added: HashMap<usize, bool>,
    pub(crate) msg_content_added: HashMap<usize, bool>,
    pub(crate) msg_item_done: HashMap<usize, bool>,

    pub(crate) func_item_added: HashMap<String, bool>,
    pub(crate) func_item_custom: HashMap<String, bool>,

    pub(crate) func_identity: HashMap<String, (String, String)>,
    pub(crate) func_args_done: HashMap<String, bool>,
    pub(crate) func_item_done: HashMap<String, bool>,
    pub(crate) custom_tool_names: HashSet<String>,
    pub(crate) finish_reason: String,

    pub(crate) prompt_tokens: i64,
    pub(crate) cached_tokens: i64,
    pub(crate) completion_tokens: i64,
    pub(crate) total_tokens: i64,
    pub(crate) reasoning_tokens: i64,
    pub(crate) usage_seen: bool,

    pub(crate) think_scan: bool,
    pub(crate) think_closed: bool,

    pub(crate) think_tail: String,
}

impl ResponsesStreamState {
    pub(crate) fn new() -> Self {
        Self {
            seq: 0,
            response_id: String::new(),
            created: 0,
            started: false,
            completed_emitted: false,
            reasoning_id: String::new(),
            reasoning_index: 0,
            reasonings: Vec::new(),
            msg_text_buf: HashMap::new(),
            reasoning_buf: String::new(),
            func_args_buf: HashMap::new(),
            func_names: HashMap::new(),
            func_call_ids: HashMap::new(),
            func_output_ix: HashMap::new(),
            func_args_sent: HashMap::new(),
            msg_output_ix: HashMap::new(),
            next_output_ix: 0,
            msg_item_added: HashMap::new(),
            msg_content_added: HashMap::new(),
            msg_item_done: HashMap::new(),
            func_item_added: HashMap::new(),
            func_item_custom: HashMap::new(),
            func_identity: HashMap::new(),
            func_args_done: HashMap::new(),
            func_item_done: HashMap::new(),
            custom_tool_names: HashSet::new(),
            finish_reason: String::new(),
            prompt_tokens: 0,
            cached_tokens: 0,
            completion_tokens: 0,
            total_tokens: 0,
            reasoning_tokens: 0,
            usage_seen: false,
            think_scan: true,
            think_closed: false,
            think_tail: String::new(),
        }
    }

    pub(crate) fn next_seq(&mut self) -> i64 {
        self.seq += 1;
        self.seq
    }

    pub(crate) fn alloc_output_index(&mut self) -> usize {
        let index = self.next_output_ix;
        self.next_output_ix += 1;
        index
    }

    pub(crate) fn reset_for_new_response(&mut self) {
        self.msg_text_buf.clear();
        self.reasoning_buf.clear();
        self.reasoning_id.clear();
        self.reasoning_index = 0;
        self.func_args_buf.clear();
        self.func_names.clear();
        self.func_call_ids.clear();
        self.func_output_ix.clear();
        self.func_args_sent.clear();
        self.msg_output_ix.clear();
        self.next_output_ix = 0;
        self.msg_item_added.clear();
        self.msg_content_added.clear();
        self.msg_item_done.clear();
        self.func_item_added.clear();
        self.func_item_custom.clear();
        self.func_identity.clear();
        self.func_args_done.clear();
        self.func_item_done.clear();
        self.prompt_tokens = 0;
        self.cached_tokens = 0;
        self.completion_tokens = 0;
        self.total_tokens = 0;
        self.reasoning_tokens = 0;
        self.finish_reason.clear();
        self.usage_seen = false;
        self.think_scan = true;
        self.think_closed = false;
        self.think_tail.clear();
        self.completed_emitted = false;
    }
}

pub(crate) fn emit_tool_item(
    st: &mut ResponsesStreamState,
    out: &mut Vec<Value>,
    key: &str,
    force: bool,
    request_for_namespace: &[u8],
) {
    if st.func_item_added.get(key).copied().unwrap_or(false) {
        return;
    }
    let mut call_id = st.func_call_ids.get(key).cloned().unwrap_or_default();
    let mut name = st.func_names.get(key).cloned().unwrap_or_default();
    if !force && (call_id.is_empty() || name.is_empty()) {
        return;
    }
    if name.is_empty() {
        if let Some(custom) = responses_single_custom_tool_name(request_for_namespace) {
            name = custom.clone();
            st.func_names.insert(key.to_string(), custom);
        }
    }
    if call_id.is_empty() {
        call_id = format!("call_{}_{}", st.response_id, key.replace(':', "_"));
        st.func_call_ids.insert(key.to_string(), call_id.clone());
    }

    let output_index = st.func_output_ix.get(key).copied().unwrap_or(0);
    let is_custom_tool = st.custom_tool_names.contains(&name);
    st.func_item_custom.insert(key.to_string(), is_custom_tool);

    let request_root: Value = serde_json::from_slice(request_for_namespace).unwrap_or(Value::Null);
    let (local_name, namespace) =
        crate::translate::responses::tools::split_responses_qualified_function_call_from_request(
            &request_root,
            &name,
        );
    st.func_identity
        .insert(key.to_string(), (local_name.clone(), namespace.clone()));
    let name = local_name;
    let mut item = json!({
        "type": "response.output_item.added",
        "output_index": output_index,
        "item": {
            "id": if is_custom_tool { format!("ctc_{call_id}") } else { format!("fc_{call_id}") },
            "type": if is_custom_tool { "custom_tool_call" } else { "function_call" },
            "status": "in_progress",
            "arguments": "",
            "call_id": call_id,
            "name": name,
        },
    });
    if is_custom_tool {
        item["item"]["input"] = json!("");
    }
    if !namespace.is_empty() {
        item["item"]["namespace"] = json!(namespace);
    }
    let seq = st.next_seq();
    item["sequence_number"] = json!(seq);
    out.push(item);
    st.func_item_added.insert(key.to_string(), true);
}

pub(crate) fn emit_pending_function_args(
    st: &mut ResponsesStreamState,
    out: &mut Vec<Value>,
    key: &str,
) {
    if !st.func_item_added.get(key).copied().unwrap_or(false)
        || st.func_item_custom.get(key).copied().unwrap_or(false)
    {
        return;
    }
    let Some(args_buf) = st.func_args_buf.get(key) else {
        return;
    };
    let args_sent = st.func_args_sent.get(key).copied().unwrap_or(0);
    if args_buf.len() <= args_sent {
        return;
    }
    let args = args_buf.clone();
    let delta = args[args_sent..].to_string();
    let call_id = st.func_call_ids.get(key).cloned().unwrap_or_default();
    let output_index = st.func_output_ix.get(key).copied().unwrap_or(0);
    let mut ad = json!({
        "type": "response.function_call_arguments.delta",
        "item_id": format!("fc_{call_id}"),
        "output_index": output_index,
        "delta": delta,
    });
    let seq = st.next_seq();
    ad["sequence_number"] = json!(seq);
    out.push(ad);
    st.func_args_sent.insert(key.to_string(), args.len());
}

pub(crate) fn stop_reasoning(st: &mut ResponsesStreamState, out: &mut Vec<Value>) {
    if st.reasoning_id.is_empty() {
        return;
    }
    let text = st.reasoning_buf.clone();
    let mut text_done = json!({
        "type": "response.reasoning_summary_text.done",
        "item_id": st.reasoning_id,
        "output_index": st.reasoning_index,
        "summary_index": 0,
        "text": text,
    });
    let seq = st.next_seq();
    text_done["sequence_number"] = json!(seq);
    out.push(text_done);

    let mut part_done = json!({
        "type": "response.reasoning_summary_part.done",
        "item_id": st.reasoning_id,
        "output_index": st.reasoning_index,
        "summary_index": 0,
        "part": {"type": "summary_text", "text": text},
    });
    let seq = st.next_seq();
    part_done["sequence_number"] = json!(seq);
    out.push(part_done);

    let mut output_item_done = json!({
        "type": "response.output_item.done",
        "item": {
            "id": st.reasoning_id,
            "type": "reasoning",
            "encrypted_content": "",
            "summary": [{"type": "summary_text", "text": text}],
        },
        "output_index": st.reasoning_index,
    });
    let seq = st.next_seq();
    output_item_done["sequence_number"] = json!(seq);
    out.push(output_item_done);

    st.reasonings.push(ResponsesStreamReasoning {
        reasoning_id: st.reasoning_id.clone(),
        reasoning_data: text,
        output_index: st.reasoning_index,
    });
    st.reasoning_id.clear();
}

pub(crate) fn emit_message_item_done(
    st: &mut ResponsesStreamState,
    out: &mut Vec<Value>,
    idx: usize,
) {
    if !st.msg_item_added.get(&idx).copied().unwrap_or(false)
        || st.msg_item_done.get(&idx).copied().unwrap_or(false)
    {
        return;
    }
    let msg_output_index = st.msg_output_ix.get(&idx).copied().unwrap_or(0);
    let full_text = st.msg_text_buf.get(&idx).cloned().unwrap_or_default();
    let item_id = format!("msg_{}_{}", st.response_id, idx);

    let mut done = json!({
        "type": "response.output_text.done",
        "item_id": item_id,
        "output_index": msg_output_index,
        "content_index": 0,
        "text": full_text,
        "logprobs": [],
    });
    let seq = st.next_seq();
    done["sequence_number"] = json!(seq);
    out.push(done);

    let mut part_done = json!({
        "type": "response.content_part.done",
        "item_id": item_id,
        "output_index": msg_output_index,
        "content_index": 0,
        "part": {"type": "output_text", "annotations": [], "logprobs": [], "text": full_text},
    });
    let seq = st.next_seq();
    part_done["sequence_number"] = json!(seq);
    out.push(part_done);

    let (_, is_incomplete) = incomplete_by_finish_reason(&st.finish_reason);
    let msg_status = if is_incomplete {
        "incomplete"
    } else {
        "completed"
    };
    let mut item_done = json!({
        "type": "response.output_item.done",
        "output_index": msg_output_index,
        "item": {
            "id": item_id,
            "type": "message",
            "status": msg_status,
            "content": [{"type": "output_text", "annotations": [], "logprobs": [], "text": full_text}],
            "role": "assistant",
        },
    });
    let seq = st.next_seq();
    item_done["sequence_number"] = json!(seq);
    out.push(item_done);
    st.msg_item_done.insert(idx, true);
}

pub(crate) fn finalize_open_items(
    st: &mut ResponsesStreamState,
    out: &mut Vec<Value>,
    request_for_namespace: &[u8],
) {
    if !st.msg_item_added.is_empty() {
        let mut idxs: Vec<usize> = st.msg_item_added.keys().copied().collect();
        idxs.sort_by_key(|idx| st.msg_output_ix.get(idx).copied().unwrap_or(0));
        for idx in idxs {
            emit_message_item_done(st, out, idx);
        }
    }
    if !st.reasoning_id.is_empty() {
        stop_reasoning(st, out);
        st.reasoning_buf.clear();
    }
    if st.func_args_buf.is_empty() {
        return;
    }
    let mut keys: Vec<String> = st.func_args_buf.keys().cloned().collect();
    keys.sort_by(|a, b| {
        let left = st.func_output_ix.get(a).copied().unwrap_or(0);
        let right = st.func_output_ix.get(b).copied().unwrap_or(0);
        left.cmp(&right).then_with(|| a.cmp(b))
    });
    for key in keys {
        if st.func_item_done.get(&key).copied().unwrap_or(false) {
            continue;
        }
        let b = st.func_args_buf.get(&key).cloned();
        let has_args = b.as_ref().map(|s| !s.is_empty()).unwrap_or(false);
        let (_, is_incomplete) = incomplete_by_finish_reason(&st.finish_reason);
        let is_explicit_tool_finish =
            st.finish_reason == "tool_calls" || st.finish_reason == "stop";

        if st.finish_reason.is_empty()
            && (!has_args
                || !b
                    .as_ref()
                    .map(|s| serde_json::from_str::<Value>(s).is_ok())
                    .unwrap_or(false))
        {
            continue;
        }

        emit_tool_item(st, out, &key, true, request_for_namespace);
        emit_pending_function_args(st, out, &key);
        let call_id = st.func_call_ids.get(&key).cloned().unwrap_or_default();
        if call_id.is_empty() || st.func_item_done.get(&key).copied().unwrap_or(false) {
            continue;
        }

        let output_index = st.func_output_ix.get(&key).copied().unwrap_or(0);
        let tool_status = if is_incomplete {
            "incomplete"
        } else {
            "completed"
        };
        let args = if has_args {
            b.as_ref().cloned().unwrap_or_default()
        } else if is_incomplete || !is_explicit_tool_finish {
            String::new()
        } else {
            "{}".to_string()
        };

        let is_custom = st.func_item_custom.get(&key).copied().unwrap_or(false);
        if is_custom {
            let input = unwrap_custom_tool_input(&args);
            let mut input_done = json!({
                "type": "response.custom_tool_call_input.done",
                "item_id": format!("ctc_{call_id}"),
                "output_index": output_index,
                "input": input,
            });
            let seq = st.next_seq();
            input_done["sequence_number"] = json!(seq);
            out.push(input_done);

            let (local_name, namespace) =
                st.func_identity.get(&key).cloned().unwrap_or_else(|| {
                    (
                        st.func_names.get(&key).cloned().unwrap_or_default(),
                        String::new(),
                    )
                });
            let mut item_done = json!({
                "type": "response.output_item.done",
                "output_index": output_index,
                "item": {
                    "id": format!("ctc_{call_id}"),
                    "type": "custom_tool_call",
                    "status": tool_status,
                    "input": input,
                    "call_id": call_id,
                    "name": local_name,
                },
            });
            if !namespace.is_empty() {
                item_done["item"]["namespace"] = json!(namespace);
            }
            let seq = st.next_seq();
            item_done["sequence_number"] = json!(seq);
            out.push(item_done);
            st.func_item_done.insert(key.clone(), true);
            st.func_args_done.insert(key, true);
            continue;
        }

        let mut fc_done = json!({
            "type": "response.function_call_arguments.done",
            "item_id": format!("fc_{call_id}"),
            "output_index": output_index,
            "arguments": args,
        });
        let seq = st.next_seq();
        fc_done["sequence_number"] = json!(seq);
        out.push(fc_done);

        let (local_name, namespace) = st.func_identity.get(&key).cloned().unwrap_or_else(|| {
            (
                st.func_names.get(&key).cloned().unwrap_or_default(),
                String::new(),
            )
        });
        let mut item_done = json!({
            "type": "response.output_item.done",
            "output_index": output_index,
            "item": {
                "id": format!("fc_{call_id}"),
                "type": "function_call",
                "status": tool_status,
                "arguments": args,
                "call_id": call_id,
                "name": local_name,
            },
        });
        if !namespace.is_empty() {
            item_done["item"]["namespace"] = json!(namespace);
        }
        let seq = st.next_seq();
        item_done["sequence_number"] = json!(seq);
        out.push(item_done);
        st.func_item_done.insert(key.clone(), true);
        st.func_args_done.insert(key, true);
    }
}

pub(crate) fn build_completed_event_from_state(
    st: &mut ResponsesStreamState,
    request_json: &[u8],
) -> Value {
    let (incomplete_details, is_incomplete) = incomplete_by_finish_reason(&st.finish_reason);
    let event_type = if is_incomplete {
        "response.incomplete"
    } else {
        "response.completed"
    };
    let status = if is_incomplete {
        "incomplete"
    } else {
        "completed"
    };

    let mut completed = json!({
        "type": event_type,
        "response": {
            "id": st.response_id,
            "object": "response",
            "created_at": st.created,
            "status": status,
            "background": false,
            "error": null,
        },
    });
    let seq = st.next_seq();
    completed["sequence_number"] = json!(seq);
    if let Some(details) = incomplete_details {
        completed["response"]["incomplete_details"] = details;
    }

    if !request_json.is_empty() {
        if let Ok(req) = serde_json::from_slice::<Value>(request_json) {
            for key in [
                "instructions",
                "max_output_tokens",
                "max_tool_calls",
                "model",
                "parallel_tool_calls",
                "previous_response_id",
                "prompt_cache_key",
                "reasoning",
                "safety_identifier",
                "service_tier",
                "store",
                "temperature",
                "text",
                "tool_choice",
                "tools",
                "top_logprobs",
                "top_p",
                "truncation",
                "user",
                "metadata",
            ] {
                if let Some(value) = req.get(key) {
                    if !value.is_null() {
                        completed["response"][key] = value.clone();
                    }
                }
            }
        }
    }

    let mut output_items: Vec<(usize, Value)> = Vec::new();
    for r in &st.reasonings {
        output_items.push((
            r.output_index,
            json!({
                "id": r.reasoning_id,
                "type": "reasoning",
                "summary": [{"type": "summary_text", "text": r.reasoning_data}],
            }),
        ));
    }
    for idx in st.msg_item_added.keys() {
        let text = st.msg_text_buf.get(idx).cloned().unwrap_or_default();
        let (_, is_inc) = incomplete_by_finish_reason(&st.finish_reason);
        let msg_status = if is_inc { "incomplete" } else { "completed" };
        output_items.push((
            st.msg_output_ix.get(idx).copied().unwrap_or(0),
            json!({
                "id": format!("msg_{}_{}", st.response_id, idx),
                "type": "message",
                "status": msg_status,
                "content": [{"type": "output_text", "annotations": [], "logprobs": [], "text": text}],
                "role": "assistant",
            }),
        ));
    }
    for key in st.func_args_buf.keys() {
        if !st.func_item_done.get(key).copied().unwrap_or(false) {
            continue;
        }
        let args = st.func_args_buf.get(key).cloned().unwrap_or_default();
        let call_id = st.func_call_ids.get(key).cloned().unwrap_or_default();
        let name = st.func_names.get(key).cloned().unwrap_or_default();
        let (_, is_inc) = incomplete_by_finish_reason(&st.finish_reason);
        let tool_status = if is_inc { "incomplete" } else { "completed" };
        if st.func_item_custom.get(key).copied().unwrap_or(false) {
            let (local_name, namespace) = st
                .func_identity
                .get(key)
                .cloned()
                .unwrap_or_else(|| (name.clone(), String::new()));
            let mut item = json!({
                "id": format!("ctc_{call_id}"),
                "type": "custom_tool_call",
                "status": tool_status,
                "input": unwrap_custom_tool_input(&args),
                "call_id": call_id,
                "name": local_name,
            });
            if !namespace.is_empty() {
                item["namespace"] = json!(namespace);
            }
            output_items.push((st.func_output_ix.get(key).copied().unwrap_or(0), item));
        } else {
            let (local_name, namespace) = st
                .func_identity
                .get(key)
                .cloned()
                .unwrap_or_else(|| (name.clone(), String::new()));
            let mut item = json!({
                "id": format!("fc_{call_id}"),
                "type": "function_call",
                "status": tool_status,
                "arguments": args,
                "call_id": call_id,
                "name": local_name,
            });
            if !namespace.is_empty() {
                item["namespace"] = json!(namespace);
            }
            output_items.push((st.func_output_ix.get(key).copied().unwrap_or(0), item));
        }
    }
    output_items.sort_by_key(|(index, _)| *index);
    if !output_items.is_empty() {
        completed["response"]["output"] =
            Value::Array(output_items.into_iter().map(|(_, item)| item).collect());
    }

    if st.usage_seen {
        let total = if st.total_tokens == 0 {
            st.prompt_tokens + st.completion_tokens
        } else {
            st.total_tokens
        };
        completed["response"]["usage"] = json!({
            "input_tokens": st.prompt_tokens,
            "input_tokens_details": {"cached_tokens": st.cached_tokens},
            "output_tokens": st.completion_tokens,
            "output_tokens_details": {"reasoning_tokens": st.reasoning_tokens},
            "total_tokens": total,
        });
        if st.reasoning_tokens == 0 {
            if let Some(details) =
                completed["response"]["usage"]["output_tokens_details"].as_object_mut()
            {
                details.remove("reasoning_tokens");
            }
        }
    }

    completed
}
