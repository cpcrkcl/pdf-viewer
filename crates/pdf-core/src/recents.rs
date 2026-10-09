//! Recently opened documents.
//!
//! Locations are stored as opaque bookmark data produced by a
//! [`BookmarkCoder`]. The macOS app supplies a security-scoped bookmark
//! coder; [`PathBookmarkCoder`] stores plain UTF-8 paths.

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use crate::error::{CoreError, CoreResult};
use crate::persistence::JsonFile;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentDocument {
    pub id: String,
    pub display_name: String,
    #[serde(with = "base64_bytes")]
    pub bookmark: Vec<u8>,
    pub last_opened_at: DateTime<Utc>,
}

pub trait BookmarkCoder: Send {
    fn bookmark(&self, path: &Path) -> CoreResult<Vec<u8>>;
    fn resolve(&self, bookmark: &[u8]) -> CoreResult<PathBuf>;
}

pub struct PathBookmarkCoder;

impl BookmarkCoder for PathBookmarkCoder {
    fn bookmark(&self, path: &Path) -> CoreResult<Vec<u8>> {
        Ok(path.to_string_lossy().into_owned().into_bytes())
    }

    fn resolve(&self, bookmark: &[u8]) -> CoreResult<PathBuf> {
        String::from_utf8(bookmark.to_vec())
            .map(PathBuf::from)
            .map_err(|_| CoreError::FileUnavailable)
    }
}

#[derive(Serialize, Deserialize)]
struct RecentDocumentTransfer {
    version: u32,
    documents: Vec<RecentDocument>,
}

pub struct RecentDocumentsStore {
    documents: Vec<RecentDocument>,
    file: JsonFile,
    coder: Box<dyn BookmarkCoder>,
    limit: usize,
}

impl RecentDocumentsStore {
    pub fn new(path: PathBuf, coder: Box<dyn BookmarkCoder>, limit: usize) -> Self {
        assert!(limit > 0);
        let file = JsonFile::new(path);
        let mut loaded: Vec<RecentDocument> = file.load().unwrap_or_default();
        loaded.sort_by(|a, b| b.last_opened_at.cmp(&a.last_opened_at));
        let mut seen = HashSet::new();
        loaded.retain(|document| seen.insert(document.id.clone()));
        loaded.truncate(limit);
        Self {
            documents: loaded,
            file,
            coder,
            limit,
        }
    }

    pub fn documents(&self) -> &[RecentDocument] {
        &self.documents
    }

    pub fn record(&mut self, path: &Path) -> CoreResult<()> {
        self.record_at(path, Utc::now())
    }

    pub fn record_at(&mut self, path: &Path, opened_at: DateTime<Utc>) -> CoreResult<()> {
        let bookmark = self.coder.bookmark(path)?;
        let identifier = std::fs::canonicalize(path)
            .unwrap_or_else(|_| path.to_path_buf())
            .to_string_lossy()
            .into_owned();
        let document = RecentDocument {
            id: identifier.clone(),
            display_name: path
                .file_name()
                .map(|name| name.to_string_lossy().into_owned())
                .unwrap_or_default(),
            bookmark,
            last_opened_at: opened_at,
        };
        let mut updated: Vec<_> = self
            .documents
            .iter()
            .filter(|existing| existing.id != identifier)
            .cloned()
            .collect();
        updated.insert(0, document);
        updated.truncate(self.limit);
        self.file.save(&updated)?;
        self.documents = updated;
        Ok(())
    }

    pub fn resolve(&self, document: &RecentDocument) -> CoreResult<PathBuf> {
        self.coder.resolve(&document.bookmark)
    }

    pub fn clear(&mut self) -> CoreResult<()> {
        self.file.save(&Vec::<RecentDocument>::new())?;
        self.documents.clear();
        Ok(())
    }

    pub fn export_json(&self) -> CoreResult<Vec<u8>> {
        serde_json::to_vec_pretty(&RecentDocumentTransfer {
            version: 1,
            documents: self.documents.clone(),
        })
        .map_err(|error| CoreError::Io(error.to_string()))
    }

    pub fn import_json(&mut self, data: &[u8]) -> CoreResult<()> {
        let invalid = || CoreError::Io("The recent documents file is not valid.".into());
        let transfer: RecentDocumentTransfer = serde_json::from_slice(data).map_err(|_| invalid())?;
        if transfer.version != 1 || transfer.documents.len() > 1_000 {
            return Err(invalid());
        }
        let mut merged: HashMap<String, RecentDocument> = self
            .documents
            .iter()
            .map(|document| (document.id.clone(), document.clone()))
            .collect();
        for document in transfer.documents {
            if document.id.is_empty()
                || document.display_name.chars().count() > 512
                || document.bookmark.len() > 1_048_576
            {
                continue;
            }
            let newer = merged
                .get(&document.id)
                .is_none_or(|existing| existing.last_opened_at < document.last_opened_at);
            if newer {
                merged.insert(document.id.clone(), document);
            }
        }
        let mut updated: Vec<_> = merged.into_values().collect();
        updated.sort_by(|a, b| b.last_opened_at.cmp(&a.last_opened_at));
        updated.truncate(self.limit);
        self.file.save(&updated)?;
        self.documents = updated;
        Ok(())
    }
}

/// Bookmark data is binary; JSON carries it as base64 like Foundation's `Data`.
mod base64_bytes {
    use serde::{Deserialize, Deserializer, Serializer};

    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";

    pub fn serialize<S: Serializer>(bytes: &[u8], serializer: S) -> Result<S::Ok, S::Error> {
        let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
        for chunk in bytes.chunks(3) {
            let b = [chunk[0], *chunk.get(1).unwrap_or(&0), *chunk.get(2).unwrap_or(&0)];
            let n = (u32::from(b[0]) << 16) | (u32::from(b[1]) << 8) | u32::from(b[2]);
            for i in 0..4 {
                if i <= chunk.len() {
                    out.push(ALPHABET[((n >> (18 - 6 * i)) & 63) as usize] as char);
                } else {
                    out.push('=');
                }
            }
        }
        serializer.serialize_str(&out)
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(deserializer: D) -> Result<Vec<u8>, D::Error> {
        let text = String::deserialize(deserializer)?;
        decode(&text).ok_or_else(|| serde::de::Error::custom("invalid base64"))
    }

    pub(crate) fn decode(text: &str) -> Option<Vec<u8>> {
        let mut out = Vec::with_capacity(text.len() / 4 * 3);
        let mut buffer = 0u32;
        let mut bits = 0;
        for byte in text.bytes().filter(|byte| !byte.is_ascii_whitespace()) {
            if byte == b'=' {
                break;
            }
            let value = ALPHABET.iter().position(|candidate| *candidate == byte)? as u32;
            buffer = (buffer << 6) | value;
            bits += 6;
            if bits >= 8 {
                bits -= 8;
                out.push((buffer >> bits) as u8);
                buffer &= (1 << bits) - 1;
            }
        }
        Some(out)
    }
}
