use std::sync::Arc;
use std::time::Duration;

use crate::config::Config;
use crate::providers::antigravity::Antigravity;
use crate::providers::workbuddy::Workbuddy;
use crate::state::accounts::{AccountsManager, Channel};
use crate::state::catalog::CatalogCache;
use crate::state::providers::Store;
use crate::state::usage::UsageRecorder;

pub struct App {
    pub accounts: Arc<AccountsManager>,
    pub providers: Arc<Store>,
    pub usage: Arc<UsageRecorder>,
    pub catalog: Arc<CatalogCache>,
    pub workbuddy: Arc<Workbuddy>,
    pub antigravity: Arc<Antigravity>,

    pub client: reqwest::Client,
}

impl App {
    pub fn build(config: &Config) -> Result<Self, String> {
        let client = reqwest::Client::builder()
            .connect_timeout(Duration::from_secs(30))
            .pool_idle_timeout(Duration::from_secs(90))
            .pool_max_idle_per_host(32)
            .build()
            .map_err(|err| format!("build http client: {err}"))?;

        let accounts = Arc::new(AccountsManager::new(&config.data_dir)?);
        let workbuddy = Workbuddy::new(&config.data_dir, Arc::clone(&accounts), client.clone());
        let antigravity = Antigravity::new(Arc::clone(&accounts));

        Ok(Self {
            usage: Arc::new(UsageRecorder::new(&config.data_dir)?),
            providers: Arc::new(Store::new(&config.data_dir)?),
            catalog: Arc::new(CatalogCache::new()),
            accounts,
            workbuddy,
            antigravity,
            client,
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
