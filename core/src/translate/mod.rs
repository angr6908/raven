pub mod chat;
pub mod collect;
pub mod finish;
pub mod generate;
pub mod ids;
pub mod json;
pub mod messages;
pub mod responses;
pub mod signature;
pub mod summary;
pub mod tokens;
pub mod usage;

use crate::translate::collect::Collector;

pub struct StreamOutcome {
    pub first_token_at: Option<std::time::Instant>,
    pub usage: Collector,
    pub finish: String,
    pub error: Option<String>,
}

impl StreamOutcome {
    pub fn failed(first_token_at: Option<std::time::Instant>, message: String) -> Self {
        Self {
            first_token_at,
            usage: Collector::counting(),
            finish: String::new(),
            error: Some(message),
        }
    }
}
