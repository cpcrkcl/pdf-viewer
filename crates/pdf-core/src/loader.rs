//! Opening PDFs into protected working copies.
//!
//! The source file is read once, fingerprinted, decrypted (if needed) and
//! re-serialized as an independent, unencrypted working copy. The source file
//! itself is never written. Opening is pure and `Send`, so callers run it on a
//! background thread and only hand the finished session to the UI.

use std::path::{Path, PathBuf};

use lopdf::{Document as LoDocument, LoadOptions, Object};

use crate::editor::DocumentEditor;
use crate::engine;
use crate::error::{CoreError, CoreResult};
use crate::ids::{WorkingPageId, sha256_hex};
use crate::outline::{OutlineNode, build_outline};
use crate::structure;

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub enum UnlockLevel {
    User,
    Owner,
}

/// The standard security handler `/P` bits (PDF 32000-1, table 22).
#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct AccessPermissions(pub u32);

impl AccessPermissions {
    pub const ALL: Self = Self(u32::MAX);
    pub const PRINT: u32 = 1 << 2;
    pub const MODIFY: u32 = 1 << 3;
    pub const COPY: u32 = 1 << 4;
    pub const ANNOTATE: u32 = 1 << 5;
    pub const FILL_FORMS: u32 = 1 << 8;
    pub const EXTRACT_ACCESSIBILITY: u32 = 1 << 9;
    pub const ASSEMBLE: u32 = 1 << 10;
    pub const PRINT_HIGH_QUALITY: u32 = 1 << 11;

