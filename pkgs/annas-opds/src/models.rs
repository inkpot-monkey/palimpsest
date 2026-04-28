//! Minimal OPDS 2.0 JSON shapes for search feeds (Readium / OPDS 2.0 conventions).

use serde::Serialize;

#[derive(Serialize)]
pub struct OpdsFeed {
    pub metadata: FeedMetadata,
    pub links: Vec<FeedLink>,
    pub publications: Vec<Publication>,
}

#[derive(Serialize)]
pub struct FeedMetadata {
    pub title: String,
}

#[derive(Serialize)]
pub struct FeedLink {
    pub rel: String,
    pub href: String,
    #[serde(rename = "type")]
    pub media_type: String,
}

#[derive(Serialize)]
pub struct Publication {
    pub metadata: PublicationMetadata,
    pub links: Vec<AcquisitionLink>,
}

#[derive(Serialize)]
pub struct PublicationMetadata {
    pub identifier: String,
    pub title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub author: Option<Author>,
}

#[derive(Serialize)]
pub struct Author {
    pub name: String,
}

#[derive(Serialize)]
pub struct AcquisitionLink {
    pub rel: String,
    pub href: String,
    #[serde(rename = "type")]
    pub media_type: String,
}

/// OPDS 2.0 acquisition link for open-access EPUB.
pub const ACQUISITION_OPEN_ACCESS: &str = "http://opds-spec.org/acquisition/open-access";
pub const MIME_EPUB_ZIP: &str = "application/epub+zip";
pub const MIME_OPDS_JSON: &str = "application/opds+json";
