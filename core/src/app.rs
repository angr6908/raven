use std::sync::Arc;
use std::time::Duration;

use crate::providers::commandcode::{self, limits::AccountLimits, models::ModelCache};
use crate::providers::workbuddy::Workbuddy;
use crate::config::{Config, VERSION};
use crate::state::accounts::{AccountsManager, Channel};
use crate::state::catalog::CatalogCache;
use crate::state::providers::Store;
use crate::state::usage::UsageRecorder;
use crate::translate::ids::project_slug_from_path;

pub struct App {
    pub accounts: Arc<AccountsManager>,
    pub providers: Arc<Store>,
    pub usage: Arc<UsageRecorder>,
    pub limits: Arc<AccountLimits>,
    pub models: Arc<ModelCache>,
    pub catalog: Arc<CatalogCache>,
    pub workbuddy: Arc<Workbuddy>,

    pub client: reqwest::Client,
    pub commandcode: commandcode::Settings,
    pub work_dir: String,
    pub project_slug: String,
    pub user_agent: String,
}

impl App {
    pub fn build(config: &Config) -> Result<Self, String> {
        let commandcode = commandcode::Settings::resolve(&config.api_base, &config.cli_version);
        let user_agent = format!("raven/{VERSION}");
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(30))
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(32)
            .build()
            .map_err(|err| format!("build http client: {err}"))?;

        let accounts = Arc::new(AccountsManager::new(&config.data_dir)?);
        let workbuddy = Workbuddy::new(&config.data_dir, Arc::clone(&accounts), client.clone());

        Ok(Self {
            limits: Arc::new(AccountLimits::new(
                client.clone(),
                user_agent.clone(),
                commandcode.clone(),
            )),
            models: Arc::new(ModelCache::new(
                client.clone(),
                &commandcode,
                user_agent.clone(),
            )),
            usage: Arc::new(UsageRecorder::new(&config.data_dir)?),
            providers: Arc::new(Store::new(&config.data_dir)?),
            catalog: Arc::new(CatalogCache::new()),
            accounts,
            workbuddy,
            client,
            commandcode,
            work_dir: config.work_dir().to_string_lossy().into_owned(),
            project_slug: project_slug_from_path(&config.work_dir().to_string_lossy()),
            user_agent,
        })
    }

    pub fn report_pools(&self) {
        let mut any = false;
        for channel in Channel::ALL {
            let names: Vec<String> = self
                .accounts
                .serving(channel)
                .into_iter()
                .map(|account| account.name)
                .collect();
            any |= !names.is_empty();
            eprintln!(
                "pool {channel}: {} serving: {}",
                names.len(),
                if names.is_empty() {
                    "—".to_string()
                } else {
                    names.join(", ")
                }
            );
        }
        if !any {
            eprintln!(
                "warning: no enabled account with live credentials on any channel; add accounts in the panel"
            );
        }
    }

    pub fn shutdown(&self) {
        self.workbuddy.pool.flush();
        self.usage.close();
    }
}
