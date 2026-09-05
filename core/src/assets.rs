use axum::extract::Request;
use axum::http::header::{CACHE_CONTROL, CONTENT_TYPE};
use axum::http::HeaderValue;
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::Router;
use regex::Regex;
use std::path::Path;
use std::sync::OnceLock;
use tower_http::services::{ServeDir, ServeFile};

pub fn router(dir: &Path) -> Option<Router> {
    let index = dir.join("index.html");
    if !index.is_file() {
        eprintln!(
            "panel: no index.html in {} — not serving the panel (dev mode: `cd app && bun run dev`)",
            dir.display()
        );
        return None;
    }
    eprintln!("panel: serving {}", dir.display());
    let files = ServeDir::new(dir).fallback(ServeFile::new(index));
    Some(
        Router::new()
            .fallback_service(files)
            .layer(middleware::from_fn(cache_control)),
    )
}

async fn cache_control(request: Request, next: Next) -> Response {
    let path = request.uri().path().to_owned();
    let mut response = next.run(request).await;
    let is_html = response
        .headers()
        .get(CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .is_some_and(|content_type| content_type.starts_with("text/html"));
    let directive = if is_html {
        Some("no-cache")
    } else if is_hashed_asset(&path) {
        Some("public, max-age=31536000, immutable")
    } else {
        None
    };
    if let Some(directive) = directive {
        response
            .headers_mut()
            .insert(CACHE_CONTROL, HeaderValue::from_static(directive));
    }
    response
}

fn is_hashed_asset(path: &str) -> bool {
    static HASHED: OnceLock<Regex> = OnceLock::new();
    let hashed = HASHED.get_or_init(|| Regex::new(r"-[A-Za-z0-9_=-]{8,}\.").expect("static regex"));
    let file = path.rsplit('/').next().unwrap_or(path);
    hashed.is_match(file)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hashed_assets_are_recognized() {
        assert!(is_hashed_asset("/assets/index-BgDaEnEv.js"));
        assert!(is_hashed_asset(
            "/assets/geist-latin-wght-normal-BgDaEnEv.woff2"
        ));
        assert!(!is_hashed_asset("/index.html"));
        assert!(!is_hashed_asset("/favicon-dark.svg"));
        assert!(!is_hashed_asset("/icons.svg"));
    }
}
