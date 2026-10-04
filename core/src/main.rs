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
    std::process::exit(0);
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
        "raven {} listening on http://{}/v1",
        config::VERSION,
        config.address,
    );

    let router = routes::build(Arc::clone(&app), &config.static_dir);
    let (stop_tx, stop_rx) = tokio::sync::oneshot::channel::<()>();
    let serve = axum::serve(listener, router).with_graceful_shutdown(async move {
        let _ = stop_rx.await;
    });
    let trigger = async move {
        shutdown(config.exit_on_stdin_close).await;
        let _ = stop_tx.send(());
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
    };
    tokio::select! {
        result = serve => result.map_err(|err| format!("server error: {err}"))?,
        _ = trigger => {}
    }

    app.shutdown();
    Ok(())
}

async fn shutdown(exit_on_stdin_close: bool) {
    if !exit_on_stdin_close {
        return routes::shutdown_signal().await;
    }
    tokio::select! {
        _ = routes::shutdown_signal() => {}
        _ = stdin_closed() => {}
    }
}

async fn stdin_closed() {
    use tokio::io::AsyncReadExt;
    let mut stdin = tokio::io::stdin();
    let mut buf = [0u8; 256];
    while let Ok(read) = stdin.read(&mut buf).await {
        if read == 0 {
            return;
        }
    }
}
