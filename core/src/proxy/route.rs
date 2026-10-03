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
        Some(entry) => {
            let provider = providers::from_entry(&entry.provider);
            match provider {
                Provider::CommandCode => commandcode_target(app, &alias).await,
                _ => Target {
                    name: entry.provider_name().to_string(),
                    upstream_model: entry.upstream_model(&alias).to_string(),
                    provider,
                    alias: alias.clone(),
                    effort: String::new(),
                },
            }
        }
        None => commandcode_target(app, &alias).await,
    };
    target.effort = effort;
    eprintln!(
        "{}: {} -> {} ({}){}",
        endpoint,
        model,
        target.upstream_model,
        if target.name.is_empty() {
            "commandcode"
        } else {
            &target.name
        },
        if target.effort.is_empty() {
            String::new()
        } else {
            format!(" effort={}", target.effort)
        }
    );
    target
}

async fn commandcode_target(app: &App, model: &str) -> Target {
    let upstream_model = match app.providers.commandcode_model(model) {
        Some(name) => name,
        None => app.models.resolve(model).await,
    };
    Target {
        name: crate::state::accounts::Channel::Commandcode
            .as_str()
            .to_string(),
        upstream_model,
        provider: Provider::CommandCode,
        alias: model.to_string(),
        effort: String::new(),
    }
}
