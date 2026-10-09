//! `PDFVIEWER_CAPTURE=/path.png` saves one screenshot of the app window once
//! rendering settles, then quits. Used for local visual checks without
//! capturing anything else on screen.

use std::path::PathBuf;

pub struct DebugCapture {
    path: PathBuf,
    frames: u32,
    requested: bool,
    /// `PDFVIEWER_CAPTURE_SEARCH`: a query to run in the first document.
    pub search: Option<String>,
    /// `PDFVIEWER_CAPTURE_ROTATE=1`: rotate the first page before capturing.
    pub rotate: bool,
}

impl DebugCapture {
    pub fn from_env() -> Option<Self> {
        std::env::var_os("PDFVIEWER_CAPTURE").map(|path| Self {
            path: PathBuf::from(path),
            frames: 0,
            requested: false,
            search: std::env::var("PDFVIEWER_CAPTURE_SEARCH").ok(),
            rotate: std::env::var_os("PDFVIEWER_CAPTURE_ROTATE").is_some(),
        })
    }

    pub fn tick(&mut self, ctx: &egui::Context) {
        self.frames += 1;
        let delay = std::env::var("PDFVIEWER_CAPTURE_FRAMES").ok().and_then(|v| v.parse().ok()).unwrap_or(90);
        if !self.requested && self.frames >= delay {
            self.requested = true;
            ctx.send_viewport_cmd(egui::ViewportCommand::Screenshot(egui::UserData::default()));
        }
        let image = ctx.input(|input| {
            input.raw.events.iter().find_map(|event| match event {
                egui::Event::Screenshot { image, .. } => Some(image.clone()),
                _ => None,
            })
        });
        if let Some(image) = image {
            let [width, height] = image.size;
            let pixels: Vec<u8> = image.pixels.iter().flat_map(|pixel| pixel.to_array()).collect();
            if let Some(buffer) = image::RgbaImage::from_raw(width as u32, height as u32, pixels) {
                let _ = buffer.save(&self.path);
            }
            std::process::exit(0);
        }
        ctx.request_repaint();
    }
}
