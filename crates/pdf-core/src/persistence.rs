//! Small JSON files in the app's support directory, written atomically.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde::de::DeserializeOwned;

use crate::error::CoreResult;

pub struct JsonFile {
    path: PathBuf,
}

impl JsonFile {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn load<T: DeserializeOwned>(&self) -> Option<T> {
        let data = std::fs::read(&self.path).ok()?;
        serde_json::from_slice(&data).ok()
    }

    pub fn save<T: Serialize>(&self, value: &T) -> CoreResult<()> {
        let data = serde_json::to_vec(value).map_err(|error| crate::CoreError::Io(error.to_string()))?;
        write_atomically(&self.path, &data)
    }
}

/// Writes through a same-directory temporary file and renames over `path`.
pub fn write_atomically(path: &Path, data: &[u8]) -> CoreResult<()> {
    let directory = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(directory)?;
    let temporary = directory.join(format!(
        ".{}.{}.tmp",
        path.file_name().map(|name| name.to_string_lossy()).unwrap_or_default(),
        uuid::Uuid::new_v4()
    ));
    std::fs::write(&temporary, data)?;
    if let Err(error) = std::fs::rename(&temporary, path) {
        let _ = std::fs::remove_file(&temporary);
        return Err(error.into());
    }
    Ok(())
}

/// `~/Library/Application Support/PDFViewer` (inside the sandbox container
/// when sandboxed), overridable with `PDFVIEWER_SUPPORT_DIR` for tests.
pub fn support_directory() -> PathBuf {
    if let Some(directory) = std::env::var_os("PDFVIEWER_SUPPORT_DIR") {
        return PathBuf::from(directory);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."));
    home.join("Library/Application Support/PDFViewer")
}
