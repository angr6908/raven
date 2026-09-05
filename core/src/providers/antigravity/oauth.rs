use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::translate::ids::sha256;

use super::client::{AUTH_URL, CALLBACK_PORT, CLIENT_ID, REDIRECT_URI, SCOPES};

const CALLBACK_HOST_ENV: &str = "ANTIGRAVITY_CALLBACK_HOST";
const READ_LIMIT: usize = 8 * 1024;

const PAGE_OK: &str =
    "Antigravity sign-in complete. You can close this window and return to the Raven panel.";
const PAGE_FAILED: &str = "Antigravity sign-in failed. Return to the Raven panel and try again.";

pub struct Pending {
    pub state: String,
    pub verifier: String,
    pub url: String,
}

pub fn begin() -> Pending {
    let verifier = random_token();
    let state = random_token();
    let challenge = URL_SAFE_NO_PAD.encode(sha256(&verifier));
    let scope = SCOPES.join(" ");
    let url = reqwest::Url::parse_with_params(
        AUTH_URL,
        &[
            ("client_id", CLIENT_ID),
            ("response_type", "code"),
            ("redirect_uri", REDIRECT_URI),
            ("scope", &scope),
            ("code_challenge", &challenge),
            ("code_challenge_method", "S256"),
            ("state", &state),
            ("access_type", "offline"),
            ("prompt", "consent"),
        ],
    )
    .map(String::from)
    .unwrap_or_else(|_| AUTH_URL.to_string());

    Pending {
        state,
        verifier,
        url,
    }
}

pub fn callback_host() -> String {
    let configured = std::env::var(CALLBACK_HOST_ENV).unwrap_or_default();
    match configured.trim() {
        "127.0.0.1" | "localhost" => "127.0.0.1".to_string(),
        "::1" => "::1".to_string(),
        _ => "127.0.0.1".to_string(),
    }
}

pub async fn listen() -> Result<TcpListener, String> {
    let address = format!("{}:{CALLBACK_PORT}", callback_host());
    TcpListener::bind(&address).await.map_err(|err| {
        format!("bind {address}: {err} (close whatever holds port {CALLBACK_PORT} and retry)")
    })
}

pub async fn wait_for_code(
    listener: TcpListener,
    state: &str,
    timeout: Duration,
) -> Result<String, String> {
    let deadline = tokio::time::Instant::now() + timeout;
    loop {
        let accepted = tokio::time::timeout_at(deadline, listener.accept()).await;
        let Ok(accepted) = accepted else {
            return Err("timed out waiting for the browser sign-in".to_string());
        };
        let (mut stream, _) = accepted.map_err(|err| format!("accept callback: {err}"))?;

        let mut buffer = vec![0u8; READ_LIMIT];
        let read = stream.read(&mut buffer).await.unwrap_or(0);
        let request = String::from_utf8_lossy(&buffer[..read]).to_string();
        let target = request
            .lines()
            .next()
            .and_then(|line| line.split_whitespace().nth(1))
            .unwrap_or_default()
            .to_string();

        if !target.starts_with("/oauth-callback") {
            let _ = stream.write_all(page(404, PAGE_FAILED).as_bytes()).await;
            let _ = stream.shutdown().await;
            continue;
        }

        let outcome = parse_callback(&target, state);
        let body = match &outcome {
            Ok(_) => page(200, PAGE_OK),
            Err(reason) => page(400, &format!("{PAGE_FAILED}\n\n{reason}")),
        };
        let _ = stream.write_all(body.as_bytes()).await;
        let _ = stream.shutdown().await;
        return outcome;
    }
}

