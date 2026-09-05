use crate::app::App;
use crate::providers::{self, Provider};

pub struct Target {
    pub name: String,
    pub upstream_model: String,
    pub provider: Provider,
}

pub async fn resolve(app: &App, endpoint: &str, model: &str) -> Target {
    let target = match app.providers.find(model) {
        Some(entry) => {
            let provider = providers::from_entry(&entry.provider);
            match provider {
                Provider::CommandCode => commandcode_target(app, model).await,
                _ => Target {
                    name: entry.provider_name().to_string(),
                    upstream_model: entry.upstream_model(model).to_string(),
                    provider,
                },
            }
        }
        None => commandcode_target(app, model).await,
    };
    eprintln!(
        "{endpoint}: {} -> {} ({})",
        model,
        target.upstream_model,
        if target.name.is_empty() {
            "commandcode"
        } else {
            &target.name
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
    }
}
