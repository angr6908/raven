use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::translate::usage::TokenUsage;

#[derive(Debug, Serialize)]
pub struct GenerateRequest {
    pub config: GenerateConfig,
    pub memory: Value,
    pub taste: Value,
    pub skills: Value,
    pub params: GenerateParams,
    #[serde(rename = "threadId")]
    pub thread_id: String,
}

#[derive(Debug, Default, Serialize)]
pub struct GenerateConfig {
    #[serde(rename = "workingDir")]
    pub working_dir: String,
    pub date: String,
    pub environment: String,
    pub structure: Vec<String>,
    #[serde(rename = "isGitRepo")]
    pub is_git_repo: bool,
    #[serde(rename = "currentBranch")]
    pub current_branch: String,
    #[serde(rename = "mainBranch")]
    pub main_branch: String,
    #[serde(rename = "gitStatus")]
    pub git_status: String,
    #[serde(rename = "recentCommits")]
    pub recent_commits: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct GenerateParams {
    pub model: String,
    pub messages: Vec<Value>,
    pub tools: Vec<GenerateTool>,
    pub system: String,
    #[serde(rename = "reasoning_effort", skip_serializing_if = "String::is_empty")]
    pub reasoning_effort: String,
    #[serde(rename = "max_tokens")]
    pub max_tokens: i64,
    pub temperature: f64,
    pub stream: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct GenerateTool {
    pub r#type: String,
    pub name: String,
    pub description: String,
    #[serde(rename = "input_schema")]
    pub input_schema: Value,
}

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
#[derive(Debug, Deserialize)]
pub struct GenerateErrorEnvelope {
    #[serde(default)]
    pub error: GenerateErrorBody,
}

#[derive(Debug, Default, Deserialize)]
pub struct GenerateErrorBody {
    #[serde(default)]
    pub code: String,
    pub status: Option<i32>,
    #[serde(default)]
    pub message: String,
}
