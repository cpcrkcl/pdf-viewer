//! One open document: its session, reader state and view bookkeeping.

use std::collections::HashSet;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, channel};

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
    pub focus_page: usize,
}

impl TextSelection {
    pub fn range_on_page(&self, page: usize, length: usize) -> Option<(usize, usize)> {
        let a = (self.page, self.anchor);
        let b = (self.focus_page, self.focus);
        let (start, end) = if a <= b { (a, b) } else { (b, a) };
        if page < start.0 || page > end.0 {
            return None;
        }
        Some((
            if page == start.0 {
                start.1.min(length)
            } else {
                0
            },
            if page == end.0 {
                (end.1 + 1).min(length)
            } else {
                length
            },
        ))
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
    waiting: bool,
    running: Option<(Arc<AtomicBool>, Receiver<Result<SearchOutcome, CoreError>>)>,
    pub focus_requested: bool,
    /// Matches chosen in the results list for redaction.
    pub marked: std::collections::BTreeSet<usize>,
}

impl SearchState {
    pub fn is_running(&self) -> bool {
        self.waiting || self.running.is_some()
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
        self.waiting = false;
        if let Some((cancel, _)) = self.running.take() {
            cancel.store(true, Ordering::Relaxed);
        }
    }

    pub fn is_stale(&self) -> bool {
        self.searched
            .as_ref()
            .is_some_and(|(query, options, _)| query != &self.query || *options != self.options)
    }
}

enum TextMessage {
    Page(usize, PageText),
    Finished,
}

pub struct DocumentTab {
    pub id: u64,
    pub session: DocumentSession,
    pub reader: ReaderState,
    pub history: NavigationHistory,
    pub pages: Vec<PageInfo>,
    pub layout_cache: crate::reader_view::LayoutCache,
    pub appearance_digests: Vec<String>,
    pub render_carry: Option<(u64, HashSet<usize>)>,
    pages_generation: Option<u64>,
    text: Option<(u64, Arc<Vec<PageText>>)>,
    text_job: Option<(u64, Arc<AtomicBool>, Receiver<TextMessage>)>,
    text_priority: Arc<AtomicUsize>,
    text_complete: bool,
    text_ready: Vec<bool>,
    pub search: SearchState,
    pub tool: Tool,
    pub selection: Option<TextSelection>,
    pub annotations: crate::annotation_ui::AnnotationState,
    pub forms: crate::forms_ui::FormPanelState,
    pub redaction: crate::redaction_ui::RedactionState,
    /// Scroll the reader so this page is at the top on the next frame.
    pub scroll_to_page: Option<usize>,
    /// Scroll so this user-space point of the page is visible.
    pub scroll_to_point: Option<(usize, (f32, f32))>,
    pub go_to_page_text: String,
    pub scroll_offset: Vec2,
    pub navigation_anchor: Option<usize>,
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
            layout_cache: Default::default(),
            appearance_digests: Vec::new(),
            render_carry: None,
            pages_generation: None,
            text: None,
            text_job: None,
            text_priority: Arc::new(AtomicUsize::new(0)),
            text_complete: false,
            text_ready: Vec::new(),
            search: SearchState::default(),
            tool: Tool::SelectText,
            selection: None,
            annotations: Default::default(),
            forms: Default::default(),
            redaction: Default::default(),
            scroll_to_page: None,
            scroll_to_point: None,
            go_to_page_text: "1".into(),
            scroll_offset: Vec2::ZERO,
            navigation_anchor: None,
        };
        tab.refresh_pages();
        tab.refresh_annotation_index();
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
        self.layout_cache.clear();
        self.pages_generation = Some(generation);
        self.pages = pdf_core::text::page_infos(&self.pdf_data()).unwrap_or_default();
    }

    /// Call after any editor mutation, undo or redo.
    pub fn after_mutation(&mut self, preferred_page: Option<usize>) {
        self.render_carry = None;
        self.search.cancel();
        self.refresh_pages();
        self.reader
            .synchronize(self.session.editor.page_count(), preferred_page);
        self.go_to_page_text = (self.reader.selected_page_index() + 1).to_string();
        self.selection = None;
        self.refresh_annotation_index();
        // Search results describe the previous revision.
        if self.search.outcome.is_some() {
            self.search.outcome = None;
            self.search.active = None;
            self.search.searched = None;
            self.search.marked.clear();
        }
    }

    /// Incremental text for this revision. Missing pages stay empty until published.
    pub fn text_index(&mut self, ctx: &egui::Context) -> Option<Arc<Vec<PageText>>> {
        let generation = self.generation();
        if self
            .text
            .as_ref()
            .is_none_or(|(built, _)| *built != generation)
        {
            if let Some((_, cancel, _)) = self.text_job.take() {
                cancel.store(true, Ordering::Relaxed);
            }
            self.text = Some((
                generation,
                Arc::new(vec![PageText::default(); self.pages.len()]),
            ));
            self.text_complete = false;
            self.text_ready = vec![false; self.pages.len()];
            let cancel = Arc::new(AtomicBool::new(false));
            let (sender, receiver) = std::sync::mpsc::sync_channel(8);
            let bytes = self.pdf_data();
            let worker_cancel = Arc::clone(&cancel);
            let priority = Arc::clone(&self.text_priority);
            let ctx = ctx.clone();
            std::thread::spawn(move || {
                let _ = pdf_core::text::stream_text_index(
                    &bytes,
                    &worker_cancel,
                    &priority,
                    |index, text| {
                        if sender.send(TextMessage::Page(index, text)).is_err() {
                            return false;
                        }
                        ctx.request_repaint();
                        true
                    },
                );
                let _ = sender.send(TextMessage::Finished);
                ctx.request_repaint();
            });
            self.text_job = Some((generation, cancel, receiver));
        }
        let mut finished = false;
        if let Some((_, _, receiver)) = &self.text_job {
            loop {
                match receiver.try_recv() {
                    Ok(TextMessage::Page(index, page)) => {
                        let pages = Arc::make_mut(&mut self.text.as_mut().unwrap().1);
                        if let Some(slot) = pages.get_mut(index) {
                            *slot = page;
                            self.text_ready[index] = true;
                        }
                    }
                    Ok(TextMessage::Finished) | Err(TryRecvError::Disconnected) => {
                        finished = true;
                        break;
                    }
                    Err(TryRecvError::Empty) => break,
                }
            }
        }
        if finished {
            self.text_job = None;
            self.text_complete = true;
        }
        self.text.as_ref().map(|(_, text)| Arc::clone(text))
    }

    pub fn prioritize_text(&self, page: usize) {
        self.text_priority.store(page, Ordering::Relaxed);
    }

    pub fn start_search(&mut self, ctx: &egui::Context) {
        self.search.cancel();
        self.search.outcome = None;
        self.search.active = None;
        self.search.marked.clear();
        if self.search.query.trim().is_empty() {
            self.search.searched = None;
            return;
        }
        self.search.searched = Some((
            self.search.query.clone(),
            self.search.options,
            self.generation(),
        ));
        self.search.waiting = true;
        self.poll_search(ctx);
    }

    pub fn poll_search(&mut self, ctx: &egui::Context) {
        if self.search.waiting {
            let pages = self.text_index(ctx);
            if self.text_complete
                && let Some(pages) = pages
            {
                self.search.waiting = false;
                let query = self.search.query.trim().to_owned();
                let options = self.search.options;
                let cancel = Arc::new(AtomicBool::new(false));
                let worker_cancel = Arc::clone(&cancel);
                let (sender, receiver) = channel();
                let ctx = ctx.clone();
                std::thread::spawn(move || {
                    let _ = sender.send(pdf_core::text::search(
                        &pages,
                        &query,
                        options,
                        &worker_cancel,
                    ));
                    ctx.request_repaint();
                });
                self.search.running = Some((cancel, receiver));
            }
        }
        let Some((_, receiver)) = &self.search.running else {
            return;
        };
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

    pub fn metadata_generation(&self) -> Option<u64> {
        self.pages_generation
    }
    pub fn record_render_carry(&mut self, generation: u64, unchanged: HashSet<usize>) {
        if let Some((_, pages)) = &mut self.render_carry {
            pages.retain(|page| unchanged.contains(page));
        } else {
            self.render_carry = Some((generation, unchanged));
        }
    }

    /// Known annotation/form edits preserve text, geometry, labels and links.
    pub fn preserve_page_metadata(&mut self) {
        let previous = self.pages_generation;
        self.layout_cache.preserve_generation(self.generation());
        self.pages_generation = Some(self.generation());
        if let Some((generation, _)) = &mut self.text
            && Some(*generation) == previous
        {
            *generation = self.session.editor.generation();
        }
        if let Some((generation, _, _)) = &mut self.text_job
            && Some(*generation) == previous
        {
            *generation = self.session.editor.generation();
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
        let next = if forward {
            (current + 1) % count
        } else {
            (current + count - 1) % count
        };
        self.select_search_match(Some(next));
    }

    pub fn selected_text(&self) -> Option<String> {
        let selection = self.selection.as_ref()?;
        let (generation, text) = self.text.as_ref()?;
        if *generation != self.generation() {
            return None;
        }
        let start_page = selection.page.min(selection.focus_page);
        let end_page = selection.page.max(selection.focus_page);
        if (start_page..=end_page).any(|page| !self.text_ready.get(page).copied().unwrap_or(false))
        {
            return None;
        }
        let value = text
            .iter()
            .enumerate()
            .filter_map(|(index, page)| {
                selection
                    .range_on_page(index, page.chars.len())
                    .map(|(start, end)| page.substring(start, end))
            })
            .collect::<Vec<_>>()
            .join("\n\n");
        (!value.trim().is_empty()).then_some(value)
    }

    /// Navigates and records history (outline, bookmarks, go-to, search).
    pub fn navigate_to(&mut self, index: usize) {
        if self.reader.select_page(index) {
            if let Some(page_id) = self.session.editor.page_id(index).cloned() {
                self.history.record(NavigationLocation { page_id });
            }
            self.prioritize_text(index);
            self.scroll_to_page = Some(index);
            self.go_to_page_text = (index + 1).to_string();
        }
    }

    /// Moves without recording history (arrow keys, thumbnails).
    pub fn show_page(&mut self, index: usize) {
        if self.reader.select_page(index) {
            self.prioritize_text(index);
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

impl Drop for DocumentTab {
    fn drop(&mut self) {
        self.search.cancel();
        if let Some((_, cancel, _)) = &self.text_job {
            cancel.store(true, Ordering::Relaxed);
        }
    }
}

#[cfg(test)]
mod edit_cache_tests {
    use super::*;
    fn tab() -> DocumentTab {
        let pdf_core::loader::OpenResult::Opened(session) =
            pdf_core::loader::open_bytes(pdf_core::testing::numbered_pdf(2), "cache.pdf".into())
                .unwrap()
        else {
            panic!("fixture")
        };
        DocumentTab::new(1, session)
    }
    #[test]
    fn annotation_keeps_unaffected_images_and_does_not_retag_stale_text() {
        let mut tab = tab();
        tab.text = Some((tab.generation(), Arc::new(vec![PageText::default(); 2])));
        tab.session.editor.rotate_pages(&[0], true).unwrap();
        tab.after_mutation(None);
        let stale_generation = tab.text.as_ref().unwrap().0;
        let generation = tab.generation();
        tab.annotate(|doc| {
            pdf_core::annotations::add_text_note(
                doc,
                0,
                (72.0, 200.0),
                "note",
                pdf_core::annotations::palette::YELLOW,
            )
            .map(|_| ())
        })
        .unwrap();
        assert_eq!(tab.text.as_ref().unwrap().0, stale_generation);
        assert_eq!(tab.render_carry.as_ref().unwrap().0, generation);
        assert_eq!(tab.render_carry.as_ref().unwrap().1, HashSet::from([1]));
    }
    #[test]
    fn form_changes_invalidate_only_their_page() {
        let pdf_core::loader::OpenResult::Opened(session) =
            pdf_core::loader::open_bytes(pdf_core::testing::form_pdf(), "form.pdf".into()).unwrap()
        else {
            panic!("fixture")
        };
        let mut tab = DocumentTab::new(1, session);
        tab.session
            .editor
            .mutate(|doc| {
                pdf_core::forms::set_value(
                    doc,
                    "name",
                    &pdf_core::forms::FieldValue::Text("Ada".into()),
                )
            })
            .unwrap();
        tab.after_annotation_change();
        assert_eq!(tab.render_carry.as_ref().unwrap().1, HashSet::from([1]));
    }
}
