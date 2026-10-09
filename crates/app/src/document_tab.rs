//! One open document: its session, reader state and view bookkeeping.

use std::collections::HashSet;
use std::sync::Arc;

use egui::Vec2;
use pdf_core::navigation::{NavigationHistory, NavigationLocation};
use pdf_core::{DocumentSession, WorkingPageId};

use crate::reader_state::ReaderState;
use crate::render::DocumentKey;

#[derive(Debug, Clone)]
pub struct PageMetrics {
    /// Displayed size in points, after page rotation.
    pub size: Vec2,
    pub label: Option<String>,
}

pub struct DocumentTab {
    pub id: u64,
    pub session: DocumentSession,
    pub reader: ReaderState,
    pub history: NavigationHistory,
    pub metrics: Vec<PageMetrics>,
    metrics_generation: Option<u64>,
    /// Scroll the reader so this page is at the top on the next frame.
    pub scroll_to_page: Option<usize>,
    pub go_to_page_text: String,
}

impl DocumentTab {
    pub fn new(id: u64, session: DocumentSession) -> Self {
        let page_count = session.editor.page_count();
        let mut history = NavigationHistory::default();
        history.reset(session.editor.page_id(0).cloned());
        let mut tab = Self {
            id,
            session,
            reader: ReaderState::new(page_count),
            history,
            metrics: Vec::new(),
            metrics_generation: None,
            scroll_to_page: None,
            go_to_page_text: "1".into(),
        };
        tab.refresh_metrics();
        tab
    }

    pub fn title(&self) -> String {
        self.session.display_name()
    }

    pub fn document_key(&self) -> DocumentKey {
        DocumentKey {
            tab: self.id,
            generation: self.session.editor.generation(),
        }
    }

    pub fn pdf_data(&self) -> Arc<Vec<u8>> {
        self.session.editor.pdf_data()
    }

    pub fn has_unexported_changes(&self) -> bool {
        self.session.editor.has_unexported_changes()
    }

    pub fn valid_page_ids(&self) -> HashSet<WorkingPageId> {
        self.session.editor.page_ids().iter().cloned().collect()
    }

    /// Re-reads page sizes and labels when the working copy changed.
    pub fn refresh_metrics(&mut self) {
        let generation = self.session.editor.generation();
        if self.metrics_generation == Some(generation) {
            return;
        }
        self.metrics_generation = Some(generation);
        self.metrics = load_metrics(&self.pdf_data());
    }

    /// Call after any editor mutation, undo or redo.
    pub fn after_mutation(&mut self, preferred_page: Option<usize>) {
        self.refresh_metrics();
        self.reader.synchronize(self.session.editor.page_count(), preferred_page);
        self.go_to_page_text = (self.reader.selected_page_index() + 1).to_string();
    }

    /// Navigates and records history (outline, bookmarks, go-to, search).
    pub fn navigate_to(&mut self, index: usize) {
        if self.reader.select_page(index) {
            if let Some(page_id) = self.session.editor.page_id(index).cloned() {
                self.history.record(NavigationLocation { page_id });
            }
            self.scroll_to_page = Some(index);
            self.go_to_page_text = (index + 1).to_string();
        }
    }

    /// Moves without recording history (arrow keys, thumbnails).
    pub fn show_page(&mut self, index: usize) {
        if self.reader.select_page(index) {
            self.scroll_to_page = Some(index);
            self.go_to_page_text = (index + 1).to_string();
        }
    }

    pub fn navigate_to_page_id(&mut self, page_id: &WorkingPageId) -> bool {
        match self.session.editor.index_of(page_id) {
            Some(index) => {
                self.navigate_to(index);
                true
            }
            None => false,
        }
    }

    pub fn go_back(&mut self) {
        let valid = self.valid_page_ids();
        if let Some(location) = self.history.go_back(&valid)
            && let Some(index) = self.session.editor.index_of(&location.page_id)
        {
            self.show_page(index);
        }
    }

    pub fn go_forward(&mut self) {
        let valid = self.valid_page_ids();
        if let Some(location) = self.history.go_forward(&valid)
            && let Some(index) = self.session.editor.index_of(&location.page_id)
        {
            self.show_page(index);
        }
    }

    pub fn page_label(&self, index: usize) -> String {
        let document_label = self.metrics.get(index).and_then(|metrics| metrics.label.as_deref());
        self.reader.page_label(index, document_label)
    }
}

fn load_metrics(bytes: &[u8]) -> Vec<PageMetrics> {
    let Ok(document) = pdf_core::engine::load(bytes.to_vec(), None) else {
        return Vec::new();
    };
    document
        .pages()
        .iter()
        .map(|page| PageMetrics {
            size: Vec2::new(page.width().value, page.height().value),
            label: page.label().map(str::to_owned),
        })
        .collect()
}
