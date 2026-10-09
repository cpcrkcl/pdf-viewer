//! Application shell: tabs, menus, shortcuts, dialogs and background jobs.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Receiver, TryRecvError, channel};

use egui::{Align, Align2, Color32, Key, KeyboardShortcut, Layout, Modifiers, RichText, Ui};
use pdf_core::export::{self, Compression, ExportResult, Protection};
use pdf_core::loader::{self, LockedDocument, OpenResult};
use pdf_core::navigation::PageBookmarkStore;
use pdf_core::persistence::support_directory;
use pdf_core::recents::{BookmarkCoder, RecentDocumentsStore};
use pdf_core::{CoreError, DocumentSession};
use serde::{Deserialize, Serialize};

use crate::document_tab::DocumentTab;
use crate::reader_state::{DisplayMode, PageLabelStyle, ReaderTheme};
use crate::render::RenderService;
use crate::theme::{self, mocha};
use crate::annotation_ui::{self, AnnotationRequest, AnnotationTool, StampChoice};
use crate::document_tab::Tool;
use crate::forms_ui::{self, FormRequest};
use crate::libraries_ui::{LibraryDialog, LibraryKind, LibraryOutcome};
use crate::redaction_ui::{self, RedactionRequest};
use crate::{interaction, reader_view, sidebar};

const PREFERENCES_KEY: &str = "pdfviewer.preferences.v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Preferences {
    theme: ReaderTheme,
    display_mode: DisplayMode,
    sidebar_visible: bool,
    compression: Compression,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            theme: ReaderTheme::Night,
            display_mode: DisplayMode::Continuous,
            sidebar_visible: true,
            compression: Compression::Standard,
        }
    }
}

enum Job {
    Opening {
        path: PathBuf,
        receiver: Receiver<Result<OpenResult, CoreError>>,
    },
    Exporting {
        receiver: Receiver<Result<ExportResult, String>>,
        tab: u64,
        then: AfterExport,
    },
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum AfterExport {
    Nothing,
    CloseTab,
}

enum Dialog {
    Error(String),
    Password {
        locked: LockedDocument,
        input: String,
        wrong: bool,
    },
    ConfirmDeletePages {
        tab: u64,
        pages: Vec<usize>,
    },
    UnsavedChanges {
        tab: u64,
    },
    QuitWithUnexportedChanges {
        count: usize,
    },
    Export {
        tab: u64,
        compression: Compression,
        then: AfterExport,
    },
    ExportReceipt(ExportResult),
    RenameBookmark {
        id: uuid::Uuid,
        input: String,
    },
    PageLabels {
        tab: u64,
    },
    ConfirmLink(String),
    Info(String),
    ConfirmRedaction {
        tab: u64,
    },
    Note {
        tab: u64,
        page: usize,
        target: NoteTarget,
        text: String,
    },
    Library {
        dialog: LibraryDialog,
        /// Place the chosen image here once picked.
        place: Option<(u64, usize, (f32, f32))>,
    },
}

enum NoteTarget {
    New((f32, f32)),
    Existing(pdf_core::annotations::AnnotationId),
}

pub struct PdfViewerApp {
    tabs: Vec<DocumentTab>,
    active: usize,
    next_tab_id: u64,
    renderer: RenderService,
    recents: RecentDocumentsStore,
    bookmarks: PageBookmarkStore,
    preferences: Preferences,
    job: Option<Job>,
    dialogs: Vec<Dialog>,
    allow_quit: bool,
    capture: Option<crate::debug_capture::DebugCapture>,
    signatures: pdf_core::signatures::SignatureLibrary,
    stamps: pdf_core::signatures::SignatureLibrary,
    library_thumbnails: std::collections::HashMap<uuid::Uuid, Option<egui::TextureHandle>>,
}

impl PdfViewerApp {
    pub fn new(cc: &eframe::CreationContext<'_>, initial_paths: Vec<PathBuf>) -> Self {
        theme::apply(&cc.egui_ctx);
        crate::fonts::install(&cc.egui_ctx);
        let preferences = cc
            .storage
            .and_then(|storage| eframe::get_value(storage, PREFERENCES_KEY))
            .unwrap_or_default();
        let support = support_directory();
        let mut app = Self {
            tabs: Vec::new(),
            active: 0,
            next_tab_id: 1,
            renderer: RenderService::new(cc.egui_ctx.clone()),
            recents: RecentDocumentsStore::new(support.join("recent-documents.v1.json"), bookmark_coder(), 10),
            bookmarks: PageBookmarkStore::new(support.join("page-bookmarks.v1.json")),
            preferences,
            job: None,
            dialogs: Vec::new(),
            allow_quit: false,
            capture: crate::debug_capture::DebugCapture::from_env(),
            signatures: pdf_core::signatures::SignatureLibrary::new(support.join("Signatures"), "Visual Signature"),
            stamps: pdf_core::signatures::SignatureLibrary::new(support.join("Stamps"), "Custom Stamp"),
            library_thumbnails: Default::default(),
        };
        if let Some(error) = pdf_core::engine::pdfium().err() {
            app.dialogs.push(Dialog::Error(error.to_string()));
        }
        for path in initial_paths {
            app.open_path(path);
        }
        app
    }

    fn active_tab(&mut self) -> Option<&mut DocumentTab> {
        self.tabs.get_mut(self.active)
    }

    fn tab_index(&self, id: u64) -> Option<usize> {
        self.tabs.iter().position(|tab| tab.id == id)
    }

    fn error(&mut self, message: impl Into<String>) {
        self.dialogs.push(Dialog::Error(message.into()));
    }

    // MARK: Opening

    fn present_open_panel(&mut self) {
        if let Some(paths) = rfd::FileDialog::new().add_filter("PDF", &["pdf", "PDF"]).pick_files() {
            for path in paths {
                self.open_path(path);
            }
        }
    }

    pub fn open_path(&mut self, path: PathBuf) {
        if let Some(index) = self.tabs.iter().position(|tab| same_file(&tab.session.source_path, &path)) {
            self.active = index;
            return;
        }
        if self.job.is_some() {
            self.error("Another document is still being prepared. Try again when it finishes.");
            return;
        }
        let (sender, receiver) = channel();
        let worker_path = path.clone();
        std::thread::spawn(move || {
            let _ = sender.send(loader::open(&worker_path));
        });
        self.job = Some(Job::Opening { path, receiver });
    }

    fn activate(&mut self, session: DocumentSession) {
        let _ = self.recents.record(&session.source_path);
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        let mut tab = DocumentTab::new(id, session);
        tab.reader.theme = self.preferences.theme;
        tab.reader.display_mode = self.preferences.display_mode;
        tab.reader.is_sidebar_visible = self.preferences.sidebar_visible;
        self.tabs.push(tab);
        self.active = self.tabs.len() - 1;
    }

    fn poll_job(&mut self) {
        let Some(job) = self.job.take() else { return };
        match job {
            Job::Opening { path, receiver } => match receiver.try_recv() {
                Err(TryRecvError::Empty) => self.job = Some(Job::Opening { path, receiver }),
                Err(TryRecvError::Disconnected) => self.error(CoreError::InvalidPdf.to_string()),
                Ok(Ok(OpenResult::Opened(session))) => self.activate(session),
                Ok(Ok(OpenResult::PasswordRequired(locked))) => self.dialogs.push(Dialog::Password {
                    locked,
                    input: String::new(),
                    wrong: false,
                }),
                Ok(Err(error)) => self.error(error.to_string()),
            },
            Job::Exporting { receiver, tab, then } => match receiver.try_recv() {
                Err(TryRecvError::Empty) => self.job = Some(Job::Exporting { receiver, tab, then }),
                Err(TryRecvError::Disconnected) => self.error("The export stopped unexpectedly."),
                Ok(Err(message)) => self.error(message),
                Ok(Ok(result)) => self.finish_export(result, tab, then),
            },
        }
    }

    // MARK: Export

