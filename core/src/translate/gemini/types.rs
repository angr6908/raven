use serde::Serialize;
use serde_json::Value;

pub const REQUEST_TYPE_AGENT: &str = "agent";
pub const USER_AGENT_ANTIGRAVITY: &str = "antigravity";

pub const ROLE_USER: &str = "user";
pub const ROLE_MODEL: &str = "model";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Thinking {
    pub include_thoughts: bool,
    pub budget: i64,
}

#[derive(Debug, Clone, Default)]
pub struct Plan {
    pub runtime_model: String,
    pub model_enum: String,
    pub max_output_tokens: i64,
    pub thinking: Option<Thinking>,
    pub tool_call_ids: bool,
    pub legacy_tool_parameters: bool,
    pub requires_thought_signature: bool,
}

#[derive(Debug, Serialize)]
pub struct Envelope {
    pub model: String,
    pub request: Request,
    #[serde(rename = "requestType")]
    pub request_type: &'static str,
    #[serde(rename = "userAgent")]
    pub user_agent: &'static str,
    #[serde(rename = "requestId")]
    pub request_id: String,
}

#[derive(Debug, Serialize)]
pub struct Request {
    pub contents: Vec<Value>,
    #[serde(rename = "systemInstruction", skip_serializing_if = "Value::is_null")]
    pub system_instruction: Value,
    #[serde(rename = "generationConfig", skip_serializing_if = "Value::is_null")]
    pub generation_config: Value,
    #[serde(skip_serializing_if = "Value::is_null")]
    pub tools: Value,
    #[serde(rename = "toolConfig", skip_serializing_if = "Value::is_null")]
    pub tool_config: Value,
    #[serde(rename = "sessionId")]
    pub session_id: String,
    pub labels: Value,
}
