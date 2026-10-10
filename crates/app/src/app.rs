//! Application shell: tabs, menus, shortcuts, dialogs and background jobs.

use std::collections::{BTreeSet, HashSet};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, TryRecvError, channel};

use egui::{Align, Align2, Color32, Key, Layout, Modifiers, RichText, Ui};
use pdf_core::export::{self, Compression, ExportResult, Protection};
use pdf_core::loader::{self, LockedDocument, OpenResult};
use pdf_core::navigation::PageBookmarkStore;
use pdf_core::persistence::support_directory;
use pdf_core::recents::{BookmarkCoder, RecentDocumentsStore};
use pdf_core::{CoreError, DocumentSession};
use serde::{Deserialize, Serialize};

use crate::annotation_ui::{self, AnnotationRequest, AnnotationTool, StampChoice};
use crate::commands::Command;
use crate::conversion_ui::{ConversionOutcome, ConversionSheet};
use crate::document_tab::DocumentTab;
use crate::document_tab::Tool;
use crate::forms_ui::{self, FormRequest};
use crate::libraries_ui::{LibraryDialog, LibraryKind, LibraryOutcome};
use crate::ocr_ui::{OcrSheet, SheetOutcome};
use crate::reader_state::{DisplayMode, PageLabelStyle, ReaderTheme};
use crate::redaction_ui::{self, RedactionRequest};
use crate::render::RenderService;
use crate::theme;
use crate::{interaction, reader_view, sidebar};

#[path = "app_commands.rs"]
mod dispatch;

const PREFERENCES_KEY: &str = "pdfviewer.preferences.v1";

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Preferences {
    theme: ReaderTheme,
    display_mode: DisplayMode,
    sidebar_visible: bool,
    compression: Compression,
    /// The user-chosen LibreOffice `soffice` for Office conversion.
    #[serde(default)]
    soffice: Option<PathBuf>,
}

