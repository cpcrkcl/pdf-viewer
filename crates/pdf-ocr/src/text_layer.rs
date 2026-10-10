//! The invisible OCR text layer.
//!
//! Text is drawn in render mode 3 (invisible) with one shared Type0 font whose
//! CIDs are the characters' Unicode values, so a fixed ToUnicode CMap makes
//! any BMP script extractable and searchable without embedding glyphs.
//! Each line is stretched with `Tz` to span its recognized box.

use std::fmt::Write;

use lopdf::{Dictionary, Document as LoDocument, ObjectId, Stream, dictionary};

use crate::RecognizedLine;

const FONT_NAME: &str = "PDFViewerOCR";
/// Every glyph advances one em.
const GLYPH_WIDTH: f32 = 1000.0;

pub fn add_font(document: &mut LoDocument) -> ObjectId {
    let mut cmap = String::from(
        "/CIDInit /ProcSet findresource begin\n12 dict begin\nbegincmap\n\
         /CIDSystemInfo << /Registry (Adobe) /Ordering (UCS) /Supplement 0 >> def\n\
         /CMapName /PDFViewerOCR-UCS def\n/CMapType 2 def\n\
         1 begincodespacerange\n<0000> <FFFF>\nendcodespacerange\n",
    );
    // bfrange entries may only vary in their last byte; skip surrogates.
    let high_bytes: Vec<u32> = (0..=0xFFu32).filter(|high| !(0xD8..=0xDF).contains(high)).collect();
    for chunk in high_bytes.chunks(100) {
        let _ = writeln!(cmap, "{} beginbfrange", chunk.len());
        for high in chunk {
            let _ = writeln!(cmap, "<{high:02X}00> <{high:02X}FF> <{high:02X}00>");
        }
        cmap.push_str("endbfrange\n");
    }
    cmap.push_str("endcmap\nCMapName currentdict /CMap defineresource pop\nend\nend\n");
    let mut to_unicode = Stream::new(Dictionary::new(), cmap.into_bytes());
    let _ = to_unicode.compress();
    let to_unicode = document.add_object(to_unicode);

    let descriptor = document.add_object(dictionary! {
        "Type" => "FontDescriptor",
        "FontName" => "Helvetica",
        "Flags" => 32,
        "FontBBox" => vec![0.into(), (-200).into(), 1000.into(), 800.into()],
        "ItalicAngle" => 0,
        "Ascent" => 800,
        "Descent" => -200,
        "CapHeight" => 700,
        "StemV" => 80,
    });
    let descendant = document.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "CIDFontType2",
        "BaseFont" => "Helvetica",
        "CIDSystemInfo" => dictionary! {
            "Registry" => lopdf::Object::string_literal("Adobe"),
            "Ordering" => lopdf::Object::string_literal("Identity"),
            "Supplement" => 0,
        },
        "FontDescriptor" => descriptor,
        "DW" => GLYPH_WIDTH as i64,
        "CIDToGIDMap" => "Identity",
    });
    document.add_object(dictionary! {
        "Type" => "Font",
        "Subtype" => "Type0",
        "BaseFont" => "Helvetica",
        "Encoding" => "Identity-H",
        "DescendantFonts" => vec![descendant.into()],
        "ToUnicode" => to_unicode,
    })
}

/// Content and resources drawing `lines` invisibly on a page of `size` points.
pub fn content(lines: &[RecognizedLine], size: (f32, f32), font: ObjectId) -> (String, Dictionary) {
    let (page_width, page_height) = size;
    let mut content = String::new();
    for line in lines {
        let (x, y) = (line.x * page_width, line.y * page_height);
        let (width, height) = (line.width * page_width, line.height * page_height);
        let codes: Vec<u16> = line
            .text
            .chars()
            .map(|c| u16::try_from(u32::from(c)).ok().filter(|code| !(0xD800..=0xDFFF).contains(code)).unwrap_or(0xFFFD))
            .collect();
        if !(width > 0.5 && height > 0.5 && x.is_finite() && y.is_finite()) || codes.is_empty() {
            continue;
        }
        let font_size = (height * 0.82).max(4.0);
        let natural_width = codes.len() as f32 * font_size * GLYPH_WIDTH / 1000.0;
        let stretch = width / natural_width * 100.0;
        let hex: String = codes.iter().map(|code| format!("{code:04X}")).collect();
        let _ = writeln!(
            content,
            "BT 3 Tr /{FONT_NAME} {font_size:.3} Tf {stretch:.3} Tz {x:.3} {:.3} Td <{hex}> Tj ET",
            y + height * 0.08
        );
    }
    (content, dictionary! { "Font" => dictionary! { FONT_NAME => font } })
}

#[cfg(test)]
mod tests {
    use super::*;
    use pdf_core::{engine, raster, structure, testing};

    #[test]
    fn invisible_layer_is_extractable_and_searchable() {
        let mut document = structure::parse(&testing::image_pdf(400, 300)).unwrap();
        let page = structure::page_ids(&document)[0];
        let font = add_font(&mut document);
        let lines = [
            RecognizedLine { text: "Invoice 2024".into(), x: 0.1, y: 0.7, width: 0.5, height: 0.08, confidence: 1.0 },
            RecognizedLine { text: "Grüße 東京".into(), x: 0.1, y: 0.4, width: 0.5, height: 0.08, confidence: 1.0 },
        ];
        let image = raster::embed_lossless(&mut document, &image::DynamicImage::ImageLuma8(image::GrayImage::new(40, 30)));
        raster::replace_page_with_image(&mut document, page, image, (200.0, 150.0), Some(content(&lines, (200.0, 150.0), font))).unwrap();
        let bytes = structure::serialize(&mut document).unwrap();
        let text = &engine::page_texts(&bytes).unwrap()[0];
        assert!(text.contains("Invoice 2024"), "got {text:?}");
        assert!(text.contains("Grüße 東京"), "got {text:?}");
    }
}
