use serde::Deserialize;
use serde_json::Value;

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    #[serde(default)]
    pub input_tokens: i64,
    #[serde(default)]
    pub output_tokens: i64,
    #[serde(default)]
    pub total_tokens: i64,
    #[serde(default)]
    pub cached_input_tokens: i64,
    #[serde(default)]
    pub input_token_details: InputTokenDetails,
    #[serde(default)]
    pub output_token_details: OutputTokenDetails,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InputTokenDetails {
    #[serde(default)]
    pub cache_read_tokens: i64,
    #[serde(default)]
    pub cache_write_tokens: i64,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputTokenDetails {
    #[serde(default)]
    pub reasoning_tokens: i64,
}

fn i64_at(usage: &Value, pointer: &str) -> i64 {
    usage.pointer(pointer).and_then(Value::as_i64).unwrap_or(0)
}

impl TokenUsage {
    pub fn from_counts(
        input_tokens: i64,
        output_tokens: i64,
        total_tokens: i64,
        cached_tokens: i64,
        reasoning_tokens: i64,
    ) -> Self {
        Self {
            input_tokens,
            output_tokens,
            total_tokens: if total_tokens == 0 {
                input_tokens + output_tokens
            } else {
                total_tokens
            },
            cached_input_tokens: cached_tokens,
            input_token_details: InputTokenDetails {
                cache_read_tokens: cached_tokens,
                cache_write_tokens: 0,
            },
            output_token_details: OutputTokenDetails { reasoning_tokens },
        }
    }

    pub fn from_openai_chat_usage(usage: &Value) -> Self {
        Self::from_counts(
            i64_at(usage, "/prompt_tokens"),
            i64_at(usage, "/completion_tokens"),
            i64_at(usage, "/total_tokens"),
            i64_at(usage, "/prompt_tokens_details/cached_tokens"),
            i64_at(usage, "/completion_tokens_details/reasoning_tokens"),
        )
    }

    pub fn from_responses_usage(usage: &Value) -> Self {
        let mut out = Self::from_counts(
            i64_at(usage, "/input_tokens"),
            i64_at(usage, "/output_tokens"),
            i64_at(usage, "/total_tokens"),
            i64_at(usage, "/input_tokens_details/cached_tokens"),
            i64_at(usage, "/output_tokens_details/reasoning_tokens"),
        );
        out.input_token_details.cache_write_tokens =
            i64_at(usage, "/input_tokens_details/cache_write_tokens");
        out
    }

    pub fn from_messages_usage(usage: &Value) -> Self {
        let cached = i64_at(usage, "/cache_read_input_tokens");
        Self::from_counts(
            i64_at(usage, "/input_tokens") + cached,
            i64_at(usage, "/output_tokens"),
            0,
            cached,
            0,
        )
    }
}
