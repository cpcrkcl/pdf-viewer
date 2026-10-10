//! Searchable actions use the same dispatcher and permission checks as menus.
use crate::commands::Command;
use crate::reader_state::DisplayMode;

#[derive(Default)]
pub struct Palette {
    query: String,
    selected: usize,
    focus: bool,
}

impl Palette {
    pub fn new() -> Self {
        Self {
            focus: true,
            ..Self::default()
        }
    }
    pub fn show(
        &mut self,
        ctx: &egui::Context,
        enabled: impl Fn(Command) -> bool,
    ) -> (bool, Option<Command>) {
        let mut action = None;
        let mut close = false;
        // Consume navigation before the text field so it cannot eat arrows or Enter.
        let down =
            ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::ArrowDown));
        let up =
            ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::ArrowUp));
        let enter =
            ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::Enter));
        egui::Modal::new(egui::Id::new("command-palette")).show(ctx, |ui| {
            ui.set_width(430.0);
            ui.heading("Commands");
            let input = ui.add(
                egui::TextEdit::singleline(&mut self.query)
                    .hint_text("Find an action…")
                    .desired_width(f32::INFINITY),
            );
            if std::mem::take(&mut self.focus) {
                input.request_focus();
            }
            if input.changed() {
                self.selected = 0;
            }
            let items: Vec<_> = actions()
                .into_iter()
                .filter(|(title, _, command)| {
                    enabled(*command) && matches_query(title, &self.query)
                })
                .collect();
            if down {
                self.selected = (self.selected + 1).min(items.len().saturating_sub(1));
            }
            if up {
                self.selected = self.selected.saturating_sub(1);
            }
            self.selected = self.selected.min(items.len().saturating_sub(1));
            egui::ScrollArea::vertical()
                .max_height(310.0)
                .show(ui, |ui| {
                    for (index, (title, shortcut, command)) in items.iter().enumerate() {
                        let response = ui.add(
                            egui::Button::new(format!("{title}    {shortcut}"))
                                .selected(index == self.selected)
                                .frame(false)
                                .min_size(egui::vec2(ui.available_width(), 27.0)),
                        );
                        if response.clicked() || (enter && index == self.selected) {
                            action = Some(*command);
                        }
                        if index == self.selected && (down || up) {
                            response.scroll_to_me(None);
                        }
                    }
                    if items.is_empty() {
                        ui.weak("No available commands match. Try “pages” or “zoom”.");
                    }
                });
            ui.separator();
            ui.weak("↑ ↓ to choose · Enter to run · Esc to close");
        });
        if ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::Escape)) {
            close = true;
        }
        (close || action.is_some(), action)
    }
}

fn matches_query(title: &str, query: &str) -> bool {
    let title = title.to_lowercase();
    query
        .split_whitespace()
        .all(|word| title.contains(&word.to_lowercase()))
}

fn actions() -> Vec<(&'static str, &'static str, Command)> {
    use Command::*;
    vec![
        ("Open PDF…", "⌘O", Open),
        ("Export edited copy…", "⌘E", Export),
        ("Print…", "⌘P", Print),
        ("Close tab", "⌘W", CloseTab),
        ("Undo", "⌘Z", Undo),
        ("Redo", "⇧⌘Z", Redo),
        ("Find text", "⌘F", Find),
        ("Next search result", "⌘G", FindNext),
        ("Previous search result", "⇧⌘G", FindPrevious),
        ("Zoom in", "⌘+", ZoomIn),
        ("Zoom out", "⌘−", ZoomOut),
        ("Zoom to fit", "⌘0", ZoomToFit),
        ("Actual size", "", ActualSize),
        ("Continuous pages", "", Display(DisplayMode::Continuous)),
        ("Single page", "", Display(DisplayMode::SinglePage)),
        ("Two-page spreads", "", Display(DisplayMode::TwoPage)),
        ("Split reading view", "⇧⌘\\", ToggleSplit),
        ("Show or hide sidebar", "⌥⌘S", ToggleSidebar),
        ("Annotation tools", "⇧⌘A", ToggleAnnotate),
        ("Redaction tools", "", ToggleRedact),
        ("Fill forms", "", ToggleForms),
        ("Add bookmark", "⌘D", AddBookmark),
        ("First page", "", FirstPage),
        ("Last page", "", LastPage),
        ("Next tab", "Ctrl Tab", NextTab),
        ("Rotate selected pages clockwise", "⌘R", RotateRight),
        ("Rotate selected pages counterclockwise", "⇧⌘R", RotateLeft),
        ("Move selected pages up", "", MoveUp),
        ("Move selected pages down", "", MoveDown),
        ("Move selected pages to beginning", "", MoveToBeginning),
        ("Move selected pages to end", "", MoveToEnd),
        ("Insert pages from PDF…", "", InsertPages),
        ("Extract selected pages…", "", ExtractPages),
        ("Delete selected pages…", "", DeletePages),
        ("Page labels…", "", PageLabels),
        ("OCR and scan enhancement…", "", Ocr),
        ("Convert PDF, images or Office files…", "", Convert),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_all_query_words_case_insensitively() {
        assert!(matches_query(
            "Rotate selected pages clockwise",
            "PAGES rotate"
        ));
        assert!(!matches_query("Zoom in", "pages"));
    }
}

#[cfg(test)]
mod keyboard_tests {
    use super::*;
    #[test]
    fn keyboard_filters_and_executes_enabled_actions() {
        let ctx = egui::Context::default();
        let mut palette = Palette::new();
        palette.query = "rotate".into();
        let mut result = None;
        let mut output = ctx.run_ui(egui::RawInput::default(), |ui| {
            palette.show(ui.ctx(), |_| true);
        });
        output.textures_delta.clear();
        let event = |key| egui::Event::Key {
            key,
            physical_key: None,
            pressed: true,
            repeat: false,
            modifiers: egui::Modifiers::NONE,
        };
        let mut output = ctx.run_ui(
            egui::RawInput {
                events: vec![event(egui::Key::ArrowDown)],
                ..Default::default()
            },
            |ui| {
                palette.show(ui.ctx(), |_| true);
            },
        );
        output.textures_delta.clear();
        let mut output = ctx.run_ui(
            egui::RawInput {
                events: vec![event(egui::Key::Enter)],
                ..Default::default()
            },
            |ui| {
                result = palette.show(ui.ctx(), |_| true).1;
            },
        );
        output.textures_delta.clear();
        assert_eq!(result, Some(Command::RotateLeft));
    }
}
