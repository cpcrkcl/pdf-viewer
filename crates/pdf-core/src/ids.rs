use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use uuid::Uuid;

pub fn sha256_hex(data: &[u8]) -> String {
    Sha256::digest(data).iter().map(|byte| format!("{byte:02x}")).collect()
}

/// Stable identity of a page across reorders, inserts and revisions.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkingPageId {
    pub document_fingerprint: String,
    pub original_page_index: usize,
    #[serde(rename = "occurrenceID")]
    pub occurrence_id: Uuid,
}

impl WorkingPageId {
    pub fn original(document_fingerprint: &str, page_index: usize) -> Self {
        Self {
            document_fingerprint: document_fingerprint.to_owned(),
            original_page_index: page_index,
            occurrence_id: deterministic_occurrence_id(document_fingerprint, page_index),
        }
    }

    pub fn inserted(document_fingerprint: &str, page_index: usize) -> Self {
        Self {
            document_fingerprint: document_fingerprint.to_owned(),
            original_page_index: page_index,
            occurrence_id: Uuid::new_v4(),
        }
    }

    pub fn represents_original_occurrence(&self) -> bool {
        self.occurrence_id
            == deterministic_occurrence_id(&self.document_fingerprint, self.original_page_index)
    }
}

/// UUIDv5-shaped identifier derived from the fingerprint and page index, so
/// reopening the same PDF yields the same page identities (and bookmarks resolve).
fn deterministic_occurrence_id(document_fingerprint: &str, page_index: usize) -> Uuid {
    let digest = Sha256::digest(format!("{document_fingerprint}:{page_index}").as_bytes());
    let mut bytes = [0u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    bytes[6] = (bytes[6] & 0x0F) | 0x50;
    bytes[8] = (bytes[8] & 0x3F) | 0x80;
    Uuid::from_bytes(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn original_ids_are_deterministic_and_inserted_ids_are_unique() {
        let fingerprint = sha256_hex(b"fixture");
        assert_eq!(fingerprint.len(), 64);
        let first = WorkingPageId::original(&fingerprint, 3);
        assert_eq!(first, WorkingPageId::original(&fingerprint, 3));
        assert!(first.represents_original_occurrence());
        assert_eq!(first.occurrence_id.get_version_num(), 5);

        let inserted = WorkingPageId::inserted(&fingerprint, 3);
        assert_ne!(inserted, first);
        assert!(!inserted.represents_original_occurrence());
    }
}
