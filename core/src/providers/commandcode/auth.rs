use reqwest::header::{HeaderMap, SET_COOKIE};
use serde_json::json;

const SESSION_COOKIE_NAME: &str = "__Secure-commandcode_prod_.session_token";
const AUTH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(30);
const SIGN_IN_PATH: &str = "/auth/sign-in/email";

pub struct CommandCodeAuth {
    client: reqwest::Client,
    api_base: String,
    agent: String,
}

impl CommandCodeAuth {
    pub fn new(client: reqwest::Client, api_base: String, agent: String) -> Self {
        Self {
            client,
            api_base,
            agent,
        }
    }

    pub async fn sign_in(
        &self,
        email: &str,
        password: &str,
        captcha_response: Option<&str>,
    ) -> Result<String, String> {
        sign_in(
            &self.client,
            &self.api_base,
            &self.agent,
            email,
            password,
            captcha_response,
        )
        .await
    }
}

pub async fn sign_in(
    client: &reqwest::Client,
    api_base: &str,
    agent: &str,
    email: &str,
    password: &str,
    captcha_response: Option<&str>,
) -> Result<String, String> {
    if email.trim().is_empty() || password.is_empty() {
        return Err("email and password are required".to_string());
    }

    let mut request = client
        .post(format!("{}{SIGN_IN_PATH}", api_base.trim_end_matches('/')))
        .header("Accept", "application/json")
        .header("Content-Type", "application/json")
        .header("Origin", "https://commandcode.ai")
        .header("Referer", "https://commandcode.ai/signin")
        .header("User-Agent", agent)
        .json(&json!({
            "email": email.trim(),
            "password": password,
        }))
        .timeout(AUTH_TIMEOUT);
    if let Some(response) = captcha_response.filter(|token| !token.is_empty()) {
        request = request.header("x-captcha-response", response);
    }

    let response = request.send().await.map_err(|_| {
        "Command Code sign-in request failed; check connectivity and try again".to_string()
    })?;
    let status = response.status();
    let headers = response.headers().clone();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        let code = serde_json::from_str::<serde_json::Value>(&body)
            .ok()
            .and_then(|value| {
                value
                    .get("code")
                    .or_else(|| value.get("error").and_then(|error| error.get("code")))
                    .or_else(|| value.get("error"))
                    .and_then(|code| code.as_str())
                    .map(str::to_owned)
            })
            .unwrap_or_default();
        if code == "TURNSTILE_REQUIRED" || code == "TURNSTILE_FAILED" {
            return Err("Command Code requires interactive Turnstile verification".to_string());
        }
        if status.as_u16() == 429 {
            return Err("Command Code sign-in is rate limited; try again later".to_string());
        }
        if status.as_u16() == 401 {
            return Err("Command Code rejected the email or password".to_string());
        }
        return Err(format!(
            "Command Code sign-in failed (HTTP {})",
            status.as_u16()
        ));
    }

    session_token(&headers).ok_or_else(|| {
        "Command Code sign-in succeeded without returning a session cookie".to_string()
    })
}

fn session_token(headers: &HeaderMap) -> Option<String> {
    headers
        .get_all(SET_COOKIE)
        .iter()
        .filter_map(|value| value.to_str().ok())
        .find_map(|cookie| {
            cookie
                .split(';')
                .next()
                .and_then(|pair| pair.strip_prefix(&format!("{SESSION_COOKIE_NAME}=")))
                .filter(|value| !value.is_empty())
                .map(str::to_owned)
        })
}

#[cfg(test)]
mod tests {
    use super::{session_token, SESSION_COOKIE_NAME, SIGN_IN_PATH};
    use reqwest::header::{HeaderMap, HeaderValue, SET_COOKIE};

    #[test]
    fn reads_session_cookie_without_other_cookie_values() {
        let mut headers = HeaderMap::new();
        headers.append(
            SET_COOKIE,
            HeaderValue::from_str(&format!("{SESSION_COOKIE_NAME}=renewed; Path=/; HttpOnly"))
                .unwrap(),
        );
        headers.append(
            SET_COOKIE,
            HeaderValue::from_static("other_cookie=unrelated; Path=/"),
        );

        assert_eq!(session_token(&headers).as_deref(), Some("renewed"));
    }

    #[test]
    fn builds_site_api_base_for_login() {
        assert_eq!(
            format!("https://api.commandcode.ai{SIGN_IN_PATH}"),
            "https://api.commandcode.ai/auth/sign-in/email"
        );
    }

    #[test]
    fn ignores_response_without_session_cookie() {
        let mut headers = HeaderMap::new();
        headers.append(SET_COOKIE, HeaderValue::from_static("other=value; Path=/"));
        assert_eq!(session_token(&headers), None);
    }
}
