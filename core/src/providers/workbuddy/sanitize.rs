use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;

const SANITIZE_FEATURES: [&str; 4] = [
    "x-anthropic-billing-header",
    "cc_entrypoint=",
    "You are Claude Code",
    "Main branch (",
];

fn header_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)x-anthropic-billing-header:[^;\n]*;?\s*").unwrap())
}

fn kv_re() -> &'static Regex {
    static RE: OnceLock<Regex> = OnceLock::new();
    RE.get_or_init(|| Regex::new(r"(?i)\bcc_[a-z0-9_]+=[^;\n]*;?\s*").unwrap())
}

const SANITIZE_REWRITES: [(&str, &str); 2] = [
    (
        "You are Claude Code, Anthropic's official CLI for Claude.",
        "You are Claude Code, Anthropic's official CLI tool for Claude.",
    ),
    (
        "Main branch (you will usually use this for PRs)",
        "Default branch (you will usually use this for PRs)",
    ),
];

fn has_fingerprint(text: &str) -> bool {
    for feature in SANITIZE_FEATURES {
        if text.contains(feature) {
            return true;
        }
    }
    header_re().is_match(text)
}

pub fn sanitize_text(text: &str) -> String {
    if !has_fingerprint(text) {
        return text.to_string();
    }
    let mut out = text.to_string();
    for (from, to) in SANITIZE_REWRITES {
        out = out.replace(from, to);
    }
    if header_re().is_match(&out) {
        out = header_re().replace_all(&out, "").into_owned();
    }
    if out.contains("cc_") {
        let mut prev = String::new();
        while prev != out {
            prev = out.clone();
            out = kv_re().replace_all(&out, "").into_owned();
        }
    }
    out.trim().to_string()
}

pub fn sanitize_content(value: &mut Value) -> bool {
    match value {
        Value::String(s) => {
            let cleaned = sanitize_text(s);
            if cleaned != *s {
                *s = cleaned;
                true
            } else {
                false
            }
        }
        Value::Array(parts) => {
            let mut changed = false;
            for part in parts.iter_mut() {
                if let Some(map) = part.as_object_mut() {
                    if let Some(Value::String(text)) = map.get_mut("text") {
                        let cleaned = sanitize_text(text);
                        if cleaned != *text {
                            *text = cleaned;
                            changed = true;
                        }
                    }
                }
            }
            changed
        }
        _ => false,
    }
}

pub fn sanitize_messages(messages: &mut [Value]) -> bool {
    let mut changed = false;
    for message in messages.iter_mut() {
        if let Some(map) = message.as_object_mut() {
            if let Some(content) = map.get_mut("content") {
                if sanitize_content(content) {
                    changed = true;
                }
            }
        }
    }
    changed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unchanged_text_returns_original() {
        let text = "Say hello to the world";
        assert_eq!(sanitize_text(text), text);
    }

    #[test]
    fn identity_rewrite_changes_one_word() {
        let text = "You are Claude Code, Anthropic's official CLI for Claude.";
        let out = sanitize_text(text);
        assert_eq!(
            out,
            "You are Claude Code, Anthropic's official CLI tool for Claude."
        );
    }

    #[test]
    fn billing_header_segment_is_stripped() {
        let text = "prefix; x-anthropic-billing-header:abc=123; suffix";
        assert_eq!(sanitize_text(text), "prefix; suffix");
    }

    #[test]
    fn trailing_cc_kv_is_stripped_in_loop() {
        let text = "cc_version=1.2.3; cc_entrypoint=desktop; end";
        let out = sanitize_text(text);
        assert_eq!(out, "end");
    }

    #[test]
    fn case_insensitive_header_is_caught_by_regex() {
        let text = "X-Anthropic-Billing-Header:foo; rest";
        assert!(!sanitize_text(text).contains("X-Anthropic-Billing-Header"));
    }

    #[test]
    fn multimodal_content_only_touches_text_parts() {
        let mut v = serde_json::json!([
            {"type": "text", "text": "You are Claude Code, Anthropic's official CLI for Claude."},
            {"type": "image", "image_url": "data:image/png;base64,AAAA"},
            {"type": "text", "text": "plain text"}
        ]);
        assert!(sanitize_content(&mut v));
        let arr = v.as_array().unwrap();
        assert_eq!(
            arr[0]["text"],
            "You are Claude Code, Anthropic's official CLI tool for Claude."
        );
        assert_eq!(arr[1]["image_url"], "data:image/png;base64,AAAA");
        assert_eq!(arr[2]["text"], "plain text");
    }
}
