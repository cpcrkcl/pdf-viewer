//! Command dispatch and menu state for [`PdfViewerApp`]. Shortcuts and the
//! native macOS menu bar both end up in [`PdfViewerApp::perform`].

use egui::{Key, KeyboardShortcut, Modifiers};

use super::{Dialog, PdfViewerApp};
use crate::annotation_ui::AnnotationTool;
use crate::commands::{Command, CommandState};
use crate::document_tab::{DocumentTab, Tool};
use crate::reader_state::SidebarTab;

impl PdfViewerApp {
    /// Whether menus and shortcuts may act on documents right now.
    pub(super) fn accepts_commands(&self) -> bool {
        self.dialogs.is_empty()
    }

    pub(super) fn perform(&mut self, ctx: &egui::Context, command: Command) {
        use Command::*;
        if command == Quit {
            ctx.send_viewport_cmd(egui::ViewportCommand::Close);
            return;
        }
        if !self.accepts_commands() || !self.command_state(command).enabled {
            return;
        }
        match command {
            Quit | Cut | Copy | Paste | SelectAll => {}
            Palette => self.palette = Some(crate::palette::Palette::new()),
            ToggleSplit => self.toggle_split(),
            Open => self.present_open_panel(),
            OpenRecent(index) => {
                if let Some(document) = self.recents.documents().get(index).cloned() {
                    match self.recents.resolve(&document) {
                        Ok(path) => self.open_path(path),
                        Err(error) => self.error(error.to_string()),
                    }
                }
            }
            ClearRecents => {
                let _ = self.recents.clear();
            }
            Export => self.request_export_active(),
            ExtractPages => self.extract_selected(),
            Convert => self.request_conversion(),
            Print => self.print_active(),
            ExportBookmarks => {
                let data = self.bookmarks.export_json();
                self.export_library_json("Export Bookmarks", "PDFViewer Bookmarks.json", data);
            }
            ImportBookmarks => {
                if let Some(data) = self.import_library_json("Import Bookmarks")
                    && let Err(error) = self.bookmarks.import_json(&data)
                {
                    self.error(error.to_string());
                }
            }
            ExportRecents => {
                let data = self.recents.export_json();
                self.export_library_json(
                    "Export Recent Documents",
                    "PDFViewer Recent Documents.json",
                    data,
                );
            }
            ImportRecents => {
                if let Some(data) = self.import_library_json("Import Recent Documents")
                    && let Err(error) = self.recents.import_json(&data)
                {
                    self.error(error.to_string());
                }
            }
            CloseTab => self.request_close_tab(self.active),
            Undo => self.undo(),
            Redo => self.redo(),
            Find => self.with_tab(|tab| {
                tab.search.focus_requested = true;
                tab.reader.is_sidebar_visible = true;
                tab.reader.sidebar_tab = SidebarTab::Search;
            }),
            FindNext => self.with_tab(|tab| tab.step_search(true)),
            FindPrevious => self.with_tab(|tab| tab.step_search(false)),
            ToggleSidebar => {
                let visible = self.tabs.get_mut(self.active).map(|tab| {
                    tab.reader.is_sidebar_visible = !tab.reader.is_sidebar_visible;
                    tab.reader.is_sidebar_visible
                });
                if let Some(visible) = visible {
                    self.preferences.sidebar_visible = visible;
                }
            }
            Display(mode) => {
                self.preferences.display_mode = mode;
                self.with_tab(|tab| {
                    tab.reader.display_mode = mode;
                    tab.scroll_to_page = Some(tab.reader.selected_page_index());
                });
            }
            Theme(theme) => {
                self.preferences.theme = theme;
                self.with_tab(|tab| tab.reader.theme = theme);
            }
            ZoomIn => self.with_tab(|tab| tab.reader.zoom_in()),
            ZoomOut => self.with_tab(|tab| tab.reader.zoom_out()),
            ZoomToFit => self.with_tab(|tab| tab.reader.zoom_to_fit()),
            ActualSize => self.with_tab(|tab| tab.reader.actual_size()),
            PageLabels => {
                if let Some(tab) = self.tabs.get(self.active) {
                    let id = tab.id;
                    self.dialogs.push(Dialog::PageLabels { tab: id });
                }
            }
            ToggleAnnotate => self.with_tab(|tab| {
                let annotating = matches!(tab.tool, Tool::Annotate(_));
                tab.tool = if annotating {
                    Tool::SelectText
                } else {
                    Tool::Annotate(AnnotationTool::Select)
                };
                tab.annotations.selected = None;
            }),
            ToggleRedact => self.with_tab(|tab| {
                tab.tool = if tab.tool == Tool::Redact {
                    Tool::SelectText
                } else {
                    Tool::Redact
                }
            }),
            ToggleForms => self.with_tab(|tab| tab.forms.visible = !tab.forms.visible),
            PreviousPage => self
                .with_tab(|tab| tab.show_page(tab.reader.selected_page_index().saturating_sub(1))),
            NextPage => self.with_tab(|tab| {
                let last = tab.session.editor.page_count().saturating_sub(1);
                tab.show_page((tab.reader.selected_page_index() + 1).min(last));
            }),
            FirstPage => self.with_tab(|tab| tab.show_page(0)),
            LastPage => self
                .with_tab(|tab| tab.show_page(tab.session.editor.page_count().saturating_sub(1))),
            Back => self.with_tab(DocumentTab::go_back),
            Forward => self.with_tab(DocumentTab::go_forward),
            AddBookmark => {
                let bookmark = self.tabs.get(self.active).and_then(|tab| {
                    let index = tab.reader.selected_page_index();
                    let page_id = tab.session.editor.page_id(index).cloned()?;
                    Some((
                        tab.session.fingerprint.clone(),
                        page_id,
                        format!("Page {}", tab.page_label(index)),
                    ))
                });
                if let Some((fingerprint, page_id, label)) = bookmark {
                    self.bookmarks.add(&fingerprint, page_id, &label);
                }
            }
            NextTab => self.active = (self.active + 1) % self.tabs.len(),
            RotateRight => self.rotate_selected(true),
            RotateLeft => self.rotate_selected(false),
            MoveUp => {
                let first = self.selection_bounds().0;
                self.move_selected(move |_| first - 1);
            }
            MoveDown => {
                let last = self.selection_bounds().1;
                self.move_selected(move |_| last + 2);
            }
            MoveToBeginning => self.move_selected(|_| 0),
            MoveToEnd => {
                let count = self
                    .tabs
                    .get(self.active)
                    .map_or(0, |tab| tab.session.editor.page_count());
                self.move_selected(move |_| count);
            }
            InsertPages => self.insert_pages_from_pdf(),
            DeletePages => self.request_delete_selected(),
            Ocr => self.request_ocr(),
        }
    }