pub fn parse_callback(raw: &str, expected_state: &str) -> Result<String, String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return Err("paste the full callback URL from the browser address bar".to_string());
    }
    let absolute = if trimmed.starts_with("http://") || trimmed.starts_with("https://") {
        trimmed.to_string()
    } else if trimmed.starts_with('/') {
        format!("http://localhost:{CALLBACK_PORT}{trimmed}")
    } else {
        let query = trimmed.strip_prefix('?').unwrap_or(trimmed);
        format!("http://localhost:{CALLBACK_PORT}/oauth-callback?{query}")
    };
    let url = reqwest::Url::parse(&absolute).map_err(|err| format!("parse callback: {err}"))?;

    let mut code = String::new();
    let mut state = String::new();
    let mut error = String::new();
    for (key, value) in url.query_pairs() {
        match key.as_ref() {
            "code" => code = value.into_owned(),
            "state" => state = value.into_owned(),
            "error" => error = value.into_owned(),
            _ => {}
        }
    }

    if !error.is_empty() {
        return Err(format!("google returned {error}"));
    }
    if code.is_empty() || state.is_empty() {
        return Err("callback carries no code or state".to_string());
    }
    if state != expected_state {
        return Err("callback belongs to a different sign-in; start again".to_string());
    }
    Ok(code)
}

fn page(status: u16, body: &str) -> String {
    let reason = match status {
        200 => "OK",
        404 => "Not Found",
        _ => "Bad Request",
    };
    format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n{body}",
        body.len()
    )
}

fn random_token() -> String {
    let mut bytes = Vec::with_capacity(32);
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    bytes.extend_from_slice(uuid::Uuid::new_v4().as_bytes());
    URL_SAFE_NO_PAD.encode(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_auth_url_carries_pkce_and_offline_access() {
        let pending = begin();
        assert!(pending.url.starts_with(AUTH_URL));
        assert!(pending.url.contains("code_challenge_method=S256"));
        assert!(pending.url.contains("access_type=offline"));
        assert!(pending.url.contains(&format!("state={}", pending.state)));
        assert_ne!(pending.verifier, pending.state);
    }

    #[test]
    fn callbacks_are_accepted_as_urls_paths_or_bare_queries() {
        let full = "http://localhost:51121/oauth-callback?state=s&code=c";
        assert_eq!(parse_callback(full, "s").unwrap(), "c");
        assert_eq!(parse_callback("/oauth-callback?state=s&code=c", "s").unwrap(), "c");
        assert_eq!(parse_callback("state=s&code=c", "s").unwrap(), "c");
        assert_eq!(parse_callback("?state=s&code=c", "s").unwrap(), "c");
    }

    #[test]
    fn an_iss_parameter_does_not_make_a_relative_callback_look_absolute() {
        let target = "/oauth-callback?state=s&iss=https://accounts.google.com\
                      &code=4/0ATsMZqAK-x_y&authuser=1&prompt=consent";
        assert_eq!(parse_callback(target, "s").unwrap(), "4/0ATsMZqAK-x_y");

        let bare = "state=s&iss=https://accounts.google.com&code=4/0ATsMZqAK";
        assert_eq!(parse_callback(bare, "s").unwrap(), "4/0ATsMZqAK");

        let full = "http://localhost:51121/oauth-callback?state=s\
                    &iss=https://accounts.google.com&code=4/0ATsMZqAK";
        assert_eq!(parse_callback(full, "s").unwrap(), "4/0ATsMZqAK");
    }

    #[test]
    fn mismatched_state_and_provider_errors_are_refused() {
        assert!(parse_callback("state=other&code=c", "s").is_err());
        assert!(parse_callback("state=s", "s").is_err());
        assert!(parse_callback("error=access_denied&state=s", "s")
            .unwrap_err()
            .contains("access_denied"));
        assert!(parse_callback("   ", "s").is_err());
    }

    #[test]
    fn the_callback_host_stays_on_loopback() {
        std::env::set_var(CALLBACK_HOST_ENV, "example.com");
        assert_eq!(callback_host(), "127.0.0.1");
        std::env::set_var(CALLBACK_HOST_ENV, "::1");
        assert_eq!(callback_host(), "::1");
        std::env::remove_var(CALLBACK_HOST_ENV);
    }
}
