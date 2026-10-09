#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod annotation_ui;
mod app;
mod debug_capture;
mod document_tab;
mod fonts;
mod forms_ui;
mod interaction;
mod libraries_ui;
#[cfg(target_os = "macos")]
mod macos;
mod reader_state;
mod reader_view;
mod redaction_ui;
mod render;
mod sidebar;
mod theme;

use std::path::PathBuf;

fn main() -> eframe::Result {
    let initial_paths: Vec<PathBuf> = std::env::args_os()
        .skip(1)
        .map(PathBuf::from)
        .filter(|path| path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("pdf")))
        .collect();

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("PDFViewer")
            .with_app_id("com.pdfviewer.app")
            .with_inner_size([1180.0, 820.0])
            .with_min_inner_size([640.0, 420.0])
            .with_drag_and_drop(true),
        ..Default::default()
    };
    eframe::run_native(
        "PDFViewer",
        options,
        Box::new(move |cc| Ok(Box::new(app::PdfViewerApp::new(cc, initial_paths)))),
    )
}
