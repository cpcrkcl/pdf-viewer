//! The OCR & Scan Enhancement sheet and its live before/after preview.

use std::sync::Arc;
use std::sync::mpsc::{Receiver, TryRecvError, channel};

use egui::{Color32, RichText, TextureHandle, Ui};
use pdf_ocr::{Enhancement, Language, OcrError, OcrOptions, Preview, RasterQuality};

use crate::theme;

const CROP_CHOICES: [(f32, &str); 4] = [(0.0, "None"), (2.0, "2% per edge"), (5.0, "5% per edge"), (10.0, "10% per edge")];

type PreviewKey = (usize, Enhancement, u32);

pub struct OcrSheet {
    pub tab: u64,
    all_pages: bool,
    searchable_text: bool,
    enhancement: Enhancement,
    quality: RasterQuality,
    language: Language,
    minimum_confidence: f32,
    crop_margins_percent: f32,
    split_double_pages: bool,
    preview_key: Option<PreviewKey>,
    preview_job: Option<Receiver<Result<Preview, OcrError>>>,
    preview: Result<Option<(TextureHandle, TextureHandle)>, String>,
}

pub enum SheetOutcome {
    Open,
    Cancel,
    Start(OcrOptions),
}

impl OcrSheet {
    pub fn new(tab: u64) -> Self {
        Self {
            tab,
            all_pages: false,
            searchable_text: true,
            enhancement: Enhancement::CleanScan,
            quality: RasterQuality::Balanced,
            language: Language::Automatic,
            minimum_confidence: 0.5,
            crop_margins_percent: 0.0,
            split_double_pages: false,
            preview_key: None,
            preview_job: None,
            preview: Ok(None),
        }
    }

    fn options(&self, pages: &[usize]) -> OcrOptions {
        OcrOptions {
            pages: pages.iter().copied().collect(),
            searchable_text: self.searchable_text,
            enhancement: self.enhancement,
            quality: self.quality,
            language: self.language,
            minimum_confidence: self.minimum_confidence,
            crop_margins_percent: self.crop_margins_percent,
            split_double_pages: self.split_double_pages,
        }
    }

    /// Starts a new preview when its inputs change and collects finished ones.
    fn update_preview(&mut self, ctx: &egui::Context, data: &Arc<Vec<u8>>, page: Option<usize>) {
        let Some(page) = page else {
            self.preview = Err("Select a page to preview.".into());
            self.preview_key = None;
            return;
        };
        let key = (page, self.enhancement, (self.crop_margins_percent * 100.0) as u32);
        if self.preview_key != Some(key) {
            self.preview_key = Some(key);
            self.preview = Ok(None);
            let (sender, receiver) = channel();
            let (data, enhancement, crop) = (Arc::clone(data), self.enhancement, self.crop_margins_percent);
            std::thread::spawn(move || {
                let _ = sender.send(pdf_ocr::preview(&data, page, enhancement, crop));
            });
            // Replacing the receiver drops any stale result.
            self.preview_job = Some(receiver);
        }
        let Some(receiver) = &self.preview_job else { return };
        match receiver.try_recv() {
            Err(TryRecvError::Empty) => ctx.request_repaint_after(std::time::Duration::from_millis(60)),
            Err(TryRecvError::Disconnected) => {
                self.preview_job = None;
                self.preview = Err("The preview could not be generated.".into());
            }
            Ok(result) => {
                self.preview_job = None;
                self.preview = result
                    .map(|preview| {
                        let original = texture(ctx, "ocr-before", &image::DynamicImage::ImageRgb8(preview.original));
                        let processed = texture(ctx, "ocr-after", &preview.processed);
                        Some((original, processed))
                    })
                    .map_err(|error| error.to_string());
            }
        }
    }

