use crate::translate::finish::map_finish_reason;
use crate::translate::chat::types::{
    ChatToolCall, ChatUsage, CompletionTokensDetails, PromptTokensDetails,
};
use crate::translate::usage::TokenUsage;

#[derive(Default)]
pub struct Collector {
    pub content: String,
    pub reasoning: String,
    pub tool_calls: Vec<ChatToolCall>,
    pub usage: Option<TokenUsage>,
    pub(crate) finish: String,
    pub(crate) tool_call_count: usize,
    pub(crate) collect_body: bool,

    pub(crate) stream_done: bool,
}

impl Collector {
    pub fn buffering() -> Self {
        Self {
            collect_body: true,
            ..Self::default()
        }
    }

    pub fn counting() -> Self {
        Self::default()
    }

    pub fn with_usage(usage: TokenUsage) -> Self {
        Self {
            usage: Some(usage),
            ..Self::default()
        }
    }

    pub fn finish_reason(&self) -> String {
        if !self.finish.is_empty() {
            return self.finish.clone();
        }

        map_finish_reason(if self.tool_call_count == 0 {
            ""
        } else {
            "tool-calls"
        })
    }

    pub fn cached_tokens(&self) -> i64 {
        self.usage
            .as_ref()
            .map(|usage| {
                if usage.input_token_details.cache_read_tokens != 0 {
                    usage.input_token_details.cache_read_tokens
                } else {
                    usage.cached_input_tokens
                }
            })
            .unwrap_or(0)
    }

    pub fn reasoning_tokens(&self) -> i64 {
        self.usage
            .as_ref()
            .map(|usage| usage.output_token_details.reasoning_tokens)
            .unwrap_or(0)
    }

    pub fn cache_write_tokens(&self) -> i64 {
        self.usage
            .as_ref()
            .map(|usage| usage.input_token_details.cache_write_tokens)
            .unwrap_or(0)
    }

    pub fn total_tokens(&self) -> i64 {
        self.usage
            .as_ref()
            .map(|usage| {
                if usage.total_tokens != 0 {
                    usage.total_tokens
                } else {
                    usage.input_tokens + usage.output_tokens
                }
            })
            .unwrap_or(0)
    }

    pub fn usage_input(&self) -> i64 {
        self.usage.as_ref().map_or(0, |usage| usage.input_tokens)
    }

    pub fn usage_output(&self) -> i64 {
        self.usage.as_ref().map_or(0, |usage| usage.output_tokens)
    }

    pub fn openai_usage(&self) -> Option<ChatUsage> {
        let usage = self.usage.as_ref()?;
        let cached = self.cached_tokens();
        let total = self.total_tokens();
        let mut prompt_details = None;
        if cached > 0 {
            prompt_details = Some(PromptTokensDetails {
                cached_tokens: cached,
            });
        }
        let mut completion_details = None;
        if usage.output_token_details.reasoning_tokens > 0 {
            completion_details = Some(CompletionTokensDetails {
                reasoning_tokens: usage.output_token_details.reasoning_tokens,
            });
        }
        Some(ChatUsage {
            prompt_tokens: usage.input_tokens,
            completion_tokens: usage.output_tokens,
            total_tokens: total,
            prompt_tokens_details: prompt_details,
            completion_tokens_details: completion_details,
        })
    }
}

pub fn completion_id() -> String {
    format!("chatcmpl-{}", crate::translate::ids::uuid_v4_simple())
}
