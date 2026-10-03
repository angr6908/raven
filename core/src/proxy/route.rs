use crate::app::App;
use crate::providers::{self, Provider};

pub struct Target {
    pub name: String,
    pub upstream_model: String,
    pub provider: Provider,
    pub alias: String,
    pub effort: String,
}

pub async fn resolve(app: &App, endpoint: &str, model: &str) -> Target {
    let mut alias = model.to_string();
    let mut effort = String::new();
    if let Some((base, level)) = app.providers.find_with_effort(model) {
        alias = base.to_string();
        effort = level.to_string();
    }
    let mut target = match app.providers.find(&alias) {
        Some(entry) => Target {
            name: entry.provider_name().to_string(),
            upstream_model: entry.upstream_model(&alias).to_string(),
            provider: providers::from_entry(&entry.provider),
            alias: alias.clone(),
            effort: String::new(),
        },
        None => Target {
            name: String::new(),
            upstream_model: alias.clone(),
            provider: providers::from_entry(&serde_json::Value::Null),
            alias: alias.clone(),
            effort: String::new(),
        },
    };
    target.effort = effort;
    eprintln!(
        "{}: {} -> {} ({}){}",
        endpoint,
        model,
        target.upstream_model,
        target.name,
        if target.effort.is_empty() {
            String::new()
        } else {
            format!(" effort={}", target.effort)
        }
    );
    target
}
