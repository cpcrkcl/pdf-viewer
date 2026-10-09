//! Annotation tools and the annotation navigator.

use egui::Ui;

use crate::document_tab::DocumentTab;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AnnotationTool {
    Select,
    Highlight,
    Underline,
    Strikethrough,
    Freehand,
    Eraser,
    TextNote,
    Rectangle,
    Oval,
    Line,
    Arrow,
    Stamp,
    Signature,
}

impl AnnotationTool {
    pub const ALL: [Self; 13] = [
        Self::Select,
        Self::Highlight,
        Self::Underline,
        Self::Strikethrough,
        Self::Freehand,
        Self::Eraser,
        Self::TextNote,
        Self::Rectangle,
        Self::Oval,
        Self::Line,
        Self::Arrow,
        Self::Stamp,
        Self::Signature,
    ];

    pub fn title(self) -> &'static str {
        match self {
            Self::Select => "Select",
            Self::Highlight => "Highlight",
            Self::Underline => "Underline",
            Self::Strikethrough => "Strikethrough",
            Self::Freehand => "Freehand",
            Self::Eraser => "Ink Eraser",
            Self::TextNote => "Text Note",
            Self::Rectangle => "Rectangle",
            Self::Oval => "Oval",
            Self::Line => "Line",
            Self::Arrow => "Arrow",
            Self::Stamp => "Stamp",
            Self::Signature => "Visual Signature",
        }
    }

    pub fn requires_text_selection(self) -> bool {
        matches!(self, Self::Highlight | Self::Underline | Self::Strikethrough)
    }
}

pub fn annotation_list(ui: &mut Ui, _tab: &mut DocumentTab) {
    ui.weak("Annotation tools are being ported.");
}