    pub fn show(&mut self, ui: &mut Ui, data: &Arc<Vec<u8>>, selected: &[usize], page_count: usize) -> SheetOutcome {
        ui.set_width(540.0);
        let pages: Vec<usize> = if self.all_pages { (0..page_count).collect() } else { selected.to_vec() };
        self.update_preview(ui.ctx(), data, pages.first().copied());
        let mut outcome = SheetOutcome::Open;

        ui.heading("OCR & Scan Enhancement");
        ui.weak("Runs entirely on this Mac. Pages and recognized text are never uploaded.");
        ui.separator();
        egui::ScrollArea::vertical().max_height(ui.ctx().content_rect().height() * 0.6).show(ui, |ui| {
            egui::Grid::new("ocr-settings").num_columns(2).spacing([12.0, 8.0]).show(ui, |ui| {
                ui.label("Pages");
                ui.horizontal(|ui| {
                    ui.selectable_value(&mut self.all_pages, false, "Selected Pages");
                    ui.selectable_value(&mut self.all_pages, true, "All Pages");
                    let count = pages.len();
                    ui.weak(format!("{count} {} will be processed.", if count == 1 { "page" } else { "pages" }));
                });
                ui.end_row();

                ui.label("Text");
                ui.checkbox(&mut self.searchable_text, "Add searchable text with local OCR");
                ui.end_row();

                ui.label("OCR Language");
                ui.add_enabled_ui(self.searchable_text, |ui| {
                    egui::ComboBox::from_id_salt("ocr-language").selected_text(self.language.title()).show_ui(ui, |ui| {
                        for language in Language::ALL {
                            ui.selectable_value(&mut self.language, language, language.title());
                        }
                    });
                });
                ui.end_row();

                ui.label("Minimum Confidence");
                ui.add_enabled_ui(self.searchable_text, |ui| {
                    ui.vertical(|ui| {
                        ui.add(egui::Slider::new(&mut self.minimum_confidence, 0.0..=1.0).step_by(0.05).custom_formatter(|value, _| format!("{:.0}%", value * 100.0)));
                        ui.weak("Lower keeps more uncertain text; higher reduces false positives.");
                    });
                });
                ui.end_row();

                ui.label("Scan Appearance");
                ui.vertical(|ui| {
                    egui::ComboBox::from_id_salt("ocr-enhancement").selected_text(self.enhancement.title()).show_ui(ui, |ui| {
                        for preset in Enhancement::ALL {
                            ui.selectable_value(&mut self.enhancement, preset, preset.title());
                        }
                    });
                    ui.weak(self.enhancement.summary());
                });
                ui.end_row();

                ui.label("Raster Quality");
                ui.vertical(|ui| {
                    egui::ComboBox::from_id_salt("ocr-quality").selected_text(self.quality.title()).show_ui(ui, |ui| {
                        for quality in RasterQuality::ALL {
                            ui.selectable_value(&mut self.quality, quality, quality.title());
                        }
                    });
                    ui.weak("Higher DPI improves fine text recognition but uses more memory and produces larger files.");
                });
                ui.end_row();

                ui.label("Crop Margins");
                ui.vertical(|ui| {
                    let current = CROP_CHOICES.iter().find(|(value, _)| *value == self.crop_margins_percent).map_or("Custom", |(_, title)| title);
                    egui::ComboBox::from_id_salt("ocr-crop").selected_text(current).show_ui(ui, |ui| {
                        for (value, title) in CROP_CHOICES {
                            ui.selectable_value(&mut self.crop_margins_percent, value, title);
                        }
                    });
                    ui.weak("Removes the chosen percentage from every edge of each processed page.");
                });
                ui.end_row();

                ui.label("Double Pages");
                ui.vertical(|ui| {
                    ui.checkbox(&mut self.split_double_pages, "Split wide double-page scans into left and right pages");
                    ui.weak("Only pages at least 30% wider than they are tall are split. Left pages remain before right pages.");
                });
                ui.end_row();
            });
            ui.add_space(6.0);
            ui.label(
                RichText::new(
                    "ⓘ Processed pages are rasterized at high resolution. Existing form fields and annotations on those pages become part of the page image. The operation is undoable before export.",
                )
                .color(theme::colors().muted),
            );
        });

        ui.separator();
        ui.horizontal(|ui| {
            ui.strong("Before / After Preview");
            if let Some(page) = pages.first() {
                ui.weak(format!("Page {}", page + 1));
            }
        });
        let height = 170.0;
        match &self.preview {
            Ok(Some((before, after))) => {
                ui.columns(2, |columns| {
                    for (column, (title, texture)) in columns.iter_mut().zip([("Before", before), ("After", after)]) {
                        column.vertical_centered(|ui| {
                            ui.label(RichText::new(title).small().strong());
                            let size = texture.size_vec2();
                            let scale = (height / size.y).min(ui.available_width() / size.x);
                            ui.add(egui::Image::new(texture).fit_to_exact_size(size * scale).bg_fill(Color32::WHITE));
                        });
                    }
                });
            }
            Ok(None) => {
                ui.horizontal(|ui| {
                    ui.set_min_height(height);
                    ui.spinner();
                    ui.weak("Preparing local preview…");
                });
            }
            Err(message) => {
                ui.horizontal(|ui| {
                    ui.set_min_height(height);
                    ui.label(RichText::new(format!("⚠ {message}")).color(theme::colors().warning));
                });
            }
        }

        ui.separator();
        ui.horizontal(|ui| {
            if ui.button("Cancel").clicked() || ui.input(|input| input.key_pressed(egui::Key::Escape)) {
                outcome = SheetOutcome::Cancel;
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                let options = self.options(&pages);
                let ready = !pages.is_empty() && options.has_work();
                if ui.add_enabled(ready, theme::primary("Process Locally")).clicked() {
                    outcome = SheetOutcome::Start(options);
                }
            });
        });
        outcome
    }
}

fn texture(ctx: &egui::Context, name: &str, image: &image::DynamicImage) -> TextureHandle {
    let rgba = image.to_rgba8();
    let size = [rgba.width() as usize, rgba.height() as usize];
    ctx.load_texture(name, egui::ColorImage::from_rgba_unmultiplied(size, rgba.as_raw()), egui::TextureOptions::LINEAR)
}