    fn with_tab(&mut self, body: impl FnOnce(&mut DocumentTab)) {
        if let Some(tab) = self.tabs.get_mut(self.active) {
            body(tab);
        }
    }

    /// First and last selected page of the active document.
    fn selection_bounds(&self) -> (usize, usize) {
        let selected = self
            .tabs
            .get(self.active)
            .map(|tab| tab.reader.selected_pages_vec())
            .unwrap_or_default();
        (
            selected.first().copied().unwrap_or(0),
            selected.last().copied().unwrap_or(0),
        )
    }

    /// Enabled and checked state for menus. Text editing commands stay
    /// enabled so their shortcuts reach text fields inside dialogs.
    pub(super) fn command_state(&self, command: Command) -> CommandState {
        use Command::*;
        let enabled = |enabled: bool| CommandState {
            enabled,
            checked: false,
        };
        if command.is_text_editing() || command == Quit {
            return enabled(true);
        }
        if !self.accepts_commands() || (self.job.is_some() && !command.is_reading()) {
            return enabled(false);
        }
        let Some(tab) = self.tabs.get(self.active) else {
            return enabled(command.is_global());
        };
        let security = &tab.session.security;
        let editor = &tab.session.editor;
        let count = editor.page_count();
        let selected = tab.reader.selected_pages_vec();
        let (first, last) = self.selection_bounds();
        let valid = || tab.valid_page_ids();
        let current = tab.reader.selected_page_index();
        if matches!(
            command,
            RotateRight
                | RotateLeft
                | MoveUp
                | MoveDown
                | MoveToBeginning
                | MoveToEnd
                | InsertPages
                | DeletePages
        ) && !security.allows_document_assembly()
        {
            return enabled(false);
        }
        match command {
            Undo => enabled(editor.can_undo()),
            Redo => enabled(editor.can_redo()),
            Print => enabled(cfg!(target_os = "macos") && security.allows_printing()),
            Ocr => enabled(security.allows_document_changes()),
            ToggleAnnotate => CommandState {
                enabled: true,
                checked: matches!(tab.tool, Tool::Annotate(_)),
            },
            ToggleRedact => CommandState {
                enabled: true,
                checked: tab.tool == Tool::Redact,
            },
            ToggleForms => CommandState {
                enabled: true,
                checked: tab.forms.visible,
            },
            ToggleSplit => CommandState {
                enabled: true,
                checked: self.split.is_some(),
            },
            ToggleSidebar => CommandState {
                enabled: true,
                checked: tab.reader.is_sidebar_visible,
            },
            Display(mode) => CommandState {
                enabled: true,
                checked: tab.reader.display_mode == mode,
            },
            Theme(theme) => CommandState {
                enabled: true,
                checked: tab.reader.theme == theme,
            },
            FindNext | FindPrevious => enabled(!tab.search.matches().is_empty()),
            PreviousPage => enabled(current > 0),
            NextPage => enabled(current + 1 < count),
            Back => enabled(tab.history.can_go_back(&valid())),
            Forward => enabled(tab.history.can_go_forward(&valid())),
            NextTab => enabled(self.tabs.len() > 1),
            MoveUp | MoveToBeginning => enabled(first > 0),
            MoveDown | MoveToEnd => enabled(last + 1 < count),
            DeletePages => enabled(selected.len() < count),
            ClearRecents => enabled(!self.recents.documents().is_empty()),
            _ => enabled(true),
        }
    }

