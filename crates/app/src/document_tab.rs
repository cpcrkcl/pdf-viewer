//! One open document: its session, reader state and view bookkeeping.

use std::collections::HashSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, channel};
use std::sync::Arc;

use egui::Vec2;
use pdf_core::navigation::{NavigationHistory, NavigationLocation};
use pdf_core::text::{PageInfo, PageText, SearchMatch, SearchOptions, SearchOutcome};
use pdf_core::{CoreError, DocumentSession, WorkingPageId};

use crate::reader_state::ReaderState;
use crate::render::DocumentKey;

/// What a primary-button drag on a page does.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tool {
    SelectText,
    Annotate(crate::annotation_ui::AnnotationTool),
    Redact,
}

#[derive(Debug, Clone, PartialEq)]
pub struct TextSelection {
    pub page: usize,
    pub anchor: usize,
    pub focus: usize,
}

impl TextSelection {
    pub fn range(&self) -> (usize, usize) {
        (self.anchor.min(self.focus), self.anchor.max(self.focus) + 1)
    }
}

#[derive(Default)]
pub struct SearchState {
    pub query: String,
    pub options: SearchOptions,
    pub outcome: Option<SearchOutcome>,
    pub active: Option<usize>,
    /// Query and options the outcome belongs to.
    searched: Option<(String, SearchOptions, u64)>,
    running: Option<(Arc<AtomicBool>, Receiver<Result<SearchOutcome, CoreError>>)>,
    pub focus_requested: bool,
    /// Matches chosen in the results list for redaction.
    pub marked: std::collections::BTreeSet<usize>,
}

impl SearchState {
    pub fn is_running(&self) -> bool {
        self.running.is_some()
    }

    pub fn matches(&self) -> &[SearchMatch] {
        match &self.outcome {
            Some(SearchOutcome::Matches(matches)) => matches,
            _ => &[],
        }
    }

    pub fn active_match(&self) -> Option<&SearchMatch> {
        self.active.and_then(|index| self.matches().get(index))
    }

    pub fn clear(&mut self) {
        self.cancel();
        self.query.clear();
        self.outcome = None;
        self.active = None;
        self.searched = None;
        self.marked.clear();
    }

    fn cancel(&mut self) {
        if let Some((cancel, _)) = self.running.take() {
            cancel.store(true, Ordering::Relaxed);
        }
    }

    pub fn is_stale(&self) -> bool {
        self.searched.as_ref().is_some_and(|(query, options, _)| query != &self.query || *options != self.options)
    }
}

