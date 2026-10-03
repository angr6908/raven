use serde::Deserialize;
use serde_json::Value;

use crate::translate::usage::TokenUsage;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct GenerateEvent {
    #[serde(default)]
    pub r#type: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub tool_call_id: String,
    #[serde(default)]
    pub tool_name: String,
    #[serde(default)]
    pub input: Value,
    #[serde(default)]
    pub finish_reason: String,
    pub total_usage: Option<TokenUsage>,
    #[serde(default)]
    pub error: Option<Value>,
}
