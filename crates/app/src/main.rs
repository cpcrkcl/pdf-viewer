#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod annotation_ui;
mod app;
mod commands;
mod conversion_ui;
mod debug_capture;
mod document_tab;
mod fonts;
mod forms_ui;
mod icons;
mod interaction;
mod libraries_ui;
#[cfg(target_os = "macos")]
mod macos;
#[cfg(target_os = "macos")]
mod native;
mod ocr_ui;
mod palette;
mod reader_state;
mod reader_view;
mod redaction_ui;
mod render;
mod session;
mod sidebar;
mod theme;

use std::path::PathBuf;

fn main() -> eframe::Result {
    let initial_paths: Vec<PathBuf> = std::env::args_os()
        .skip(1)
        .map(PathBuf::from)
        .filter(|path| {
            path.extension()
                .is_some_and(|extension| extension.eq_ignore_ascii_case("pdf"))
        })
        .collect();

    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("PDFViewer")
            .with_app_id("com.pdfviewer.app")
            .with_inner_size([1180.0, 820.0])
            .with_min_inner_size([640.0, 420.0])
            .with_drag_and_drop(true)
            // The toolbar draws into the title bar, beside the window buttons.
            .with_fullsize_content_view(true)
            .with_titlebar_shown(false)
            .with_title_shown(false),
        ..Default::default()
    };
    let creator: eframe::AppCreator<'static> =
        Box::new(move |cc| Ok(Box::new(app::PdfViewerApp::new(cc, initial_paths))));
    #[cfg(target_os = "macos")]
    {
        // Our own event loop lets the app delegate learn Finder open and
        // quit events before launch finishes (see `native.rs`).
        let event_loop =
            winit::event_loop::EventLoop::<eframe::UserEvent>::with_user_event().build()?;
        native::extend_app_delegate();
        let mut app = eframe::create_native("PDFViewer", options, creator, &event_loop);
        event_loop.run_app(&mut app)?;
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    eframe::run_native("PDFViewer", options, creator)
}