    pub fn has(self, bit: u32) -> bool {
        self.0 & bit != 0
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct SecurityContext {
    pub is_encrypted: bool,
    pub unlock_level: UnlockLevel,
    pub permissions: AccessPermissions,
}

impl SecurityContext {
    pub const UNPROTECTED: Self = Self {
        is_encrypted: false,
        unlock_level: UnlockLevel::Owner,
        permissions: AccessPermissions::ALL,
    };

    fn allows(&self, bit: u32) -> bool {
        self.unlock_level == UnlockLevel::Owner || self.permissions.has(bit)
    }

    pub fn allows_commenting(&self) -> bool {
        self.allows(AccessPermissions::ANNOTATE)
    }
    pub fn allows_document_assembly(&self) -> bool {
        self.allows(AccessPermissions::ASSEMBLE)
    }
    pub fn allows_content_copying(&self) -> bool {
        self.allows(AccessPermissions::COPY)
    }
    pub fn allows_printing(&self) -> bool {
        self.allows(AccessPermissions::PRINT)
    }
    pub fn allows_form_field_entry(&self) -> bool {
        self.allows(AccessPermissions::FILL_FORMS) || self.allows(AccessPermissions::ANNOTATE)
    }
    pub fn allows_document_changes(&self) -> bool {
        self.allows(AccessPermissions::MODIFY)
    }
}

/// An open document: its source, working copy and session metadata.
pub struct DocumentSession {
    pub source_path: PathBuf,
    pub editor: DocumentEditor,
    pub security: SecurityContext,
    pub fingerprint: String,
    pub outline: Vec<OutlineNode>,
    /// Kept only for the session so protected exports can be re-encrypted.
    session_password: Option<String>,
}

impl DocumentSession {
    pub fn display_name(&self) -> String {
        display_name(&self.source_path)
    }

    pub fn session_password(&self) -> Option<&str> {
        self.session_password.as_deref()
    }

    pub fn close(&mut self) {
        self.session_password = None;
    }
}

/// A password-protected PDF awaiting its password.
pub struct LockedDocument {
    pub source_path: PathBuf,
    source: Option<Vec<u8>>,
    fingerprint: String,
}

impl LockedDocument {
    pub fn display_name(&self) -> String {
        display_name(&self.source_path)
    }

    /// `Ok(None)` means the password was wrong; the handle stays usable.
    pub fn unlock(&mut self, password: &str) -> CoreResult<Option<DocumentSession>> {
        let source = self
            .source
            .as_ref()
            .ok_or(CoreError::LockedHandleUnavailable)?;
        let prepared = match prepare(source, Some(password)) {
            Ok(prepared) => prepared,
            Err(CoreError::PasswordRequired) => return Ok(None),
            Err(error) => {
                self.cancel();
                return Err(error);
            }
        };
        self.source = None;
        session_from(
            prepared,
            self.source_path.clone(),
            self.fingerprint.clone(),
            Some(password),
        )
        .map(Some)
    }

    pub fn cancel(&mut self) {
        self.source = None;
    }
}

pub enum OpenResult {
    Opened(DocumentSession),
    PasswordRequired(LockedDocument),
}

pub fn open(path: &Path) -> CoreResult<OpenResult> {
    let is_pdf = path
        .extension()
        .and_then(|extension| extension.to_str())
        .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"));
    if !is_pdf {
        return Err(CoreError::UnsupportedFileType);
    }
    let source_path = std::path::absolute(path).unwrap_or_else(|_| path.to_path_buf());
    let bytes = std::fs::read(&source_path).map_err(|_| CoreError::FileUnavailable)?;
    open_bytes(bytes, source_path)
}

pub fn open_bytes(bytes: Vec<u8>, source_path: PathBuf) -> CoreResult<OpenResult> {
    if bytes.is_empty() {
        return Err(CoreError::InvalidPdf);
    }
    let fingerprint = sha256_hex(&bytes);
    match prepare(&bytes, None) {
        Ok(prepared) => {
            session_from(prepared, source_path, fingerprint, None).map(OpenResult::Opened)
        }
        Err(CoreError::PasswordRequired) => Ok(OpenResult::PasswordRequired(LockedDocument {
            source_path,
            source: Some(bytes),
            fingerprint,
        })),
        Err(error) => Err(error),
    }
}

struct Prepared {
    working_copy: Vec<u8>,
    security: SecurityContext,
}

fn session_from(
    prepared: Prepared,
    source_path: PathBuf,
    fingerprint: String,
    password: Option<&str>,
) -> CoreResult<DocumentSession> {
    let editor = DocumentEditor::new(prepared.working_copy, &fingerprint)
        .map_err(|_| CoreError::InvalidPdf)?;
    let outline = {
        let document = engine::load(editor.pdf_data().to_vec(), None)?;
        build_outline(&document, editor.page_ids())
    };
    Ok(DocumentSession {
        source_path,
        editor,
        security: prepared.security,
        fingerprint,
        outline,
        session_password: if prepared.security.is_encrypted {
            Some(password.unwrap_or_default().to_owned())
        } else {
            None
        },
    })
}

/// Produces an unencrypted working copy plus the source's security context.
fn prepare(source: &[u8], password: Option<&str>) -> CoreResult<Prepared> {
    let password = password.unwrap_or("");
    let parsed = LoDocument::load_mem_with_options(source, LoadOptions::with_password(password));
    let (mut document, security) = match parsed {
        Ok(document) if document.is_encrypted() || document.was_encrypted() => {
            decrypted(document, source, password)?
        }
        Ok(document) => (document, SecurityContext::UNPROTECTED),
        Err(_) => {
            // lopdf is stricter than PDFium. Let PDFium repair the file, then
            // continue with its re-serialized output.
            let repaired = match engine::load(source.to_vec(), Some(password)) {
                Ok(document) => engine::serialize(&document)?,
                Err(CoreError::PasswordRequired) => return Err(CoreError::PasswordRequired),
                Err(_) => return Err(CoreError::InvalidPdf),
            };
            let document = LoDocument::load_mem(&repaired).map_err(|_| CoreError::InvalidPdf)?;
            if document.is_encrypted() {
                return Err(CoreError::InvalidPdf);
            }
            (document, SecurityContext::UNPROTECTED)
        }
    };

    if structure::page_count(&document) == 0 {
        return Err(CoreError::InvalidPdf);
    }
    structure::flatten_page_tree(&mut document)?;
    document.prune_objects();
    let working_copy = structure::serialize(&mut document)?;
    Ok(Prepared {
        working_copy,
        security,
    })
}

fn decrypted(
    mut document: LoDocument,
    source: &[u8],
    password: &str,
) -> CoreResult<(LoDocument, SecurityContext)> {
    // PDFium is the authority on the password: lopdf silently decrypts
    // documents whose user password is empty, which hides the distinction.
    let unlock_level = {
        let rendered = engine::load(source.to_vec(), Some(password))?;
        let permissions = rendered.permissions();
        let everything = [
            permissions.can_print_high_quality(),
            permissions.can_assemble_document(),
            permissions.can_modify_document_content(),
            permissions.can_extract_text_and_graphics(),
            permissions.can_add_or_modify_text_annotations(),
            permissions.can_fill_existing_interactive_form_fields(),
        ]
        .into_iter()
        .all(|allowed| allowed.unwrap_or(false));
        if everything {
            UnlockLevel::Owner
        } else {
            UnlockLevel::User
        }
    };

    if document.is_encrypted() {
        document
            .decrypt(password)
            .map_err(|_| CoreError::PasswordRequired)?;
    }
    let permissions = document
        .encryption_state
        .as_ref()
        .map(|state| AccessPermissions(state.permissions().bits() as u32))
        .or_else(|| {
            document
                .get_encrypted()
                .ok()
                .and_then(|dictionary| dictionary.get(b"P").ok())
                .and_then(|value| value.as_i64().ok())
                .map(|bits| AccessPermissions(bits as u32))
        })
        .unwrap_or(AccessPermissions(0));
    if let Ok(Object::Reference(id)) = document.trailer.get(b"Encrypt").cloned() {
        document.objects.remove(&id);
    }
    document.trailer.remove(b"Encrypt");
    document.encryption_state = None;
    Ok((
        document,
        SecurityContext {
            is_encrypted: true,
            unlock_level,
            permissions,
        },
    ))
}

fn display_name(path: &Path) -> String {
    path.file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Untitled.pdf".to_owned())
}

/// Page identities for a freshly opened document (used by tests and tools).
pub fn original_page_ids(fingerprint: &str, count: usize) -> Vec<WorkingPageId> {
    (0..count)
        .map(|index| WorkingPageId::original(fingerprint, index))
        .collect()
}
