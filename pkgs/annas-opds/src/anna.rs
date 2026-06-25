//! Anna's Archive HTTP helpers: configurable JSON search + fast_download JSON.

use crate::config::{Config, SearchMode};
use serde::Deserialize;
use serde_json::Value;
use thiserror::Error;

#[derive(Debug, Clone)]
pub struct AnnaHit {
    pub md5: String,
    pub title: Option<String>,
    pub author: Option<String>,
    pub extension: Option<String>,
}

#[derive(Debug, Error)]
pub enum AnnaError {
    #[error("HTTP error: {0}")]
    Http(#[from] reqwest::Error),
    #[error("JSON error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("Search misconfigured: {0}")]
    Config(String),
    #[error("Unexpected search response shape")]
    SearchShape,
    #[error("Fast download response missing URL")]
    MissingDownloadUrl,
}

#[derive(Deserialize)]
struct HitLoose {
    md5: Option<String>,
    title: Option<String>,
    author: Option<String>,
    extension: Option<String>,
}

pub async fn search(
    http: &reqwest::Client,
    cfg: &Config,
    query: &str,
) -> Result<Vec<AnnaHit>, AnnaError> {
    match cfg.search_mode {
        SearchMode::Mock => Ok(mock_hits()),
        SearchMode::Http => search_http(http, cfg, query).await,
    }
}

fn mock_hits() -> Vec<AnnaHit> {
    vec![
        AnnaHit {
            md5: "mockdeadbeef00000000000000000001".into(),
            title: Some("Demo EPUB (mock search)".into()),
            author: Some("Anna's OPDS".into()),
            extension: Some("epub".into()),
        },
        AnnaHit {
            md5: "mockdeadbeef00000000000000000002".into(),
            title: Some("Second mock title".into()),
            author: Some("Another Author".into()),
            extension: Some("epub".into()),
        },
    ]
}

async fn search_http(
    http: &reqwest::Client,
    cfg: &Config,
    query: &str,
) -> Result<Vec<AnnaHit>, AnnaError> {
    let template = cfg
        .annas_search_url
        .as_ref()
        .ok_or_else(|| AnnaError::Config("ANNAS_SEARCH_URL missing".into()))?;
    let encoded = urlencoding::encode(query);
    let url = template.replace("{query}", encoded.as_ref());
    let res = http.get(url).send().await?.error_for_status()?;
    let body = res.bytes().await?;
    parse_search_json(&body)
}

fn parse_search_json(body: &[u8]) -> Result<Vec<AnnaHit>, AnnaError> {
    let root: Value = serde_json::from_slice(body)?;
    if let Some(arr) = root.as_array() {
        return hits_from_array(arr);
    }
    if let Some(results) = root.get("results").and_then(|v| v.as_array()) {
        return hits_from_array(results);
    }
    if let Some(data) = root.get("data") {
        if let Some(results) = data.get("results").and_then(|v| v.as_array()) {
            return hits_from_array(results);
        }
    }
    Err(AnnaError::SearchShape)
}

fn hits_from_array(arr: &[Value]) -> Result<Vec<AnnaHit>, AnnaError> {
    let mut out = Vec::with_capacity(arr.len());
    for v in arr {
        let h: HitLoose = serde_json::from_value(v.clone()).map_err(|_| AnnaError::SearchShape)?;
        let md5 = h.md5.clone().filter(|s| !s.is_empty());
        let Some(md5) = md5 else {
            continue;
        };
        out.push(AnnaHit {
            md5,
            title: h.title,
            author: h.author,
            extension: h.extension,
        });
    }
    Ok(out)
}

/// Resolve a download URL via Anna's fast_download JSON API.
pub async fn resolve_download_url(
    http: &reqwest::Client,
    cfg: &Config,
    md5: &str,
) -> Result<String, AnnaError> {
    let mut req = http.get(&cfg.annas_fast_download_url);
    req = req.query(&[(cfg.annas_md5_param.as_str(), md5)]);
    if let Some(ref secret) = cfg.annas_member_secret {
        req = req.query(&[(cfg.annas_secret_param.as_str(), secret.as_str())]);
    }
    let res = req.send().await?.error_for_status()?;
    let v: Value = res.json().await?;
    extract_download_url(&v).ok_or(AnnaError::MissingDownloadUrl)
}

fn extract_download_url(v: &Value) -> Option<String> {
    const KEYS: &[&str] = &[
        "download_url",
        "downloadUrl",
        "url",
        "href",
        "link",
        "download",
    ];
    for k in KEYS {
        if let Some(s) = v.get(*k).and_then(|x| x.as_str()) {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    if let Some(arr) = v.get("links").and_then(|x| x.as_array()) {
        for link in arr {
            if let Some(href) = link.get("href").and_then(|x| x.as_str()) {
                if !href.is_empty() {
                    return Some(href.to_string());
                }
            }
        }
    }
    if let Some(inner) = v.get("data") {
        return extract_download_url(inner);
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parse_search_json_accepts_root_array() {
        let body = br#"[{"md5":"abc123","title":"One","author":"A1"}]"#;
        let hits = parse_search_json(body).expect("parse");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].md5, "abc123");
        assert_eq!(hits[0].title.as_deref(), Some("One"));
        assert_eq!(hits[0].author.as_deref(), Some("A1"));
    }

    #[test]
    fn parse_search_json_accepts_results_key() {
        let body = br#"{"results":[{"md5":"x","title":"T"}]}"#;
        let hits = parse_search_json(body).expect("parse");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].md5, "x");
    }

    #[test]
    fn parse_search_json_accepts_data_results() {
        let body = br#"{"data":{"results":[{"md5":"inner"}]}}"#;
        let hits = parse_search_json(body).expect("parse");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].md5, "inner");
    }

    #[test]
    fn parse_search_json_skips_objects_without_md5() {
        let body = br#"[{"title":"orphan"},{"md5":"keep","title":"ok"}]"#;
        let hits = parse_search_json(body).expect("parse");
        assert_eq!(hits.len(), 1);
        assert_eq!(hits[0].md5, "keep");
    }

    #[test]
    fn parse_search_json_rejects_unknown_shape() {
        let err = parse_search_json(br#"{"foo":[]}"#).unwrap_err();
        assert!(matches!(err, AnnaError::SearchShape));
    }

    #[test]
    fn extract_download_url_variants() {
        assert_eq!(
            extract_download_url(&json!({"download_url": "https://dl.example/a"})),
            Some("https://dl.example/a".into())
        );
        assert_eq!(
            extract_download_url(&json!({"downloadUrl": "https://camel"})),
            Some("https://camel".into())
        );
        assert_eq!(
            extract_download_url(&json!({"data": {"url": "https://nested"}})),
            Some("https://nested".into())
        );
        assert_eq!(
            extract_download_url(&json!({"links": [{"href": "https://from-links"}]})),
            Some("https://from-links".into())
        );
        assert_eq!(extract_download_url(&json!({})), None);
    }
}