impl Default for Preferences {
    fn default() -> Self {
        Self {
            theme: ReaderTheme::Night,
            display_mode: DisplayMode::Continuous,
            sidebar_visible: true,
            compression: Compression::Standard,
            soffice: None,
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
    Task {
        title: String,
        receiver: Receiver<Completion>,
    },
    Processing {
        receiver: Receiver<ProcessingMessage>,
        cancel: Arc<AtomicBool>,
        progress: Option<pdf_ocr::OcrProgress>,
        tab: u64,
        /// The editor generation processing started from.
        generation: u64,
    },
}

/// Work finished on a background thread, applied on the main thread.
type Completion = Box<dyn FnOnce(&mut PdfViewerApp) + Send>;

enum ProcessingMessage {
    Progress(pdf_ocr::OcrProgress),
    Finished(Result<pdf_ocr::OcrResult, pdf_ocr::OcrError>),
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
    Ocr(Box<OcrSheet>),
    Conversion(Box<ConversionSheet>),
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

struct SplitView {
    tab: u64,
    reader: crate::reader_state::ReaderState,
    offset: egui::Vec2,
    scroll_to_page: Option<usize>,
    anchor: Option<usize>,
}

pub struct PdfViewerApp {
    tabs: Vec<DocumentTab>,
    active: usize,
    selection_tab: Option<u64>,
    next_tab_id: u64,
    renderer: RenderService,
    recents: RecentDocumentsStore,
    bookmarks: PageBookmarkStore,
    preferences: Preferences,
    job: Option<Job>,
    dialogs: Vec<Dialog>,
    allow_quit: bool,
    discard_recovery: bool,
    /// Files waiting for the current open to finish.
    pending_opens: std::collections::VecDeque<PathBuf>,
    /// Menu commands received since the last frame.
    pending_commands: Vec<Command>,
    /// The native macOS menu bar replaced the in-window one.
    native_menu: bool,
    capture: Option<crate::debug_capture::DebugCapture>,
    signatures: pdf_core::signatures::SignatureLibrary,
    stamps: pdf_core::signatures::SignatureLibrary,
    session_store: crate::session::SessionStore,
    restore_tabs: Vec<crate::session::SavedTab>,
    restore_active: Option<PathBuf>,
    last_checkpoint: std::time::Instant,
    checkpoint_signature: std::cell::RefCell<Option<String>>,
    palette: Option<crate::palette::Palette>,
    split: Option<SplitView>,
    library_thumbnails: std::collections::HashMap<uuid::Uuid, Option<egui::TextureHandle>>,
}

impl PdfViewerApp {
    pub fn new(cc: &eframe::CreationContext<'_>, initial_paths: Vec<PathBuf>) -> Self {
        crate::fonts::install(&cc.egui_ctx);
        let preferences = cc
            .storage
            .and_then(|storage| eframe::get_value(storage, PREFERENCES_KEY))
            .unwrap_or_default();
        let support = support_directory();
        let session_store = crate::session::SessionStore::new(support.join("Recovery"));
        let saved = if crate::debug_capture::DebugCapture::from_env().is_none() {
            session_store.load()
        } else {
            Default::default()
        };
        let mut paths: std::collections::VecDeque<PathBuf> = saved
            .tabs
            .iter()
            .map(|tab| session_store.opening_path(tab))
            .collect();
        for path in initial_paths {
            if !paths.contains(&path) {
                paths.push_back(path);
            }
        }
        let mut app = Self {
            tabs: Vec::new(),
            active: 0,
            selection_tab: None,
            next_tab_id: 1,
            renderer: RenderService::new(cc.egui_ctx.clone()),
            recents: RecentDocumentsStore::new(
                support.join("recent-documents.v1.json"),
                bookmark_coder(),
                10,
            ),
            bookmarks: PageBookmarkStore::new(support.join("page-bookmarks.v1.json")),
            preferences,
            job: None,
            dialogs: Vec::new(),
            allow_quit: false,
            discard_recovery: false,
            pending_opens: paths,
            pending_commands: Vec::new(),
            native_menu: false,
            capture: crate::debug_capture::DebugCapture::from_env(),
            signatures: pdf_core::signatures::SignatureLibrary::new(
                support.join("Signatures"),
                "Visual Signature",
            ),
            stamps: pdf_core::signatures::SignatureLibrary::new(
                support.join("Stamps"),
                "Custom Stamp",
            ),
            session_store,
            restore_tabs: saved.tabs,
            restore_active: saved.active,
            last_checkpoint: std::time::Instant::now(),
            checkpoint_signature: std::cell::RefCell::new(None),
            palette: None,
            split: None,
            library_thumbnails: Default::default(),
        };
        if let Some(error) = pdf_core::engine::pdfium().err() {
            app.dialogs.push(Dialog::Error(error.to_string()));
        }
        #[cfg(target_os = "macos")]
        {
            crate::native::attach(&cc.egui_ctx);
            app.native_menu = crate::native::install_menu();
        }
        app
    }

    fn toggle_split(&mut self) {
        if self.split.take().is_none()
            && let Some(tab) = self.tabs.get(self.active)
        {
            self.split = Some(SplitView {
                tab: tab.id,
                reader: tab.reader.clone(),
                offset: tab.scroll_offset,
                scroll_to_page: Some(tab.reader.selected_page_index()),
                anchor: None,
            });
        }
    }

    fn show_reference(&mut self, ui: &mut Ui, ctx: &egui::Context) {
        let Some(mut split) = self.split.take() else {
            return;
        };
        let mut close = false;
        ui.horizontal(|ui| {
            ui.label("Reference");
            egui::ComboBox::from_id_salt("reference-document")
                .width((ui.available_width() - 38.0).max(60.0))
                .truncate()
                .selected_text(
                    self.tabs
                        .iter()
                        .find(|tab| tab.id == split.tab)
                        .map(DocumentTab::title)
                        .unwrap_or_default(),
                )
                .show_ui(ui, |ui| {
                    for tab in &self.tabs {
                        if ui
                            .selectable_value(&mut split.tab, tab.id, tab.title())
                            .changed()
                        {
                            split.reader = tab.reader.clone();
                            split.offset = egui::Vec2::ZERO;
                            split.scroll_to_page = Some(tab.reader.selected_page_index());
                        }
                    }
                });
            if ui
                .small_button("×")
                .on_hover_text("Close split view")
                .clicked()
            {
                close = true;
            }
        });
        let Some(index) = self.tab_index(split.tab) else {
            return;
        };
        let tab = &mut self.tabs[index];
        split
            .reader
            .synchronize(tab.session.editor.page_count(), None);
        let mut primary_reader = std::mem::replace(&mut tab.reader, split.reader);
        let primary_anchor = std::mem::replace(&mut tab.navigation_anchor, split.anchor);
        let primary_offset = std::mem::replace(&mut tab.scroll_offset, split.offset);
        let primary_target = std::mem::replace(&mut tab.scroll_to_page, split.scroll_to_page);
        let primary_point = tab.scroll_to_point.take();
        let primary_go_text = std::mem::take(&mut tab.go_to_page_text);
        let primary_tool = std::mem::replace(&mut tab.tool, Tool::SelectText);
        ui.horizontal_wrapped(|ui| {
            if ui.small_button("‹").clicked() {
                tab.show_page(tab.reader.selected_page_index().saturating_sub(1));
            }
            let mut page = tab.reader.selected_page_index() + 1;
            if ui
                .add(egui::DragValue::new(&mut page).range(1..=tab.pages.len().max(1)))
                .changed()
            {
                tab.show_page(page - 1);
            }
            ui.weak(format!("of {}", tab.pages.len()));
            if ui.small_button("›").clicked() {
                tab.show_page((page).min(tab.pages.len().saturating_sub(1)));
            }
            if ui.small_button("−").clicked() {
                tab.reader.zoom_out();
            }
            if ui.small_button("+").clicked() {
                tab.reader.zoom_in();
            }
            if ui.small_button("Fit").clicked() {
                tab.reader.zoom_to_fit();
            }
            if ui.small_button("Copy selection").clicked()
                && tab.session.security.allows_content_copying()
                && let Some(text) = tab.selected_text()
            {
                ctx.copy_text(text);
            }
        });
        let response = reader_view::show_pane(ui, tab, &mut self.renderer, 1);
        let action = interaction::handle_select_text(ctx, tab, &response);
        if response.drag_start.is_some()
            || response.double_click.is_some()
            || response.triple_click.is_some()
        {
            self.selection_tab = Some(tab.id);
        }
        interaction::paint_text_overlays(&ui.painter_at(response.canvas), ctx, tab, &response);
        std::mem::swap(&mut primary_reader, &mut tab.reader);
        split.reader = primary_reader;
        split.anchor = std::mem::replace(&mut tab.navigation_anchor, primary_anchor);
        split.offset = std::mem::replace(&mut tab.scroll_offset, primary_offset);
        split.scroll_to_page = std::mem::replace(&mut tab.scroll_to_page, primary_target);
        tab.scroll_to_point = primary_point;
        tab.go_to_page_text = primary_go_text;
        tab.tool = primary_tool;
        if let interaction::InteractionAction::ConfirmExternalLink(uri) = action {
            self.dialogs.push(Dialog::ConfirmLink(uri));
        }
        if !close {
            self.split = Some(split);
        }
    }

    fn checkpoint_session(&self) {
        if self.capture.is_some() {
            return;
        }
        let mut saved = crate::session::SavedSession {
            tabs: Vec::new(),
            active: self
                .tabs
                .get(self.active)
                .map(|tab| tab.session.source_path.clone()),
        };
        let mut documents = Vec::new();
        for tab in &self.tabs {
            // A failed restore keeps its existing snapshot rather than replacing it.
            if let Some(retained) = self
                .restore_tabs
                .iter()
                .find(|saved| same_file(&saved.source, &tab.session.source_path))
            {
                saved.tabs.push(retained.clone());
                documents.push(None);
                continue;
            }
            saved.tabs.push(crate::session::SavedTab {
                source: tab.session.source_path.clone(),
                fingerprint: tab.session.fingerprint.clone(),
                security: tab.session.security,
                reader: tab.reader.clone(),
                snapshot: None,
                unexported: tab.has_unexported_changes(),
                page_ids: tab.session.editor.page_ids().to_vec(),
            });
            let document = if (tab.session.editor.is_dirty() || tab.has_unexported_changes())
                && !self.discard_recovery
            {
                if tab.session.security.is_encrypted && tab.session.session_password().is_none() {
                    return;
                }
                Some(crate::session::RecoveryPdf {
                    bytes: tab.pdf_data(),
                    password: tab.session.session_password().map(str::to_owned),
                    permissions: tab.session.security.permissions,
                })
            } else {
                None
            };
            documents.push(document);
        }
        for retained in &self.restore_tabs {
            if !saved
                .tabs
                .iter()
                .any(|saved| same_file(&saved.source, &retained.source))
            {
                saved.tabs.push(retained.clone());
                documents.push(None);
            }
        }
        let generations: Vec<_> = self
            .tabs
            .iter()
            .map(|tab| (tab.id, tab.generation(), tab.has_unexported_changes()))
            .collect();
        let signature = format!(
            "{}:{generations:?}:{}",
            serde_json::to_string(&saved).unwrap_or_default(),
            self.discard_recovery
        );
        if self.checkpoint_signature.borrow().as_ref() == Some(&signature) {
            return;
        }
        self.checkpoint_signature.replace(Some(signature));
        self.session_store.request(crate::session::Checkpoint {
            session: saved,
            documents,
        });
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
        if let Some(paths) = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf", "PDF"])
            .pick_files()
        {
            for path in paths {
                self.open_path(path);
            }
        }
    }

    pub fn open_path(&mut self, path: PathBuf) {
        if let Some(index) = self
            .tabs
            .iter()
            .position(|tab| same_file(&tab.session.source_path, &path))
        {
            self.active = index;
            return;
        }
        if self.job.is_some() {
            if !self.pending_opens.contains(&path) {
                self.pending_opens.push_back(path);
            }
            return;
        }
        let (sender, receiver) = channel();
        let worker_path = path.clone();
        std::thread::spawn(move || {
            let _ = sender.send(loader::open(&worker_path));
        });
        self.job = Some(Job::Opening { path, receiver });
    }

    fn activate(&mut self, mut session: DocumentSession) {
        let restored = self.restore_tabs.iter().position(|saved| {
            same_file(&saved.source, &session.source_path)
                || self
                    .session_store
                    .snapshot_path(saved)
                    .is_some_and(|path| same_file(&path, &session.source_path))
        });
        let mut reader = None;
        if let Some(index) = restored {
            let saved = self.restore_tabs[index].clone();
            if !same_file(&saved.source, &session.source_path) {
                match session
                    .editor
                    .recovered_without_source(saved.page_ids.clone())
                {
                    Ok(()) => {
                        session.source_path = saved.source.clone();
                        session.fingerprint = saved.fingerprint.clone();
                        session.security = saved.security;
                        if !saved.unexported {
                            session.editor.mark_current_revision_exported();
                        }
                        self.restore_tabs.remove(index);
                    }
                    Err(error) => self.error(error.to_string()),
                }
            } else if saved.snapshot.is_some() {
                match self.session_store.recover(&mut session, &saved) {
                    Ok(()) => {
                        self.restore_tabs.remove(index);
                    }
                    Err(error) => self.error(format!(
                        "{} Recovery files: {}",
                        error,
                        support_directory().join("Recovery").display()
                    )),
                }
            } else {
                self.restore_tabs.remove(index);
            }
            reader = Some(crate::session::normalized_reader(
                saved.reader,
                session.editor.page_count(),
            ));
        }
        let _ = self.recents.record(&session.source_path);
        let id = self.next_tab_id;
        self.next_tab_id += 1;
        let mut tab = DocumentTab::new(id, session);
        tab.reader.theme = self.preferences.theme;
        tab.reader.display_mode = self.preferences.display_mode;
        tab.reader.is_sidebar_visible = self.preferences.sidebar_visible;
        if let Some(reader) = reader {
            tab.reader = reader;
            tab.scroll_to_page = Some(tab.reader.selected_page_index());
        }
        self.tabs.push(tab);
        self.active = self.tabs.len() - 1;
        if self.pending_opens.is_empty()
            && let Some(path) = self.restore_active.take()
            && let Some(index) = self
                .tabs
                .iter()
                .position(|tab| same_file(&tab.session.source_path, &path))
        {
            self.active = index;
        }
    }

    fn poll_job(&mut self) {
        let Some(job) = self.job.take() else { return };
        match job {
            Job::Opening { path, receiver } => match receiver.try_recv() {
                Err(TryRecvError::Empty) => self.job = Some(Job::Opening { path, receiver }),
                Err(TryRecvError::Disconnected) => self.error(CoreError::InvalidPdf.to_string()),
                Ok(Ok(OpenResult::Opened(session))) => self.activate(session),
                Ok(Ok(OpenResult::PasswordRequired(locked))) => {
                    self.dialogs.push(Dialog::Password {
                        locked,
                        input: String::new(),
                        wrong: false,
                    })
                }
                Ok(Err(error)) => self.error(error.to_string()),
            },
            Job::Exporting {
                receiver,
                tab,
                then,
            } => match receiver.try_recv() {
                Err(TryRecvError::Empty) => {
                    self.job = Some(Job::Exporting {
                        receiver,
                        tab,
                        then,
                    })
                }
                Err(TryRecvError::Disconnected) => self.error("The export stopped unexpectedly."),
                Ok(Err(message)) => self.error(message),
                Ok(Ok(result)) => self.finish_export(result, tab, then),
            },
            Job::Task { title, receiver } => match receiver.try_recv() {
                Err(TryRecvError::Empty) => self.job = Some(Job::Task { title, receiver }),
                Err(TryRecvError::Disconnected) => {
                    self.error(format!("{title} stopped unexpectedly."))
                }
                Ok(completion) => completion(self),
            },
            Job::Processing {
                receiver,
                cancel,
                mut progress,
                tab,
                generation,
            } => loop {
                match receiver.try_recv() {
                    Ok(ProcessingMessage::Progress(update)) => progress = Some(update),
                    Err(TryRecvError::Empty) => {
                        self.job = Some(Job::Processing {
                            receiver,
                            cancel,
                            progress,
                            tab,
                            generation,
                        });
                        break;
                    }
                    Err(TryRecvError::Disconnected) => {
                        break self.error("Local processing stopped unexpectedly.");
                    }
                    Ok(ProcessingMessage::Finished(Err(pdf_ocr::OcrError::Cancelled))) => break,
                    Ok(ProcessingMessage::Finished(Err(error))) => {
                        break self.error(error.to_string());
                    }
                    Ok(ProcessingMessage::Finished(Ok(result))) => {
                        break self.finish_processing(result, tab, generation);
                    }
                }
            },
        }
    }

    // MARK: Conversion

    /// Runs `work` on a background thread behind the job overlay.
    fn run_task(&mut self, title: &str, work: impl FnOnce() -> Completion + Send + 'static) {
        if self.job.is_some() {
            return self.error("Another operation is still running. Try again when it finishes.");
        }
        let (sender, receiver) = channel();
        std::thread::spawn(move || {
            let _ = sender.send(work());
        });
        self.job = Some(Job::Task {
            title: title.to_owned(),
            receiver,
        });
    }

    fn request_conversion(&mut self) {
        let tab = self.tabs.get(self.active).map(|tab| tab.id);
        self.dialogs
            .push(Dialog::Conversion(Box::new(ConversionSheet::new(tab))));
    }

    fn handle_conversion(&mut self, tab_id: Option<u64>, outcome: ConversionOutcome) {
        let tab = tab_id
            .and_then(|id| self.tab_index(id))
            .map(|index| &self.tabs[index]);
        let stem = tab.map(|tab| {
            tab.session
                .source_path
                .file_stem()
                .map(|s| s.to_string_lossy().into_owned())
                .unwrap_or_default()
        });
        let directory = tab.and_then(|tab| tab.session.source_path.parent().map(Path::to_path_buf));
        match outcome {
            ConversionOutcome::Open | ConversionOutcome::Cancel => {}
            ConversionOutcome::ExportImages { pages, format, dpi } => {
                let Some(tab) = tab else { return };
                let mut dialog = rfd::FileDialog::new()
                    .set_title(format!("Export PDF Pages as {} Images", format.title()));
                if let Some(directory) = &directory {
                    dialog = dialog.set_directory(directory);
                }
                let Some(destination) = dialog.pick_folder() else {
                    return;
                };
                let (data, stem) = (tab.pdf_data(), stem.unwrap_or_default());
                self.run_task("Exporting images", move || {
                    let result =
                        pdf_core::conversion::image_files(&data, &pages, format, dpi, &stem)
                            .and_then(|files| {
                                pdf_core::conversion::write_image_files(&files, &destination)
                            });
                    Box::new(move |app: &mut Self| match result {
                        Ok(paths) => app.dialogs.push(Dialog::Info(format!(
                            "Exported {} image{} to {}. Existing files were not overwritten.",
                            paths.len(),
                            if paths.len() == 1 { "" } else { "s" },
                            destination.display()
                        ))),
                        Err(error) => app.error(error.to_string()),
                    })
                });
            }
            ConversionOutcome::ExportText { pages } => {
                let Some(tab) = tab else { return };
                let mut dialog = rfd::FileDialog::new()
                    .add_filter("Plain Text", &["txt"])
                    .set_file_name(format!("{}.txt", stem.unwrap_or_default()));
                if let Some(directory) = &directory {
                    dialog = dialog.set_directory(directory);
                }
                let Some(destination) = dialog.save_file() else {
                    return;
                };
                let data = tab.pdf_data();
                self.run_task("Exporting text", move || {
                    let result = pdf_core::conversion::searchable_text(&data, &pages)
                        .and_then(|text| pdf_core::conversion::write_text(&text, &destination));
                    Box::new(move |app: &mut Self| match result {
                        Ok(()) => app.dialogs.push(Dialog::Info(format!(
                            "Saved text as {}.",
                            destination.display()
                        ))),
                        Err(error) => app.error(error.to_string()),
                    })
                });
            }
            ConversionOutcome::CreatePdf => {
                let Some(images) = rfd::FileDialog::new()
                    .set_title("Choose Images")
                    .add_filter("Images", &pdf_core::conversion::IMAGE_EXTENSIONS)
                    .pick_files()
                else {
                    return;
                };
                if images.len() > pdf_core::conversion::MAXIMUM_IMAGE_COUNT {
                    return self
                        .error(pdf_core::conversion::ConversionError::TooManyImages.to_string());
                }
                let first = images[0].clone();
                let base = first
                    .file_stem()
                    .map(|s| s.to_string_lossy().into_owned())
                    .filter(|s| !s.is_empty())
                    .unwrap_or_else(|| "Images".into());
                let mut dialog = rfd::FileDialog::new()
                    .set_title("Create PDF From Images")
                    .add_filter("PDF", &["pdf"])
                    .set_file_name(format!("{base} Converted.pdf"));
                if let Some(directory) = first.parent() {
                    dialog = dialog.set_directory(directory);
                }
                let Some(destination) = dialog.save_file() else {
                    return;
                };
                self.run_task("Creating PDF", move || {
                    let result = pdf_core::conversion::pdf_from_images(&images)
                        .map_err(|error| error.to_string())
                        .and_then(|pdf| {
                            export::export(
                                &pdf,
                                &first,
                                &destination,
                                &Protection::None,
                                Compression::Standard,
                            )
                            .map_err(|error| error.to_string())
                        });
                    Box::new(move |app: &mut Self| match result {
                        Ok(receipt) => app.dialogs.push(Dialog::ExportReceipt(receipt)),
                        Err(message) => app.error(message),
                    })
                });
            }
            ConversionOutcome::ChooseSoffice => {
                let Some(path) = rfd::FileDialog::new()
                    .set_title("Choose the LibreOffice soffice Executable")
                    .pick_file()
                else {
                    return;
                };
                // Dialogs show last-pushed first, so the sheet goes below any error.
                self.dialogs
                    .push(Dialog::Conversion(Box::new(ConversionSheet::office(
                        tab_id,
                    ))));
                match pdf_core::office::validate_executable(&path) {
                    Ok(()) => self.preferences.soffice = Some(path),
                    Err(error) => self.error(error.to_string()),
                }
            }
            ConversionOutcome::ForgetSoffice => {
                self.preferences.soffice = None;
                self.dialogs
                    .push(Dialog::Conversion(Box::new(ConversionSheet::office(
                        tab_id,
                    ))));
            }
            ConversionOutcome::ConvertOffice => {
                let Some(soffice) = self.preferences.soffice.clone() else {
                    return;
                };
                let Some(helper) = pdf_core::office::helper_path() else {
                    return self
                        .error(pdf_core::office::OfficeError::HelperUnavailable.to_string());
                };
                let Some(input) = rfd::FileDialog::new()
                    .set_title("Choose an Office Document")
                    .add_filter("Office Documents", &pdf_core::office::ALLOWED_EXTENSIONS)
                    .pick_file()
                else {
                    return;
                };
                self.run_task("Converting locally with LibreOffice", move || {
                    let result = pdf_core::office::convert_with_helper(&helper, &soffice, &input);
                    Box::new(move |app: &mut Self| match result {
                        Ok(pdf) => app.save_office_output(pdf, &input),
                        Err(message) => app.error(message),
                    })
                });
            }
        }
    }

    fn save_office_output(&mut self, pdf: Vec<u8>, input: &Path) {
        let name = input
            .file_stem()
            .map(|s| s.to_string_lossy().into_owned())
            .unwrap_or_else(|| "Document".into());
        let mut dialog = rfd::FileDialog::new()
            .set_title("Save Converted PDF")
            .add_filter("PDF", &["pdf"])
            .set_file_name(format!("{name}.pdf"));
        if let Some(directory) = input.parent() {
            dialog = dialog.set_directory(directory);
        }
        let Some(destination) = dialog.save_file() else {
            return self.dialogs.push(Dialog::Info(
                "Conversion completed; saving was cancelled.".into(),
            ));
        };
        let source = input.to_path_buf();
        self.run_task("Saving converted PDF", move || {
            let result = export::export(
                &pdf,
                &source,
                &destination,
                &Protection::None,
                Compression::Standard,
            );
            Box::new(move |app: &mut Self| match result {
                Ok(receipt) => app.dialogs.push(Dialog::ExportReceipt(receipt)),
                Err(error) => app.error(error.to_string()),
            })
        });
    }

    // MARK: OCR

    fn request_ocr(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        if !tab.session.security.allows_document_changes() {
            return self.error(CoreError::PermissionDenied.to_string());
        }
        let id = tab.id;
        self.dialogs.push(Dialog::Ocr(Box::new(OcrSheet::new(id))));
    }

    fn start_processing(&mut self, tab_id: u64, options: pdf_ocr::OcrOptions) {
        let Some(index) = self.tab_index(tab_id) else {
            return;
        };
        let tab = &self.tabs[index];
        let data = tab.pdf_data();
        let generation = tab.session.editor.generation();
        let cancel = Arc::new(AtomicBool::new(false));
        let (sender, receiver) = channel();
        let worker_cancel = Arc::clone(&cancel);
        std::thread::spawn(move || {
            let progress_sender = sender.clone();
            let result = pdf_ocr::process(&data, &options, &worker_cancel, |progress| {
                let _ = progress_sender.send(ProcessingMessage::Progress(progress));
            });
            let _ = sender.send(ProcessingMessage::Finished(result));
        });
        self.job = Some(Job::Processing {
            receiver,
            cancel,
            progress: None,
            tab: tab_id,
            generation,
        });
    }

    fn finish_processing(&mut self, result: pdf_ocr::OcrResult, tab: u64, generation: u64) {
        let Some(index) = self.tab_index(tab) else {
            return;
        };
        let tab = &mut self.tabs[index];
        if tab.session.editor.generation() != generation {
            return self.error("The working PDF changed while local processing was running. Review the latest revision and try again.");
        }
        let added = result
            .source_page_indexes
            .len()
            .saturating_sub(tab.session.editor.page_count());
        if let Err(error) = tab
            .session
            .editor
            .apply_processed_document(result.pdf_data, Some(&result.source_page_indexes))
        {
            return self.error(error.to_string());
        }
        tab.after_mutation(None);
        let lines = result.recognized_lines;
        let mut message = format!(
            "Processed the document locally. {lines} line{} of text recognized.",
            if lines == 1 { "" } else { "s" }
        );
        if added > 0 {
            message.push_str(&format!(
                " {added} double page{} split.",
                if added == 1 { " was" } else { "s were" }
            ));
        }
        self.dialogs.push(Dialog::Info(message));
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
        let Some(index) = self.tab_index(tab_id) else {
            return;
        };
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
        let Some(mut destination) = dialog.save_file() else {
            return;
        };
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
        let Some(index) = self.tab_index(tab) else {
            return;
        };
        self.tabs[index]
            .session
            .editor
            .mark_current_revision_exported();
        match then {
            AfterExport::CloseTab => self.close_tab_now(index),
            AfterExport::Nothing => self.dialogs.push(Dialog::ExportReceipt(result)),
        }
    }

    // MARK: Closing

    fn request_close_tab(&mut self, index: usize) {
        let Some(tab) = self.tabs.get(index) else {
            return;
        };
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
        if self
            .split
            .as_ref()
            .is_some_and(|split| split.tab == self.tabs[index].id)
        {
            self.split = None;
        }
        let mut tab = self.tabs.remove(index);
        tab.session.close();
        self.restore_tabs
            .retain(|saved| !same_file(&saved.source, &tab.session.source_path));
        self.checkpoint_session();
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

    fn page_operation(
        &mut self,
        operation: impl FnOnce(&mut DocumentTab) -> Result<Option<usize>, CoreError>,
    ) {
        if self.job.is_some() {
            return;
        }
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
            tab.session
                .editor
                .rotate_pages(&pages, clockwise)
                .map(|_| None)
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
            tab.reader
                .synchronize(tab.session.editor.page_count(), Some(start));
            tab.reader.select_pages(new_selection, Some(start));
            let _ = first;
            Ok(Some(start))
        });
    }

    fn request_delete_selected(&mut self) {
        if !self.with_assembly_permission() {
            return;
        }
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        self.dialogs.push(Dialog::ConfirmDeletePages {
            tab: tab.id,
            pages: tab.reader.selected_pages_vec(),
        });
    }

    fn insert_pages_from_pdf(&mut self) {
        if !self.with_assembly_permission() {
            return;
        }
        let Some(path) = rfd::FileDialog::new()
            .add_filter("PDF", &["pdf"])
            .pick_file()
        else {
            return;
        };
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
            tab.session
                .editor
                .insert_pages(&data, None, Some(&fingerprint), at)?;
            Ok(Some(at))
        });
    }

