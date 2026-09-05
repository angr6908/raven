use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize, Deserialize)]
pub struct ChatRequest {
    #[serde(default)]
    pub model: String,
    #[serde(default)]
    pub messages: Vec<ChatMessage>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tools: Vec<ChatTool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool_choice: Option<Value>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub parallel_tool_calls: Option<bool>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub response_format: Option<Value>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub stream_options: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_k: Option<f64>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub n: Option<i64>,

    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub modalities: Vec<String>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_config: Option<Value>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub generation_config: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub max_completion_tokens: Option<i64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub temperature: Option<f64>,

    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub top_p: Option<f64>,

    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub stop: Vec<String>,

    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub user: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub reasoning_effort: String,
    #[serde(default)]
    pub stream: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatMessage {
    #[serde(default)]
    pub role: String,

    #[serde(default, skip_serializing_if = "Value::is_null")]
    pub content: Value,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ChatToolCall>,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub tool_call_id: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub name: String,

    #[serde(default, alias = "reasoning", skip_serializing_if = "String::is_empty")]
    pub reasoning_content: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatToolCall {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub r#type: String,
    #[serde(default)]
    pub function: ChatFunctionCall,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChatFunctionCall {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub arguments: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ChatTool {
    #[serde(default = "default_function_type")]
    pub r#type: String,
    #[serde(default)]
    pub function: ChatToolFunction,
}

fn default_function_type() -> String {
    "function".to_string()
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ChatToolFunction {
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub description: String,
    #[serde(default)]
    pub parameters: Value,
}

#[derive(Debug, Serialize)]
pub struct ChatCompletion {
    pub id: String,
    pub object: String,
    pub created: i64,
    pub model: String,
    pub choices: Vec<ChatChoice>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub usage: Option<ChatUsage>,
}

#[derive(Debug, Serialize)]
pub struct ChatChoice {
    pub index: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub delta: Option<ChatDelta>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<ChatMessageOut>,
    pub finish_reason: Option<String>,
}

#[derive(Debug, Serialize, Default)]
pub struct ChatDelta {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub role: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning_content: Option<String>,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ChatToolCallDelta>,
}

#[derive(Debug, Serialize)]
pub struct ChatMessageOut {
    pub role: String,
    pub content: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub reasoning_content: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub tool_calls: Vec<ChatToolCall>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ChatToolCallDelta {
    pub index: usize,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub r#type: String,
    #[serde(default)]
    pub function: ChatToolCallDeltaFunction,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ChatToolCallDeltaFunction {
    #[serde(skip_serializing_if = "String::is_empty")]
    pub name: String,
    pub arguments: String,
}

#[derive(Debug, Serialize)]
pub struct ChatUsage {
    pub prompt_tokens: i64,
    pub completion_tokens: i64,
    pub total_tokens: i64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_tokens_details: Option<PromptTokensDetails>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub completion_tokens_details: Option<CompletionTokensDetails>,
}

#[derive(Debug, Serialize)]
pub struct PromptTokensDetails {
    pub cached_tokens: i64,
}

#[derive(Debug, Serialize)]
pub struct CompletionTokensDetails {
    pub reasoning_tokens: i64,
}
impl ChatRequest {
    pub fn apply_openai_compat_defaults(&mut self) {
        if !self.stream {
            return;
        }
        self.stream_options = Some(serde_json::json!({"include_usage": true}));
    }
}
