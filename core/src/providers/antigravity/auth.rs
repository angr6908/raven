use std::time::Duration;

use crate::state::accounts::Account;
use crate::translate::ids::{now_unix_secs, sha256};

#[derive(Debug, Clone, Default)]
pub struct Auth {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
    pub project_id: String,
    pub email: String,
}

impl Auth {
    pub fn from_account(account: &Account) -> Self {
        Self {
            access_token: account.antigravity_access_token.clone(),
            refresh_token: account.antigravity_refresh_token.clone(),
            expires_at: account.antigravity_expires_at,
            project_id: account.antigravity_project_id.clone(),
            email: account.antigravity_email.clone(),
        }
    }

    pub fn needs_refresh(&self, within: Duration) -> bool {
        if self.access_token.is_empty() {
            return true;
        }
        if self.expires_at <= 0 {
            return true;
        }
        now_unix_secs() + within.as_secs() as i64 >= self.expires_at
    }
}

pub fn stable_project_id(seed: &str) -> String {
    let digest = sha256(&format!("antigravity:{seed}"));
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0f) | 0x50;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    let hex = hex::encode(bytes);
    format!(
        "{}-{}-{}-{}-{}",
        &hex[0..8],
        &hex[8..12],
        &hex[12..16],
        &hex[16..20],
        &hex[20..]
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_missing_or_expiring_token_asks_for_a_refresh() {
        let mut auth = Auth {
            access_token: "t".into(),
            expires_at: now_unix_secs() + 3600,
            ..Auth::default()
        };
        assert!(!auth.needs_refresh(Duration::from_secs(300)));
        assert!(auth.needs_refresh(Duration::from_secs(4000)));

        auth.access_token = String::new();
        assert!(auth.needs_refresh(Duration::from_secs(0)));
    }

    #[test]
    fn the_fallback_project_id_is_a_stable_uuid() {
        let first = stable_project_id("a@example.com");
        assert_eq!(first, stable_project_id("a@example.com"));
        assert_ne!(first, stable_project_id("b@example.com"));
        assert_eq!(first.len(), 36);
        assert_eq!(&first[14..15], "5");
    }
}
