//! Optional Office → PDF conversion through a user-installed LibreOffice.
//!
//! PDFViewer never bundles or downloads LibreOffice. The app runs the
//! separate `PDFViewerOfficeHelper` executable, which validates the chosen
//! `soffice` and document, converts into a fresh private directory with a
//! timeout and no inherited input or diagnostics, and writes the PDF to its
//! standard output. The app then validates that output independently.

use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use thiserror::Error;

use crate::conversion::PrivateDirectory;

pub const ALLOWED_EXTENSIONS: [&str; 9] = ["doc", "docx", "ppt", "pptx", "xls", "xlsx", "odt", "ods", "odp"];
pub const MAXIMUM_INPUT_BYTES: u64 = 1 << 30;
pub const MAXIMUM_OUTPUT_BYTES: u64 = 256 << 20;
pub const TIMEOUT: Duration = Duration::from_secs(120);
pub const HELPER_NAME: &str = "PDFViewerOfficeHelper";

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum OfficeError {
    #[error("Choose a supported local Office document.")]
    InvalidSelection,
    #[error("The selected file is not a valid, non-symlink soffice executable.")]
    InvalidExecutable,
    #[error("LibreOffice could not convert this document locally.")]
    ConversionFailed,
    #[error("LibreOffice did not produce one valid PDF.")]
    InvalidOutput,
    #[error("The conversion helper is unavailable.")]
    HelperUnavailable,
}

pub fn validate_executable(path: &Path) -> Result<(), OfficeError> {
    let metadata = std::fs::symlink_metadata(path).map_err(|_| OfficeError::InvalidExecutable)?;
    let executable = {
        #[cfg(unix)]
        {
            std::os::unix::fs::PermissionsExt::mode(&metadata.permissions()) & 0o111 != 0
        }
        #[cfg(not(unix))]
        {
            true
        }
    };
    if path.file_name().is_some_and(|name| name == "soffice") && metadata.is_file() && executable {
        Ok(())
    } else {
        Err(OfficeError::InvalidExecutable)
    }
}

pub fn validate_input(path: &Path) -> Result<(), OfficeError> {
    let extension = path.extension().and_then(|e| e.to_str()).map(str::to_ascii_lowercase).unwrap_or_default();
    let metadata = std::fs::symlink_metadata(path).map_err(|_| OfficeError::InvalidSelection)?;
    if ALLOWED_EXTENSIONS.contains(&extension.as_str()) && metadata.is_file() && (1..=MAXIMUM_INPUT_BYTES).contains(&metadata.len()) {
        Ok(())
    } else {
        Err(OfficeError::InvalidSelection)
    }
}

/// A PDF signature, a size limit, and at least one page PDFium can open.
pub fn validate_output(data: &[u8]) -> Result<(), OfficeError> {
    if data.len() <= 4 || data.len() as u64 > MAXIMUM_OUTPUT_BYTES || !data.starts_with(b"%PDF") {
        return Err(OfficeError::InvalidOutput);
    }
    match crate::editor::validated_page_count(data) {
        Ok(count) if count > 0 => Ok(()),
        _ => Err(OfficeError::InvalidOutput),
    }
}

/// Runs LibreOffice directly. Called inside the helper process.
pub fn convert(executable: &Path, input: &Path) -> Result<Vec<u8>, OfficeError> {
    validate_executable(executable)?;
    validate_input(input)?;
    let directory = PrivateDirectory::new(&std::env::temp_dir()).map_err(|_| OfficeError::ConversionFailed)?;
    let output_directory = directory.path.join("out");
    std::fs::create_dir(&output_directory).map_err(|_| OfficeError::ConversionFailed)?;
    // A private profile avoids clashing with a running LibreOffice instance.
    let profile = format!("-env:UserInstallation=file://{}", directory.path.join("profile").display());
    let mut child = Command::new(executable)
        .arg(profile)
        .args(["--headless", "--nologo", "--nodefault", "--nolockcheck", "--norestore", "--nofirststartwizard", "--convert-to", "pdf", "--outdir"])
        .arg(&output_directory)
        .arg(input)
        // Diagnostics can fill an unread pipe and may contain document paths.
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| OfficeError::ConversionFailed)?;
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) if started.elapsed() < TIMEOUT => std::thread::sleep(Duration::from_millis(100)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Err(OfficeError::ConversionFailed);
            }
        }
    };
    if !status.success() {
        return Err(OfficeError::ConversionFailed);
    }
    let outputs: Vec<PathBuf> = std::fs::read_dir(&output_directory)
        .map_err(|_| OfficeError::InvalidOutput)?
        .filter_map(|entry| entry.ok().map(|entry| entry.path()))
        .filter(|path| path.extension().is_some_and(|e| e.eq_ignore_ascii_case("pdf")))
        .collect();
    let [output] = outputs.as_slice() else { return Err(OfficeError::InvalidOutput) };
    let metadata = std::fs::symlink_metadata(output).map_err(|_| OfficeError::InvalidOutput)?;
    if !metadata.is_file() || metadata.len() <= 4 || metadata.len() > MAXIMUM_OUTPUT_BYTES {
        return Err(OfficeError::InvalidOutput);
    }
    let data = std::fs::read(output).map_err(|_| OfficeError::InvalidOutput)?;
    if !data.starts_with(b"%PDF") {
        return Err(OfficeError::InvalidOutput);
    }
    Ok(data)
}

/// The helper next to the running executable (`Contents/MacOS` in the bundle).
pub fn helper_path() -> Option<PathBuf> {
    let path = std::env::current_exe().ok()?.parent()?.join(HELPER_NAME);
    path.is_file().then_some(path)
}

/// Runs the conversion in the helper process and validates its output.
pub fn convert_with_helper(helper: &Path, executable: &Path, input: &Path) -> Result<Vec<u8>, String> {
    validate_executable(executable).map_err(|e| e.to_string())?;
    validate_input(input).map_err(|e| e.to_string())?;
    let mut child = Command::new(helper)
        .arg(executable)
        .arg(input)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|_| OfficeError::HelperUnavailable.to_string())?;
    let mut data = Vec::new();
    let read = child.stdout.take().map(|stdout| stdout.take(MAXIMUM_OUTPUT_BYTES + 1).read_to_end(&mut data));
    let mut message = String::new();
    if let Some(stderr) = child.stderr.take() {
        let _ = stderr.take(512).read_to_string(&mut message);
    }
    let status = child.wait().map_err(|_| OfficeError::HelperUnavailable.to_string())?;
    if !status.success() {
        let message = message.trim();
        return Err(if message.is_empty() { "The conversion helper stopped unexpectedly.".into() } else { message.to_owned() });
    }
    if !matches!(read, Some(Ok(_))) {
        return Err(OfficeError::InvalidOutput.to_string());
    }
    validate_output(&data).map_err(|_| "The helper returned an invalid PDF.".to_owned())?;
    Ok(data)
}
