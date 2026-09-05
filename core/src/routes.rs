use axum::body::Body;
use axum::http::{Request, StatusCode};
use axum::middleware::{self, Next};
use axum::response::Response;
use axum::routing::{get, post};
use axum::Router;
use std::path::Path;
use std::sync::Arc;
use std::time::Instant;

use crate::app::App;
use crate::providers::workbuddy;
use crate::{assets, proxy, state};

pub fn build(app: Arc<App>, static_dir: &Path) -> Router {
    let api = routes();
    let mut router = Router::new()
        .merge(api.clone())
        .nest("/api", api.fallback(|| async { StatusCode::NOT_FOUND }));
    if let Some(panel) = assets::router(static_dir) {
        router = router.fallback_service(panel);
    }
    router
        .layer(middleware::from_fn(log_requests))
        .with_state(app)
}

fn routes() -> Router<Arc<App>> {
    Router::new()
        .merge(inference())
        .merge(management())
}

fn inference() -> Router<Arc<App>> {
    Router::new()
        .merge(aliased("/chat/completions", post(proxy::chat::handle)))
        .merge(aliased("/messages", post(proxy::messages::handle)))
        .merge(aliased(
            "/messages/count_tokens",
            post(proxy::messages::handle_count_tokens),
        ))
        .merge(aliased("/responses", post(proxy::responses::handle)))
        .merge(aliased("/models", get(proxy::models::handle)))
}

fn management() -> Router<Arc<App>> {
    Router::new()
        .route("/health", get(state::handle_health))
        .route("/models-dev", get(state::models::handle_models_dev))
        .route("/providers/models", get(state::models::handle_provider_models))
        .route(
            "/providers/{kind}/models",
            get(state::models::handle_provider_kind_models),
        )
        .route("/effort-levels", get(state::models::handle_effort_levels))
        .route(
            "/providers",
            get(state::providers::handle_get).put(state::providers::handle_put),
        )
        .merge(aliased(
            "/usage",
            get(state::usage::handle_list).delete(state::usage::handle_clear),
        ))
        .route("/usage/stream", get(state::usage::handle_stream))
        .route(
            "/prices",
            get(state::usage::handle_prices).post(state::usage::handle_prices_save),
        )
        .route("/limits/all", get(state::accounts::handle_limits))
        .route(
            "/accounts",
            get(state::accounts::handle_list)
                .post(state::accounts::handle_add)
                .delete(state::accounts::handle_remove),
        )
        .route("/accounts/edit", post(state::accounts::handle_edit))
        .route(
            "/accounts/workbuddy",
            post(workbuddy::panel::handle_add),
        )
        .route(
            "/accounts/workbuddy/local",
            get(workbuddy::panel::handle_local),
        )
        .route("/workbuddy/status", get(workbuddy::panel::handle_status))
        .route("/workbuddy/refresh", post(workbuddy::panel::handle_refresh))
        .route(
            "/oauth/workbuddy/start",
            get(workbuddy::panel::handle_oauth_start),
        )
        .route(
            "/oauth/workbuddy/status",
            get(workbuddy::panel::handle_oauth_status),
        )
}

fn aliased(path: &str, method: axum::routing::MethodRouter<Arc<App>>) -> Router<Arc<App>> {
    Router::new()
        .route(path, method.clone())
        .route(&format!("/v1{path}"), method)
}

async fn log_requests(request: Request<Body>, next: Next) -> Response {
    let started = Instant::now();
    let method = request.method().clone();
    let path = request.uri().path().to_string();
    let response = next.run(request).await;
    if path != "/health" && path != "/api/health" {
        eprintln!(
            "{} {} -> {} ({:?})",
            method,
            path,
            response.status(),
            started.elapsed()
        );
    }
    response
}

pub async fn shutdown_signal() {
    let ctrl_c = tokio::signal::ctrl_c();
    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("install SIGTERM handler")
            .recv()
            .await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
    eprintln!("received shutdown signal, shutting down");

    tokio::spawn(async {
        tokio::time::sleep(std::time::Duration::from_secs(5)).await;
        eprintln!("shutdown drain timed out after 5s, exiting");
        std::process::exit(0);
    });
}
