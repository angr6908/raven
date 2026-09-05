use serde_json::Value;
use std::path::PathBuf;

use crate::translate::ids::now_unix_secs;

#[derive(Debug, Clone)]
pub struct Auth {
    pub access_token: String,
    pub refresh_token: String,
    pub expires_at: i64,
    pub domain: String,
    pub uid: String,
    pub enterprise_id: String,
    pub nickname: String,

    pub account_name: String,
}

impl Auth {
    pub fn region(&self) -> &'static str {
        let d = self.domain.trim().to_ascii_lowercase();
        if d == "workbuddy.ai" || d.ends_with(".workbuddy.ai") {
            "global"
        } else {
            "cn"
        }
    }

    pub fn needs_refresh(&self, within: std::time::Duration) -> bool {
        if self.expires_at <= 0 {
            return true;
        }
        now_unix_secs() + within.as_secs() as i64 >= self.expires_at
    }
}

pub fn parse(raw: &[u8]) -> Result<Auth, String> {
    if raw.is_empty() {
        return Err("empty auth storage".to_string());
    }
    let probe: Value =
        serde_json::from_slice(raw).map_err(|e| format!("storage_parse_error: {e}"))?;
    let is_nested = probe.get("auth").is_some();

    let (access_token, refresh_token, expires_at, domain, uid, enterprise_id, nickname) =
        if is_nested {
            let nested = serde_json::from_slice::<serde_json::Value>(raw)
                .map_err(|e| format!("storage_parse_error: {e}"))?;
            let auth = nested
                .get("auth")
                .and_then(Value::as_object)
                .ok_or_else(|| "nested auth missing 'auth' key".to_string())?;
            let account = nested
                .get("account")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();
            (
                auth.get("accessToken")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                auth.get("refreshToken")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                auth.get("expiresAt").and_then(Value::as_i64).unwrap_or(0),
                auth.get("domain")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                account
                    .get("uid")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                account
                    .get("enterpriseId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                account
                    .get("nickname")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            )
        } else {
            let flat = serde_json::from_slice::<serde_json::Value>(raw)
                .map_err(|e| format!("storage_parse_error: {e}"))?;
            (
                flat.get("accessToken")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                flat.get("refreshToken")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                flat.get("expiresAt").and_then(Value::as_i64).unwrap_or(0),
                flat.get("domain")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                flat.get("uid")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                flat.get("enterpriseId")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
                flat.get("nickname")
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string(),
            )
        };

    if access_token.trim().is_empty() {
        return Err("parse_error: missing accessToken".to_string());
    }

    let expires_at = normalize_expires_at(expires_at);

    let account_name = uid.clone();

    Ok(Auth {
        access_token,
        refresh_token,
        expires_at,
        domain,
        uid,
        enterprise_id,
        nickname,
        account_name,
    })
}

pub fn to_nested_value(a: &Auth) -> Value {
    serde_json::json!({
        "account": {
            "uid": a.uid,
            "enterpriseId": a.enterprise_id,
            "nickname": a.nickname,
        },
        "auth": {
            "accessToken": a.access_token,
            "refreshToken": a.refresh_token,
            "expiresAt": a.expires_at,
            "domain": a.domain,
        },
    })
}

pub fn read_local() -> Result<(PathBuf, Auth), Vec<PathBuf>> {
    let mut searched: Vec<PathBuf> = Vec::new();
    let Some(home) = std::env::var_os("HOME").map(PathBuf::from) else {
        return Err(searched);
    };

    let desktop = home.join(
        "Library/Application Support/CodeBuddyExtension/Data/Public/auth/workbuddy-desktop.info",
    );
    searched.push(desktop.clone());
    if let Ok(raw) = std::fs::read(&desktop) {
        if let Ok(auth) = parse(&raw) {
            return Ok((desktop, auth));
        }
    }

    Err(searched)
}

fn normalize_expires_at(expires_at: i64) -> i64 {
    if expires_at >= 1_000_000_000_000 {
        expires_at / 1000
    } else {
        expires_at
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn millisecond_expiry_is_normalized_to_seconds() {
        let raw = br#"{
            "account": {"uid": "u-1", "nickname": "tester"},
            "auth": {"accessToken": "tok", "refreshToken": "ref",
                     "expiresAt": 1793192466459, "domain": "www.workbuddy.cn"}
        }"#;
        let a = parse(raw).unwrap();
        assert_eq!(a.expires_at, 1793192466);
        assert_eq!(a.uid, "u-1");
        assert_eq!(a.region(), "cn");
    }

    #[test]
    fn second_expiry_is_left_alone() {
        let raw = br#"{"accessToken": "tok", "expiresAt": 1793192466, "uid": "u-2"}"#;
        let a = parse(raw).unwrap();
        assert_eq!(a.expires_at, 1793192466);
    }
}