    fn request_export(&mut self, tab: u64, then: AfterExport) {
        self.dialogs.push(Dialog::Export {
            tab,
            compression: self.preferences.compression,
            then,
        });
    }

    fn request_export_active(&mut self) {
        if let Some(tab) = self.tabs.get(self.active) {
            let id = tab.id;
            self.request_export(id, AfterExport::Nothing);
        }
    }

    fn start_export(&mut self, tab_id: u64, compression: Compression, then: AfterExport) {
        let Some(index) = self.tab_index(tab_id) else { return };
        let tab = &self.tabs[index];
        let stem = tab
            .session
            .source_path
            .file_stem()
            .map(|stem| stem.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Document".into());
        let mut dialog = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf"])
            .set_file_name(format!("{stem} (edited).pdf"));
        if let Some(directory) = tab.session.source_path.parent() {
            dialog = dialog.set_directory(directory);
        }
        let Some(mut destination) = dialog.save_file() else { return };
        if destination.extension().is_none() {
            destination.set_extension("pdf");
        }
        let protection = match protection_for(&tab.session) {
            Ok(protection) => protection,
            Err(message) => return self.error(message),
        };
        self.preferences.compression = compression;
        let data = tab.pdf_data();
        let source = tab.session.source_path.clone();
        let (sender, receiver) = channel();
        std::thread::spawn(move || {
            let result = export::export(&data, &source, &destination, &protection, compression)
                .map_err(|error| error.to_string());
            let _ = sender.send(result);
        });
        self.job = Some(Job::Exporting {
            receiver,
            tab: tab_id,
            then,
        });
    }

    /// Protects the exported revision. The working copy can't have changed
    /// meanwhile: the export overlay blocks input until it finishes.
    fn finish_export(&mut self, result: ExportResult, tab: u64, then: AfterExport) {
        let Some(index) = self.tab_index(tab) else { return };
        self.tabs[index].session.editor.mark_current_revision_exported();
        match then {
            AfterExport::CloseTab => self.close_tab_now(index),
            AfterExport::Nothing => self.dialogs.push(Dialog::ExportReceipt(result)),
        }
    }

    // MARK: Closing

    fn request_close_tab(&mut self, index: usize) {
        let Some(tab) = self.tabs.get(index) else { return };
        if tab.has_unexported_changes() {
            self.dialogs.push(Dialog::UnsavedChanges { tab: tab.id });
        } else {
            self.close_tab_now(index);
        }
    }

    fn close_tab_now(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        let mut tab = self.tabs.remove(index);
        tab.session.close();
        if self.active >= self.tabs.len() {
            self.active = self.tabs.len().saturating_sub(1);
        }
    }

    // MARK: Page operations

    fn with_assembly_permission(&mut self) -> bool {
        match self.tabs.get(self.active) {
            Some(tab) if tab.session.security.allows_document_assembly() => true,
            Some(_) => {
                self.error(CoreError::PermissionDenied.to_string());
                false
            }
            None => false,
        }
    }

    fn page_operation(&mut self, operation: impl FnOnce(&mut DocumentTab) -> Result<Option<usize>, CoreError>) {
        if !self.with_assembly_permission() {
            return;
        }
        let Some(tab) = self.active_tab() else { return };
        match operation(tab) {
            Ok(preferred) => tab.after_mutation(preferred),
            Err(error) => {
                let message = error.to_string();
                self.error(message);
            }
        }
    }

    fn rotate_selected(&mut self, clockwise: bool) {
        self.page_operation(|tab| {
            let pages = tab.reader.selected_pages_vec();
            tab.session.editor.rotate_pages(&pages, clockwise).map(|_| None)
        });
    }

    fn move_selected(&mut self, destination: impl FnOnce(&DocumentTab) -> usize) {
        self.page_operation(|tab| {
            let pages = tab.reader.selected_pages_vec();
            let target = destination(tab);
            tab.session.editor.move_pages(&pages, target)?;
            // Keep the moved pages selected at their new positions.
            let first = pages[0];
            let count = pages.len();
            let before = pages.iter().filter(|page| **page < target).count();
            let start = target - before;
            let new_selection: BTreeSet<usize> = (start..start + count).collect();
            tab.reader.synchronize(tab.session.editor.page_count(), Some(start));
            tab.reader.select_pages(new_selection, Some(start));
            let _ = first;
            Ok(Some(start))
        });
    }

    fn request_delete_selected(&mut self) {
        if !self.with_assembly_permission() {
            return;
        }
        let Some(tab) = self.tabs.get(self.active) else { return };
        self.dialogs.push(Dialog::ConfirmDeletePages {
            tab: tab.id,
            pages: tab.reader.selected_pages_vec(),
        });
    }

    fn insert_pages_from_pdf(&mut self) {
        if !self.with_assembly_permission() {
            return;
        }
        let Some(path) = rfd::FileDialog::new().add_filter("PDF", &["pdf"]).pick_file() else { return };
        let session = match loader::open(&path) {
            Ok(OpenResult::Opened(session)) => session,
            Ok(OpenResult::PasswordRequired(_)) => {
                return self.error("Protected PDFs can't be merged. Open it, export an unprotected copy, then merge that copy.");
            }
            Err(error) => return self.error(error.to_string()),
        };
        let fingerprint = session.fingerprint.clone();
        let data = session.editor.pdf_data();
        self.page_operation(|tab| {
            let at = tab.reader.selected_page_index() + 1;
            tab.session.editor.insert_pages(&data, None, Some(&fingerprint), at)?;
            Ok(Some(at))
        });
    }

    fn extract_selected(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else { return };
        let pages = tab.reader.selected_pages_vec();
        let extracted = match tab.session.editor.extract_pages(&pages) {
            Ok(bytes) => bytes,
            Err(error) => return self.error(error.to_string()),
        };
        let protection = match protection_for(&tab.session) {
            Ok(protection) => protection,
            Err(message) => return self.error(message),
        };
        let source = tab.session.source_path.clone();
        let Some(destination) = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf"])
            .set_file_name("Extracted Pages.pdf")
            .save_file()
        else {
            return;
        };
        match export::export(&extracted, &source, &destination, &protection, self.preferences.compression) {
            Ok(result) => self.dialogs.push(Dialog::ExportReceipt(result)),
            Err(error) => self.error(error.to_string()),
        }
    }

    fn undo(&mut self) {
        let Some(tab) = self.active_tab() else { return };
        if tab.session.editor.undo().is_ok() {
            tab.after_mutation(None);
        }
    }

    fn redo(&mut self) {
        let Some(tab) = self.active_tab() else { return };
        if tab.session.editor.redo().is_ok() {
            tab.after_mutation(None);
        }
    }

    fn copy_selection(&mut self, ctx: &egui::Context) {
        let Some(tab) = self.tabs.get(self.active) else { return };
        let Some(text) = tab.selected_text() else { return };
        if !tab.session.security.allows_content_copying() {
            return self.error("This PDF's permissions don't allow copying text.");
        }
        ctx.copy_text(text);
    }

    // MARK: Annotations and forms

    fn handle_annotation_request(&mut self, request: AnnotationRequest) {
        let Some(tab_id) = self.tabs.get(self.active).map(|tab| tab.id) else { return };
        match request {
            AnnotationRequest::None => {}
            AnnotationRequest::Error(message) => self.error(message),
            AnnotationRequest::NewNote { page, point } => self.dialogs.push(Dialog::Note {
                tab: tab_id,
                page,
                target: NoteTarget::New(point),
                text: String::new(),
            }),
            AnnotationRequest::EditNote { page, id, contents } => self.dialogs.push(Dialog::Note {
                tab: tab_id,
                page,
                target: NoteTarget::Existing(id),
                text: contents,
            }),
            AnnotationRequest::PlaceStamp { page, point, choice } => {
                let result = match choice {
                    StampChoice::Preset(preset) => {
                        let tab = &mut self.tabs[self.active];
                        tab.annotate(|document| pdf_core::annotations::add_stamp(document, page, point, preset).map(|_| ()))
                    }
                    StampChoice::Custom(id) => match self.stamps.image_data(id) {
                        Ok(data) => {
                            let name = self.stamps.signatures().iter().find(|s| s.id == id).map(|s| s.display_name.clone()).unwrap_or_default();
                            let tab = &mut self.tabs[self.active];
                            annotation_ui::place_image(tab, page, point, &data, pdf_core::annotations::SignatureSize::Medium, Some(&name))
                        }
                        Err(error) => Err(error.to_string()),
                    },
                };
                if let Err(message) = result {
                    self.error(message);
                }
            }
            AnnotationRequest::PlaceSignature { page, point } => {
                let chosen = self.tabs[self.active].annotations.signature;
                match chosen.map(|id| self.signatures.image_data(id)) {
                    Some(Ok(data)) => {
                        let tab = &mut self.tabs[self.active];
                        let size = tab.annotations.signature_size;
                        if let Err(message) = annotation_ui::place_image(tab, page, point, &data, size, None) {
                            self.error(message);
                        }
                    }
                    _ => self.dialogs.push(Dialog::Library {
                        dialog: LibraryDialog::new(LibraryKind::Signatures),
                        place: Some((tab_id, page, point)),
                    }),
                }
            }
            AnnotationRequest::OpenSignatureLibrary => self.dialogs.push(Dialog::Library {
                dialog: LibraryDialog::new(LibraryKind::Signatures),
                place: None,
            }),
            AnnotationRequest::OpenStampLibrary => self.dialogs.push(Dialog::Library {
                dialog: LibraryDialog::new(LibraryKind::Stamps),
                place: None,
            }),
        }
    }

    fn use_library_item(&mut self, kind: LibraryKind, id: uuid::Uuid, place: Option<(u64, usize, (f32, f32))>) {
        let Some(index) = place.and_then(|(tab, _, _)| self.tab_index(tab)).or(Some(self.active)) else { return };
        let Some(tab) = self.tabs.get_mut(index) else { return };
        match kind {
            LibraryKind::Signatures => {
                tab.annotations.signature = Some(id);
                tab.tool = Tool::Annotate(AnnotationTool::Signature);
                if let Some((_, page, point)) = place {
                    let size = tab.annotations.signature_size;
                    let result = self.signatures.image_data(id).map_err(|error| error.to_string()).and_then(|data| {
                        annotation_ui::place_image(&mut self.tabs[index], page, point, &data, size, None)
                    });
                    if let Err(message) = result {
                        self.error(message);
                    }
                }
            }
            LibraryKind::Stamps => {
                tab.annotations.stamp = StampChoice::Custom(id);
                tab.tool = Tool::Annotate(AnnotationTool::Stamp);
            }
        }
    }

    fn handle_form_request(&mut self, request: FormRequest) {
        match request {
            FormRequest::None => {}
            FormRequest::Error(message) => self.error(message),
            FormRequest::Info(message) => self.dialogs.push(Dialog::Info(message)),
            FormRequest::ExportValues(json) => {
                self.export_library_json("Export Form Values", "Form Values.json", Ok(json));
            }
            FormRequest::ExportFlattened(bytes) => {
                let Some(tab) = self.tabs.get(self.active) else { return };
                let protection = match protection_for(&tab.session) {
                    Ok(protection) => protection,
                    Err(message) => return self.error(message),
                };
                let source = tab.session.source_path.clone();
                let Some(destination) = rfd::FileDialog::new()
                    .add_filter("PDF", &["pdf"])
                    .set_file_name(format!("{} (flattened).pdf", source.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default()))
                    .save_file()
                else {
                    return;
                };
                match export::export(&bytes, &source, &destination, &protection, self.preferences.compression) {
                    Ok(result) => self.dialogs.push(Dialog::ExportReceipt(result)),
                    Err(error) => self.error(error.to_string()),
                }
            }
        }
    }

    // MARK: Library JSON

    fn export_library_json(&mut self, title: &str, file_name: &str, data: Result<Vec<u8>, CoreError>) {
        let data = match data {
            Ok(data) => data,
            Err(error) => return self.error(error.to_string()),
        };
        let Some(path) = rfd::FileDialog::new()
            .set_title(title)
            .add_filter("JSON", &["json"])
            .set_file_name(file_name)
            .save_file()
        else {
            return;
        };
        if let Err(error) = pdf_core::persistence::write_atomically(&path, &data) {
            self.error(error.to_string());
        }
    }

    fn import_library_json(&mut self, title: &str) -> Option<Vec<u8>> {
        let path = rfd::FileDialog::new().set_title(title).add_filter("JSON", &["json"]).pick_file()?;
        match std::fs::read(&path) {
            Ok(data) if data.len() <= 16 * 1024 * 1024 => Some(data),
            Ok(_) => {
                self.error("That file is too large to import.");
                None
            }
            Err(error) => {
                self.error(error.to_string());
                None
            }
        }
    }

    // MARK: Input

    fn handle_shortcuts(&mut self, ctx: &egui::Context) {
        let shortcut = |modifiers: Modifiers, key: Key| {
            ctx.input_mut(|input| input.consume_shortcut(&KeyboardShortcut::new(modifiers, key)))
        };
        let command = Modifiers::COMMAND;
        let command_shift = Modifiers::COMMAND | Modifiers::SHIFT;
        let command_option = Modifiers::COMMAND | Modifiers::ALT;

        if shortcut(command, Key::O) {
            self.present_open_panel();
        }
        if self.tabs.is_empty() {
            return;
        }
        if shortcut(command, Key::W) {
            self.request_close_tab(self.active);
        }
        if shortcut(command_shift, Key::S) || shortcut(command, Key::E) {
            self.request_export_active();
        }
        if shortcut(command_shift, Key::Z) {
            self.redo();
        } else if shortcut(command, Key::Z) {
            self.undo();
        }
        if shortcut(command, Key::Plus) || shortcut(command, Key::Equals) {
            self.active_tab().map(|tab| tab.reader.zoom_in());
        }
        if shortcut(command, Key::Minus) {
            self.active_tab().map(|tab| tab.reader.zoom_out());
        }
        if shortcut(command, Key::Num0) {
            self.active_tab().map(|tab| tab.reader.zoom_to_fit());
        }
        if shortcut(command_option, Key::S) {
            self.active_tab().map(|tab| tab.reader.is_sidebar_visible = !tab.reader.is_sidebar_visible);
        }
        if shortcut(command, Key::OpenBracket) {
            self.active_tab().map(DocumentTab::go_back);
        }
        if shortcut(command, Key::CloseBracket) {
            self.active_tab().map(DocumentTab::go_forward);
        }
        if shortcut(command, Key::R) {
            self.rotate_selected(true);
        }
        if shortcut(command_shift, Key::R) {
            self.rotate_selected(false);
        }
        if shortcut(command, Key::D) {
            self.active_tab().map(|tab| {
                let index = tab.reader.selected_page_index();
                if let Some(page_id) = tab.session.editor.page_id(index).cloned() {
                    Some((tab.session.fingerprint.clone(), page_id, format!("Page {}", tab.page_label(index))))
                } else {
                    None
                }
            })
            .flatten()
            .map(|(fingerprint, page_id, label)| self.bookmarks.add(&fingerprint, page_id, &label));
        }
        if shortcut(Modifiers::CTRL, Key::Tab) {
            self.active = (self.active + 1) % self.tabs.len();
        }
        if shortcut(command_shift, Key::A) {
            self.active_tab().map(|tab| {
                let annotating = matches!(tab.tool, Tool::Annotate(_));
                tab.tool = if annotating { Tool::SelectText } else { Tool::Annotate(AnnotationTool::Select) };
            });
        }
        if shortcut(command, Key::F) {
            self.active_tab().map(|tab| {
                tab.search.focus_requested = true;
                tab.reader.is_sidebar_visible = true;
                tab.reader.sidebar_tab = crate::reader_state::SidebarTab::Search;
            });
        }
        if shortcut(command_shift, Key::G) {
            self.active_tab().map(|tab| tab.step_search(false));
        } else if shortcut(command, Key::G) {
            self.active_tab().map(|tab| tab.step_search(true));
        }
        if !ctx.egui_wants_keyboard_input() && ctx.input_mut(|input| {
            input.events.iter().any(|event| matches!(event, egui::Event::Copy))
        }) {
            self.copy_selection(ctx);
        }

        if ctx.egui_wants_keyboard_input() {
            return;
        }
        let pressed = |key: Key| ctx.input(|input| input.key_pressed(key) && input.modifiers.is_none());
        let Some(tab) = self.tabs.get_mut(self.active) else { return };
        let current = tab.reader.selected_page_index();
        let last = tab.session.editor.page_count().saturating_sub(1);
        let step = if tab.reader.display_mode == DisplayMode::TwoPage { 2 } else { 1 };
        let single = tab.reader.display_mode == DisplayMode::SinglePage;
        if pressed(Key::PageDown) || (single && (pressed(Key::ArrowRight) || pressed(Key::ArrowDown) || pressed(Key::Space))) {
            tab.show_page((current + step).min(last));
        }
        if pressed(Key::PageUp) || (single && (pressed(Key::ArrowLeft) || pressed(Key::ArrowUp))) {
            tab.show_page(current.saturating_sub(step));
        }
        if pressed(Key::Escape) {
            tab.selection = None;
            tab.annotations.selected = None;
            if matches!(tab.tool, Tool::Annotate(tool) if tool != AnnotationTool::Select) {
                tab.tool = Tool::Annotate(AnnotationTool::Select);
            }
        }
        if pressed(Key::Home) {
            tab.show_page(0);
        }
        if pressed(Key::End) {
            tab.show_page(last);
        }
        if pressed(Key::Delete) || pressed(Key::Backspace) {
            if tab.annotations.selected.is_some() {
                if let Err(message) = annotation_ui::delete_selected(tab) {
                    self.error(message);
                }
            } else if tab.reader.is_sidebar_visible && tab.reader.sidebar_tab == crate::reader_state::SidebarTab::Thumbnails {
                self.request_delete_selected();
            }
        }
    }

    fn handle_dropped_files(&mut self, ctx: &egui::Context) {
        let dropped: Vec<PathBuf> = ctx.input(|input| input.raw.dropped_files.iter().map(|file| file.path().to_path_buf()).filter(|path| !path.as_os_str().is_empty()).collect());
        let mut rejected = false;
        for path in dropped {
            if path.extension().and_then(|extension| extension.to_str()).is_some_and(|e| e.eq_ignore_ascii_case("pdf")) {
                self.open_path(path);
            } else {
                rejected = true;
            }
        }
        if rejected {
            self.error("PDFViewer can open PDF files only.");
        }
    }

    fn handle_close_request(&mut self, ctx: &egui::Context) {
        if !ctx.input(|input| input.viewport().close_requested()) {
            return;
        }
        if self.allow_quit {
            return;
        }
        let unexported = self.tabs.iter().filter(|tab| tab.has_unexported_changes()).count();
        if unexported > 0 {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            if !self.dialogs.iter().any(|dialog| matches!(dialog, Dialog::QuitWithUnexportedChanges { .. })) {
                self.dialogs.push(Dialog::QuitWithUnexportedChanges { count: unexported });
            }
        }
    }

    // MARK: Layout

    fn menu_bar(&mut self, ui: &mut Ui) {
        let has_tab = !self.tabs.is_empty();
        egui::MenuBar::new().ui(ui, |ui| {
            ui.menu_button("File", |ui| {
                if ui.button("Open…            ⌘O").clicked() {
                    self.present_open_panel();
                }
                ui.menu_button("Open Recent", |ui| {
                    let recents = self.recents.documents().to_vec();
                    if recents.is_empty() {
                        ui.weak("No recent documents");
                    }
                    for document in recents {
                        if ui.button(&document.display_name).clicked() {
                            match self.recents.resolve(&document) {
                                Ok(path) => self.open_path(path),
                                Err(error) => self.error(error.to_string()),
                            }
                        }
                    }
                    ui.separator();
                    if ui.button("Clear Menu").clicked() {
                        let _ = self.recents.clear();
                    }
                });
                ui.separator();
                if ui.add_enabled(has_tab, egui::Button::new("Export PDF…      ⇧⌘S")).clicked() {
                    self.request_export_active();
                }
                if ui.add_enabled(has_tab, egui::Button::new("Extract Selected Pages…")).clicked() {
                    self.extract_selected();
                }
                ui.separator();
                ui.menu_button("Library", |ui| {
                    if ui.button("Export Bookmarks…").clicked() {
                        let data = self.bookmarks.export_json();
                        self.export_library_json("Export Bookmarks", "PDFViewer Bookmarks.json", data);
                    }
                    if ui.button("Import Bookmarks…").clicked()
                        && let Some(data) = self.import_library_json("Import Bookmarks")
                        && let Err(error) = self.bookmarks.import_json(&data)
                    {
                        self.error(error.to_string());
                    }
                    if ui.button("Export Recent Documents…").clicked() {
                        let data = self.recents.export_json();
                        self.export_library_json("Export Recent Documents", "PDFViewer Recent Documents.json", data);
                    }
                    if ui.button("Import Recent Documents…").clicked()
                        && let Some(data) = self.import_library_json("Import Recent Documents")
                        && let Err(error) = self.recents.import_json(&data)
                    {
                        self.error(error.to_string());
                    }
                });
                ui.separator();
                if ui.add_enabled(has_tab, egui::Button::new("Close Tab        ⌘W")).clicked() {
                    self.request_close_tab(self.active);
                }
            });
            ui.menu_button("Edit", |ui| {
                let (can_undo, can_redo) = self
                    .tabs
                    .get(self.active)
                    .map(|tab| (tab.session.editor.can_undo(), tab.session.editor.can_redo()))
                    .unwrap_or_default();
                if ui.add_enabled(can_undo, egui::Button::new("Undo             ⌘Z")).clicked() {
                    self.undo();
                }
                if ui.add_enabled(can_redo, egui::Button::new("Redo            ⇧⌘Z")).clicked() {
                    self.redo();
                }
            });
            ui.add_enabled_ui(has_tab, |ui| {
                ui.menu_button("View", |ui| self.view_menu(ui));
                ui.menu_button("Go", |ui| self.go_menu(ui));
                ui.menu_button("Pages", |ui| self.pages_menu(ui));
            });
        });
    }

    fn view_menu(&mut self, ui: &mut Ui) {
        let Some(tab) = self.tabs.get_mut(self.active) else { return };
        if ui.checkbox(&mut tab.reader.is_sidebar_visible, "Sidebar   ⌥⌘S").changed() {
            self.preferences.sidebar_visible = tab.reader.is_sidebar_visible;
        }
        ui.separator();
        for mode in DisplayMode::ALL {
            if ui.radio_value(&mut tab.reader.display_mode, mode, mode.title()).clicked() {
                self.preferences.display_mode = mode;
                tab.scroll_to_page = Some(tab.reader.selected_page_index());
            }
        }
        ui.separator();
        for candidate in ReaderTheme::ALL {
            if ui.radio_value(&mut tab.reader.theme, candidate, candidate.title()).clicked() {
                self.preferences.theme = candidate;
            }
        }
        ui.separator();
        if ui.button("Zoom In            ⌘+").clicked() {
            tab.reader.zoom_in();
        }
        if ui.button("Zoom Out           ⌘−").clicked() {
            tab.reader.zoom_out();
        }
        if ui.button("Zoom to Fit        ⌘0").clicked() {
            tab.reader.zoom_to_fit();
        }
        if ui.button("Actual Size").clicked() {
            tab.reader.actual_size();
        }
        ui.separator();
        if ui.button("Page Labels…").clicked() {
            let id = tab.id;
            self.dialogs.push(Dialog::PageLabels { tab: id });
        }
    }

    fn go_menu(&mut self, ui: &mut Ui) {
        let Some(tab) = self.tabs.get_mut(self.active) else { return };
        let valid = tab.valid_page_ids();
        let current = tab.reader.selected_page_index();
        let last = tab.session.editor.page_count().saturating_sub(1);
        if ui.add_enabled(current > 0, egui::Button::new("Previous Page")).clicked() {
            tab.show_page(current - 1);
        }
        if ui.add_enabled(current < last, egui::Button::new("Next Page")).clicked() {
            tab.show_page(current + 1);
        }
        if ui.button("First Page").clicked() {
            tab.show_page(0);
        }
        if ui.button("Last Page").clicked() {
            tab.show_page(last);
        }
        ui.separator();
        if ui.add_enabled(tab.history.can_go_back(&valid), egui::Button::new("Back      ⌘[")).clicked() {
            tab.go_back();
        }
        if ui.add_enabled(tab.history.can_go_forward(&valid), egui::Button::new("Forward   ⌘]")).clicked() {
            tab.go_forward();
        }
        ui.separator();
        if ui.button("Add Bookmark      ⌘D").clicked()
            && let Some(page_id) = tab.session.editor.page_id(current).cloned()
        {
            let label = format!("Page {}", tab.page_label(current));
            self.bookmarks.add(&tab.session.fingerprint, page_id, &label);
        }
    }

    fn pages_menu(&mut self, ui: &mut Ui) {
        let Some(tab) = self.tabs.get(self.active) else { return };
        let selected = tab.reader.selected_pages_vec();
        let count = tab.session.editor.page_count();
        let first = selected.first().copied().unwrap_or(0);
        let last_selected = selected.last().copied().unwrap_or(0);
        if ui.button("Rotate Right        ⌘R").clicked() {
            self.rotate_selected(true);
        }
        if ui.button("Rotate Left        ⇧⌘R").clicked() {
            self.rotate_selected(false);
        }
        ui.separator();
        if ui.add_enabled(first > 0, egui::Button::new("Move Up")).clicked() {
            self.move_selected(move |_| first - 1);
        }
        if ui.add_enabled(last_selected + 1 < count, egui::Button::new("Move Down")).clicked() {
            self.move_selected(move |_| last_selected + 2);
        }
        if ui.add_enabled(first > 0, egui::Button::new("Move to Beginning")).clicked() {
            self.move_selected(|_| 0);
        }
        if ui.add_enabled(last_selected + 1 < count, egui::Button::new("Move to End")).clicked() {
            self.move_selected(move |_| count);
        }
        ui.separator();
        if ui.button("Insert Pages from PDF…").clicked() {
            self.insert_pages_from_pdf();
        }
        if ui.add_enabled(selected.len() < count, egui::Button::new("Delete Selected Pages…")).clicked() {
            self.request_delete_selected();
        }
    }

    fn tab_strip(&mut self, ui: &mut Ui) {
        let mut close = None;
        ui.horizontal(|ui| {
            for (index, tab) in self.tabs.iter().enumerate() {
                let mut title = tab.title();
                if tab.has_unexported_changes() {
                    title.insert_str(0, "• ");
                }
                let selected = index == self.active;
                let text = if selected { RichText::new(title).strong() } else { RichText::new(title) };
                if ui.selectable_label(selected, text).clicked() {
                    self.active = index;
                }
                if ui.small_button("✕").on_hover_text("Close Tab").clicked() {
                    close = Some(index);
                }
                ui.separator();
            }
        });
        if let Some(index) = close {
            self.request_close_tab(index);
        }
    }

    fn toolbar(&mut self, ui: &mut Ui) {
        let Some(tab) = self.tabs.get_mut(self.active) else { return };
        ui.horizontal(|ui| {
            if ui.button("☰").on_hover_text("Toggle Sidebar").clicked() {
                tab.reader.is_sidebar_visible = !tab.reader.is_sidebar_visible;
                self.preferences.sidebar_visible = tab.reader.is_sidebar_visible;
            }
            ui.separator();
            let valid = tab.valid_page_ids();
            if ui.add_enabled(tab.history.can_go_back(&valid), egui::Button::new("◀")).on_hover_text("Back").clicked() {
                tab.go_back();
            }
            if ui.add_enabled(tab.history.can_go_forward(&valid), egui::Button::new("▶")).on_hover_text("Forward").clicked() {
                tab.go_forward();
            }
            ui.separator();
            let response = ui.add(egui::TextEdit::singleline(&mut tab.go_to_page_text).desired_width(44.0).horizontal_align(Align::Center));
            if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter)) {
                match tab.go_to_page_text.trim().parse::<usize>() {
                    Ok(number) if (1..=tab.session.editor.page_count()).contains(&number) => tab.navigate_to(number - 1),
                    _ => tab.go_to_page_text = (tab.reader.selected_page_index() + 1).to_string(),
                }
            }
            ui.label(format!("of {}", tab.session.editor.page_count()));
            let label = tab.page_label(tab.reader.selected_page_index());
            if label != (tab.reader.selected_page_index() + 1).to_string() {
                ui.weak(format!("({label})"));
            }
            ui.separator();
            if ui.button("−").on_hover_text("Zoom Out").clicked() {
                tab.reader.zoom_out();
            }
            ui.label(format!("{:.0}%", tab.reader.effective_scale * 100.0));
            if ui.button("+").on_hover_text("Zoom In").clicked() {
                tab.reader.zoom_in();
            }
            if ui.button("Fit").clicked() {
                tab.reader.zoom_to_fit();
            }
            ui.separator();
            egui::ComboBox::from_id_salt("display-mode")
                .selected_text(tab.reader.display_mode.title())
                .show_ui(ui, |ui| {
                    for mode in DisplayMode::ALL {
                        if ui.selectable_value(&mut tab.reader.display_mode, mode, mode.title()).clicked() {
                            self.preferences.display_mode = mode;
                            tab.scroll_to_page = Some(tab.reader.selected_page_index());
                        }
                    }
                });
            egui::ComboBox::from_id_salt("theme")
                .selected_text(tab.reader.theme.title())
                .show_ui(ui, |ui| {
                    for candidate in ReaderTheme::ALL {
                        if ui.selectable_value(&mut tab.reader.theme, candidate, candidate.title()).clicked() {
                            self.preferences.theme = candidate;
                        }
                    }
                });
            ui.separator();
            let annotating = matches!(tab.tool, Tool::Annotate(_));
            if ui.selectable_label(annotating, "✏ Annotate").on_hover_text("Annotation Tools (⇧⌘A)").clicked() {
                tab.tool = if annotating { Tool::SelectText } else { Tool::Annotate(AnnotationTool::Select) };
                tab.annotations.selected = None;
            }
            let redacting = tab.tool == Tool::Redact;
            if ui.selectable_label(redacting, "▮ Redact").on_hover_text("Permanent Redaction").clicked() {
                tab.tool = if redacting { Tool::SelectText } else { Tool::Redact };
            }
            if ui.selectable_label(tab.forms.visible, "Form").on_hover_text("Fill Form Fields").clicked() {
                tab.forms.visible = !tab.forms.visible;
            }
            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                search_field(ui, tab);
                if tab.session.security.is_encrypted {
                    ui.label(RichText::new("🔒 Protected").color(mocha::YELLOW));
                }
                if tab.session.editor.is_dirty() {
                    ui.label(RichText::new("Edited").color(mocha::PEACH));
                }
            });
        });
    }

    fn empty_state(&mut self, ui: &mut Ui) {
        ui.vertical_centered(|ui| {
            ui.add_space(ui.available_height() * 0.28);
            ui.heading("PDFViewer");
            ui.add_space(6.0);
            ui.label(RichText::new("Open a PDF or drop one here. Originals are never modified.").color(mocha::SUBTEXT0));
            ui.add_space(14.0);
            if ui.button(RichText::new("Open PDF…").size(16.0)).clicked() {
                self.present_open_panel();
            }
            let recents = self.recents.documents().to_vec();
            if !recents.is_empty() {
                ui.add_space(24.0);
                ui.label(RichText::new("Recent").strong());
                for document in recents.into_iter().take(6) {
                    if ui.link(&document.display_name).clicked() {
                        match self.recents.resolve(&document) {
                            Ok(path) => self.open_path(path),
                            Err(error) => self.error(error.to_string()),
                        }
                    }
                }
            }
        });
    }

    fn job_overlay(&mut self, ctx: &egui::Context) {
        let Some(job) = &self.job else { return };
        let (title, cancellable) = match job {
            Job::Opening { path, .. } => (
                format!("Preparing {}…", path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()),
                true,
            ),
            Job::Exporting { .. } => ("Exporting and verifying…".to_owned(), false),
        };
        let mut cancel = false;
        egui::Modal::new(egui::Id::new("job-overlay")).show(ctx, |ui| {
            ui.set_width(320.0);
            ui.horizontal(|ui| {
                ui.spinner();
                ui.label(title);
            });
            if cancellable {
                ui.add_space(8.0);
                ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                    if ui.button("Cancel").clicked() {
                        cancel = true;
                    }
                });
            }
        });
        if cancel {
            // The worker finishes in the background; its result is dropped.
            self.job = None;
        }
        ctx.request_repaint_after(std::time::Duration::from_millis(100));
    }

    fn show_dialogs(&mut self, ctx: &egui::Context) {
        let Some(dialog) = self.dialogs.pop() else { return };
        let mut keep = true;
        let mut follow_up: Option<Box<dyn FnOnce(&mut Self)>> = None;
        let mut dialog = dialog;
        egui::Modal::new(egui::Id::new("dialog")).show(ctx, |ui| {
            ui.set_width(380.0);
            match &mut dialog {
                Dialog::Error(message) => {
                    ui.heading("Something went wrong");
                    ui.add_space(4.0);
                    ui.label(message.as_str());
                    ui.add_space(8.0);
                    if ok_button(ui, "OK") {
                        keep = false;
                    }
                }
                Dialog::Password { locked, input, wrong } => {
                    ui.heading(format!("“{}” is protected", locked.display_name()));
                    ui.label("Enter the document password to open a working copy.");
                    let response = ui.add(egui::TextEdit::singleline(input).password(true).hint_text("Password"));
                    response.request_focus();
                    if *wrong {
                        ui.colored_label(mocha::RED, "That password is incorrect.");
                    }
                    let submit = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            locked.cancel();
                            keep = false;
                        }
                        if ui.button("Open").clicked() || submit {
                            match locked.unlock(input) {
                                Ok(Some(session)) => {
                                    keep = false;
                                    follow_up = Some(Box::new(move |app: &mut Self| app.activate(session)));
                                }
                                Ok(None) => {
                                    *wrong = true;
                                    input.clear();
                                }
                                Err(error) => {
                                    keep = false;
                                    let message = error.to_string();
                                    follow_up = Some(Box::new(move |app: &mut Self| app.error(message)));
                                }
                            }
                        }
                    });
                }
                Dialog::ConfirmDeletePages { tab, pages } => {
                    let noun = if pages.len() == 1 { "page" } else { "pages" };
                    ui.heading(format!("Delete {} {noun}?", pages.len()));
                    ui.label("You can undo this until you close the document.");
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button(RichText::new("Delete").color(mocha::RED)).clicked() {
                            keep = false;
                            let (tab, pages) = (*tab, pages.clone());
                            follow_up = Some(Box::new(move |app: &mut Self| {
                                if let Some(index) = app.tab_index(tab) {
                                    app.active = index;
                                    let first = pages[0];
                                    app.page_operation(|tab| tab.session.editor.delete_pages(&pages).map(|_| Some(first)));
                                }
                            }));
                        }
                    });
                }
                Dialog::UnsavedChanges { tab } => {
                    ui.heading("Export changes before closing?");
                    ui.label("The working copy has changes that haven't been exported. The original PDF is unchanged either way.");
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button("Discard").clicked() {
                            keep = false;
                            let tab = *tab;
                            follow_up = Some(Box::new(move |app: &mut Self| {
                                if let Some(index) = app.tab_index(tab) {
                                    app.close_tab_now(index);
                                }
                            }));
                        }
                        if ui.button("Export…").clicked() {
                            keep = false;
                            let tab = *tab;
                            follow_up = Some(Box::new(move |app: &mut Self| {
                                if let Some(index) = app.tab_index(tab) {
                                    app.active = index;
                                }
                                app.request_export(tab, AfterExport::CloseTab);
                            }));
                        }
                    });
                }
                Dialog::QuitWithUnexportedChanges { count } => {
                    let noun = if *count == 1 { "document has" } else { "documents have" };
                    ui.heading("Quit PDFViewer?");
                    ui.label(format!("{count} {noun} changes that haven't been exported. Originals are unchanged."));
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button(RichText::new("Discard and Quit").color(mocha::RED)).clicked() {
                            keep = false;
                            follow_up = Some(Box::new(|app: &mut Self| {
                                app.allow_quit = true;
                                for tab in &mut app.tabs {
                                    tab.session.close();
                                }
                            }));
                            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                        }
                    });
                }
                Dialog::Export { tab, compression, then } => {
                    ui.heading("Export PDF");
                    ui.label("Writes a new PDF. The original is never replaced.");
                    ui.add_space(6.0);
                    for candidate in Compression::ALL {
                        ui.radio_value(compression, candidate, candidate.title());
                        ui.weak(format!("    {}", candidate.summary()));
                    }
                    if let Some(index) = self.tab_index(*tab)
                        && self.tabs[index].session.security.is_encrypted
                    {
                        ui.add_space(4.0);
                        ui.colored_label(mocha::YELLOW, "The export keeps this PDF's password protection.");
                    }
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button("Choose Location…").clicked() {
                            keep = false;
                            let (tab, compression, then) = (*tab, *compression, *then);
                            follow_up = Some(Box::new(move |app: &mut Self| app.start_export(tab, compression, then)));
                        }
                    });
                }
                Dialog::ExportReceipt(result) => {
                    ui.heading("Export complete");
                    ui.label(format!(
                        "{} · {} page{} · {}",
                        result.path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(),
                        result.page_count,
                        if result.page_count == 1 { "" } else { "s" },
                        human_size(result.file_size)
                    ));
                    ui.weak("The output was reopened and verified.");
                    ui.horizontal(|ui| {
                        if ui.button("Show in Finder").clicked() {
                            let _ = std::process::Command::new("open").arg("-R").arg(&result.path).spawn();
                        }
                        if ok_button(ui, "Done") {
                            keep = false;
                        }
                    });
                }
                Dialog::RenameBookmark { id, input } => {
                    ui.heading("Rename Bookmark");
                    let response = ui.text_edit_singleline(input);
                    let submit = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button("Rename").clicked() || submit {
                            keep = false;
                            let (id, label) = (*id, input.clone());
                            follow_up = Some(Box::new(move |app: &mut Self| app.bookmarks.rename(id, &label)));
                        }
                    });
                }
                Dialog::ConfirmLink(uri) => {
                    ui.heading("Open external link?");
                    ui.label("This PDF wants to open:");
                    ui.add(egui::Label::new(RichText::new(uri.as_str()).monospace()).wrap());
                    ui.weak("Links in documents can lead anywhere. Only continue if you trust this PDF.");
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button("Open Link").clicked() {
                            keep = false;
                            let _ = std::process::Command::new("open").arg(uri.as_str()).spawn();
                        }
                    });
                }
                Dialog::ConfirmRedaction { tab } => {
                    let summary = self.tab_index(*tab).map(|index| {
                        let regions = &self.tabs[index].redaction.regions;
                        let pages: std::collections::BTreeSet<usize> = regions.iter().map(|r| r.page).collect();
                        (regions.len(), pages.len())
                    });
                    let Some((areas, pages)) = summary else {
                        keep = false;
                        return;
                    };
                    ui.heading("Apply permanent redaction?");
                    ui.label(format!(
                        "{areas} area{} on {pages} page{} will be burned in. Those pages become images: their text, links and annotations are removed, and the document's metadata and outline are cleared.",
                        if areas == 1 { "" } else { "s" },
                        if pages == 1 { "" } else { "s" },
                    ));
                    ui.weak("You can undo until you close the document. Export afterwards to share the redacted copy.");
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.button(RichText::new("Redact Permanently").color(mocha::RED)).clicked() {
                            keep = false;
                            let tab = *tab;
                            follow_up = Some(Box::new(move |app: &mut Self| {
                                let Some(index) = app.tab_index(tab) else { return };
                                if let Err(message) = redaction_ui::apply(&mut app.tabs[index]) {
                                    app.error(message);
                                }
                            }));
                        }
                    });
                }
                Dialog::Info(message) => {
                    ui.label(message.as_str());
                    ui.add_space(6.0);
                    if ok_button(ui, "OK") {
                        keep = false;
                    }
                }
                Dialog::Note { tab, page, target, text } => {
                    ui.heading(match target {
                        NoteTarget::New(_) => "New Text Note",
                        NoteTarget::Existing(_) => "Edit Text Note",
                    });
                    let response = ui.add(egui::TextEdit::multiline(text).desired_rows(5).desired_width(f32::INFINITY).char_limit(10_000));
                    if ui.memory(|memory| memory.focused().is_none()) {
                        response.request_focus();
                    }
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.add_enabled(!text.trim().is_empty(), egui::Button::new("Save")).clicked() {
                            keep = false;
                            let (tab, page, contents) = (*tab, *page, text.clone());
                            let target = match target {
                                NoteTarget::New(point) => NoteTarget::New(*point),
                                NoteTarget::Existing(id) => NoteTarget::Existing(*id),
                            };
                            follow_up = Some(Box::new(move |app: &mut Self| {
                                let Some(index) = app.tab_index(tab) else { return };
                                let tab = &mut app.tabs[index];
                                let color = tab.annotations.color;
                                let result = tab.annotate(|document| match target {
                                    NoteTarget::New(point) => pdf_core::annotations::add_text_note(document, page, point, &contents, color).map(|_| ()),
                                    NoteTarget::Existing(id) => pdf_core::annotations::set_note_contents(document, page, id, &contents),
                                });
                                if let Err(message) = result {
                                    app.error(message);
                                }
                            }));
                        }
                    });
                }
                Dialog::Library { dialog, place } => {
                    ui.set_width(480.0);
                    let library = match dialog.kind {
                        LibraryKind::Signatures => &mut self.signatures,
                        LibraryKind::Stamps => &mut self.stamps,
                    };
                    match dialog.show(ui, library, &mut self.library_thumbnails) {
                        LibraryOutcome::Open => {}
                        LibraryOutcome::Close => keep = false,
                        LibraryOutcome::Error(message) => {
                            follow_up = Some(Box::new(move |app: &mut Self| app.error(message)));
                        }
                        LibraryOutcome::Chose(id) => {
                            keep = false;
                            let (kind, place) = (dialog.kind, *place);
                            follow_up = Some(Box::new(move |app: &mut Self| app.use_library_item(kind, id, place)));
                        }
                    }
                }
                Dialog::PageLabels { tab } => {
                    ui.heading("Page Labels");
                    let Some(index) = self.tab_index(*tab) else {
                        keep = false;
                        return;
                    };
                    let reader = &mut self.tabs[index].reader;
                    egui::ComboBox::from_label("Style")
                        .selected_text(reader.page_label_style.title())
                        .show_ui(ui, |ui| {
                            for style in PageLabelStyle::ALL {
                                ui.selectable_value(&mut reader.page_label_style, style, style.title());
                            }
                        });
                    ui.add_enabled_ui(reader.page_label_style != PageLabelStyle::Document, |ui| {
                        ui.horizontal(|ui| {
                            ui.label("Start at");
                            ui.add(egui::DragValue::new(&mut reader.page_label_start).range(1..=100_000));
                        });
                        ui.horizontal(|ui| {
                            ui.label("Prefix");
                            ui.add(egui::TextEdit::singleline(&mut reader.page_label_prefix).char_limit(20).desired_width(120.0));
                        });
                    });
                    if ok_button(ui, "Done") {
                        keep = false;
                    }
                }
            }
        });
        if keep {
            self.dialogs.push(dialog);
        }
        if let Some(follow_up) = follow_up {
            follow_up(self);
        }
    }
}