pub struct DocumentTab {
    pub id: u64,
    pub session: DocumentSession,
    pub reader: ReaderState,
    pub history: NavigationHistory,
    pub pages: Vec<PageInfo>,
    pages_generation: Option<u64>,
    text: Option<(u64, Arc<Vec<PageText>>)>,
    text_job: Option<(u64, Arc<AtomicBool>, Receiver<Result<Vec<PageText>, CoreError>>)>,
    pub search: SearchState,
    pub tool: Tool,
    pub selection: Option<TextSelection>,
    /// Scroll the reader so this page is at the top on the next frame.
    pub scroll_to_page: Option<usize>,
    /// Scroll so this user-space point of the page is visible.
    pub scroll_to_point: Option<(usize, (f32, f32))>,
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
            pages: Vec::new(),
            pages_generation: None,
            text: None,
            text_job: None,
            search: SearchState::default(),
            tool: Tool::SelectText,
            selection: None,
            scroll_to_page: None,
            scroll_to_point: None,
            go_to_page_text: "1".into(),
        };
        tab.refresh_pages();
        tab
    }

    pub fn title(&self) -> String {
        self.session.display_name()
    }

    pub fn generation(&self) -> u64 {
        self.session.editor.generation()
    }

    pub fn document_key(&self) -> DocumentKey {
        DocumentKey {
            tab: self.id,
            generation: self.generation(),
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

    pub fn page_size(&self, index: usize) -> Vec2 {
        self.pages
            .get(index)
            .map(|info| {
                let (w, h) = info.geometry.display_size();
                Vec2::new(w, h)
            })
            .unwrap_or(Vec2::new(612.0, 792.0))
    }

    /// Re-reads geometry, labels and links when the working copy changed.
    pub fn refresh_pages(&mut self) {
        let generation = self.generation();
        if self.pages_generation == Some(generation) {
            return;
        }
        self.pages_generation = Some(generation);
        self.pages = pdf_core::text::page_infos(&self.pdf_data()).unwrap_or_default();
    }

    /// Call after any editor mutation, undo or redo.
    pub fn after_mutation(&mut self, preferred_page: Option<usize>) {
        self.refresh_pages();
        self.reader.synchronize(self.session.editor.page_count(), preferred_page);
        self.go_to_page_text = (self.reader.selected_page_index() + 1).to_string();
        self.selection = None;
        // Search results describe the previous revision.
        if self.search.outcome.is_some() {
            self.search.outcome = None;
            self.search.active = None;
            self.search.searched = None;
            self.search.marked.clear();
        }
    }

    /// The text index for the current revision, starting a background build
    /// when it's missing. `None` until ready.
    pub fn text_index(&mut self, ctx: &egui::Context) -> Option<Arc<Vec<PageText>>> {
        let generation = self.generation();
        if let Some((built, text)) = &self.text
            && *built == generation
        {
            return Some(Arc::clone(text));
        }
        if let Some((job_generation, cancel, receiver)) = &self.text_job {
            if *job_generation != generation {
                cancel.store(true, Ordering::Relaxed);
                self.text_job = None;
            } else {
                match receiver.try_recv() {
                    Ok(Ok(pages)) => {
                        let pages = Arc::new(pages);
                        self.text = Some((generation, Arc::clone(&pages)));
                        self.text_job = None;
                        return Some(pages);
                    }
                    Ok(Err(_)) | Err(TryRecvError::Disconnected) => {
                        self.text = Some((generation, Arc::new(Vec::new())));
                        self.text_job = None;
                        return self.text.as_ref().map(|(_, text)| Arc::clone(text));
                    }
                    Err(TryRecvError::Empty) => return None,
                }
            }
        }
        let cancel = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = channel();
        let bytes = self.pdf_data();
        let worker_cancel = Arc::clone(&cancel);
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let _ = sender.send(pdf_core::text::build_text_index(&bytes, &worker_cancel));
            ctx.request_repaint();
        });
        self.text_job = Some((generation, cancel, receiver));
        None
    }

    pub fn start_search(&mut self, ctx: &egui::Context) {
        self.search.cancel();
        self.search.outcome = None;
        self.search.active = None;
        self.search.marked.clear();
        let query = self.search.query.trim().to_owned();
        if query.is_empty() {
            self.search.searched = None;
            return;
        }
        self.search.searched = Some((self.search.query.clone(), self.search.options, self.generation()));
        let cancel = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = channel();
        let options = self.search.options;
        let ready = self.text_index(ctx);
        let bytes = self.pdf_data();
        let worker_cancel = Arc::clone(&cancel);
        let ctx = ctx.clone();
        std::thread::spawn(move || {
            let pages = match ready {
                Some(pages) => pages,
                None => match pdf_core::text::build_text_index(&bytes, &worker_cancel) {
                    Ok(pages) => Arc::new(pages),
                    Err(error) => {
                        let _ = sender.send(Err(error));
                        return;
                    }
                },
            };
            let _ = sender.send(pdf_core::text::search(&pages, &query, options, &worker_cancel));
            ctx.request_repaint();
        });
        self.search.running = Some((cancel, receiver));
    }

    pub fn poll_search(&mut self) {
        let Some((_, receiver)) = &self.search.running else { return };
        match receiver.try_recv() {
            Err(TryRecvError::Empty) => {}
            Err(TryRecvError::Disconnected) | Ok(Err(_)) => self.search.running = None,
            Ok(Ok(outcome)) => {
                self.search.running = None;
                let first = matches!(outcome, SearchOutcome::Matches(_)).then_some(0);
                self.search.outcome = Some(outcome);
                self.select_search_match(first);
            }
        }
    }

    pub fn select_search_match(&mut self, index: Option<usize>) {
        self.search.active = index;
        if let Some(found) = self.search.active_match() {
            let page = found.page;
            let point = found.bounds().map(|bounds| bounds.center());
            self.navigate_to(page);
            if let Some(point) = point {
                self.scroll_to_point = Some((page, point));
                self.scroll_to_page = None;
            }
        }
    }

    pub fn step_search(&mut self, forward: bool) {
        let count = self.search.matches().len();
        if count == 0 {
            return;
        }
        let current = self.search.active.unwrap_or(0);
        let next = if forward { (current + 1) % count } else { (current + count - 1) % count };
        self.select_search_match(Some(next));
    }

    pub fn selected_text(&self) -> Option<String> {
        let selection = self.selection.as_ref()?;
        let (_, text) = self.text.as_ref()?;
        let page = text.get(selection.page)?;
        let (start, end) = selection.range();
        let value = page.substring(start, end);
        (!value.trim().is_empty()).then_some(value)
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
        let document_label = self.pages.get(index).and_then(|info| info.label.as_deref());
        self.reader.page_label(index, document_label)
    }
}
