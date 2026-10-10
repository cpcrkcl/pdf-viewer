//! Local OCR and scan enhancement.
//!
//! Selected pages are rendered with their annotations and form data, optionally
//! cropped, split and enhanced, and replaced by that image plus an invisible,
//! searchable text layer from Apple Vision. Unselected pages stay native.
//! Nothing leaves the machine.

pub mod enhance;
mod text_layer;
#[cfg(target_os = "macos")]
pub mod vision;

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};

use image::{DynamicImage, RgbImage};
use lopdf::Object;
use pdf_core::{engine, raster, structure};
use thiserror::Error;

pub use enhance::Enhancement;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum OcrError {
    #[error("Select one or more pages to process.")]
    NoPagesSelected,
    #[error("One of the selected pages is no longer available.")]
    InvalidPageSelection,
    #[error("PDFViewer could not render one of the selected pages for local processing.")]
    CouldNotRenderPage,
    #[error("Local text recognition could not process one of the selected pages.")]
    RecognitionFailed,
    #[error("PDFViewer could not build a validated searchable PDF working copy.")]
    CouldNotBuildSearchablePdf,
    #[error("Choose a crop margin between 0 and 20 percent.")]
    InvalidCropMargins,
    #[error("Processing was cancelled.")]
    Cancelled,
}

/// One recognized line. The box is normalized to the processed image with
/// its origin at the lower-left corner, as Vision reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct RecognizedLine {
    pub text: String,
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
    pub confidence: f32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum RasterQuality {
    Compact,
    #[default]
    Balanced,
    Archival,
}

impl RasterQuality {
    pub const ALL: [Self; 3] = [Self::Compact, Self::Balanced, Self::Archival];

