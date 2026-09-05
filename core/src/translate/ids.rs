use regex::Regex;
use std::sync::OnceLock;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

static NON_SLUG_CHARS: OnceLock<Regex> = OnceLock::new();

pub fn uuid_v4() -> String {
    Uuid::new_v4().to_string()
}

pub fn uuid_v4_simple() -> String {
    Uuid::new_v4().simple().to_string()
}

pub fn sha256(text: &str) -> [u8; 32] {
    use sha2::Digest;
    let mut hasher = sha2::Sha256::new();
    hasher.update(text.as_bytes());
    hasher.finalize().into()
}

pub fn sha256_hex_prefix(text: &str, n: usize) -> String {
    hex::encode(&sha256(text)[..n])
}

pub fn now_unix_secs() -> i64 {
    since_epoch().as_secs() as i64
}

pub fn now_unix_millis() -> i64 {
    since_epoch().as_millis() as i64
}

pub fn now_unix_nanos() -> u128 {
    since_epoch().as_nanos()
}

pub fn project_slug_from_path(path: &str) -> String {
    let regex = NON_SLUG_CHARS.get_or_init(|| Regex::new(r"[^a-z0-9]+").unwrap());
    let mut slug = path.to_lowercase();
    let bytes = slug.as_bytes();
    if bytes.len() > 1 && bytes[1] == b':' {
        slug.drain(..2);
    }
    let slug = regex.replace_all(&slug, "-").to_string();
    let slug = slug.trim_matches('-').to_string();
    if slug.is_empty() {
        "project".to_string()
    } else {
        slug
    }
}

fn since_epoch() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn project_slug_handles_windows_paths() {
        assert_eq!(
            project_slug_from_path("/Users/Me/My App"),
            "users-me-my-app"
        );
        assert_eq!(project_slug_from_path("C:\\Apps\\Raven"), "apps-raven");
    }
}