    fn extract_selected(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
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
        match export::export(
            &extracted,
            &source,
            &destination,
            &protection,
            self.preferences.compression,
        ) {
            Ok(result) => self.dialogs.push(Dialog::ExportReceipt(result)),
            Err(error) => self.error(error.to_string()),
        }
    }

    fn undo(&mut self) {
        if self.job.is_some() {
            return;
        }
        let Some(tab) = self.active_tab() else { return };
        match tab.session.editor.undo() {
            Ok(()) => tab.after_mutation(None),
            Err(error) => self.error(error.to_string()),
        }
    }

    fn redo(&mut self) {
        if self.job.is_some() {
            return;
        }
        let Some(tab) = self.active_tab() else { return };
        match tab.session.editor.redo() {
            Ok(()) => tab.after_mutation(None),
            Err(error) => self.error(error.to_string()),
        }
    }

    fn copy_selection(&mut self, ctx: &egui::Context) {
        let index = self
            .selection_tab
            .and_then(|id| self.tab_index(id))
            .unwrap_or(self.active);
        let Some(tab) = self.tabs.get(index) else {
            return;
        };
        let Some(text) = tab.selected_text() else {
            return;
        };
        if !tab.session.security.allows_content_copying() {
            return self.error("This PDF's permissions don't allow copying text.");
        }
        ctx.copy_text(text);
    }

