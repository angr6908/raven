use base64::engine::general_purpose::{URL_SAFE, URL_SAFE_NO_PAD};
use base64::Engine;
use serde_json::Value;

const MAX_GPT_REASONING_SIGNATURE_LEN: usize = 32 * 1024 * 1024;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum SignatureProvider {
    Claude,
    Gemini,
    Gpt,
    #[default]
    Unknown,
}

pub fn signature_provider_from_cache_prefix(prefix: &str) -> SignatureProvider {
    match prefix.trim().to_ascii_lowercase().as_str() {
        "claude" | "anthropic" | "cais" | "claude-cais" | "claude_cais" | "ccmax"
        | "claude-code-max" | "claude_code_max" => SignatureProvider::Claude,
        "gemini" | "google" => SignatureProvider::Gemini,
        "openai" | "gpt" | "codex" => SignatureProvider::Gpt,
        _ => SignatureProvider::Unknown,
    }
}

pub fn split_signature_provider_prefix(raw: &str) -> (SignatureProvider, &str, bool) {
    let trimmed = raw.trim();
    let Some((prefix, rest)) = trimmed.split_once('#') else {
        return (SignatureProvider::Unknown, raw, false);
    };
    match signature_provider_from_cache_prefix(prefix) {
        SignatureProvider::Unknown => (SignatureProvider::Unknown, raw, false),
        provider => (provider, rest.trim(), true),
    }
}

pub fn is_valid_gpt_reasoning_signature(raw: &str) -> bool {
    let sig = raw.trim();
    if sig.is_empty() || sig.len() > MAX_GPT_REASONING_SIGNATURE_LEN {
        return false;
    }

    if !sig.starts_with("gAAAA") {
        return false;
    }
    if !sig
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_' || b == b'=')
    {
        return false;
    }
    let Some(decoded) = URL_SAFE_NO_PAD
        .decode(sig)
        .ok()
        .or_else(|| URL_SAFE.decode(sig).ok())
    else {
        return false;
    };
    if decoded.len() < 73 || decoded[0] != 0x80 {
        return false;
    }

    let ciphertext_len = decoded.len() - 1 - 8 - 16 - 32;
    ciphertext_len > 0 && ciphertext_len % 16 == 0
}

pub fn thinking_text(part: &Value) -> String {
    if let Some(text) = part.get("text").and_then(Value::as_str) {
        return text.to_string();
    }
    let Some(field) = part.get("thinking") else {
        return String::new();
    };
    if let Some(text) = field.as_str() {
        return text.to_string();
    }
    if field.is_object() {
        for key in ["text", "thinking"] {
            if let Some(inner) = field.get(key).and_then(Value::as_str) {
                return inner.to_string();
            }
        }
    }
    String::new()
}

pub fn signature_payload_without_provider_prefix(raw: &str) -> &str {
    match split_signature_provider_prefix(raw) {
        (_, payload, true) => payload,
        _ => raw.trim(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cache_prefix_is_strict() {
        assert_eq!(
            signature_provider_from_cache_prefix("gpt"),
            SignatureProvider::Gpt
        );
        assert_eq!(
            signature_provider_from_cache_prefix("Codex"),
            SignatureProvider::Gpt
        );
        assert_eq!(
            signature_provider_from_cache_prefix("claude-cache"),
            SignatureProvider::Unknown
        );
    }

    #[test]
    fn rejects_non_gpt_signatures() {
        assert!(!is_valid_gpt_reasoning_signature(""));
        assert!(!is_valid_gpt_reasoning_signature("EroDCkYIBhgCKkD..."));
        assert!(!is_valid_gpt_reasoning_signature("gAAAA!!!"));
    }

    #[test]
    fn reads_thinking_text_in_reference_order() {
        assert_eq!(thinking_text(&json!({"text": "a", "thinking": "b"})), "a");
        assert_eq!(thinking_text(&json!({"thinking": "b"})), "b");
        assert_eq!(thinking_text(&json!({"thinking": {"text": "c"}})), "c");
        assert_eq!(thinking_text(&json!({})), "");
    }
}
