use std::time::{Duration, SystemTime, UNIX_EPOCH};
use uuid::Uuid;

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

fn since_epoch() -> Duration {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
}
