use reqwest::header::HeaderMap;
use reqwest::header::HeaderName;
use reqwest::header::HeaderValue;
use std::str::FromStr;

use super::auth::Auth;

pub const CLIENT_UA: &str = "CLI/2.63.2 CodeBuddy/2.63.2";
const ORIGIN_REFERER_CN: &str = "https://www.codebuddy.cn";
const ORIGIN_REFERER_GLOBAL: &str = "https://www.workbuddy.ai";

fn origin_referer_for(a: Option<&Auth>) -> &'static str {
    if let Some(a) = a {
        if a.region() == "global" {
            return ORIGIN_REFERER_GLOBAL;
        }
    }
    ORIGIN_REFERER_CN
}

fn set(map: &mut HeaderMap, name: &'static str, value: &str) {
    if let (Ok(n), Ok(v)) = (HeaderName::from_str(name), HeaderValue::from_str(value)) {
        map.insert(n, v);
    }
}

fn common_headers(a: Option<&Auth>) -> HeaderMap {
    let mut map = HeaderMap::new();
    let origin = origin_referer_for(a);
    map.insert(
        reqwest::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    map.insert(
        reqwest::header::ACCEPT,
        HeaderValue::from_static("application/json, text/plain, */*"),
    );
    set(&mut map, "x-requested-with", "XMLHttpRequest");
    set(&mut map, "origin", origin);
    set(&mut map, "referer", &format!("{origin}/"));
    set(&mut map, "user-agent", CLIENT_UA);
    map
}

pub fn login_headers() -> HeaderMap {
    common_headers(None)
}

pub fn chat_headers(a: &Auth) -> HeaderMap {
    let mut map = common_headers(Some(a));
    if !a.access_token.is_empty() {
        set(
            &mut map,
            "authorization",
            &format!("Bearer {}", a.access_token),
        );
    } else {
        set(&mut map, "x-no-authorization", "1");
    }
    if !a.uid.is_empty() {
        set(&mut map, "x-user-id", &a.uid);
    } else {
        set(&mut map, "x-no-user-id", "1");
    }
    if !a.enterprise_id.is_empty() {
        set(&mut map, "x-enterprise-id", &a.enterprise_id);
    } else {
        set(&mut map, "x-no-enterprise-id", "1");
    }
    if !a.domain.is_empty() {
        set(&mut map, "x-domain", &a.domain);
    } else {
        set(&mut map, "x-no-department-info", "1");
    }
    set(&mut map, "x-product", "SaaS");
    map
}

pub fn billing_headers(a: &Auth) -> HeaderMap {
    let mut map = HeaderMap::new();
    set(
        &mut map,
        "authorization",
        &format!("Bearer {}", a.access_token),
    );
    map.insert(
        reqwest::header::ACCEPT,
        HeaderValue::from_static("application/json"),
    );
    map.insert(
        reqwest::header::CONTENT_TYPE,
        HeaderValue::from_static("application/json"),
    );
    set(&mut map, "user-agent", CLIENT_UA);
    if !a.uid.is_empty() {
        set(&mut map, "x-user-id", &a.uid);
    }
    if !a.enterprise_id.is_empty() {
        set(&mut map, "x-enterprise-id", &a.enterprise_id);
        set(&mut map, "x-tenant-id", &a.enterprise_id);
    }
    if !a.domain.is_empty() {
        set(&mut map, "x-domain", &a.domain);
    }
    map
}

pub fn refresh_headers(a: &Auth) -> HeaderMap {
    let mut map = common_headers(Some(a));
    set(&mut map, "x-refresh-token", &a.refresh_token);
    if !a.enterprise_id.is_empty() {
        set(&mut map, "x-enterprise-id", &a.enterprise_id);
    }
    set(&mut map, "x-auth-refresh-source", "workbuddy");
    map
}

pub fn models_headers(a: &Auth) -> HeaderMap {
    let mut map = HeaderMap::new();
    set(
        &mut map,
        "authorization",
        &format!("Bearer {}", a.access_token),
    );
    map.insert(
        reqwest::header::ACCEPT,
        HeaderValue::from_static("application/json"),
    );
    let origin = origin_referer_for(Some(a));
    set(&mut map, "origin", origin);
    set(&mut map, "referer", &format!("{origin}/"));
    set(&mut map, "user-agent", CLIENT_UA);
    map
}

#[cfg(test)]
mod tests {
    use super::*;

    fn auth() -> Auth {
        Auth {
            access_token: "tok".into(),
            refresh_token: "rtok".into(),
            expires_at: 0,
            domain: "www.codebuddy.cn".into(),
            uid: "u-1".into(),
            enterprise_id: String::new(),
            nickname: String::new(),
            account_name: String::new(),
        }
    }

    #[test]
    fn billing_headers_carry_user_agent() {
        let h = billing_headers(&auth());
        assert_eq!(h["user-agent"], HeaderValue::from_static(CLIENT_UA));
        assert_eq!(h["authorization"], HeaderValue::from_static("Bearer tok"));
        assert_eq!(h["x-user-id"], HeaderValue::from_static("u-1"));
    }
}