impl eframe::App for PdfViewerApp {
    fn ui(&mut self, ui: &mut Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.renderer.begin_frame(&ctx);
        self.poll_job();
        self.handle_dropped_files(&ctx);
        self.handle_close_request(&ctx);
        if self.dialogs.is_empty() && self.job.is_none() {
            self.handle_shortcuts(&ctx);
        }
        let live: HashSet<_> = self.tabs.iter().map(DocumentTab::document_key).collect();
        self.renderer.retain_documents(live);

        let mut annotation_request = AnnotationRequest::None;
        let mut redaction_request = RedactionRequest::None;
        egui::Panel::top("menu").show(ui, |ui| {
            self.menu_bar(ui);
            if !self.tabs.is_empty() {
                if self.tabs.len() > 1 {
                    self.tab_strip(ui);
                }
                self.toolbar(ui);
                let (signatures, stamps) = (self.signatures.signatures().to_vec(), self.stamps.signatures().to_vec());
                if let Some(tab) = self.tabs.get_mut(self.active)
                    && matches!(tab.tool, Tool::Annotate(_))
                {
                    ui.separator();
                    annotation_request = annotation_ui::toolbar(ui, tab, &signatures, &stamps);
                }
                if let Some(tab) = self.tabs.get_mut(self.active)
                    && tab.tool == Tool::Redact
                {
                    ui.separator();
                    redaction_request = redaction_ui::toolbar(ui, tab);
                }
            }
        });
        self.handle_annotation_request(annotation_request);
        match redaction_request {
            RedactionRequest::None => {}
            RedactionRequest::Error(message) => self.error(message),
            RedactionRequest::ConfirmApply => {
                let tab = self.tabs[self.active].id;
                self.dialogs.push(Dialog::ConfirmRedaction { tab });
            }
        }

        let mut form_request = FormRequest::None;
        if let Some(tab) = self.tabs.get_mut(self.active)
            && tab.forms.visible
        {
            egui::Panel::right("forms")
                .resizable(true)
                .default_size(280.0)
                .size_range(220.0..=440.0)
                .show(ui, |ui| {
                    form_request = forms_ui::panel(ui, tab);
                });
        }
        self.handle_form_request(form_request);

        let mut sidebar_action = sidebar::SidebarAction::None;
        if let Some(tab) = self.tabs.get_mut(self.active)
            && tab.reader.is_sidebar_visible
        {
            egui::Panel::left("sidebar")
                .resizable(true)
                .default_size(200.0)
                .size_range(150.0..=360.0)
                .show(ui, |ui| {
                    sidebar_action = sidebar::show(ui, tab, &mut self.renderer, &mut self.bookmarks);
                });
        }
        if let sidebar::SidebarAction::RenameBookmark(id) = sidebar_action {
            let input = self.bookmarks.all().iter().find(|b| b.id == id).map(|b| b.label.clone()).unwrap_or_default();
            self.dialogs.push(Dialog::RenameBookmark { id, input });
        }

        let mut deferred_request = AnnotationRequest::None;
        egui::CentralPanel::no_frame().show(ui, |ui| {
            if let Some(tab) = self.tabs.get_mut(self.active) {
                tab.poll_search();
                let response = reader_view::show(ui, tab, &mut self.renderer);
                let painter = ui.painter_at(response.canvas);
                interaction::paint_text_overlays(&painter, &ctx, tab, &response);
                let request = annotation_ui::handle(&ctx, tab, &response);
                annotation_ui::paint_overlays(&painter, tab, &response);
                redaction_ui::handle(&ctx, tab, &response);
                redaction_ui::paint(&painter, tab, &response);
                if let Some(click) = response.click
                    && tab.tool == Tool::SelectText
                    && let Some(field) = tab.form_fields().into_iter().find(|f| f.page == click.page && f.rect.contains(click.point))
                {
                    tab.forms.visible = true;
                    tab.forms.focus = Some(field.name);
                }
                deferred_request = request;
                match interaction::handle_select_text(&ctx, tab, &response) {
                    interaction::InteractionAction::None => {}
                    interaction::InteractionAction::ConfirmExternalLink(uri) => self.dialogs.push(Dialog::ConfirmLink(uri)),
                    interaction::InteractionAction::RejectedLink => {
                        self.dialogs.push(Dialog::Error("PDFViewer only opens web and email links from documents.".into()))
                    }
                }
            } else {
                ui.painter().rect_filled(ui.max_rect(), 0.0, mocha::BASE);
                self.empty_state(ui);
            }
        });

        self.handle_annotation_request(deferred_request);

        if ctx.input(|input| !input.raw.hovered_files.is_empty()) {
            let screen = ctx.content_rect();
            let painter = ctx.layer_painter(egui::LayerId::new(egui::Order::Foreground, egui::Id::new("drop")));
            painter.rect_filled(screen, 0.0, Color32::from_black_alpha(140));
            painter.text(screen.center(), Align2::CENTER_CENTER, "Drop PDFs to open", egui::FontId::proportional(22.0), mocha::TEXT);
        }

        self.job_overlay(&ctx);
        if self.job.is_none() {
            self.show_dialogs(&ctx);
        }
        if let Some(tab) = self.tabs.get(self.active) {
            let dirty = if tab.has_unexported_changes() { " — Edited" } else { "" };
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(format!("{}{dirty}", tab.title())));
        } else {
            ctx.send_viewport_cmd(egui::ViewportCommand::Title("PDFViewer".into()));
        }
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if let Some(capture) = &mut self.capture {
            if let Some(tab) = self.tabs.first_mut() {
                if std::mem::take(&mut capture.rotate) {
                    let _ = tab.session.editor.rotate_pages(&[0], true);
                    tab.after_mutation(Some(0));
                }
                if std::mem::take(&mut capture.redact) {
                    tab.redaction.reason_label = "Privileged".into();
                    tab.redaction.regions.push(pdf_core::redaction::RedactionRegion {
                        page: 0,
                        rect: pdf_core::geometry::PdfBox::new(60.0, 690.0, 560.0, 740.0),
                    });
                    let _ = crate::redaction_ui::apply(tab);
                }
                if std::mem::take(&mut capture.forms) {
                    tab.forms.visible = true;
                }
                if std::mem::take(&mut capture.annotate) {
                    use pdf_core::annotations::*;
                    use pdf_core::geometry::PdfBox;
                    let _ = tab.annotate(|d| {
                        add_text_markup(d, MarkupKind::Highlight, &[(0, vec![PdfBox::new(90.0, 700.0, 330.0, 722.0)])], palette::YELLOW)?;
                        add_ink(d, 0, &[(80.0, 300.0), (120.0, 340.0), (160.0, 290.0), (200.0, 350.0)], palette::BLUE, LineWidth::Bold)?;
                        add_shape(d, ShapeKind::Rectangle, 0, (250.0, 280.0), (360.0, 360.0), palette::RED, LineWidth::Standard)?;
                        add_shape(d, ShapeKind::Oval, 0, (380.0, 280.0), (480.0, 360.0), palette::GREEN, LineWidth::Standard)?;
                        add_shape(d, ShapeKind::Arrow, 0, (100.0, 200.0), (250.0, 240.0), palette::PINK, LineWidth::Bold)?;
                        add_text_note(d, 0, (520.0, 330.0), "Note", palette::YELLOW)?;
                        add_stamp(d, 0, (420.0, 200.0), StampPreset::Approved)?;
                        Ok(())
                    });
                    tab.tool = crate::document_tab::Tool::Annotate(crate::annotation_ui::AnnotationTool::Select);
                    tab.refresh_annotation_index();
                    if let Some(info) = tab.annotations.index.first().and_then(|page| page.get(2)).cloned() {
                        tab.annotations.selected = Some(crate::annotation_ui::Selected { page: 0, info });
                    }
                }
                if let Some(query) = capture.search.take() {
                    tab.search.query = query;
                    tab.start_search(ctx);
                    tab.reader.sidebar_tab = crate::reader_state::SidebarTab::Search;
                }
            }
            capture.tick(ctx);
        }
    }

    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        eframe::set_value(storage, PREFERENCES_KEY, &self.preferences);
    }

    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        mocha::CRUST.to_normalized_gamma_f32()
    }
}

