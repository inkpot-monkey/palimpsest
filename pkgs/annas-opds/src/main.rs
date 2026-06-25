use annas_opds::config::Config;
use annas_opds::handlers::{download, opds_search, AppState};
use axum::routing::get;
use axum::Router;
use std::sync::Arc;
use tower_http::trace::TraceLayer;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();

    let config = Arc::new(Config::from_env()?);
    tokio::fs::create_dir_all(&config.books_dir).await?;

    let bind_addr = config.bind_addr.clone();

    let http = reqwest::Client::builder()
        .user_agent(concat!("annas-opds/", env!("CARGO_PKG_VERSION")))
        .build()?;

    let state = AppState { config, http };

    let app = Router::new()
        .route("/opds/search", get(opds_search))
        .route("/download/{md5}", get(download))
        .with_state(state)
        .layer(TraceLayer::new_for_http());

    let listener = tokio::net::TcpListener::bind(&bind_addr).await?;
    tracing::info!(%bind_addr, "listening");
    axum::serve(listener, app).await?;

    Ok(())
}