    pub fn dpi(self) -> f32 {
        match self {
            Self::Compact => 150.0,
            Self::Balanced => 200.0,
            Self::Archival => 300.0,
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Compact => "Compact (150 DPI)",
            Self::Balanced => "Balanced (200 DPI)",
            Self::Archival => "Archival (300 DPI)",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Language {
    #[default]
    Automatic,
    EnglishUs,
    Spanish,
    French,
    German,
    Italian,
    Portuguese,
    Japanese,
    Korean,
    ChineseSimplified,
}

impl Language {
    pub const ALL: [Self; 10] = [
        Self::Automatic,
        Self::EnglishUs,
        Self::Spanish,
        Self::French,
        Self::German,
        Self::Italian,
        Self::Portuguese,
        Self::Japanese,
        Self::Korean,
        Self::ChineseSimplified,
    ];

    pub fn code(self) -> Option<&'static str> {
        match self {
            Self::Automatic => None,
            Self::EnglishUs => Some("en-US"),
            Self::Spanish => Some("es-ES"),
            Self::French => Some("fr-FR"),
            Self::German => Some("de-DE"),
            Self::Italian => Some("it-IT"),
            Self::Portuguese => Some("pt-BR"),
            Self::Japanese => Some("ja-JP"),
            Self::Korean => Some("ko-KR"),
            Self::ChineseSimplified => Some("zh-Hans"),
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Automatic => "Automatic",
            Self::EnglishUs => "English (US)",
            Self::Spanish => "Spanish",
            Self::French => "French",
            Self::German => "German",
            Self::Italian => "Italian",
            Self::Portuguese => "Portuguese (Brazil)",
            Self::Japanese => "Japanese",
            Self::Korean => "Korean",
            Self::ChineseSimplified => "Chinese (Simplified)",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct OcrOptions {
    pub pages: BTreeSet<usize>,
    pub searchable_text: bool,
    pub enhancement: Enhancement,
    pub quality: RasterQuality,
    pub language: Language,
    pub minimum_confidence: f32,
    /// Removed from every edge of each processed page, 0–20.
    pub crop_margins_percent: f32,
    /// Splits pages at least 30% wider than tall into left and right halves.
    pub split_double_pages: bool,
}

impl OcrOptions {
    pub fn has_work(&self) -> bool {
        self.searchable_text || self.enhancement != Enhancement::None || self.crop_margins_percent > 0.0 || self.split_double_pages
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OcrProgress {
    pub completed: usize,
    pub total: usize,
}

#[derive(Debug, Clone)]
pub struct OcrResult {
    pub pdf_data: Vec<u8>,
    pub recognized_lines: usize,
    /// For each output page, the input page it came from (for
    /// `DocumentEditor::apply_processed_document`).
    pub source_page_indexes: Vec<usize>,
}

pub struct Preview {
    pub original: RgbImage,
    pub processed: DynamicImage,
}

const PREVIEW_DIMENSION: f32 = 520.0;

fn validate_crop(percent: f32) -> Result<(), OcrError> {
    if percent.is_finite() && (0.0..=20.0).contains(&percent) { Ok(()) } else { Err(OcrError::InvalidCropMargins) }
}

/// Removes `percent` from every edge.
fn crop_margins(image: RgbImage, percent: f32) -> Result<RgbImage, OcrError> {
    if percent <= 0.0 {
        return Ok(image);
    }
    let fraction = percent / 100.0;
    let (width, height) = (image.width() as f32, image.height() as f32);
    let (x, y) = ((width * fraction).round() as u32, (height * fraction).round() as u32);
    let (cropped_width, cropped_height) = (image.width().saturating_sub(2 * x), image.height().saturating_sub(2 * y));
    if cropped_width < 2 || cropped_height < 2 {
        return Err(OcrError::InvalidCropMargins);
    }
    Ok(image::imageops::crop_imm(&image, x, y, cropped_width, cropped_height).to_image())
}

/// Left then right half for wide spreads; otherwise the page itself.
fn split_if_double_page(image: RgbImage) -> Vec<RgbImage> {
    if (image.width() as f32) < image.height() as f32 * 1.3 {
        return vec![image];
    }
    let half = image.width() / 2;
    vec![
        image::imageops::crop_imm(&image, 0, 0, half, image.height()).to_image(),
        image::imageops::crop_imm(&image, half, 0, image.width() - half, image.height()).to_image(),
    ]
}

fn recognize(image: &DynamicImage, options: &OcrOptions) -> Result<Vec<RecognizedLine>, OcrError> {
    if !options.searchable_text {
        return Ok(Vec::new());
    }
    #[cfg(target_os = "macos")]
    {
        objc2::rc::autoreleasepool(|_| vision::recognize_text(image, options.language.code(), options.minimum_confidence))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = image;
        Err(OcrError::RecognitionFailed)
    }
}

/// Processes `options.pages` of `bytes` and returns the new document. Page
/// order is kept; split pages become two consecutive pages.
pub fn process(bytes: &[u8], options: &OcrOptions, cancel: &AtomicBool, mut progress: impl FnMut(OcrProgress)) -> Result<OcrResult, OcrError> {
    if options.pages.is_empty() {
        return Err(OcrError::NoPagesSelected);
    }
    validate_crop(options.crop_margins_percent)?;
    if !(options.minimum_confidence.is_finite() && (0.0..=1.0).contains(&options.minimum_confidence)) {
        return Err(OcrError::RecognitionFailed);
    }
    let infos = pdf_core::text::page_infos(bytes).map_err(|_| OcrError::CouldNotRenderPage)?;
    if options.pages.iter().any(|page| *page >= infos.len()) {
        return Err(OcrError::InvalidPageSelection);
    }

    let mut document = structure::parse(bytes).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?;
    structure::flatten_page_tree(&mut document).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?;
    let page_ids = structure::page_ids(&document);
    if page_ids.len() != infos.len() {
        return Err(OcrError::CouldNotBuildSearchablePdf);
    }
    let rendered = engine::load(bytes.to_vec(), None).map_err(|_| OcrError::CouldNotRenderPage)?;
    let font = options.searchable_text.then(|| text_layer::add_font(&mut document));

    let mut order = Vec::with_capacity(page_ids.len());
    let mut source_page_indexes = Vec::with_capacity(page_ids.len());
    let mut recognized_lines = 0;
    let mut completed = 0;
    for (index, page_id) in page_ids.iter().copied().enumerate() {
        if !options.pages.contains(&index) {
            order.push(page_id);
            source_page_indexes.push(index);
            continue;
        }
        if cancel.load(Ordering::Relaxed) {
            return Err(OcrError::Cancelled);
        }
        let page = raster::render_page(&rendered, index, infos[index].geometry, options.quality.dpi()).map_err(|_| OcrError::CouldNotRenderPage)?;
        let scale = page.scale;
        let pieces = {
            let cropped = crop_margins(page.image, options.crop_margins_percent)?;
            if options.split_double_pages { split_if_double_page(cropped) } else { vec![cropped] }
        };
        // Extra pages start as copies of the original so they have a parent.
        let original = structure::page_dictionary(&document, page_id).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?.clone();
        for (piece_index, piece) in pieces.into_iter().enumerate() {
            if cancel.load(Ordering::Relaxed) {
                return Err(OcrError::Cancelled);
            }
            let size = (piece.width() as f32 / scale, piece.height() as f32 / scale);
            let image = enhance::enhance(DynamicImage::ImageRgb8(piece), options.enhancement);
            let lines = recognize(&image, options)?;
            recognized_lines += lines.len();
            let target = if piece_index == 0 { page_id } else { document.add_object(Object::Dictionary(original.clone())) };
            let image_id = raster::embed_lossless(&mut document, &image);
            let text = font.map(|font| text_layer::content(&lines, size, font));
            raster::replace_page_with_image(&mut document, target, image_id, size, text).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?;
            order.push(target);
            source_page_indexes.push(index);
        }
        completed += 1;
        progress(OcrProgress { completed, total: options.pages.len() });
    }

    structure::set_page_order(&mut document, &order).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?;
    let untouched: Vec<_> = page_ids.iter().enumerate().filter(|(index, _)| !options.pages.contains(index)).map(|(_, id)| *id).collect();
    structure::retain_form_fields_on_pages(&mut document, &untouched);
    document.prune_objects();
    let pdf_data = structure::serialize(&mut document).map_err(|_| OcrError::CouldNotBuildSearchablePdf)?;
    match pdf_core::editor::validated_page_count(&pdf_data) {
        Ok(count) if count == source_page_indexes.len() => {}
        _ => return Err(OcrError::CouldNotBuildSearchablePdf),
    }
    Ok(OcrResult {
        pdf_data,
        recognized_lines,
        source_page_indexes,
    })
}

/// A small before/after rendering of one page for the settings sheet.
pub fn preview(bytes: &[u8], page: usize, enhancement: Enhancement, crop_margins_percent: f32) -> Result<Preview, OcrError> {
    validate_crop(crop_margins_percent)?;
    let infos = pdf_core::text::page_infos(bytes).map_err(|_| OcrError::CouldNotRenderPage)?;
    let info = infos.get(page).ok_or(OcrError::InvalidPageSelection)?;
    let (width, height) = info.geometry.display_size();
    let dpi = 72.0 * (PREVIEW_DIMENSION / width.max(height)).min(1.0);
    let rendered = engine::load(bytes.to_vec(), None).map_err(|_| OcrError::CouldNotRenderPage)?;
    // `render_page` never renders below 72 DPI, so downscale afterwards.
    let page = raster::render_page(&rendered, page, info.geometry, dpi).map_err(|_| OcrError::CouldNotRenderPage)?;
    let target = (width * dpi / 72.0, height * dpi / 72.0);
    let original = if page.image.width() as f32 > target.0 + 1.0 {
        image::imageops::resize(&page.image, target.0.round().max(1.0) as u32, target.1.round().max(1.0) as u32, image::imageops::FilterType::Triangle)
    } else {
        page.image
    };
    let cropped = crop_margins(original.clone(), crop_margins_percent)?;
    #[cfg(target_os = "macos")]
    let processed = objc2::rc::autoreleasepool(|_| enhance::enhance(DynamicImage::ImageRgb8(cropped), enhancement));
    #[cfg(not(target_os = "macos"))]
    let processed = enhance::enhance(DynamicImage::ImageRgb8(cropped), enhancement);
    Ok(Preview { original, processed })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn crop_and_split_follow_the_swift_rules() {
        let page = RgbImage::new(200, 100);
        let cropped = crop_margins(page.clone(), 10.0).unwrap();
        assert_eq!((cropped.width(), cropped.height()), (160, 80));
        assert_eq!(split_if_double_page(cropped).len(), 2, "wide pages split");
        assert_eq!(split_if_double_page(RgbImage::new(120, 100)).len(), 1, "less than 30% wider stays whole");
        assert!(validate_crop(25.0).is_err());
        assert!(validate_crop(f32::NAN).is_err());
    }
}
