//! Rewrite EPUB `content.opf` title/author and repack the ZIP.

use regex::Regex;
use std::io::{Cursor, Read, Write};
use thiserror::Error;
use zip::write::SimpleFileOptions;
use zip::CompressionMethod::Deflated;
use zip::{ZipArchive, ZipWriter};

#[derive(Debug, Error)]
pub enum ScrubError {
    #[error("ZIP: {0}")]
    Zip(String),
    #[error("Missing META-INF/container.xml")]
    MissingContainer,
    #[error("Missing OPF path in container")]
    MissingOpfPath,
    #[error("Missing OPF entry in archive")]
    MissingOpf,
    #[error("UTF-8: {0}")]
    Utf8(#[from] std::str::Utf8Error),
}

impl From<zip::result::ZipError> for ScrubError {
    fn from(e: zip::result::ZipError) -> Self {
        ScrubError::Zip(e.to_string())
    }
}

impl From<std::io::Error> for ScrubError {
    fn from(e: std::io::Error) -> Self {
        ScrubError::Zip(e.to_string())
    }
}

fn xml_escape(text: &str) -> String {
    text.chars()
        .flat_map(|c| match c {
            '&' => "&amp;".chars().collect::<Vec<_>>(),
            '<' => "&lt;".chars().collect::<Vec<_>>(),
            '>' => "&gt;".chars().collect::<Vec<_>>(),
            '"' => "&quot;".chars().collect::<Vec<_>>(),
            _ => vec![c],
        })
        .collect()
}

fn replace_dc(xml: &str, element: &str, new_text: &str) -> String {
    let escaped = xml_escape(new_text);
    let re = Regex::new(&format!(
        r"(?s)(<dc:{}[^>]*>)(.*?)(</dc:{}>)",
        regex::escape(element),
        regex::escape(element)
    ))
    .expect("valid regex");
    if re.is_match(xml) {
        return re
            .replace(xml, |caps: &regex::Captures| {
                format!("{}{}{}", &caps[1], escaped, &caps[3])
            })
            .into_owned();
    }
    xml.to_string()
}

fn opf_path_from_container(container_xml: &str) -> Option<String> {
    let re = Regex::new(r#"full-path\s*=\s*"([^"]+)""#).ok()?;
    re.captures(container_xml)
        .map(|c| c.get(1).map(|m| m.as_str().to_string()))
        .flatten()
}

/// Strip CR and normalize path separators inside the ZIP.
fn normalize_zip_path(name: &str) -> String {
    name.replace('\\', "/").trim_start_matches('/').to_string()
}

/// Replace dc:title and dc:creator in the package OPF; repack EPUB bytes.
pub fn scrub_epub(
    epub_bytes: &[u8],
    title: &str,
    author: &str,
) -> Result<Vec<u8>, ScrubError> {
    let cursor = Cursor::new(epub_bytes);
    let mut archive = ZipArchive::new(cursor)?;

    let mut container_raw = Vec::<u8>::new();
    let container_path = ["META-INF/container.xml", "META-INF\\container.xml"]
        .into_iter()
        .find(|p| archive.by_name(p).is_ok());

    let container_path = container_path.ok_or(ScrubError::MissingContainer)?;
    archive
        .by_name(container_path)?
        .read_to_end(&mut container_raw)?;
    let container_xml = std::str::from_utf8(&container_raw)?;

    let opf_rel = opf_path_from_container(container_xml).ok_or(ScrubError::MissingOpfPath)?;
    let opf_key = normalize_zip_path(&opf_rel);

    let mut opf_raw = Vec::<u8>::new();
    let names: Vec<String> = (0..archive.len())
        .filter_map(|i| archive.by_index(i).ok().map(|f| f.name().to_string()))
        .collect();

    let opf_match = names
        .iter()
        .find(|n| normalize_zip_path(n) == opf_key)
        .cloned()
        .ok_or(ScrubError::MissingOpf)?;

    archive.by_name(&opf_match)?.read_to_end(&mut opf_raw)?;
    let opf_xml = std::str::from_utf8(&opf_raw)?;
    let mut fixed = replace_dc(opf_xml, "title", title);
    fixed = replace_dc(&fixed, "creator", author);

    let cursor = Cursor::new(epub_bytes);
    let mut archive = ZipArchive::new(cursor)?;
    let mut out = Cursor::new(Vec::new());
    {
        let mut writer = ZipWriter::new(&mut out);
        let opts = SimpleFileOptions::default()
            .compression_method(Deflated);

        for i in 0..archive.len() {
            let mut file = archive.by_index(i)?;
            let name = file.name().to_string();
            let path_norm = normalize_zip_path(&name);
            let data = if path_norm == opf_key {
                fixed.as_bytes().to_vec()
            } else {
                let mut buf = Vec::new();
                file.read_to_end(&mut buf)?;
                buf
            };

            if name.ends_with('/') {
                continue;
            }
            writer.start_file(name.clone(), opts)?;
            writer.write_all(&data)?;
        }
        writer.finish()?;
    }

    Ok(out.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use zip::write::ZipWriter;

    fn tiny_epub(title: &str, author: &str) -> Vec<u8> {
        let buf = Cursor::new(Vec::new());
        let mut zip = ZipWriter::new(buf);
        let opts = SimpleFileOptions::default().compression_method(Deflated);

        zip.start_file("META-INF/container.xml", opts).unwrap();
        write!(
            zip,
            r#"<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>"#
        )
        .unwrap();

        zip.start_file("OEBPS/content.opf", opts).unwrap();
        write!(
            zip,
            r#"<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0"
  xmlns:dc="http://purl.org/dc/elements/1.1/">
  <metadata>
    <dc:title>{title}</dc:title>
    <dc:creator>{author}</dc:creator>
    <meta property="dcterms:modified">2024-01-01T00:00:00Z</meta>
  </metadata>
  <manifest>
    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
  </manifest>
  <spine>
    <itemref idref="nav"/>
  </spine>
</package>"#
        )
        .unwrap();

        zip.start_file("OEBPS/nav.xhtml", opts).unwrap();
        write!(
            zip,
            r#"<?xml version="1.0"?>
<html xmlns="http://www.w3.org/1999/xhtml"><head><title>t</title></head><body><p>x</p></body></html>"#
        )
        .unwrap();

        zip.finish().unwrap().into_inner()
    }

    #[test]
    fn scrub_updates_opf_metadata() {
        let raw = tiny_epub("Junk Title", "Junk Author");
        let out = scrub_epub(&raw, "Clean Title", "Clean Author").expect("scrub");
        let mut arch = ZipArchive::new(Cursor::new(&out)).unwrap();
        let mut s = String::new();
        arch.by_name("OEBPS/content.opf")
            .unwrap()
            .read_to_string(&mut s)
            .unwrap();
        assert!(s.contains("<dc:title>Clean Title</dc:title>"));
        assert!(s.contains("<dc:creator>Clean Author</dc:creator>"));
        assert!(!s.contains("Junk Title"));
    }

    #[test]
    fn scrub_xml_escapes_special_chars_in_metadata() {
        let raw = tiny_epub("Plain", "Plain");
        let out = scrub_epub(&raw, "A & B < C", "Quote \"X\"").expect("scrub");
        let mut arch = ZipArchive::new(Cursor::new(&out)).unwrap();
        let mut s = String::new();
        arch.by_name("OEBPS/content.opf")
            .unwrap()
            .read_to_string(&mut s)
            .unwrap();
        assert!(s.contains("<dc:title>A &amp; B &lt; C</dc:title>"));
        assert!(s.contains("<dc:creator>Quote &quot;X&quot;</dc:creator>"));
    }

    #[test]
    fn scrub_rejects_zip_without_container() {
        let buf = Cursor::new(Vec::new());
        let mut zip = ZipWriter::new(buf);
        let opts = SimpleFileOptions::default().compression_method(Deflated);
        zip.start_file("readme.txt", opts).unwrap();
        write!(zip, "not an epub").unwrap();
        let raw = zip.finish().unwrap().into_inner();
        let err = scrub_epub(&raw, "T", "A").unwrap_err();
        assert!(matches!(err, ScrubError::MissingContainer));
    }
}
