//! Local batch companion. Shares the app's protected loader and converters.
use pdf_core::{
    conversion,
    loader::{self, OpenResult},
};
use std::collections::{BTreeSet, HashMap};
use std::path::{Path, PathBuf};
use std::sync::{
    Arc,
    atomic::{AtomicBool, Ordering},
};
use std::time::{Duration, SystemTime};

type Result<T> = std::result::Result<T, Box<dyn std::error::Error>>;

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.is_empty() || matches!(args[0].as_str(), "--help" | "-h") {
        println!(
            "pdfviewer-cli text INPUT.pdf OUTPUT.txt\npdfviewer-cli images OUTPUT.pdf IMAGE…\npdfviewer-cli batch KIND INPUT_FOLDER OUTPUT_FOLDER [--dpi 72..300]\npdfviewer-cli watch KIND INPUT_FOLDER OUTPUT_FOLDER [--dpi 72..300]\n\nKIND: text, png, jpeg, tiff, ocr, images\nWatch waits for files to settle and skips existing output. Ctrl-C cancels.\nPassword-protected PDFs must be opened in the app. Source files are never changed."
        );
        return Ok(());
    }
    let cancel = Arc::new(AtomicBool::new(false));
    let signal = Arc::clone(&cancel);
    ctrlc::set_handler(move || signal.store(true, Ordering::Relaxed))?;
    match args[0].as_str() {
        "text" if args.len() == 3 => {
            let session = open(Path::new(&args[1]))?;
            if !session.security.allows_content_copying() {
                return Err("This PDF doesn't allow text copying.".into());
            }
            let pages = (0..session.editor.page_count()).collect();
            let text = conversion::searchable_text(&session.editor.pdf_data(), &pages)?;
            write_new(text.as_bytes(), Path::new(&args[2]))?;
        }
        "images" if args.len() >= 3 => {
            let images: Vec<_> = args[2..].iter().map(PathBuf::from).collect();
            let bytes = conversion::pdf_from_images(&images)?;
            write_pdf(&bytes, Path::new(&args[1]))?;
        }
        "batch" | "watch" if args.len() == 4 || args.len() == 6 => {
            let kind = args[1].as_str();
            if !matches!(kind, "text" | "png" | "jpeg" | "tiff" | "ocr" | "images") {
                return Err("Choose text, png, jpeg, tiff, ocr or images.".into());
            }
            let input = std::fs::canonicalize(&args[2])?;
            if !input.is_dir() {
                return Err("Choose an input folder.".into());
            }
            std::fs::create_dir_all(&args[3])?;
            let output = std::fs::canonicalize(&args[3])?;
            if input == output {
                return Err("Choose separate input and output folders.".into());
            }
            let dpi = if args.len() == 6 {
                if args[4] != "--dpi" {
                    return Err("Expected --dpi 72..300.".into());
                }
                args[5].parse::<u32>()?
            } else {
                144
            };
            if !(72..=300).contains(&dpi) {
                return Err("Choose a resolution from 72 to 300 DPI.".into());
            }
            let watch = args[0] == "watch";
            let mut seen = HashMap::new();
            let mut stable = HashMap::new();
            loop {
                let mut failed = false;
                for path in inputs(&input, kind)? {
                    if cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    let stamp = stamp(&path)?;
                    if seen.get(&path) == Some(&stamp) {
                        continue;
                    }
                    if watch && stable.insert(path.clone(), stamp) != Some(stamp) {
                        continue;
                    }
                    match process(kind, &path, &output, dpi, &cancel) {
                        Ok(written) => {
                            println!(
                                "{}: {}",
                                path.display(),
                                if written {
                                    "done"
                                } else {
                                    "output already exists; skipped"
                                }
                            );
                        }
                        Err(error) => {
                            failed = true;
                            eprintln!("{}: {error}", path.display());
                        }
                    }
                    seen.insert(path, stamp);
                }
                if !watch {
                    if failed {
                        return Err(
                            "Some files could not be processed; see the messages above.".into()
                        );
                    }
                    break;
                }
                if cancel.load(Ordering::Relaxed) {
                    break;
                }
                // Bounded sleep keeps cancellation responsive; no external watcher process.
                for _ in 0..10 {
                    if cancel.load(Ordering::Relaxed) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(100));
                }
            }
        }
        _ => return Err("Invalid arguments. Run pdfviewer-cli --help.".into()),
    }
    Ok(())
}

fn open(path: &Path) -> Result<pdf_core::DocumentSession> {
    match loader::open(path)? {
        OpenResult::Opened(session) => Ok(session),
        OpenResult::PasswordRequired(_) => {
            Err("Open this protected PDF in the app to enter its password.".into())
        }
    }
}

