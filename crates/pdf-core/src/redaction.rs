//! Permanent redaction.
//!
//! A black annotation is not a redaction. Affected pages are rendered with
//! their annotations, covered with opaque boxes in the pixels, and replaced
//! by that image; their text, annotations and resources are discarded.
//! Unaffected pages stay native. Document metadata, the outline, the
//! structure tree, name trees and scripts are removed because they can
//! repeat redacted content.

use std::collections::BTreeMap;

use ab_glyph::{Font, FontVec, PxScale, ScaleFont};
use lopdf::{Document as LoDocument, Object};
use thiserror::Error;

use crate::engine;
use crate::error::{CoreError, CoreResult};
use crate::geometry::PdfBox;
use crate::raster;
use crate::structure;

pub const MAXIMUM_REGIONS: usize = 500;
const DPI: f32 = 144.0;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct RedactionRegion {
    pub page: usize,
    pub rect: PdfBox,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum RedactionError {
    #[error("Draw at least one redaction area first.")]
    NoRegions,
    #[error("One of the redaction areas is outside its page or too small to apply safely.")]
    InvalidRegion,
    #[error("PDFViewer could not securely rasterize one of the selected pages.")]
    CouldNotRasterize,
    #[error("PDFViewer could not build a clean redacted working copy.")]
    CouldNotBuildSanitizedDocument,
    #[error("PDFViewer refused the redaction because its security verification did not pass.")]
    VerificationFailed,
}

impl From<RedactionError> for CoreError {
    fn from(error: RedactionError) -> Self {
        CoreError::Redaction(error.to_string())
    }
}

pub fn sanitized_reason_label(label: &str) -> Option<String> {
    let label: String = label.trim().chars().take(80).collect();
    (!label.is_empty()).then_some(label)
}

/// Returns the redacted document's bytes. Page count and order are unchanged.
pub fn redact(bytes: &[u8], regions: &[RedactionRegion], reason_label: Option<&str>) -> CoreResult<Vec<u8>> {
    if regions.is_empty() {
        return Err(RedactionError::NoRegions.into());
    }
    let infos = crate::text::page_infos(bytes)?;
    let mut by_page: BTreeMap<usize, Vec<PdfBox>> = BTreeMap::new();
    for region in regions.iter().take(MAXIMUM_REGIONS) {
        let info = infos.get(region.page).ok_or(RedactionError::InvalidRegion)?;
        let clipped = region
            .rect
            .intersection(&info.geometry.visible)
            .filter(|rect| rect.is_finite() && rect.width() >= 2.0 && rect.height() >= 2.0)
            .ok_or(RedactionError::InvalidRegion)?;
        by_page.entry(region.page).or_default().push(clipped);
    }
    let label = reason_label.and_then(sanitized_reason_label);
    let font = label.as_ref().and_then(|_| label_font());

    let mut document = structure::parse(bytes)?;
    structure::flatten_page_tree(&mut document)?;
    let page_ids = structure::page_ids(&document);
    {
        let rendered = engine::load(bytes.to_vec(), None)?;
        for (page_index, rects) in &by_page {
            let mut page = raster::render_page(&rendered, *page_index, infos[*page_index].geometry, DPI)
                .map_err(|_| RedactionError::CouldNotRasterize)?;
            for rect in rects {
                let ((x0, y0), (x1, y1)) = page.geometry.box_to_display(&rect.inset(-0.5, -0.5));
                let (px0, py0) = page.to_pixels((x0, y0));
                let (px1, py1) = page.to_pixels((x1, y1));
                fill(&mut page.image, px0, py0, px1, py1);
                if let (Some(label), Some(font)) = (&label, &font) {
                    draw_label(&mut page.image, font, label, (px0, py0, px1, py1), page.scale);
                }
            }
            let size = page.size_points();
            let image = raster::embed_lossless(&mut document, &image::DynamicImage::ImageRgb8(page.image));
            raster::replace_page_with_image(&mut document, page_ids[*page_index], image, size, None)
                .map_err(|_| RedactionError::CouldNotBuildSanitizedDocument)?;
        }
    }
    scrub_document(&mut document, &by_page.keys().map(|index| page_ids[*index]).collect::<Vec<_>>());
    document.prune_objects();
    let output = structure::serialize(&mut document).map_err(|_| RedactionError::CouldNotBuildSanitizedDocument)?;
    verify(&output, &by_page.keys().copied().collect::<Vec<_>>(), page_ids.len())?;
    Ok(output)
}

/// Removes document-level places redacted content could survive.
fn scrub_document(document: &mut LoDocument, redacted_pages: &[lopdf::ObjectId]) {
    document.trailer.remove(b"Info");
    let Ok(catalog_id) = document.trailer.get(b"Root").and_then(Object::as_reference) else { return };
    let surviving_fields = {
        let remaining: Vec<_> = structure::page_ids(document).into_iter().filter(|page| !redacted_pages.contains(page)).collect();
        structure::root_fields_for_pages(document, &remaining)
    };
    let acro_form = document
        .get_object(catalog_id)
        .and_then(Object::as_dict)
        .ok()
        .and_then(|catalog| catalog.get(b"AcroForm").ok().cloned());
    if let Ok(catalog) = document.get_object_mut(catalog_id).and_then(Object::as_dict_mut) {
        for key in [b"Metadata".as_slice(), b"Outlines", b"StructTreeRoot", b"MarkInfo", b"Names", b"OpenAction", b"AA", b"PageLabels", b"Dests", b"PieceInfo"] {
            catalog.remove(key);
        }
        if surviving_fields.is_empty() {
            catalog.remove(b"AcroForm");
        }
    }
    if !surviving_fields.is_empty() {
        let fields: Vec<Object> = surviving_fields.into_iter().map(Object::Reference).collect();
        match acro_form {
            Some(Object::Reference(id)) => {
                if let Ok(form) = document.get_object_mut(id).and_then(Object::as_dict_mut) {
                    form.set("Fields", fields);
                    form.remove(b"XFA");
                }
            }
            Some(Object::Dictionary(_)) => {
                if let Ok(form) = document
                    .get_object_mut(catalog_id)
                    .and_then(Object::as_dict_mut)
                    .and_then(|catalog| catalog.get_mut(b"AcroForm"))
                    .and_then(Object::as_dict_mut)
                {
                    form.set("Fields", fields);
                    form.remove(b"XFA");
                }
            }
            _ => {}
        }
    }
    // Pages that weren't redacted may still point into the removed structure tree.
    for page in structure::page_ids(document) {
        if let Ok(dictionary) = structure::page_dictionary_mut(document, page) {
            dictionary.remove(b"StructParents");
        }
    }
}

fn verify(bytes: &[u8], redacted: &[usize], page_count: usize) -> Result<(), RedactionError> {
    let document = structure::parse(bytes).map_err(|_| RedactionError::VerificationFailed)?;
    if structure::page_count(&document) != page_count || document.trailer.has(b"Info") {
        return Err(RedactionError::VerificationFailed);
    }
    let texts = engine::page_texts(bytes).map_err(|_| RedactionError::VerificationFailed)?;
    let pages = structure::page_ids(&document);
    for index in redacted {
        let text_free = texts.get(*index).is_some_and(|text| text.trim().is_empty());
        let annotation_free = crate::annotations::annotation_ids(&document, pages[*index]).is_empty();
        if !text_free || !annotation_free {
            return Err(RedactionError::VerificationFailed);
        }
    }
    Ok(())
}

fn fill(image: &mut image::RgbImage, x0: f32, y0: f32, x1: f32, y1: f32) {
    let (width, height) = (image.width() as f32, image.height() as f32);
    let (left, right) = (x0.min(x1).floor().clamp(0.0, width) as u32, x0.max(x1).ceil().clamp(0.0, width) as u32);
    let (top, bottom) = (y0.min(y1).floor().clamp(0.0, height) as u32, y0.max(y1).ceil().clamp(0.0, height) as u32);
    for y in top..bottom {
        for x in left..right {
            image.put_pixel(x, y, image::Rgb([0, 0, 0]));
        }
    }
}

fn label_font() -> Option<FontVec> {
    for (path, index) in [
        ("/System/Library/Fonts/Helvetica.ttc", 1),
        ("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 0),
        ("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 0),
    ] {
        if let Ok(data) = std::fs::read(path)
            && let Ok(font) = FontVec::try_from_vec_and_index(data, index)
        {
            return Some(font);
        }
    }
    None
}

/// Burns a white label, horizontally squeezed to fit, into a covered box.
fn draw_label(image: &mut image::RgbImage, font: &FontVec, label: &str, rect: (f32, f32, f32, f32), scale: f32) {
    let (x0, y0, x1, y1) = (rect.0.min(rect.2), rect.1.min(rect.3), rect.0.max(rect.2), rect.1.max(rect.3));
    let (width, height) = (x1 - x0, y1 - y0);
    if width < 30.0 * scale || height < 14.0 * scale {
        return;
    }
    let size = (height * 0.22).clamp(8.0 * scale, 18.0 * scale);
    let scaled = font.as_scaled(PxScale::from(size));
    let mut glyphs = Vec::new();
    let mut caret = 0.0f32;
    let mut previous = None;
    for c in label.chars() {
        let id = scaled.glyph_id(c);
        if let Some(previous) = previous {
            caret += scaled.kern(previous, id);
        }
        glyphs.push((id, caret));
        caret += scaled.h_advance(id);
        previous = Some(id);
    }
    if caret <= 0.0 {
        return;
    }
    let squeeze = ((width - 12.0 * scale) / caret).clamp(0.1, 1.0);
    let start_x = x0 + (width - caret * squeeze) / 2.0;
    let baseline = y0 + height / 2.0 + size * 0.35;
    for (id, offset) in glyphs {
        let glyph = id.with_scale_and_position(PxScale { x: size * squeeze, y: size }, ab_glyph::point(start_x + offset * squeeze, baseline));
        if let Some(outlined) = font.outline_glyph(glyph) {
            let bounds = outlined.px_bounds();
            outlined.draw(|gx, gy, coverage| {
                let x = bounds.min.x as i64 + i64::from(gx);
                let y = bounds.min.y as i64 + i64::from(gy);
                if x >= x0 as i64 && x < x1 as i64 && y >= y0 as i64 && y < y1 as i64 && x >= 0 && y >= 0 {
                    let (x, y) = (x as u32, y as u32);
                    if x < image.width() && y < image.height() {
                        let value = (coverage.clamp(0.0, 1.0) * 255.0) as u8;
                        let pixel = image.get_pixel_mut(x, y);
                        let blended = pixel[0].max(value);
                        *pixel = image::Rgb([blended, blended, blended]);
                    }
                }
            });
        }
    }
}