    // MARK: Annotations and forms

    fn handle_annotation_request(&mut self, request: AnnotationRequest) {
        let Some(tab_id) = self.tabs.get(self.active).map(|tab| tab.id) else {
            return;
        };
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
            AnnotationRequest::PlaceStamp {
                page,
                point,
                choice,
            } => {
                let result = match choice {
                    StampChoice::Preset(preset) => {
                        let tab = &mut self.tabs[self.active];
                        tab.annotate(|document| {
                            pdf_core::annotations::add_stamp(document, page, point, preset)
                                .map(|_| ())
                        })
                    }
                    StampChoice::Custom(id) => match self.stamps.image_data(id) {
                        Ok(data) => {
                            let name = self
                                .stamps
                                .signatures()
                                .iter()
                                .find(|s| s.id == id)
                                .map(|s| s.display_name.clone())
                                .unwrap_or_default();
                            let tab = &mut self.tabs[self.active];
                            annotation_ui::place_image(
                                tab,
                                page,
                                point,
                                &data,
                                pdf_core::annotations::SignatureSize::Medium,
                                Some(&name),
                            )
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
                        if let Err(message) =
                            annotation_ui::place_image(tab, page, point, &data, size, None)
                        {
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

    fn use_library_item(
        &mut self,
        kind: LibraryKind,
        id: uuid::Uuid,
        place: Option<(u64, usize, (f32, f32))>,
    ) {
        let Some(index) = place
            .and_then(|(tab, _, _)| self.tab_index(tab))
            .or(Some(self.active))
        else {
            return;
        };
        let Some(tab) = self.tabs.get_mut(index) else {
            return;
        };
        match kind {
            LibraryKind::Signatures => {
                tab.annotations.signature = Some(id);
                tab.tool = Tool::Annotate(AnnotationTool::Signature);
                if let Some((_, page, point)) = place {
                    let size = tab.annotations.signature_size;
                    let result = self
                        .signatures
                        .image_data(id)
                        .map_err(|error| error.to_string())
                        .and_then(|data| {
                            annotation_ui::place_image(
                                &mut self.tabs[index],
                                page,
                                point,
                                &data,
                                size,
                                None,
                            )
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
                let Some(tab) = self.tabs.get(self.active) else {
                    return;
                };
                let protection = match protection_for(&tab.session) {
                    Ok(protection) => protection,
                    Err(message) => return self.error(message),
                };
                let source = tab.session.source_path.clone();
                let Some(destination) = rfd::FileDialog::new()
                    .add_filter("PDF", &["pdf"])
                    .set_file_name(format!(
                        "{} (flattened).pdf",
                        source
                            .file_stem()
                            .map(|s| s.to_string_lossy().into_owned())
                            .unwrap_or_default()
                    ))
                    .save_file()
                else {
                    return;
                };
                match export::export(
                    &bytes,
                    &source,
                    &destination,
                    &protection,
                    self.preferences.compression,
                ) {
                    Ok(result) => self.dialogs.push(Dialog::ExportReceipt(result)),
                    Err(error) => self.error(error.to_string()),
                }
            }
        }
    }

    // MARK: Library JSON

    fn export_library_json(
        &mut self,
        title: &str,
        file_name: &str,
        data: Result<Vec<u8>, CoreError>,
    ) {
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
        let path = rfd::FileDialog::new()
            .set_title(title)
            .add_filter("JSON", &["json"])
            .pick_file()?;
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
        self.handle_command_shortcuts(ctx);
        if self.palette.is_some() {
            return;
        }
        if self.tabs.is_empty() {
            return;
        }
        if !ctx.egui_wants_keyboard_input()
            && ctx.input_mut(|input| {
                input
                    .events
                    .iter()
                    .any(|event| matches!(event, egui::Event::Copy))
            })
        {
            self.copy_selection(ctx);
        }

        if ctx.egui_wants_keyboard_input() {
            return;
        }
        let pressed =
            |key: Key| ctx.input(|input| input.key_pressed(key) && input.modifiers.is_none());
        let Some(tab) = self.tabs.get_mut(self.active) else {
            return;
        };
        let current = tab.reader.selected_page_index();
        let last = tab.session.editor.page_count().saturating_sub(1);
        let step = if tab.reader.display_mode == DisplayMode::TwoPage {
            2
        } else {
            1
        };
        let single = tab.reader.display_mode == DisplayMode::SinglePage;
        if pressed(Key::PageDown)
            || (single
                && (pressed(Key::ArrowRight) || pressed(Key::ArrowDown) || pressed(Key::Space)))
        {
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
        if self.job.is_none() && (pressed(Key::Delete) || pressed(Key::Backspace)) {
            if tab.annotations.selected.is_some() {
                if let Err(message) = annotation_ui::delete_selected(tab) {
                    self.error(message);
                }
            } else if tab.reader.is_sidebar_visible
                && tab.reader.sidebar_tab == crate::reader_state::SidebarTab::Thumbnails
            {
                self.request_delete_selected();
            }
        }
    }

    fn handle_dropped_files(&mut self, ctx: &egui::Context) {
        let dropped: Vec<PathBuf> = ctx.input(|input| {
            input
                .raw
                .dropped_files
                .iter()
                .map(|file| file.path().to_path_buf())
                .filter(|path| !path.as_os_str().is_empty())
                .collect()
        });
        let mut rejected = false;
        for path in dropped {
            if path
                .extension()
                .and_then(|extension| extension.to_str())
                .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
            {
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
            self.checkpoint_session();
            return;
        }
        let unexported = self
            .tabs
            .iter()
            .filter(|tab| tab.has_unexported_changes())
            .count();
        if unexported > 0 {
            ctx.send_viewport_cmd(egui::ViewportCommand::CancelClose);
            if !self
                .dialogs
                .iter()
                .any(|dialog| matches!(dialog, Dialog::QuitWithUnexportedChanges { .. }))
            {
                self.dialogs
                    .push(Dialog::QuitWithUnexportedChanges { count: unexported });
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
                if ui
                    .add_enabled(has_tab, egui::Button::new("Export PDF…      ⇧⌘S"))
                    .clicked()
                {
                    self.request_export_active();
                }
                if ui
                    .add_enabled(has_tab, egui::Button::new("Extract Selected Pages…"))
                    .clicked()
                {
                    self.extract_selected();
                }
                if ui.button("Convert…").clicked() {
                    self.request_conversion();
                }
                ui.separator();
                ui.menu_button("Library", |ui| {
                    if ui.button("Export Bookmarks…").clicked() {
                        let data = self.bookmarks.export_json();
                        self.export_library_json(
                            "Export Bookmarks",
                            "PDFViewer Bookmarks.json",
                            data,
                        );
                    }
                    if ui.button("Import Bookmarks…").clicked()
                        && let Some(data) = self.import_library_json("Import Bookmarks")
                        && let Err(error) = self.bookmarks.import_json(&data)
                    {
                        self.error(error.to_string());
                    }
                    if ui.button("Export Recent Documents…").clicked() {
                        let data = self.recents.export_json();
                        self.export_library_json(
                            "Export Recent Documents",
                            "PDFViewer Recent Documents.json",
                            data,
                        );
                    }
                    if ui.button("Import Recent Documents…").clicked()
                        && let Some(data) = self.import_library_json("Import Recent Documents")
                        && let Err(error) = self.recents.import_json(&data)
                    {
                        self.error(error.to_string());
                    }
                });
                ui.separator();
                if ui
                    .add_enabled(has_tab, egui::Button::new("Close Tab        ⌘W"))
                    .clicked()
                {
                    self.request_close_tab(self.active);
                }
            });
            ui.menu_button("Edit", |ui| {
                let (can_undo, can_redo) = self
                    .tabs
                    .get(self.active)
                    .map(|tab| (tab.session.editor.can_undo(), tab.session.editor.can_redo()))
                    .unwrap_or_default();
                if ui
                    .add_enabled(can_undo, egui::Button::new("Undo             ⌘Z"))
                    .clicked()
                {
                    self.undo();
                }
                if ui
                    .add_enabled(can_redo, egui::Button::new("Redo            ⇧⌘Z"))
                    .clicked()
                {
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
        if ui.button("Commands…   ⌘K").clicked() {
            self.palette = Some(crate::palette::Palette::new());
        }
        if ui.button("Split reading view").clicked() {
            self.toggle_split();
        }
        ui.separator();
        let Some(tab) = self.tabs.get_mut(self.active) else {
            return;
        };
        if ui
            .checkbox(&mut tab.reader.is_sidebar_visible, "Sidebar   ⌥⌘S")
            .changed()
        {
            self.preferences.sidebar_visible = tab.reader.is_sidebar_visible;
        }
        ui.separator();
        for mode in DisplayMode::ALL {
            if ui
                .radio_value(&mut tab.reader.display_mode, mode, mode.title())
                .clicked()
            {
                self.preferences.display_mode = mode;
                tab.scroll_to_page = Some(tab.reader.selected_page_index());
            }
        }
        ui.separator();
        for candidate in ReaderTheme::ALL {
            if ui
                .radio_value(&mut tab.reader.theme, candidate, candidate.title())
                .clicked()
            {
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
        let Some(tab) = self.tabs.get_mut(self.active) else {
            return;
        };
        let valid = tab.valid_page_ids();
        let current = tab.reader.selected_page_index();
        let last = tab.session.editor.page_count().saturating_sub(1);
        if ui
            .add_enabled(current > 0, egui::Button::new("Previous Page"))
            .clicked()
        {
            tab.show_page(current - 1);
        }
        if ui
            .add_enabled(current < last, egui::Button::new("Next Page"))
            .clicked()
        {
            tab.show_page(current + 1);
        }
        if ui.button("First Page").clicked() {
            tab.show_page(0);
        }
        if ui.button("Last Page").clicked() {
            tab.show_page(last);
        }
        ui.separator();
        if ui
            .add_enabled(
                tab.history.can_go_back(&valid),
                egui::Button::new("Back      ⌘["),
            )
            .clicked()
        {
            tab.go_back();
        }
        if ui
            .add_enabled(
                tab.history.can_go_forward(&valid),
                egui::Button::new("Forward   ⌘]"),
            )
            .clicked()
        {
            tab.go_forward();
        }
        ui.separator();
        if ui.button("Add Bookmark      ⌘D").clicked()
            && let Some(page_id) = tab.session.editor.page_id(current).cloned()
        {
            let label = format!("Page {}", tab.page_label(current));
            self.bookmarks
                .add(&tab.session.fingerprint, page_id, &label);
        }
    }

    fn pages_menu(&mut self, ui: &mut Ui) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
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
        if ui
            .add_enabled(first > 0, egui::Button::new("Move Up"))
            .clicked()
        {
            self.move_selected(move |_| first - 1);
        }
        if ui
            .add_enabled(last_selected + 1 < count, egui::Button::new("Move Down"))
            .clicked()
        {
            self.move_selected(move |_| last_selected + 2);
        }
        if ui
            .add_enabled(first > 0, egui::Button::new("Move to Beginning"))
            .clicked()
        {
            self.move_selected(|_| 0);
        }
        if ui
            .add_enabled(last_selected + 1 < count, egui::Button::new("Move to End"))
            .clicked()
        {
            self.move_selected(move |_| count);
        }
        ui.separator();
        if ui.button("Insert Pages from PDF…").clicked() {
            self.insert_pages_from_pdf();
        }
        if ui
            .add_enabled(
                selected.len() < count,
                egui::Button::new("Delete Selected Pages…"),
            )
            .clicked()
        {
            self.request_delete_selected();
        }
        ui.separator();
        if ui.button("OCR & Scan Enhancement…").clicked() {
            self.request_ocr();
        }
    }

    fn tab_strip(&mut self, ui: &mut Ui) {
        let colors = theme::colors();
        let mut close = None;
        ui.horizontal(|ui| {
            ui.spacing_mut().item_spacing.x = 4.0;
            let width = ((ui.available_width() - 4.0 * self.tabs.len() as f32)
                / self.tabs.len() as f32)
                .clamp(110.0, 220.0);
            for (index, tab) in self.tabs.iter().enumerate() {
                let selected = index == self.active;
                let (rect, response) =
                    ui.allocate_exact_size(egui::vec2(width, 26.0), egui::Sense::click());
                let fill = if selected {
                    colors.raised
                } else if response.hovered() {
                    colors.hover
                } else {
                    Color32::TRANSPARENT
                };
                let painter = ui.painter();
                painter.rect_filled(rect, egui::CornerRadius::same(6), fill);
                if selected {
                    painter.rect_stroke(
                        rect,
                        egui::CornerRadius::same(6),
                        egui::Stroke::new(1.0, colors.hairline),
                        egui::StrokeKind::Inside,
                    );
                }
                let close_rect = egui::Rect::from_center_size(
                    egui::pos2(rect.min.x + 14.0, rect.center().y),
                    egui::vec2(18.0, 18.0),
                );
                let close_response = ui.interact(
                    close_rect,
                    ui.id().with(("close-tab", tab.id)),
                    egui::Sense::click(),
                );
                let dirty = tab.has_unexported_changes();
                if response.hovered() || close_response.hovered() {
                    if close_response.hovered() {
                        painter.rect_filled(
                            close_rect,
                            egui::CornerRadius::same(4),
                            colors.pressed,
                        );
                    }
                    crate::icons::paint(
                        painter,
                        close_rect.shrink(4.0),
                        crate::icons::Icon::Close,
                        colors.muted,
                    );
                } else if dirty {
                    painter.circle_filled(close_rect.center(), 3.0, colors.muted);
                }
                let text_color = if selected { colors.text } else { colors.muted };
                let mut job = egui::text::LayoutJob::simple_singleline(
                    tab.title(),
                    egui::FontId::proportional(12.0),
                    text_color,
                );
                job.wrap = egui::text::TextWrapping::truncate_at_width(rect.width() - 44.0);
                let galley = ui.fonts_mut(|fonts| fonts.layout_job(job));
                let painter = ui.painter();
                painter.galley(
                    egui::pos2(rect.min.x + 28.0, rect.center().y - galley.size().y / 2.0),
                    galley,
                    text_color,
                );
                if close_response.on_hover_text("Close Tab").clicked() {
                    close = Some(index);
                } else if response.clicked() {
                    self.active = index;
                }
            }
        });
        if let Some(index) = close {
            self.request_close_tab(index);
        }
    }

    /// The unified title bar: window controls inset, navigation, the
    /// document title, editing modes, view options and search.
    fn toolbar(&mut self, ui: &mut Ui) {
        use crate::icons::{self, Icon};
        let colors = theme::colors();
        let Some(tab) = self.tabs.get_mut(self.active) else {
            ui.allocate_space(egui::vec2(ui.available_width(), 26.0));
            return;
        };
        let mut wants_ocr = false;
        let mut wants_palette = false;
        let mut wants_split = false;
        ui.horizontal(|ui| {
            ui.set_height(26.0);
            ui.spacing_mut().item_spacing.x = 2.0;
            let sidebar_tip = if tab.reader.is_sidebar_visible {
                "Hide Sidebar"
            } else {
                "Show Sidebar"
            };
            if icons::button(ui, Icon::Sidebar, false, sidebar_tip).clicked() {
                tab.reader.is_sidebar_visible = !tab.reader.is_sidebar_visible;
                self.preferences.sidebar_visible = tab.reader.is_sidebar_visible;
            }
            let valid = tab.valid_page_ids();
            if ui
                .add_enabled_ui(tab.history.can_go_back(&valid), |ui| {
                    icons::button(ui, Icon::Back, false, "Back")
                })
                .inner
                .clicked()
            {
                tab.go_back();
            }
            if ui
                .add_enabled_ui(tab.history.can_go_forward(&valid), |ui| {
                    icons::button(ui, Icon::Forward, false, "Forward")
                })
                .inner
                .clicked()
            {
                tab.go_forward();
            }
            ui.add_space(8.0);

            ui.with_layout(Layout::right_to_left(Align::Center), |ui| {
                ui.spacing_mut().item_spacing.x = 2.0;
                search_field(ui, tab);
                ui.add_space(6.0);
                let view = icons::text_button(ui, "View", false, "Page layout and reading theme");
                egui::Popup::menu(&view).show(|ui| {
                    ui.set_min_width(170.0);
                    if ui.button("Commands…   ⌘K").clicked() {
                        wants_palette = true;
                    }
                    if ui.button("Split reading view").clicked() {
                        wants_split = true;
                    }
                    ui.separator();
                    ui.weak("Layout");
                    for mode in DisplayMode::ALL {
                        if ui
                            .selectable_value(&mut tab.reader.display_mode, mode, mode.title())
                            .clicked()
                        {
                            self.preferences.display_mode = mode;
                            tab.scroll_to_page = Some(tab.reader.selected_page_index());
                        }
                    }
                    ui.separator();
                    ui.weak("Theme");
                    for candidate in ReaderTheme::ALL {
                        if ui
                            .selectable_value(&mut tab.reader.theme, candidate, candidate.title())
                            .clicked()
                        {
                            self.preferences.theme = candidate;
                        }
                    }
                });
                icons::divider(ui);
                if icons::text_button(ui, "OCR", false, "OCR & Scan Enhancement").clicked() {
                    wants_ocr = true;
                }
                if icons::text_button(ui, "Form", tab.forms.visible, "Fill Form Fields").clicked() {
                    tab.forms.visible = !tab.forms.visible;
                }
                let redacting = tab.tool == Tool::Redact;
                if icons::text_button(ui, "Redact", redacting, "Permanent Redaction").clicked() {
                    tab.tool = if redacting {
                        Tool::SelectText
                    } else {
                        Tool::Redact
                    };
                }
                let annotating = matches!(tab.tool, Tool::Annotate(_));
                if icons::text_button(ui, "Annotate", annotating, "Annotation Tools (⇧⌘A)")
                    .clicked()
                {
                    tab.tool = if annotating {
                        Tool::SelectText
                    } else {
                        Tool::Annotate(AnnotationTool::Select)
                    };
                    tab.annotations.selected = None;
                }
                ui.add_space(10.0);

                // The document title takes whatever width is left.
                let rest = ui.available_rect_before_wrap();
                ui.scope_builder(
                    egui::UiBuilder::new()
                        .max_rect(rest)
                        .layout(Layout::left_to_right(Align::Center)),
                    |ui| {
                        ui.spacing_mut().item_spacing.x = 6.0;
                        if tab.session.security.is_encrypted {
                            let (rect, response) = ui
                                .allocate_exact_size(egui::vec2(14.0, 14.0), egui::Sense::hover());
                            icons::paint(ui.painter(), rect, Icon::Lock, colors.warning);
                            response
                                .on_hover_text("Password protected. Exports keep the protection.");
                        }
                        ui.add(
                            egui::Label::new(
                                RichText::new(tab.title()).color(colors.text).size(13.0),
                            )
                            .truncate()
                            .selectable(false),
                        );
                        if tab.has_unexported_changes() {
                            ui.add(
                                egui::Label::new(
                                    RichText::new("Edited").color(colors.muted).size(12.0),
                                )
                                .selectable(false),
                            )
                            .on_hover_text("Changes are in a working copy. Export to save them.");
                        }
                    },
                );
            });
        });
        if wants_palette {
            self.palette = Some(crate::palette::Palette::new());
        }
        if wants_split {
            self.toggle_split();
        }
        if wants_ocr {
            self.request_ocr();
        }
    }

    /// Floating page and zoom controls at the bottom of the desk.
    fn page_controls(ctx: &egui::Context, tab: &mut DocumentTab, canvas: egui::Rect) {
        use crate::icons::{self, Icon};
        let colors = theme::colors();
        let frame = egui::Frame::new()
            .fill(colors.raised)
            .stroke(egui::Stroke::new(1.0, colors.hairline))
            .corner_radius(egui::CornerRadius::same(10))
            .shadow(ctx.global_style().visuals.popup_shadow)
            .inner_margin(egui::Margin::symmetric(6, 4));
        egui::Area::new(egui::Id::new(("page-controls", tab.id)))
            .pivot(Align2::CENTER_BOTTOM)
            .fixed_pos(egui::pos2(canvas.center().x, canvas.bottom() - 18.0))
            .constrain_to(canvas)
            .show(ctx, |ui| {
                frame.show(ui, |ui| {
                    ui.horizontal(|ui| {
                        ui.spacing_mut().item_spacing.x = 2.0;
                        let small = egui::vec2(26.0, 24.0);
                        let index = tab.reader.selected_page_index();
                        let count = tab.session.editor.page_count();
                        if ui
                            .add_enabled_ui(index > 0, |ui| {
                                icons::sized_button(
                                    ui,
                                    Icon::Previous,
                                    false,
                                    "Previous Page",
                                    small,
                                )
                            })
                            .inner
                            .clicked()
                        {
                            tab.navigate_to(index - 1);
                        }
                        let response = ui.add(
                            egui::TextEdit::singleline(&mut tab.go_to_page_text)
                                .desired_width(34.0)
                                .horizontal_align(Align::Center)
                                .margin(egui::Margin::symmetric(4, 3)),
                        );
                        if response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter))
                        {
                            match tab.go_to_page_text.trim().parse::<usize>() {
                                Ok(number) if (1..=count).contains(&number) => {
                                    tab.navigate_to(number - 1)
                                }
                                _ => tab.go_to_page_text = (index + 1).to_string(),
                            }
                        }
                        ui.label(RichText::new(format!("of {count}")).color(colors.muted));
                        let label = tab.page_label(index);
                        if label != (index + 1).to_string() {
                            ui.label(RichText::new(format!("({label})")).color(colors.faint));
                        }
                        if ui
                            .add_enabled_ui(index + 1 < count, |ui| {
                                icons::sized_button(ui, Icon::Next, false, "Next Page", small)
                            })
                            .inner
                            .clicked()
                        {
                            tab.navigate_to(index + 1);
                        }
                        icons::divider(ui);
                        if icons::sized_button(ui, Icon::ZoomOut, false, "Zoom Out (⌘−)", small)
                            .clicked()
                        {
                            tab.reader.zoom_out();
                        }
                        let percent = format!("{:.0}%", tab.reader.effective_scale * 100.0);
                        let zoom = ui.add_sized(
                            egui::vec2(44.0, 24.0),
                            egui::Label::new(RichText::new(percent).color(colors.text))
                                .sense(egui::Sense::click())
                                .selectable(false),
                        );
                        if zoom.on_hover_text("Actual Size").clicked() {
                            tab.reader.actual_size();
                        }
                        if icons::sized_button(ui, Icon::ZoomIn, false, "Zoom In (⌘+)", small)
                            .clicked()
                        {
                            tab.reader.zoom_in();
                        }
                        if icons::text_button(ui, "Fit", false, "Zoom to Fit (⌘0)").clicked() {
                            tab.reader.zoom_to_fit();
                        }
                    });
                });
            });
    }

    /// No document open: a blank sheet on the desk that doubles as the drop
    /// target, with recent documents set on it like a contents page.
    fn empty_state(&mut self, ui: &mut Ui) {
        use crate::icons::{self, Icon};
        let colors = theme::colors();
        let area = ui.max_rect();
        ui.painter().rect_filled(area, 0.0, colors.desk);
        let height = (area.height() - 96.0).clamp(300.0, 600.0);
        let width = (height / 1.294).min(area.width() - 48.0);
        let sheet = egui::Rect::from_center_size(area.center(), egui::vec2(width, height));
        let paper = if self.preferences.theme == ReaderTheme::Sepia {
            Color32::from_rgb(248, 241, 226)
        } else {
            Color32::from_rgb(252, 252, 250)
        };
        let ink = Color32::from_rgb(28, 30, 34);
        let pencil = Color32::from_rgb(110, 114, 122);
        let accent = Color32::from_rgb(22, 122, 110);
        let hovering_files = ui.input(|input| !input.raw.hovered_files.is_empty());
        let painter = ui.painter();
        painter.add(
            egui::Shadow {
                offset: [0, 14],
                blur: 40,
                spread: 0,
                color: theme::page_shadow(),
            }
            .as_shape(sheet, 2),
        );
        painter.rect_filled(sheet, egui::CornerRadius::same(2), paper);
        if hovering_files {
            painter.rect_stroke(
                sheet.shrink(10.0),
                egui::CornerRadius::same(4),
                egui::Stroke::new(2.0, accent),
                egui::StrokeKind::Inside,
            );
        }

        let margin = (width * 0.12).clamp(28.0, 56.0);
        let content = sheet.shrink2(egui::vec2(margin, margin * 1.1));
        let mut open = false;
        let mut chosen = None;
        ui.scope_builder(egui::UiBuilder::new().max_rect(content).layout(Layout::top_down(Align::Min)), |ui| {
            let visuals = ui.visuals_mut();
            visuals.override_text_color = Some(ink);
            visuals.widgets.inactive.weak_bg_fill = accent;
            visuals.widgets.inactive.bg_fill = accent;
            visuals.widgets.hovered.weak_bg_fill = Color32::from_rgb(18, 104, 94);
            visuals.widgets.hovered.bg_fill = Color32::from_rgb(18, 104, 94);
            visuals.widgets.active.weak_bg_fill = Color32::from_rgb(14, 88, 80);
            visuals.widgets.active.bg_fill = Color32::from_rgb(14, 88, 80);
            ui.label(RichText::new("PDFViewer").size(12.0).color(pencil));
            ui.add_space(content.height() * 0.12);
            ui.label(RichText::new("Nothing open yet.").size(30.0).color(ink));
            ui.add_space(8.0);
            ui.label(
                RichText::new("Open a PDF or drop one onto this page. It stays on this Mac, and the original file is never changed.")
                    .size(13.5)
                    .color(pencil),
            );
            ui.add_space(20.0);
            let button = egui::Button::new(RichText::new("Open PDF…").size(14.0).color(Color32::WHITE)).min_size(egui::vec2(0.0, 32.0));
            if ui.add(button).on_hover_text("⌘O").clicked() {
                open = true;
            }

            let recents = self.recents.documents().to_vec();
            if !recents.is_empty() {
                ui.add_space(content.height() * 0.08);
                ui.label(RichText::new("Recent").size(12.0).color(pencil));
                ui.add_space(4.0);
                let line = egui::Stroke::new(1.0, Color32::from_rgb(226, 226, 222));
                for document in recents.into_iter().take(6) {
                    if ui.available_height() < 30.0 {
                        break;
                    }
                    let (rect, response) = ui.allocate_exact_size(egui::vec2(ui.available_width(), 30.0), egui::Sense::click());
                    let painter = ui.painter();
                    if response.hovered() {
                        painter.rect_filled(rect.expand2(egui::vec2(6.0, 0.0)), egui::CornerRadius::same(4), Color32::from_rgb(238, 241, 240));
                    }
                    painter.line_segment([rect.left_top(), rect.right_top()], line);
                    let icon_rect = egui::Rect::from_center_size(egui::pos2(rect.min.x + 8.0, rect.center().y), egui::vec2(14.0, 14.0));
                    icons::paint(painter, icon_rect, Icon::Document, if response.hovered() { accent } else { pencil });
                    let mut job = egui::text::LayoutJob::simple_singleline(
                        document.display_name.clone(),
                        egui::FontId::proportional(13.0),
                        if response.hovered() { accent } else { ink },
                    );
                    job.wrap = egui::text::TextWrapping::truncate_at_width(rect.width() - 110.0);
                    let galley = ui.fonts_mut(|fonts| fonts.layout_job(job));
                    painter.galley(egui::pos2(rect.min.x + 24.0, rect.center().y - galley.size().y / 2.0), galley, ink);
                    painter.text(
                        egui::pos2(rect.max.x, rect.center().y),
                        Align2::RIGHT_CENTER,
                        document.last_opened_at.with_timezone(&chrono::Local).format("%-d %b").to_string(),
                        egui::FontId::proportional(12.0),
                        pencil,
                    );
                    if response.on_hover_cursor(egui::CursorIcon::PointingHand).clicked() {
                        chosen = Some(document);
                    }
                }
            }
        });
        if open {
            self.present_open_panel();
        }
        if let Some(document) = chosen {
            match self.recents.resolve(&document) {
                Ok(path) => self.open_path(path),
                Err(error) => self.error(error.to_string()),
            }
        }
    }

    fn job_overlay(&mut self, ctx: &egui::Context) {
        let Some(job) = &self.job else { return };
        let (title, cancellable) = match job {
            Job::Opening { path, .. } => (
                format!(
                    "Preparing {}…",
                    path.file_name()
                        .map(|n| n.to_string_lossy().into_owned())
                        .unwrap_or_default()
                ),
                true,
            ),
            Job::Exporting { .. } => ("Exporting and verifying…".to_owned(), false),
            Job::Task { title, .. } => (format!("{title}…"), false),
            Job::Processing { .. } => ("Processing pages locally…".to_owned(), true),
        };
        let progress = match job {
            Job::Processing { progress, .. } => {
                Some(progress.map_or((0, 1), |p| (p.completed, p.total.max(1))))
            }
            _ => None,
        };
        let mut cancel = false;
        egui::Window::new("Background task")
            .id(egui::Id::new("job-overlay"))
            .anchor(Align2::RIGHT_BOTTOM, [-12.0, -12.0])
            .resizable(false)
            .collapsible(false)
            .show(ctx, |ui| {
                ui.set_width(320.0);
                ui.horizontal(|ui| {
                    ui.spinner();
                    ui.label(title);
                });
                if let Some((completed, total)) = progress {
                    ui.add(
                        egui::ProgressBar::new(completed as f32 / total as f32)
                            .text(format!("Processed {completed} of {total} pages")),
                    );
                }
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
            match &self.job {
                // Stop between pages; the worker reports `Cancelled`.
                Some(Job::Processing { cancel, .. }) => cancel.store(true, Ordering::Relaxed),
                // The worker finishes in the background; its result is dropped.
                _ => self.job = None,
            }
        }
        ctx.request_repaint_after(std::time::Duration::from_millis(100));
    }

    fn show_dialogs(&mut self, ctx: &egui::Context) {
        let Some(dialog) = self.dialogs.pop() else {
            return;
        };
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
                        ui.colored_label(theme::colors().danger, "That password is incorrect.");
                    }
                    let submit = response.lost_focus() && ui.input(|i| i.key_pressed(Key::Enter));
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            locked.cancel();
                            keep = false;
                        }
                        if ui.add(theme::primary("Open")).clicked() || submit {
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
                        if ui.add(theme::destructive("Delete")).clicked() {
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
                        if ui.add(theme::primary("Export…")).clicked() {
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
                        if ui.add(theme::destructive("Discard and Quit")).clicked() {
                            keep = false;
                            follow_up = Some(Box::new(|app: &mut Self| {
                                app.discard_recovery = true;
                                app.restore_tabs.clear();
                                app.allow_quit = true;
                                app.checkpoint_session();
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
                        ui.colored_label(theme::colors().warning, "The export keeps this PDF's password protection.");
                    }
                    ui.add_space(8.0);
                    ui.horizontal(|ui| {
                        if ui.button("Cancel").clicked() {
                            keep = false;
                        }
                        if ui.add(theme::primary("Choose Location…")).clicked() {
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
                        if ui.add(theme::primary("Rename")).clicked() || submit {
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
                        if ui.add(theme::primary("Open Link")).clicked() {
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
                        if ui.add(theme::destructive("Redact Permanently")).clicked() {
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
                Dialog::Ocr(sheet) => {
                    let Some(index) = self.tab_index(sheet.tab) else {
                        keep = false;
                        return;
                    };
                    let tab = &self.tabs[index];
                    let (data, selected, count) = (tab.pdf_data(), tab.reader.selected_pages_vec(), tab.session.editor.page_count());
                    match sheet.show(ui, &data, &selected, count) {
                        SheetOutcome::Open => {}
                        SheetOutcome::Cancel => keep = false,
                        SheetOutcome::Start(options) => {
                            keep = false;
                            let tab = sheet.tab;
                            follow_up = Some(Box::new(move |app: &mut Self| app.start_processing(tab, options)));
                        }
                    }
                }
                Dialog::Conversion(sheet) => {
                    let document = sheet.tab.and_then(|id| self.tab_index(id)).map(|index| {
                        let tab = &self.tabs[index];
                        (tab.reader.selected_pages_vec(), tab.session.editor.page_count(), tab.session.security.allows_content_copying())
                    });
                    if document.is_none() {
                        sheet.tab = None;
                    }
                    let outcome = sheet.show(ui, document, self.preferences.soffice.as_deref());
                    if !matches!(outcome, ConversionOutcome::Open) {
                        keep = false;
                        let tab = sheet.tab;
                        follow_up = Some(Box::new(move |app: &mut Self| app.handle_conversion(tab, outcome)));
                    }
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
                        if ui.add_enabled(!text.trim().is_empty(), theme::primary("Save")).clicked() {
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
        for tab in &mut self.tabs {
            tab.session.editor.poll_history();
            if tab.session.editor.history_is_archiving() {
                ctx.request_repaint_after(std::time::Duration::from_millis(50));
            }
            if let Some((generation, unchanged)) = tab.render_carry.take() {
                self.renderer.carry_forward(
                    crate::render::DocumentKey {
                        tab: tab.id,
                        generation,
                    },
                    tab.document_key(),
                    &unchanged,
                );
            }
        }
        let live: HashSet<_> = self.tabs.iter().map(DocumentTab::document_key).collect();
        self.renderer.retain_documents(live);
        self.renderer.begin_frame(&ctx);
        self.poll_job();
        if let Some(error) = self.session_store.error() {
            self.checkpoint_signature.replace(None);
            self.error(format!("Session recovery could not be saved: {error}"));
        }
        if self.last_checkpoint.elapsed() >= std::time::Duration::from_secs(2) {
            self.checkpoint_session();
            self.last_checkpoint = std::time::Instant::now();
        }
        ctx.request_repaint_after(std::time::Duration::from_secs(2));
        if self.job.is_none()
            && self.dialogs.is_empty()
            && let Some(path) = self.pending_opens.pop_front()
        {
            self.open_path(path);
        }
        self.handle_dropped_files(&ctx);
        for command in std::mem::take(&mut self.pending_commands) {
            self.perform(&ctx, command);
        }
        self.handle_close_request(&ctx);
        if self.dialogs.is_empty() && self.palette.is_none() {
            self.handle_shortcuts(&ctx);
        }
        let live: HashSet<_> = self.tabs.iter().map(DocumentTab::document_key).collect();
        self.renderer.retain_documents(live);

        let mut annotation_request = AnnotationRequest::None;
        let mut redaction_request = RedactionRequest::None;
        let reader_theme = self
            .tabs
            .get(self.active)
            .map_or(self.preferences.theme, |tab| tab.reader.theme);
        theme::apply(&ctx, reader_theme);
        let colors = theme::colors();
        // Leave room for the window buttons, which sit over the toolbar.
        let fullscreen = ctx.input(|input| input.viewport().fullscreen.unwrap_or(false));
        let inset: i8 = if cfg!(target_os = "macos") && !fullscreen {
            78
        } else {
            10
        };
        egui::Panel::top("toolbar")
            .frame(
                egui::Frame::new()
                    .fill(colors.chrome)
                    .inner_margin(egui::Margin {
                        left: inset,
                        right: 10,
                        top: 6,
                        bottom: 6,
                    }),
            )
            .show(ui, |ui| {
                // Dragging empty toolbar space moves the window; widgets
                // added afterwards take their clicks first.
                let bar = egui::Rect::from_min_size(
                    ctx.content_rect().min,
                    egui::vec2(ctx.content_rect().width(), 38.0),
                );
                let drag = ui.interact(
                    bar,
                    ui.id().with("window-drag"),
                    egui::Sense::click_and_drag(),
                );
                if drag.drag_started() {
                    ctx.send_viewport_cmd(egui::ViewportCommand::StartDrag);
                }
                if drag.double_clicked() {
                    let maximized = ctx.input(|input| input.viewport().maximized.unwrap_or(false));
                    ctx.send_viewport_cmd(egui::ViewportCommand::Maximized(!maximized));
                }
                if !self.native_menu {
                    self.menu_bar(ui);
                }
                self.toolbar(ui);

                if self.tabs.len() > 1 {
                    ui.add_space(4.0);
                    self.tab_strip(ui);
                }
            });
        if !self.tabs.is_empty() {
            let (signatures, stamps) = (
                self.signatures.signatures().to_vec(),
                self.stamps.signatures().to_vec(),
            );
            if let Some(tab) = self.tabs.get_mut(self.active)
                && !matches!(tab.tool, Tool::SelectText)
            {
                egui::Panel::top("tool-options")
                    .frame(
                        egui::Frame::new()
                            .fill(colors.chrome)
                            .inner_margin(egui::Margin {
                                left: 10,
                                right: 10,
                                top: 4,
                                bottom: 5,
                            }),
                    )
                    .show(ui, |ui| {
                        ui.add_enabled_ui(self.job.is_none(), |ui| {
                            if matches!(tab.tool, Tool::Annotate(_)) {
                                annotation_request =
                                    annotation_ui::toolbar(ui, tab, &signatures, &stamps);
                            } else if tab.tool == Tool::Redact {
                                redaction_request = redaction_ui::toolbar(ui, tab);
                            }
                        });
                    });
            }
        }
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
                    ui.add_enabled_ui(self.job.is_none(), |ui| {
                        form_request = forms_ui::panel(ui, tab)
                    });
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
                    sidebar_action =
                        sidebar::show(ui, tab, &mut self.renderer, &mut self.bookmarks);
                });
        }
        match sidebar_action {
            sidebar::SidebarAction::None => {}
            sidebar::SidebarAction::RenameBookmark(id) => {
                let input = self
                    .bookmarks
                    .all()
                    .iter()
                    .find(|b| b.id == id)
                    .map(|b| b.label.clone())
                    .unwrap_or_default();
                self.dialogs.push(Dialog::RenameBookmark { id, input });
            }
            sidebar::SidebarAction::Command(command) => self.perform(&ctx, command),
            sidebar::SidebarAction::MovePages {
                pages,
                destination,
                generation,
            } => {
                if self.job.is_none()
                    && self.dialogs.is_empty()
                    && let Some(tab) = self.tabs.get_mut(self.active)
                    && tab.generation() == generation
                {
                    tab.reader.select_pages(pages.into_iter().collect(), None);
                    self.move_selected(|_| destination);
                }
            }
        }

        let mut deferred_request = AnnotationRequest::None;
        egui::CentralPanel::no_frame().show(ui, |ui| {
            let split_enabled = self
                .split
                .as_ref()
                .is_some_and(|split| self.tab_index(split.tab).is_some());
            if !split_enabled {
                self.split = None;
            }
            let bounds = ui.available_rect_before_wrap();
            let primary_bounds = if split_enabled {
                egui::Rect::from_min_max(
                    bounds.min,
                    egui::pos2(bounds.center().x - 3.0, bounds.max.y),
                )
            } else {
                bounds
            };
            ui.scope_builder(egui::UiBuilder::new().max_rect(primary_bounds), |ui| {
                if let Some(tab) = self.tabs.get_mut(self.active) {
                    tab.poll_search(&ctx);
                    let response = reader_view::show(ui, tab, &mut self.renderer);
                    Self::page_controls(&ctx, tab, response.canvas);
                    let painter = ui.painter_at(response.canvas);
                    interaction::paint_text_overlays(&painter, &ctx, tab, &response);
                    let request = if self.job.is_none() {
                        annotation_ui::handle(&ctx, tab, &response)
                    } else {
                        AnnotationRequest::None
                    };
                    annotation_ui::paint_overlays(&painter, tab, &response);
                    if self.job.is_none() {
                        redaction_ui::handle(&ctx, tab, &response);
                    }
                    redaction_ui::paint(&painter, tab, &response);
                    if let Some(click) = response.click
                        && tab.tool == Tool::SelectText
                        && let Some(field) = tab
                            .form_fields()
                            .into_iter()
                            .find(|f| f.page == click.page && f.rect.contains(click.point))
                    {
                        tab.forms.visible = true;
                        tab.forms.focus = Some(field.name);
                    }
                    deferred_request = request;
                    if response.drag_start.is_some()
                        || response.double_click.is_some()
                        || response.triple_click.is_some()
                        || response.click.is_some()
                    {
                        self.selection_tab = Some(tab.id);
                    }
                    match interaction::handle_select_text(&ctx, tab, &response) {
                        interaction::InteractionAction::None => {}
                        interaction::InteractionAction::ConfirmExternalLink(uri) => {
                            self.dialogs.push(Dialog::ConfirmLink(uri))
                        }
                        interaction::InteractionAction::RejectedLink => {
                            self.dialogs.push(Dialog::Error(
                                "PDFViewer only opens web and email links from documents.".into(),
                            ))
                        }
                    }
                } else {
                    self.empty_state(ui);
                }
            });
            if split_enabled {
                ui.painter().vline(
                    bounds.center().x,
                    bounds.y_range(),
                    egui::Stroke::new(1.0, theme::colors().hairline),
                );
                let secondary_bounds = egui::Rect::from_min_max(
                    egui::pos2(bounds.center().x + 3.0, bounds.min.y),
                    bounds.max,
                );
                ui.scope_builder(
                    egui::UiBuilder::new()
                        .max_rect(secondary_bounds)
                        .id_salt("reference-pane"),
                    |ui| self.show_reference(ui, &ctx),
                );
            }
        });

        self.handle_annotation_request(deferred_request);

        if !self.tabs.is_empty() && ctx.input(|input| !input.raw.hovered_files.is_empty()) {
            let screen = ctx.content_rect();
            let painter = ctx.layer_painter(egui::LayerId::new(
                egui::Order::Foreground,
                egui::Id::new("drop"),
            ));
            painter.rect_filled(screen, 0.0, Color32::from_black_alpha(110));
            painter.rect_stroke(
                screen.shrink(14.0),
                egui::CornerRadius::same(12),
                egui::Stroke::new(2.0, colors.accent),
                egui::StrokeKind::Inside,
            );
            painter.text(
                screen.center(),
                Align2::CENTER_CENTER,
                "Drop to open in a new tab",
                egui::FontId::proportional(20.0),
                Color32::WHITE,
            );
        }

        self.job_overlay(&ctx);
        if let Some(mut palette) = self.palette.take() {
            let (closed, command) =
                palette.show(&ctx, |command| self.command_state(command).enabled);
            if !closed {
                self.palette = Some(palette);
            }
            if let Some(command) = command {
                self.perform(&ctx, command);
            }
        }
        if self.job.is_none() {
            self.show_dialogs(&ctx);
        }
        if let Some(tab) = self.tabs.get(self.active) {
            let dirty = if tab.has_unexported_changes() {
                " — Edited"
            } else {
                ""
            };
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(format!(
                "{}{dirty}",
                tab.title()
            )));
        } else {
            ctx.send_viewport_cmd(egui::ViewportCommand::Title("PDFViewer".into()));
        }
        #[cfg(target_os = "macos")]
        crate::native::set_can_terminate(
            self.job.is_none()
                && (self.allow_quit || !self.tabs.iter().any(DocumentTab::has_unexported_changes)),
        );
        #[cfg(target_os = "macos")]
        if self.native_menu {
            let recents: Vec<String> = self
                .recents
                .documents()
                .iter()
                .map(|document| document.display_name.clone())
                .collect();
            crate::native::update_menu(|command| self.command_state(command), &recents);
        }
    }

    /// Native menu events arrive here before egui processes input, so Cut,
    /// Copy, Paste and Select All reach focused text fields as normal input.
    fn raw_input_hook(&mut self, _ctx: &egui::Context, raw_input: &mut egui::RawInput) {
        #[cfg(target_os = "macos")]
        for event in crate::native::drain() {
            match event {
                crate::native::NativeEvent::Open(path) => {
                    if path
                        .extension()
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
                    {
                        self.pending_opens.push_back(path);
                    } else {
                        self.dialogs
                            .push(Dialog::Error("PDFViewer can open PDF files only.".into()));
                    }
                }
                crate::native::NativeEvent::Command(command) => match command {
                    Command::Copy => raw_input.events.push(egui::Event::Copy),
                    Command::Cut => raw_input.events.push(egui::Event::Cut),
                    Command::Paste => {
                        if let Some(text) = crate::native::pasteboard_text() {
                            raw_input.events.push(egui::Event::Paste(text));
                        }
                    }
                    Command::SelectAll => raw_input.events.push(egui::Event::Key {
                        key: Key::A,
                        physical_key: Some(Key::A),
                        pressed: true,
                        repeat: false,
                        modifiers: Modifiers::COMMAND,
                    }),
                    other => self.pending_commands.push(other),
                },
            }
        }
        let _ = raw_input;
    }

    fn logic(&mut self, ctx: &egui::Context, _frame: &mut eframe::Frame) {
        if let Some(capture) = &mut self.capture {
            if let Some(name) = capture.theme.take() {
                let chosen = ReaderTheme::ALL
                    .into_iter()
                    .find(|theme| theme.title().eq_ignore_ascii_case(&name));
                self.preferences.theme = chosen.unwrap_or(self.preferences.theme);
            }
            if !self.tabs.is_empty() && std::mem::take(&mut capture.palette) {
                self.palette = Some(crate::palette::Palette::new());
            }
            if !self.tabs.is_empty() && std::mem::take(&mut capture.split) {
                let tab = &self.tabs[0];
                let mut reader = tab.reader.clone();
                reader.select_page(1.min(tab.pages.len().saturating_sub(1)));
                self.split = Some(SplitView {
                    tab: tab.id,
                    scroll_to_page: Some(reader.selected_page_index()),
                    reader,
                    offset: egui::Vec2::ZERO,
                    anchor: None,
                });
            }
            if let Some(tab) = self.tabs.first_mut() {
                tab.reader.theme = self.preferences.theme;
                if std::mem::take(&mut capture.rotate) {
                    let _ = tab.session.editor.rotate_pages(&[0], true);
                    tab.after_mutation(Some(0));
                }
                if std::mem::take(&mut capture.redact) {
                    tab.redaction.reason_label = "Privileged".into();
                    tab.redaction
                        .regions
                        .push(pdf_core::redaction::RedactionRegion {
                            page: 0,
                            rect: pdf_core::geometry::PdfBox::new(60.0, 690.0, 560.0, 740.0),
                        });
                    let _ = crate::redaction_ui::apply(tab);
                }
                if std::mem::take(&mut capture.convert) {
                    let id = tab.id;
                    self.dialogs
                        .push(Dialog::Conversion(Box::new(ConversionSheet::new(Some(id)))));
                }
                if std::mem::take(&mut capture.ocr) {
                    let id = tab.id;
                    self.dialogs.push(Dialog::Ocr(Box::new(OcrSheet::new(id))));
                }
                if std::mem::take(&mut capture.forms) {
                    tab.forms.visible = true;
                }
                if std::mem::take(&mut capture.annotate) {
                    use pdf_core::annotations::*;
                    use pdf_core::geometry::PdfBox;
                    let _ = tab.annotate(|d| {
                        add_text_markup(
                            d,
                            MarkupKind::Highlight,
                            &[(0, vec![PdfBox::new(90.0, 700.0, 330.0, 722.0)])],
                            palette::YELLOW,
                        )?;
                        add_ink(
                            d,
                            0,
                            &[
                                (80.0, 300.0),
                                (120.0, 340.0),
                                (160.0, 290.0),
                                (200.0, 350.0),
                            ],
                            palette::BLUE,
                            LineWidth::Bold,
                        )?;
                        add_shape(
                            d,
                            ShapeKind::Rectangle,
                            0,
                            (250.0, 280.0),
                            (360.0, 360.0),
                            palette::RED,
                            LineWidth::Standard,
                        )?;
                        add_shape(
                            d,
                            ShapeKind::Oval,
                            0,
                            (380.0, 280.0),
                            (480.0, 360.0),
                            palette::GREEN,
                            LineWidth::Standard,
                        )?;
                        add_shape(
                            d,
                            ShapeKind::Arrow,
                            0,
                            (100.0, 200.0),
                            (250.0, 240.0),
                            palette::PINK,
                            LineWidth::Bold,
                        )?;
                        add_text_note(d, 0, (520.0, 330.0), "Note", palette::YELLOW)?;
                        add_stamp(d, 0, (420.0, 200.0), StampPreset::Approved)?;
                        Ok(())
                    });
                    tab.tool = crate::document_tab::Tool::Annotate(
                        crate::annotation_ui::AnnotationTool::Select,
                    );
                    tab.refresh_annotation_index();
                    if let Some(info) = tab
                        .annotations
                        .index
                        .first()
                        .and_then(|page| page.get(2))
                        .cloned()
                    {
                        tab.annotations.selected =
                            Some(crate::annotation_ui::Selected { page: 0, info });
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
        self.checkpoint_session();
        eframe::set_value(storage, PREFERENCES_KEY, &self.preferences);
    }

    fn on_exit(&mut self, _gl: Option<&eframe::glow::Context>) {
        self.session_store.finish();
    }

    fn clear_color(&self, _visuals: &egui::Visuals) -> [f32; 4] {
        theme::colors().chrome.to_normalized_gamma_f32()
    }
}

/// Laid out right to left: the field, then its options and match stepping.
fn search_field(ui: &mut Ui, tab: &mut DocumentTab) {
    use crate::icons::{self, Icon};
    let colors = theme::colors();
    let id = egui::Id::new(("search-field", tab.id));
    let width = if ui.available_width() > 720.0 {
        200.0
    } else {
        150.0
    };
    let response = ui.add(
        egui::TextEdit::singleline(&mut tab.search.query)
            .id(id)
            .hint_text("Search")
            .desired_width(width)
            .margin(egui::Margin {
                left: 26,
                right: 8,
                top: 4,
                bottom: 4,
            }),
    );
    let glass = egui::Rect::from_center_size(
        egui::pos2(response.rect.min.x + 14.0, response.rect.center().y),
        egui::vec2(13.0, 13.0),
    );
    icons::paint(ui.painter(), glass, Icon::Search, colors.muted);
    if std::mem::take(&mut tab.search.focus_requested) {
        response.request_focus();
    }
    let active = response.has_focus() || !tab.search.query.is_empty();
    let (mut whole, mut case) = (false, false);
    if active {
        ui.add_space(2.0);
        whole =
            icons::text_button(ui, "Word", tab.search.options.whole_words, "Whole Words").clicked();
        if whole {
            tab.search.options.whole_words = !tab.search.options.whole_words;
        }
        case =
            icons::text_button(ui, "Aa", tab.search.options.case_sensitive, "Match Case").clicked();
        if case {
            tab.search.options.case_sensitive = !tab.search.options.case_sensitive;
        }
    }
    let count = tab.search.matches().len();
    if count > 0 {
        let small = egui::vec2(24.0, 24.0);
        if icons::sized_button(ui, Icon::ChevronDown, false, "Next Match (⌘G)", small).clicked() {
            tab.step_search(true);
        }
        if icons::sized_button(ui, Icon::ChevronUp, false, "Previous Match (⇧⌘G)", small).clicked()
        {
            tab.step_search(false);
        }
        ui.label(
            RichText::new(format!(
                "{} of {count}",
                tab.search.active.map_or(0, |i| i + 1)
            ))
            .color(colors.muted)
            .size(12.0),
        );
    } else if tab.search.is_running() {
        ui.spinner();
    }
    let submitted = response.lost_focus() && ui.input(|input| input.key_pressed(Key::Enter));
    if submitted || case || whole {
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
    ui.add(theme::primary(title)).clicked() || ui.input(|input| input.key_pressed(Key::Enter))
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
