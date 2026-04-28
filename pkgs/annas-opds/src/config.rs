//! Environment-backed configuration.

use std::path::PathBuf;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SearchMode {
    Http,
    Mock,
}

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_addr: String,
    pub public_base_url: Option<String>,
    pub search_mode: SearchMode,
    /// GET URL with `{query}` replaced by encoded search string.
    pub annas_search_url: Option<String>,
    pub annas_fast_download_url: String,
    pub annas_member_secret: Option<String>,
    /// Query parameter name for the member secret (Anna's uses `secret`).
    pub annas_secret_param: String,
    pub annas_md5_param: String,
    pub books_dir: PathBuf,
    pub max_epub_bytes: u64,
    pub stump_graphql_url: String,
    pub stump_library_id: Option<String>,
    pub stump_api_key: Option<String>,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let bind_addr =
            std::env::var("BIND_ADDR").unwrap_or_else(|_| "127.0.0.1:8787".to_string());
        let public_base_url = std::env::var("PUBLIC_BASE_URL").ok().filter(|s| !s.is_empty());

        let annas_search_url = std::env::var("ANNAS_SEARCH_URL").ok().filter(|s| !s.is_empty());

        let mode_raw = std::env::var("ANNAS_SEARCH_MODE").ok();
        let search_mode = match mode_raw.as_deref() {
            Some("mock") => SearchMode::Mock,
            Some("http") => SearchMode::Http,
            Some(other) => {
                anyhow::bail!("ANNAS_SEARCH_MODE must be 'mock' or 'http', got {other:?}")
            }
            None => {
                if annas_search_url.is_some() {
                    SearchMode::Http
                } else {
                    SearchMode::Mock
                }
            }
        };

        if matches!(search_mode, SearchMode::Http) && annas_search_url.is_none() {
            anyhow::bail!("ANNAS_SEARCH_URL is required when ANNAS_SEARCH_MODE=http");
        }

        let annas_fast_download_url = std::env::var("ANNAS_FAST_DOWNLOAD_URL").unwrap_or_else(|_| {
            "https://annas-archive.org/dyn/api/fast_download.json".to_string()
        });

        let annas_member_secret = std::env::var("ANNAS_MEMBER_SECRET")
            .ok()
            .filter(|s| !s.is_empty());

        let annas_secret_param =
            std::env::var("ANNAS_SECRET_PARAM").unwrap_or_else(|_| "secret".to_string());
        let annas_md5_param =
            std::env::var("ANNAS_MD5_PARAM").unwrap_or_else(|_| "md5".to_string());

        let books_dir = std::env::var("BOOKS_DIR").unwrap_or_else(|_| "./books".to_string());
        let max_epub_bytes: u64 = std::env::var("MAX_EPUB_BYTES")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(104_857_600);

        let stump_graphql_url = std::env::var("STUMP_GRAPHQL_URL")
            .unwrap_or_else(|_| "http://127.0.0.1:10801/api/graphql".to_string());
        let stump_library_id = std::env::var("STUMP_LIBRARY_ID").ok().filter(|s| !s.is_empty());
        let stump_api_key = std::env::var("STUMP_API_KEY").ok().filter(|s| !s.is_empty());

        Ok(Self {
            bind_addr,
            public_base_url,
            search_mode,
            annas_search_url,
            annas_fast_download_url,
            annas_member_secret,
            annas_secret_param,
            annas_md5_param,
            books_dir: PathBuf::from(books_dir),
            max_epub_bytes,
            stump_graphql_url,
            stump_library_id,
            stump_api_key,
        })
    }

    /// Test-only configuration (mock search, no Stump/Anna secrets).
    #[cfg(test)]
    pub fn test_defaults() -> Self {
        Self {
            bind_addr: "127.0.0.1:0".to_string(),
            public_base_url: Some("http://127.0.0.1:8787".to_string()),
            search_mode: SearchMode::Mock,
            annas_search_url: None,
            annas_fast_download_url: "https://annas-archive.org/dyn/api/fast_download.json"
                .to_string(),
            annas_member_secret: None,
            annas_secret_param: "secret".to_string(),
            annas_md5_param: "md5".to_string(),
            books_dir: PathBuf::from("./target/test-books"),
            max_epub_bytes: 104_857_600,
            stump_graphql_url: "http://127.0.0.1:10801/api/graphql".to_string(),
            stump_library_id: None,
            stump_api_key: None,
        }
    }
}
