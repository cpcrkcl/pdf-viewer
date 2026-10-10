//! Visual signature and custom stamp libraries.

use std::collections::HashMap;

use egui::{Color32, CornerRadius, Pos2, Rect, Sense, Shape, Stroke, StrokeKind, TextureHandle, Ui, vec2};
use pdf_core::signatures::{SignatureLibrary, StoredSignature};
use uuid::Uuid;

use crate::theme;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LibraryKind {
    Signatures,
    Stamps,
}

impl LibraryKind {
    fn title(self) -> &'static str {
        match self {
            Self::Signatures => "Visual Signatures",
            Self::Stamps => "Custom Stamps",
        }
    }
}

pub struct LibraryDialog {
    pub kind: LibraryKind,
    drawing: Option<Drawing>,
}

struct Drawing {
    strokes: Vec<Vec<(f32, f32)>>,
    name: String,
}

pub enum LibraryOutcome {
    Open,
    Close,
    Chose(Uuid),
    Error(String),
}

const CANVAS: (f32, f32) = (420.0, 150.0);

impl LibraryDialog {
    pub fn new(kind: LibraryKind) -> Self {
        Self { kind, drawing: None }
    }

    pub fn show(
        &mut self,
        ui: &mut Ui,
        library: &mut SignatureLibrary,
        thumbnails: &mut HashMap<Uuid, Option<TextureHandle>>,
    ) -> LibraryOutcome {
        ui.heading(self.kind.title());
        ui.weak("Stored only on this Mac. Visual signatures are images, not certificate-backed digital signatures.");
        ui.add_space(6.0);

        if let Some(drawing) = &mut self.drawing {
            let (outcome, finished) = draw_signature(ui, drawing, library);
            if finished {
                self.drawing = None;
            }
            return outcome;
        }

        let mut outcome = LibraryOutcome::Open;
        let entries: Vec<StoredSignature> = library.signatures().to_vec();
        if entries.is_empty() {
            ui.weak("Nothing saved yet.");
        }
        egui::ScrollArea::vertical().max_height(300.0).show(ui, |ui| {
            for entry in &entries {
                ui.horizontal(|ui| {
                    let texture = thumbnails
                        .entry(entry.id)
                        .or_insert_with(|| load_thumbnail(ui.ctx(), library, entry))
                        .clone();
                    let (rect, _) = ui.allocate_exact_size(vec2(96.0, 36.0), Sense::hover());
                    ui.painter().rect_filled(rect, CornerRadius::same(3), Color32::WHITE);
                    if let Some(texture) = texture {
                        let size = texture.size_vec2();
                        let scale = (rect.width() / size.x).min(rect.height() / size.y);
                        let image_rect = Rect::from_center_size(rect.center(), size * scale);
                        ui.painter().image(texture.id(), image_rect, Rect::from_min_max(Pos2::ZERO, Pos2::new(1.0, 1.0)), Color32::WHITE);
                    }
                    ui.label(&entry.display_name);
                    ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                        if ui.small_button("Delete").clicked() {
                            match library.delete(entry.id) {
                                Ok(()) => {
                                    thumbnails.remove(&entry.id);
                                }
                                Err(error) => outcome = LibraryOutcome::Error(error.to_string()),
                            }
                        }
                        if ui.button("Use").clicked() {
                            outcome = LibraryOutcome::Chose(entry.id);
                        }
                    });
                });
            }
        });
        ui.separator();
        ui.horizontal(|ui| {
            if ui.button("Import Image…").clicked()
                && let Some(path) = rfd::FileDialog::new().add_filter("Image", &["png", "jpg", "jpeg"]).pick_file()
            {
                let name = path.file_stem().map(|stem| stem.to_string_lossy().into_owned()).unwrap_or_default();
                match std::fs::read(&path).map_err(|error| error.to_string()).and_then(|data| {
                    library.import_image(&data, &name).map_err(|error| error.to_string())
                }) {
                    Ok(stored) => outcome = LibraryOutcome::Chose(stored.id),
                    Err(message) => outcome = LibraryOutcome::Error(message),
                }
            }
            if self.kind == LibraryKind::Signatures && ui.button("Draw…").clicked() {
                self.drawing = Some(Drawing { strokes: Vec::new(), name: String::new() });
            }
            ui.with_layout(egui::Layout::right_to_left(egui::Align::Center), |ui| {
                if ui.button("Done").clicked() {
                    outcome = LibraryOutcome::Close;
                }
            });
        });
        outcome
    }
}

/// Returns the outcome and whether drawing mode should end.
fn draw_signature(ui: &mut Ui, drawing: &mut Drawing, library: &mut SignatureLibrary) -> (LibraryOutcome, bool) {
    ui.label("Sign with the trackpad or mouse:");
    let (rect, response) = ui.allocate_exact_size(vec2(CANVAS.0, CANVAS.1), Sense::drag());
    let painter = ui.painter_at(rect);
    painter.rect_filled(rect, CornerRadius::same(4), Color32::WHITE);
    painter.line_segment(
        [rect.left_bottom() + vec2(16.0, -28.0), rect.right_bottom() + vec2(-16.0, -28.0)],
        Stroke::new(1.0, Color32::from_gray(200)),
    );
    if response.drag_started() {
        drawing.strokes.push(Vec::new());
    }
    if response.dragged()
        && let Some(position) = response.interact_pointer_pos()
        && let Some(stroke) = drawing.strokes.last_mut()
    {
        let local = position - rect.min;
        stroke.push((local.x.clamp(0.0, CANVAS.0), local.y.clamp(0.0, CANVAS.1)));
    }
    for stroke in &drawing.strokes {
        let points: Vec<Pos2> = stroke.iter().map(|(x, y)| rect.min + vec2(*x, *y)).collect();
        painter.add(Shape::line(points, Stroke::new(3.0, Color32::BLACK)));
    }
    painter.rect_stroke(rect, CornerRadius::same(4), Stroke::new(1.0, theme::colors().hairline), StrokeKind::Outside);
    ui.horizontal(|ui| {
        ui.label("Name");
        ui.text_edit_singleline(&mut drawing.name);
    });
    let mut outcome = LibraryOutcome::Open;
    let mut finished = false;
    ui.horizontal(|ui| {
        if ui.button("Clear").clicked() {
            drawing.strokes.clear();
        }
        if ui.button("Cancel").clicked() {
            finished = true;
        }
        if ui.add_enabled(drawing.strokes.iter().any(|s| s.len() >= 2), theme::primary("Save")).clicked() {
            outcome = match library.create_from_drawing(&drawing.strokes, CANVAS, &drawing.name) {
                Ok(stored) => LibraryOutcome::Chose(stored.id),
                Err(error) => LibraryOutcome::Error(error.to_string()),
            };
            finished = true;
        }
    });
    (outcome, finished)
}

fn load_thumbnail(ctx: &egui::Context, library: &SignatureLibrary, entry: &StoredSignature) -> Option<TextureHandle> {
    let data = library.image_data(entry.id).ok()?;
    let image = image::load_from_memory(&data).ok()?.thumbnail(192, 72).to_rgba8();
    let size = [image.width() as usize, image.height() as usize];
    let color_image = egui::ColorImage::from_rgba_unmultiplied(size, image.as_raw());
    Some(ctx.load_texture(format!("signature-{}", entry.id), color_image, egui::TextureOptions::LINEAR))
}
