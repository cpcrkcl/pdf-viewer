//! PDF document model for PDFViewer: loading, the protected working copy,
//! revisions, page operations, navigation and local persistence.

pub mod annotations;
pub mod appearance;
pub mod editor;
pub mod engine;
pub mod error;
pub mod export;
pub mod forms;
pub mod geometry;
pub mod ids;
pub mod loader;
pub mod navigation;
pub mod outline;
pub mod persistence;
pub mod recents;
pub mod security;
pub mod signatures;
pub mod structure;
pub mod testing;
pub mod text;

pub use editor::DocumentEditor;
pub use error::{CoreError, CoreResult};
pub use ids::{WorkingPageId, sha256_hex};
pub use loader::{DocumentSession, LockedDocument, OpenResult, SecurityContext};
