//! Axum routes: OPDS search + EPUB download.

use crate::anna::{self, AnnaHit};
use crate::config::{Config, SearchMode};
use crate::models::{
    AcquisitionLink, Author, FeedLink, FeedMetadata, OpdsFeed, Publication, PublicationMetadata,
    ACQUISITION_OPEN_ACCESS, MIME_EPUB_ZIP, MIME_OPDS_JSON,
};
use crate::scrubber;
use crate::stump;
use axum::body::Body;
use axum::extract::{Path, Query, State};
use axum::http::{header, HeaderMap, HeaderValue, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use serde::Deserialize;
use std::sync::Arc;

fn safe_filename_part(s: &str) -> String {
    s.chars()
        .map(|c| match c {
            '/' | '\\' | ':' | '"' | '*' | '?' | '<' | '>' | '|' | '\0'..='\x1f' => '_',
            c => c,
        })
        .collect::<String>()
        .trim()
        .chars()
        .take(180)
        .collect()
}

fn build_base(headers: &HeaderMap, cfg: &Config) -> String {
    if let Some(ref u) = cfg.public_base_url {
        return u.trim_end_matches('/').to_string();
    }
    let host = headers
        .get(axum::http::header::HOST)
        .and_then(|h| h.to_str().ok())
        .unwrap_or("127.0.0.1:8787");
    let scheme = headers
        .get("x-forwarded-proto")
        .and_then(|h| h.to_str().ok())
        .unwrap_or("http");
    format!("{scheme}://{host}")
}

fn hit_to_pub(hit: &AnnaHit, base: &str) -> Publication {
    let title = hit
        .title
        .clone()
        .unwrap_or_else(|| "Untitled".to_string());
    let author_name = hit
        .author
        .clone()
        .unwrap_or_else(|| "Unknown".to_string());

    let q_title = urlencoding::encode(&title);
    let q_author = urlencoding::encode(&author_name);
    let href = format!(
        "{}/download/{}?title={}&author={}",
        base,
        hit.md5,
        q_title.as_ref(),
        q_author.as_ref()
    );

    Publication {
        metadata: PublicationMetadata {
            identifier: format!("urn:md5:{}", hit.md5),
            title: title.clone(),
            author: Some(Author {
                name: author_name.clone(),
            }),
        },
        links: vec![AcquisitionLink {
            rel: ACQUISITION_OPEN_ACCESS.to_string(),
            href,
            media_type: MIME_EPUB_ZIP.to_string(),
        }],
    }
}

#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Config>,
    pub http: reqwest::Client,
}

pub async fn opds_search(
    State(state): State<AppState>,
    uri: Uri,
    headers: HeaderMap,
    Query(params): Query<SearchParams>,
) -> Result<axum::Json<OpdsFeed>, ApiError> {
    let query = params.query.unwrap_or_default().trim().to_string();
    let base = build_base(&headers, &state.config);

    let hits = if query.is_empty() {
        Vec::new()
    } else {
        anna::search(&state.http, &state.config, &query)
            .await
            .map_err(ApiError::Anna)?
    };

    let publications: Vec<Publication> = hits.iter().map(|h| hit_to_pub(h, &base)).collect();

    let self_href = format!(
        "{}{}?query={}",
        base,
        uri.path(),
        urlencoding::encode(&query)
    );

    Ok(axum::Json(OpdsFeed {
        metadata: FeedMetadata {
            title: format!("Search: {query}"),
        },
        links: vec![FeedLink {
            rel: "self".to_string(),
            href: self_href,
            media_type: MIME_OPDS_JSON.to_string(),
        }],
        publications,
    }))
}

#[derive(Deserialize)]
pub struct SearchParams {
    query: Option<String>,
}

#[derive(Deserialize)]
pub struct DownloadParams {
    title: Option<String>,
    author: Option<String>,
}

pub async fn download(
    State(state): State<AppState>,
    Path(md5): Path<String>,
    Query(q): Query<DownloadParams>,
) -> Result<Response, ApiError> {
    if matches!(state.config.search_mode, SearchMode::Mock) && md5.starts_with("mockdeadbeef") {
        return Err(ApiError::MockDownload);
    }

    let url = anna::resolve_download_url(&state.http, &state.config, &md5)
        .await
        .map_err(ApiError::Anna)?;

    let req = state
        .http
        .get(url)
        .send()
        .await
        .map_err(|e| ApiError::Anna(e.into()))?;
    if !req.status().is_success() {
        return Err(ApiError::Upstream(format!(
            "download HTTP {}",
            req.status()
        )));
    }

    let bytes = req
        .bytes()
        .await
        .map_err(|e| ApiError::Anna(e.into()))?;
    if bytes.len() as u64 > state.config.max_epub_bytes {
        return Err(ApiError::TooLarge);
    }

    let title = q
        .title
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Book".to_string());
    let author = q
        .author
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Unknown".to_string());

    let cleaned = scrubber::scrub_epub(&bytes, &title, &author).map_err(|e| {
        tracing::warn!(?e, "scrub failed");
        ApiError::Scrub
    })?;

    let fname = format!(
        "{} - {}.epub",
        safe_filename_part(&author),
        safe_filename_part(&title)
    );

    let books_path = state.config.books_dir.join(&fname);
    if let Some(parent) = books_path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    if let Err(e) = tokio::fs::write(&books_path, &cleaned).await {
        tracing::warn!(?e, path=?books_path, "failed to write book copy");
    }

    stump::scan_library(&state.http, &state.config).await;

    let disposition = format!("attachment; filename=\"{}\"", safe_filename_part(&fname));

    let mut res = Response::new(Body::from(cleaned));
    res.headers_mut().insert(
        header::CONTENT_TYPE,
        HeaderValue::from_static(MIME_EPUB_ZIP),
    );
    res.headers_mut().insert(
        header::CONTENT_DISPOSITION,
        HeaderValue::from_str(&disposition).unwrap_or_else(|_| HeaderValue::from_static("attachment")),
    );

    Ok(res)
}

#[derive(Debug)]
pub enum ApiError {
    Anna(anna::AnnaError),
    MockDownload,
    Upstream(String),
    TooLarge,
    Scrub,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        match self {
            ApiError::Anna(e) => {
                tracing::warn!(?e, "anna error");
                let status = match e {
                    anna::AnnaError::Http(ref he) if he.is_timeout() => StatusCode::GATEWAY_TIMEOUT,
                    _ => StatusCode::BAD_GATEWAY,
                };
                (status, e.to_string()).into_response()
            }
            ApiError::MockDownload => (
                StatusCode::BAD_GATEWAY,
                "Download is disabled for mock MD5 (configure real fast_download + member secret)",
            )
                .into_response(),
            ApiError::Upstream(s) => (StatusCode::BAD_GATEWAY, s).into_response(),
            ApiError::TooLarge => (StatusCode::PAYLOAD_TOO_LARGE, "EPUB exceeds MAX_EPUB_BYTES").into_response(),
            ApiError::Scrub => (StatusCode::INTERNAL_SERVER_ERROR, "EPUB scrub failed").into_response(),
        }
    }
}

impl From<anna::AnnaError> for ApiError {
    fn from(e: anna::AnnaError) -> Self {
        ApiError::Anna(e)
    }
}
