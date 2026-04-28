//! Trigger Stump `scanLibrary` via GraphQL (`POST /api/graphql`).

use crate::config::Config;
use reqwest::header::{AUTHORIZATION, CONTENT_TYPE};
use serde::Serialize;

#[derive(Debug, Serialize)]
struct GraphqlBody<'a> {
    query: &'a str,
    variables: ScanVars<'a>,
}

#[derive(Debug, Serialize)]
struct ScanVars<'a> {
    id: &'a str,
}

/// Fire-and-forget scan; logs errors but does not fail the download response.
pub async fn scan_library(http: &reqwest::Client, cfg: &Config) {
    let Some(ref lib_id) = cfg.stump_library_id else {
        tracing::debug!("STUMP_LIBRARY_ID unset; skipping Stump scan");
        return;
    };

    let body = GraphqlBody {
        query: "mutation ScanLibrary($id: ID!) { scanLibrary(id: $id) }",
        variables: ScanVars { id: lib_id.as_str() },
    };

    let mut req = http
        .post(&cfg.stump_graphql_url)
        .header(CONTENT_TYPE, "application/json")
        .json(&body);

    if let Some(ref key) = cfg.stump_api_key {
        req = req.header(AUTHORIZATION, format!("Bearer {}", key));
    }

    match req.send().await {
        Ok(res) => {
            let status = res.status();
            let text = res.text().await.unwrap_or_default();
            if !status.is_success() {
                tracing::warn!(%status, body=%text, "Stump scanLibrary HTTP error");
                return;
            }
            if let Ok(v) = serde_json::from_str::<serde_json::Value>(&text) {
                if v.get("errors").is_some() {
                    tracing::warn!(?v, "Stump GraphQL returned errors");
                }
            }
            tracing::debug!("Stump scanLibrary requested");
        }
        Err(e) => tracing::warn!(?e, "Stump scanLibrary request failed"),
    }
}
