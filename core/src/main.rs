mod app;
mod assets;
mod config;
mod net;
mod protocol;
mod providers;
mod proxy;
mod routes;
mod state;
mod translate;

use app::App;
use std::sync::Arc;

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("fatal: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let config = match config::Config::from_args(std::env::args().collect())? {
        Some(config) => config,
        None => {
            println!("raven {}", config::VERSION);
            return Ok(());
        }
    };

    let app = Arc::new(App::build(&config)?);
    app.report_pools();

    let listener = tokio::net::TcpListener::bind(&config.address)
        .await
        .map_err(|err| format!("listen on {}: {err}", config.address))?;
    eprintln!(
        "raven {} listening on http://{}/v1 (upstream {})",
        config::VERSION,
        config.address,
        app.commandcode.api_base
    );

    let router = routes::build(Arc::clone(&app), &config.static_dir);
    axum::serve(listener, router)
        .with_graceful_shutdown(routes::shutdown_signal())
        .await
        .map_err(|err| format!("server error: {err}"))?;

    app.shutdown();
    Ok(())
}
