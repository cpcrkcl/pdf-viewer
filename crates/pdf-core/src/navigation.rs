//! Back/forward history and local page bookmarks.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::error::{CoreError, CoreResult};
use crate::ids::WorkingPageId;
use crate::persistence::JsonFile;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NavigationLocation {
    pub page_id: WorkingPageId,
}

#[derive(Debug, Clone)]
pub struct NavigationHistory {
    entries: Vec<NavigationLocation>,
    current_index: Option<usize>,
    maximum_entry_count: usize,
}

impl Default for NavigationHistory {
    fn default() -> Self {
        Self::new(100)
    }
}

impl NavigationHistory {
    pub fn new(maximum_entry_count: usize) -> Self {
        Self {
            entries: Vec::new(),
            current_index: None,
            maximum_entry_count: maximum_entry_count.max(1),
        }
    }

    pub fn entries(&self) -> &[NavigationLocation] {
        &self.entries
    }

    pub fn current_index(&self) -> Option<usize> {
        self.current_index
    }

    pub fn reset(&mut self, initial: Option<WorkingPageId>) {
        match initial {
            Some(page_id) => {
                self.entries = vec![NavigationLocation { page_id }];
                self.current_index = Some(0);
            }
            None => {
                self.entries.clear();
                self.current_index = None;
            }
        }
    }

    pub fn record(&mut self, location: NavigationLocation) {
        if let Some(current) = self.current_index {
            if self.entries.get(current) == Some(&location) {
                return;
            }
            self.entries.truncate(current + 1);
        }
        self.entries.push(location);
        if self.entries.len() > self.maximum_entry_count {
            let overflow = self.entries.len() - self.maximum_entry_count;
            self.entries.drain(..overflow);
        }
        self.current_index = Some(self.entries.len() - 1);
    }

    pub fn can_go_back(&self, valid: &HashSet<WorkingPageId>) -> bool {
        self.previous_valid_index(valid).is_some()
    }

    pub fn can_go_forward(&self, valid: &HashSet<WorkingPageId>) -> bool {
        self.next_valid_index(valid).is_some()
    }

    pub fn go_back(&mut self, valid: &HashSet<WorkingPageId>) -> Option<NavigationLocation> {
        let index = self.previous_valid_index(valid)?;
        self.current_index = Some(index);
        Some(self.entries[index].clone())
    }

    pub fn go_forward(&mut self, valid: &HashSet<WorkingPageId>) -> Option<NavigationLocation> {
        let index = self.next_valid_index(valid)?;
        self.current_index = Some(index);
        Some(self.entries[index].clone())
    }

    fn previous_valid_index(&self, valid: &HashSet<WorkingPageId>) -> Option<usize> {
        let current = self.current_index?;
        (0..current).rev().find(|index| valid.contains(&self.entries[*index].page_id))
    }

    fn next_valid_index(&self, valid: &HashSet<WorkingPageId>) -> Option<usize> {
        let current = self.current_index?;
        (current + 1..self.entries.len()).find(|index| valid.contains(&self.entries[*index].page_id))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PageBookmark {
    pub id: Uuid,
    pub document_fingerprint: String,
    #[serde(rename = "pageID")]
    pub page_id: WorkingPageId,
    pub label: String,
    pub created_at: DateTime<Utc>,
}

#[derive(Serialize, Deserialize)]
struct BookmarkTransfer {
    version: u32,
    bookmarks: Vec<PageBookmark>,
}

pub const MAXIMUM_BOOKMARK_LABEL_LENGTH: usize = 120;

pub struct PageBookmarkStore {
    bookmarks: Vec<PageBookmark>,
    file: JsonFile,
}

impl PageBookmarkStore {
    pub fn new(path: PathBuf) -> Self {
        let file = JsonFile::new(path);
        let bookmarks = file.load().unwrap_or_default();
        Self { bookmarks, file }
    }

    pub fn all(&self) -> &[PageBookmark] {
        &self.bookmarks
    }

    pub fn bookmarks_for(&self, fingerprint: &str) -> Vec<PageBookmark> {
        let mut matching: Vec<_> = self
            .bookmarks
            .iter()
            .filter(|bookmark| bookmark.document_fingerprint == fingerprint)
            .cloned()
            .collect();
        matching.sort_by_key(|bookmark| bookmark.created_at);
        matching
    }

    pub fn add(&mut self, fingerprint: &str, page_id: WorkingPageId, label: &str) -> PageBookmark {
        self.add_at(fingerprint, page_id, label, Utc::now())
    }

    pub fn add_at(
        &mut self,
        fingerprint: &str,
        page_id: WorkingPageId,
        label: &str,
        now: DateTime<Utc>,
    ) -> PageBookmark {
        let bookmark = PageBookmark {
            id: Uuid::new_v4(),
            document_fingerprint: fingerprint.to_owned(),
            page_id,
            label: sanitized_label(label),
            created_at: now,
        };
        self.bookmarks.push(bookmark.clone());
        self.persist();
        bookmark
    }

    pub fn rename(&mut self, id: Uuid, label: &str) {
        if let Some(bookmark) = self.bookmarks.iter_mut().find(|bookmark| bookmark.id == id) {
            bookmark.label = sanitized_label(label);
            self.persist();
        }
    }

    pub fn remove(&mut self, id: Uuid) {
        self.bookmarks.retain(|bookmark| bookmark.id != id);
        self.persist();
    }

    pub fn export_json(&self) -> CoreResult<Vec<u8>> {
        serde_json::to_vec_pretty(&BookmarkTransfer {
            version: 1,
            bookmarks: self.bookmarks.clone(),
        })
        .map_err(|error| CoreError::Io(error.to_string()))
    }

    pub fn import_json(&mut self, data: &[u8]) -> CoreResult<()> {
        let transfer: BookmarkTransfer =
            serde_json::from_slice(data).map_err(|_| CoreError::Io("The bookmark file is not valid.".into()))?;
        if transfer.version != 1 || transfer.bookmarks.len() > 20_000 {
            return Err(CoreError::Io("The bookmark file is not valid.".into()));
        }
        let mut merged: HashMap<Uuid, PageBookmark> =
            self.bookmarks.drain(..).map(|bookmark| (bookmark.id, bookmark)).collect();
        for bookmark in transfer.bookmarks {
            if bookmark.label.chars().count() <= MAXIMUM_BOOKMARK_LABEL_LENGTH
                && bookmark.document_fingerprint.len() == 64
            {
                merged.insert(bookmark.id, bookmark);
            }
        }
        let mut bookmarks: Vec<_> = merged.into_values().collect();
        bookmarks.sort_by_key(|bookmark| bookmark.created_at);
        self.bookmarks = bookmarks;
        self.persist();
        Ok(())
    }

    fn persist(&self) {
        let _ = self.file.save(&self.bookmarks);
    }
}

fn sanitized_label(label: &str) -> String {
    let trimmed = label.trim();
    let label = if trimmed.is_empty() { "Bookmark" } else { trimmed };
    label.chars().take(MAXIMUM_BOOKMARK_LABEL_LENGTH).collect()
}
