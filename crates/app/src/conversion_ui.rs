//! The Local Conversion sheet: PDF to images or text, images to PDF, and
//! optional Office to PDF through a user-installed LibreOffice.

use std::collections::BTreeSet;
use std::path::Path;

use egui::{RichText, Ui};
use pdf_core::conversion::ImageFormat;

use crate::theme::mocha;

#[derive(Clone, Copy, PartialEq, Eq)]
enum Mode {
    Images,
    Text,
    CreatePdf,
    Office,
}

impl Mode {
    const ALL: [Self; 4] = [Self::Images, Self::Text, Self::CreatePdf, Self::Office];

    fn title(self) -> &'static str {
        match self {
            Self::Images => "PDF to Images",
            Self::Text => "PDF to Text",
            Self::CreatePdf => "Images to PDF",
            Self::Office => "Office to PDF",
        }
    }
}

const DPI_CHOICES: [u32; 3] = [72, 144, 300];

pub struct ConversionSheet {
    /// The document converted from, if one is open.
    pub tab: Option<u64>,
    mode: Mode,
    all_pages: bool,
    format: ImageFormat,
    dpi: u32,
}

pub enum ConversionOutcome {
    Open,
    Cancel,
    ExportImages { pages: BTreeSet<usize>, format: ImageFormat, dpi: u32 },
    ExportText { pages: BTreeSet<usize> },
    CreatePdf,
    ChooseSoffice,
    ForgetSoffice,
    ConvertOffice,
}

impl ConversionSheet {
    pub fn new(tab: Option<u64>) -> Self {
        Self {
            tab,
            mode: if tab.is_some() { Mode::Images } else { Mode::CreatePdf },
            all_pages: false,
            format: ImageFormat::Png,
            dpi: 144,
        }
    }

    /// Reopens on the Office tab after choosing or forgetting `soffice`.
    pub fn office(tab: Option<u64>) -> Self {
        Self { mode: Mode::Office, ..Self::new(tab) }
    }

    /// `document` is the selected pages and page count of `tab`, and whether
    /// its permissions allow copying content.
    pub fn show(&mut self, ui: &mut Ui, document: Option<(Vec<usize>, usize, bool)>, soffice: Option<&Path>) -> ConversionOutcome {
        ui.set_width(560.0);
        let mut outcome = ConversionOutcome::Open;
        ui.heading("Local Conversion");
        ui.weak("Conversion runs entirely on this Mac. The source PDF and imported images are never uploaded or overwritten.");
        ui.separator();
        ui.horizontal(|ui| {
            for mode in Mode::ALL {
                let needs_document = matches!(mode, Mode::Images | Mode::Text);
                ui.add_enabled_ui(!needs_document || document.is_some(), |ui| {
                    ui.selectable_value(&mut self.mode, mode, mode.title());
                });
            }
        });
        ui.add_space(8.0);
        let pages = document.as_ref().map(|(selected, count, _)| -> BTreeSet<usize> {
            if self.all_pages { (0..*count).collect() } else { selected.iter().copied().collect() }
        });
        let may_copy = document.as_ref().is_some_and(|(_, _, may_copy)| *may_copy);
        ui.allocate_ui(egui::vec2(ui.available_width(), 200.0), |ui| {
            ui.set_min_height(200.0);
            match self.mode {
                Mode::Images | Mode::Text => {
                    let Some(pages) = &pages else { return };
                    egui::Grid::new("conversion-settings").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                        ui.label("Pages");
                        ui.horizontal(|ui| {
                            ui.selectable_value(&mut self.all_pages, false, "Selected Pages");
                            ui.selectable_value(&mut self.all_pages, true, "All Pages");
                            ui.weak(format!("{} {}", pages.len(), if pages.len() == 1 { "page" } else { "pages" }));
                        });
                        ui.end_row();
                        if self.mode == Mode::Images {
                            ui.label("Image Format");
                            ui.horizontal(|ui| {
                                for format in ImageFormat::ALL {
                                    ui.selectable_value(&mut self.format, format, format.title());
                                }
                            });
                            ui.end_row();
                            ui.label("Resolution");
                            ui.horizontal(|ui| {
                                for dpi in DPI_CHOICES {
                                    ui.selectable_value(&mut self.dpi, dpi, format!("{dpi} DPI"));
                                }
                            });
                            ui.end_row();
                        }
                    });
                    ui.add_space(6.0);
                    ui.weak(if self.mode == Mode::Images {
                        "Each selected page is rendered into a separate image. Existing visible annotations are included in the rendering. Existing files are never overwritten."
                    } else {
                        "Exports searchable text in UTF-8 with page separators. Image-only pages need local OCR first."
                    });
                    if !may_copy {
                        ui.add_space(6.0);
                        ui.label(RichText::new("⚠ This PDF's permissions don't allow copying its content.").color(mocha::YELLOW));
                    }
                }
                Mode::CreatePdf => {
                    ui.strong("Create a New PDF From Images");
                    ui.label("Choose up to 500 PNG, JPEG, HEIC, or TIFF images. Their selection order becomes the PDF page order, and the image files remain unchanged.");
                    ui.add_space(6.0);
                    if ui.button(RichText::new("Choose Images…").strong()).clicked() {
                        outcome = ConversionOutcome::CreatePdf;
                    }
                }
                Mode::Office => {
                    ui.strong("Optional User-Installed LibreOffice");
                    ui.label(
                        "PDFViewer does not bundle or download LibreOffice. A separate helper process receives only the soffice executable and the document you choose, converts into a fresh private folder, and returns a PDF that is validated before you save it.",
                    );
                    ui.add_space(6.0);
                    ui.horizontal(|ui| {
                        let title = if soffice.is_some() { "Change soffice Executable…" } else { "Choose soffice Executable…" };
                        if ui.button(title).clicked() {
                            outcome = ConversionOutcome::ChooseSoffice;
                        }
                        if soffice.is_some() && ui.button(RichText::new("Forget").color(mocha::RED)).clicked() {
                            outcome = ConversionOutcome::ForgetSoffice;
                        }
                    });
                    if let Some(path) = soffice {
                        ui.label(RichText::new(format!("✔ {}", path.display())).color(mocha::SUBTEXT0));
                    }
                    ui.add_space(6.0);
                    if ui.add_enabled(soffice.is_some(), egui::Button::new(RichText::new("Convert Office Document…").strong())).clicked() {
                        outcome = ConversionOutcome::ConvertOffice;
                    }
                }
            }
        });
        ui.separator();
        ui.horizontal(|ui| {
            if ui.button("Cancel").clicked() || ui.input(|input| input.key_pressed(egui::Key::Escape)) {
                outcome = ConversionOutcome::Cancel;
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let Some(pages) = pages else { return };
                let ready = may_copy && !pages.is_empty();
                match self.mode {
                    Mode::Images => {
                        if ui.add_enabled(ready, egui::Button::new(RichText::new("Export Images…").strong())).clicked() {
                            outcome = ConversionOutcome::ExportImages { pages, format: self.format, dpi: self.dpi };
                        }
                    }
                    Mode::Text => {
                        if ui.add_enabled(ready, egui::Button::new(RichText::new("Export Text…").strong())).clicked() {
                            outcome = ConversionOutcome::ExportText { pages };
                        }
                    }
                    Mode::CreatePdf | Mode::Office => {}
                }
            });
        });
        outcome
    }
}