    /// Prints the working copy, including unexported edits and annotations.
    fn print_active(&mut self) {
        let Some(tab) = self.tabs.get(self.active) else {
            return;
        };
        if !tab.session.security.allows_printing() {
            return self.error("This PDF's permissions don't allow printing.");
        }
        #[cfg(target_os = "macos")]
        {
            let (data, title) = (tab.pdf_data(), tab.title());
            if let Err(message) = crate::native::print(&data, &title) {
                self.error(message);
            }
        }
    }

    /// Keyboard shortcuts egui sees. With the native menu bar, AppKit takes
    /// the shortcuts it shows first, so these only fire where it doesn't.
    pub(super) fn handle_command_shortcuts(&mut self, ctx: &egui::Context) {
        use Command::*;
        let command = Modifiers::COMMAND;
        let command_shift = Modifiers::COMMAND | Modifiers::SHIFT;
        let command_option = Modifiers::COMMAND | Modifiers::ALT;
        let shortcuts = [
            (command, Key::K, Palette),
            (command_shift, Key::Backslash, ToggleSplit),
            (command, Key::O, Open),
            (command, Key::W, CloseTab),
            (command_shift, Key::S, Export),
            (command, Key::E, Export),
            (command, Key::P, Print),
            (command_shift, Key::Z, Redo),
            (command, Key::Z, Undo),
            (command, Key::Plus, ZoomIn),
            (command, Key::Equals, ZoomIn),
            (command, Key::Minus, ZoomOut),
            (command, Key::Num0, ZoomToFit),
            (command_option, Key::S, ToggleSidebar),
            (command, Key::OpenBracket, Back),
            (command, Key::CloseBracket, Forward),
            (command_shift, Key::R, RotateLeft),
            (command, Key::R, RotateRight),
            (command, Key::D, AddBookmark),
            (Modifiers::CTRL, Key::Tab, NextTab),
            (command_shift, Key::A, ToggleAnnotate),
            (command, Key::F, Find),
            (command_shift, Key::G, FindPrevious),
            (command, Key::G, FindNext),
        ];
        // Consume the most specific modifiers first so ⇧⌘Z isn't also ⌘Z.
        for (modifiers, key, action) in shortcuts {
            if ctx.input_mut(|input| input.consume_shortcut(&KeyboardShortcut::new(modifiers, key)))
            {
                self.perform(ctx, action);
            }
        }
    }
}
