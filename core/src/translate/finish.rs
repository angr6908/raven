pub fn map_finish_reason(reason: &str) -> String {
    match reason {
        "tool-calls" => "tool_calls".to_string(),
        "length" | "max_tokens" | "max-tokens" | "max_output_tokens" => "length".to_string(),
        _ => "stop".to_string(),
    }
}

pub fn normalize_chat_finish_reason(reason: &str) -> String {
    match reason {
        "stop" | "length" | "tool_calls" | "content_filter" | "function_call" => reason.to_string(),
        other => map_finish_reason(other),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chat_finish_reason_preserves_canonical_values() {
        for r in [
            "stop",
            "length",
            "tool_calls",
            "content_filter",
            "function_call",
        ] {
            assert_eq!(normalize_chat_finish_reason(r), r, "must pass {r} through");
        }

        assert_eq!(normalize_chat_finish_reason("tool-calls"), "tool_calls");
        assert_eq!(normalize_chat_finish_reason("max_tokens"), "length");

        assert_eq!(normalize_chat_finish_reason("weird"), "stop");
    }
}
