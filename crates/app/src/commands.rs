//! Application commands, shared by the native macOS menu bar and the app.

use crate::reader_state::{DisplayMode, ReaderTheme};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Command {
    Quit,
    Open,
    OpenRecent(usize),
    ClearRecents,
    Export,
    ExtractPages,
    Convert,
    Print,
    ExportBookmarks,
    ImportBookmarks,
    ExportRecents,
    ImportRecents,
    CloseTab,
    Undo,
    Redo,
    Cut,
    Copy,
    Paste,
    SelectAll,
    Find,
    FindNext,
    FindPrevious,
    ToggleSidebar,
    Palette,
    ToggleSplit,
    Display(DisplayMode),
    Theme(ReaderTheme),
    ZoomIn,
    ZoomOut,
    ZoomToFit,
    ActualSize,
    PageLabels,
    ToggleAnnotate,
    ToggleRedact,
    ToggleForms,
    PreviousPage,
    NextPage,
    FirstPage,
    LastPage,
    Back,
    Forward,
    AddBookmark,
    NextTab,
    RotateRight,
    RotateLeft,
    MoveUp,
    MoveDown,
    MoveToBeginning,
    MoveToEnd,
    InsertPages,
    DeletePages,
    Ocr,
}

impl Command {
    /// Text editing commands go to egui as input events, so they work in
    /// text fields and dialogs too.
    pub fn is_text_editing(self) -> bool {
        matches!(self, Self::Cut | Self::Copy | Self::Paste | Self::SelectAll)
    }

    pub fn is_reading(self) -> bool {
        matches!(
            self,
            Self::Palette
                | Self::ToggleSplit
                | Self::Find
                | Self::FindNext
                | Self::FindPrevious
                | Self::ToggleSidebar
                | Self::Display(_)
                | Self::Theme(_)
                | Self::ZoomIn
                | Self::ZoomOut
                | Self::ZoomToFit
                | Self::ActualSize
                | Self::PreviousPage
                | Self::NextPage
                | Self::FirstPage
                | Self::LastPage
                | Self::Back
                | Self::Forward
                | Self::NextTab
                | Self::Copy
        )
    }

    /// Commands that work without an open document.
    pub fn is_global(self) -> bool {
        matches!(
            self,
            Self::Quit
                | Self::Palette
                | Self::Open
                | Self::OpenRecent(_)
                | Self::ClearRecents
                | Self::Convert
                | Self::ExportBookmarks
                | Self::ImportBookmarks
                | Self::ExportRecents
                | Self::ImportRecents
        ) || self.is_text_editing()
    }
}

/// What the menu shows for a command right now.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct CommandState {
    pub enabled: bool,
    pub checked: bool,
}