fn inputs(directory: &Path, kind: &str) -> Result<Vec<PathBuf>> {
    let mut files = Vec::new();
    for entry in std::fs::read_dir(directory)? {
        let path = entry?.path();
        if !path.is_file() {
            continue;
        }
        let extension = path
            .extension()
            .and_then(|e| e.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if (kind == "images" && conversion::IMAGE_EXTENSIONS.contains(&extension.as_str()))
            || (kind != "images" && extension == "pdf")
        {
            files.push(path);
        }
    }
    files.sort();
    Ok(files)
}

fn stamp(path: &Path) -> Result<(u64, SystemTime)> {
    let metadata = std::fs::metadata(path)?;
    Ok((metadata.len(), metadata.modified()?))
}

fn process(kind: &str, input: &Path, output: &Path, dpi: u32, cancel: &AtomicBool) -> Result<bool> {
    let stem = conversion::safe_filename_component(
        input
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("Document"),
        "Document",
    );
    let extension = match kind {
        "text" => "txt",
        "images" | "ocr" => "pdf",
        "jpeg" => "jpg",
        other => other,
    };
    let destination = output.join(format!("{stem}.{extension}"));
    if matches!(kind, "text" | "ocr" | "images") && destination.exists() {
        return Ok(false);
    }
    if kind == "images" {
        write_pdf(
            &conversion::pdf_from_images(&[input.to_path_buf()])?,
            &destination,
        )?;
        return Ok(true);
    }
    let session = open(input)?;
    let pages: BTreeSet<_> = (0..session.editor.page_count()).collect();
    let bytes = session.editor.pdf_data();
    match kind {
        "text" => {
            if !session.security.allows_content_copying() {
                return Err("This PDF doesn't allow copying.".into());
            }
            write_new(
                conversion::searchable_text(&bytes, &pages)?.as_bytes(),
                &destination,
            )?;
        }
        "ocr" => {
            if !session.security.allows_document_changes() {
                return Err("This PDF doesn't allow document changes.".into());
            }
            let options = pdf_ocr::OcrOptions {
                pages,
                searchable_text: true,
                enhancement: pdf_ocr::Enhancement::None,
                quality: pdf_ocr::RasterQuality::Balanced,
                language: pdf_ocr::Language::Automatic,
                minimum_confidence: 0.3,
                crop_margins_percent: 0.0,
                split_double_pages: false,
            };
            let result = pdf_ocr::process(&bytes, &options, cancel, |p| {
                eprintln!("{}: OCR {}/{}", input.display(), p.completed, p.total)
            })?;
            let protection = match session.session_password() {
                Some(password) => pdf_core::export::Protection::ReuseSessionPassword {
                    password: password.to_owned(),
                    permissions: session.security.permissions,
                },
                None => pdf_core::export::Protection::None,
            };
            // Reserve output before export to prevent replacement of an existing file.
            let reservation = std::fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&destination)?;
            if let Err(error) = pdf_core::export::export(
                &result.pdf_data,
                input,
                &destination,
                &protection,
                Default::default(),
            ) {
                drop(reservation);
                let _ = std::fs::remove_file(&destination);
                return Err(error.into());
            }
        }
        _ => {
            if !session.security.allows_content_copying() {
                return Err("This PDF doesn't allow copying.".into());
            }
            let format = match kind {
                "png" => conversion::ImageFormat::Png,
                "jpeg" => conversion::ImageFormat::Jpeg,
                _ => conversion::ImageFormat::Tiff,
            };
            let directory = output.join(&stem);
            if directory.exists() {
                return Ok(false);
            }
            let files = conversion::image_files(&bytes, &pages, format, dpi, &stem)?;
            if cancel.load(Ordering::Relaxed) {
                return Err("Cancelled.".into());
            }
            std::fs::create_dir(&directory)?;
            if let Err(error) = conversion::write_image_files(&files, &directory) {
                let _ = std::fs::remove_dir(&directory);
                return Err(error.into());
            }
        }
    }
    Ok(true)
}

fn write_pdf(bytes: &[u8], destination: &Path) -> Result<()> {
    if !destination
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("pdf"))
    {
        return Err("Choose an output ending in .pdf.".into());
    }
    pdf_core::editor::validated_page_count(bytes)?;
    write_new(bytes, destination)
}

fn write_new(bytes: &[u8], destination: &Path) -> Result<()> {
    let parent = destination
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    std::fs::create_dir_all(parent)?;
    let mut staged = tempfile::NamedTempFile::new_in(parent)?;
    use std::io::Write;
    staged.write_all(bytes)?;
    staged.persist_noclobber(destination)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn batch_preserves_inputs_and_never_overwrites() {
        let directory = tempfile::tempdir().unwrap();
        let source = directory.path().join("input.pdf");
        let output = directory.path().join("out");
        std::fs::create_dir(&output).unwrap();
        let bytes = pdf_core::testing::text_pdf(&["batch document"]);
        std::fs::write(&source, &bytes).unwrap();
        assert!(process("text", &source, &output, 144, &AtomicBool::new(false)).unwrap());
        assert!(!process("text", &source, &output, 144, &AtomicBool::new(false)).unwrap());
        assert_eq!(std::fs::read(&source).unwrap(), bytes);
        assert!(
            std::fs::read_to_string(output.join("input.txt"))
                .unwrap()
                .contains("batch document")
        );
    }
}
