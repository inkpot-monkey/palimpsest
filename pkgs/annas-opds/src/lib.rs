//! OPDS 2.0 JSON proxy: Anna's Archive search/download, EPUB scrubbing, optional Stump scan.

pub mod anna;
pub mod config;
pub mod handlers;
pub mod models;
pub mod scrubber;
pub mod stump;

pub use config::{Config, SearchMode};

#[cfg(test)]
mod tests {
    use crate::config::Config;
    use crate::handlers::{download, opds_search, AppState};
    use axum::body::Body;
    use axum::http::StatusCode;
    use axum::routing::get;
    use axum::Router;
    use http::Request;
    use std::sync::Arc;
    use tower::ServiceExt;

    fn test_app() -> Router {
        Router::new()
            .route("/opds/search", get(opds_search))
            .route("/download/{md5}", get(download))
            .with_state(AppState {
                config: Arc::new(Config::test_defaults()),
                http: reqwest::Client::new(),
            })
    }

    #[tokio::test]
    async fn mock_search_returns_two_publications() {
        let app = test_app();

        let req = Request::builder()
            .uri("/opds/search?query=dune")
            .body(Body::empty())
            .unwrap();

        let res = app.oneshot(req).await.unwrap();
        assert!(res.status().is_success());

        let body = axum::body::to_bytes(res.into_body(), usize::MAX)
            .await
            .unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["publications"].as_array().unwrap().len(), 2);
        let link = &v["publications"][0]["links"][0]["href"];
        let href = link.as_str().unwrap();
        assert!(href.contains("/download/"));
        assert!(href.starts_with("http://127.0.0.1:8787/"));

        let self_href = v["links"][0]["href"].as_str().unwrap();
        assert!(self_href.contains("/opds/search"));
        assert!(self_href.contains("query=dune"));
    }

    #[tokio::test]
    async fn search_empty_query_returns_no_publications() {
        let app = test_app();
        let req = Request::builder()
            .uri("/opds/search?query=")
            .body(Body::empty())
            .unwrap();
        let res = app.oneshot(req).await.unwrap();
        assert!(res.status().is_success());
        let body = axum::body::to_bytes(res.into_body(), usize::MAX)
            .await
            .unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v["publications"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn search_whitespace_only_query_returns_no_publications() {
        let app = test_app();
        let req = Request::builder()
            .uri("/opds/search?query=%20%20%20")
            .body(Body::empty())
            .unwrap();
        let res = app.oneshot(req).await.unwrap();
        assert!(res.status().is_success());
        let body = axum::body::to_bytes(res.into_body(), usize::MAX)
            .await
            .unwrap();
        let v: serde_json::Value = serde_json::from_slice(&body).unwrap();
        assert!(v["publications"].as_array().unwrap().is_empty());
    }

    #[tokio::test]
    async fn mock_download_forbidden_md5_returns_502() {
        let app = test_app();
        let req = Request::builder()
            .uri("/download/mockdeadbeef00000000000000000001")
            .body(Body::empty())
            .unwrap();
        let res = app.oneshot(req).await.unwrap();
        assert_eq!(res.status(), StatusCode::BAD_GATEWAY);
    }
}
