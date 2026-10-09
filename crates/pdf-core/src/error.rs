use thiserror::Error;

pub type CoreResult<T> = Result<T, CoreError>;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum CoreError {
    #[error("{0}")]
    EngineUnavailable(String),

    // Loading
    #[error("PDFViewer can open PDF files only.")]
    UnsupportedFileType,
    #[error("This PDF is missing, unreadable, or no longer available.")]
    FileUnavailable,
    #[error("This file is not a valid PDF or could not be read safely.")]
    InvalidPdf,
    #[error("This PDF requires a password.")]
    PasswordRequired,
    #[error("This password prompt is no longer active. Open the PDF again to retry.")]
    LockedHandleUnavailable,
    #[error("The operation was cancelled.")]
    Cancelled,

    // Editing
    #[error("Choose one or more valid pages first.")]
    InvalidPageSelection,
    #[error("A PDF must contain at least one page.")]
    CannotDeleteOnlyPage,
    #[error("The selected insertion position is no longer valid.")]
    InvalidInsertionIndex,
    #[error("The selected PDF has no pages to add.")]
    NoPagesToInsert,
    #[error("PDFViewer could not create a safe working copy of this PDF.")]
    CouldNotCopyDocument,
    #[error("PDFViewer could not copy one of the selected pages.")]
    CouldNotCopyPage,
    #[error("There is no document operation to undo.")]
    NothingToUndo,
    #[error("There is no document operation to redo.")]
    NothingToRedo,
    #[error("The selected annotation is no longer available.")]
    InvalidAnnotation,
    #[error("This annotation was not created by PDFViewer and is read-only.")]
    AnnotationIsReadOnly,
    #[error("PDFViewer could not create that annotation safely.")]
    CouldNotCreateAnnotation,
    #[error("This document's permissions do not allow that change.")]
    PermissionDenied,

    // Export
    #[error("Choose a different destination; the original PDF is never replaced.")]
    ExportWouldReplaceSource,
    #[error("PDFViewer could not write the exported file.")]
    ExportWriteFailed,
    #[error("The exported file failed validation after writing.")]
    ExportValidationFailed,

    #[error("{0}")]
    Io(String),
}

impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        CoreError::Io(error.to_string())
    }
}
