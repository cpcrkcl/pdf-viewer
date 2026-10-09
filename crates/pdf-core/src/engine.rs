//! Process-wide PDFium binding.
//!
//! PDFium is bound exactly once. Lookup order: `PDFVIEWER_PDFIUM_PATH`, the
//! app bundle's `Contents/Frameworks`, the executable's directory, then the
//! repository's `vendor/pdfium/lib` (populated by `scripts/fetch-pdfium.sh`).

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use pdfium_render::prelude::*;

use crate::error::{CoreError, CoreResult};

static PDFIUM: OnceLock<Result<Pdfium, String>> = OnceLock::new();

pub type Document = PdfDocument<'static>;

pub fn pdfium() -> CoreResult<&'static Pdfium> {
    PDFIUM
        .get_or_init(bind)
        .as_ref()
        .map_err(|message| CoreError::EngineUnavailable(message.clone()))
}

fn bind() -> Result<Pdfium, String> {
    let mut attempted = Vec::new();
    for directory in candidate_directories() {
        let path = Pdfium::pdfium_platform_library_name_at_path(&directory);
        if !path.exists() {
            continue;
        }
        match Pdfium::bind_to_library(&path) {
            Ok(bindings) => return Ok(Pdfium::new(bindings)),
            Err(error) => attempted.push(format!("{}: {error}", path.display())),
        }
    }
    match Pdfium::bind_to_system_library() {
        Ok(bindings) => Ok(Pdfium::new(bindings)),
        Err(error) => {
            attempted.push(format!("system library: {error}"));
            Err(format!(
                "PDFium could not be loaded. Run scripts/fetch-pdfium.sh. ({})",
                attempted.join("; ")
            ))
        }
    }
}

fn candidate_directories() -> Vec<PathBuf> {
    let mut directories = Vec::new();
    if let Some(path) = std::env::var_os("PDFVIEWER_PDFIUM_PATH") {
        let path = PathBuf::from(path);
        directories.push(if path.is_file() {
            path.parent().map(Path::to_path_buf).unwrap_or_default()
        } else {
            path
        });
    }
    if let Some(executable_directory) = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(Path::to_path_buf))
    {
        directories.push(executable_directory.join("../Frameworks"));
        directories.push(executable_directory);
    }
    directories.push(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../vendor/pdfium/lib"),
    );
    directories
}

/// Opens bytes as an independent PDFium document.
pub fn load(bytes: Vec<u8>, password: Option<&str>) -> CoreResult<Document> {
    pdfium()?
        .load_pdf_from_byte_vec(bytes, password)
        .map_err(|error| match error {
            PdfiumError::PdfiumLibraryInternalError(PdfiumInternalError::PasswordError) => {
                CoreError::PasswordRequired
            }
            _ => CoreError::InvalidPdf,
        })
}

/// Opens bytes that must contain at least one page.
pub fn load_nonempty(bytes: Vec<u8>, password: Option<&str>) -> CoreResult<Document> {
    let document = load(bytes, password)?;
    if document.pages().is_empty() {
        return Err(CoreError::InvalidPdf);
    }
    Ok(document)
}

pub fn new_document() -> CoreResult<Document> {
    pdfium()?.create_new_pdf().map_err(|_| CoreError::CouldNotCopyDocument)
}

pub fn serialize(document: &Document) -> CoreResult<Vec<u8>> {
    match document.save_to_bytes() {
        Ok(bytes) if !bytes.is_empty() => Ok(bytes),
        _ => Err(CoreError::CouldNotCopyDocument),
    }
}

/// Text extraction is bounded by a rectangle; PDFium's own `all()` uses the
/// rotated page size, which drops text on 90°/270° pages.
pub const UNBOUNDED: PdfRect = PdfRect::new_from_values(-1.0e6, -1.0e6, 1.0e6, 1.0e6);

/// Plain text of every page, in order.
pub fn page_texts(bytes: &[u8]) -> CoreResult<Vec<String>> {
    let document = load(bytes.to_vec(), None)?;
    document
        .pages()
        .iter()
        .map(|page| {
            page.text()
                .map(|text| text.inside_rect(UNBOUNDED))
                .map_err(|_| CoreError::InvalidPdf)
        })
        .collect()
}