fn search_field(ui: &mut Ui, tab: &mut DocumentTab) {
    let count = tab.search.matches().len();
    if count > 0 {
        if ui.small_button("↓").on_hover_text("Next Match (⌘G)").clicked() {
            tab.step_search(true);
        }
        if ui.small_button("↑").on_hover_text("Previous Match (⇧⌘G)").clicked() {
            tab.step_search(false);
        }
        ui.label(format!("{}/{count}", tab.search.active.map_or(0, |i| i + 1)));
    } else if tab.search.is_running() {
        ui.spinner();
    }
    let whole = ui.selectable_label(tab.search.options.whole_words, "W").on_hover_text("Whole Words");
    if whole.clicked() {
        tab.search.options.whole_words = !tab.search.options.whole_words;
    }
    let case = ui.selectable_label(tab.search.options.case_sensitive, "Aa").on_hover_text("Match Case");
    if case.clicked() {
        tab.search.options.case_sensitive = !tab.search.options.case_sensitive;
    }
    let response = ui.add(
        egui::TextEdit::singleline(&mut tab.search.query)
            .hint_text("Search")
            .desired_width(180.0),
    );
    if std::mem::take(&mut tab.search.focus_requested) {
        response.request_focus();
    }
    let submitted = response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter));
    if submitted || case.clicked() || whole.clicked() {
        if tab.search.query.trim().is_empty() {
            tab.search.clear();
        } else if tab.search.is_stale() || tab.search.outcome.is_none() {
            let ctx = ui.ctx().clone();
            tab.start_search(&ctx);
            tab.reader.is_sidebar_visible = true;
            tab.reader.sidebar_tab = crate::reader_state::SidebarTab::Search;
        } else {
            let backwards = ui.input(|input| input.modifiers.shift);
            tab.step_search(!backwards);
        }
        if submitted {
            response.request_focus();
        }
    }
    if response.changed() && tab.search.query.is_empty() {
        tab.search.clear();
    }
}

fn ok_button(ui: &mut Ui, title: &str) -> bool {
    ui.button(title).clicked() || ui.input(|input| input.key_pressed(Key::Enter))
}

fn protection_for(session: &DocumentSession) -> Result<Protection, String> {
    if !session.security.is_encrypted {
        return Ok(Protection::None);
    }
    let password = session
        .session_password()
        .ok_or_else(|| export::ExportError::MissingSessionPassword.to_string())?;
    Ok(Protection::ReuseSessionPassword {
        password: password.to_owned(),
        permissions: session.security.permissions,
    })
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => a == b,
    }
}

fn human_size(bytes: u64) -> String {
    match bytes {
        0..=1023 => format!("{bytes} bytes"),
        1024..=1_048_575 => format!("{:.1} KB", bytes as f64 / 1024.0),
        _ => format!("{:.1} MB", bytes as f64 / 1_048_576.0),
    }
}

fn bookmark_coder() -> Box<dyn BookmarkCoder> {
    #[cfg(target_os = "macos")]
    {
        Box::new(crate::macos::SecurityScopedBookmarkCoder)
    }
    #[cfg(not(target_os = "macos"))]
    {
        Box::new(PathBookmarkCoder)
    }
}
