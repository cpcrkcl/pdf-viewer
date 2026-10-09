use std::collections::BTreeSet;
use std::sync::atomic::AtomicBool;

use pdf_core::{engine, structure, testing};
use pdf_ocr::{Enhancement, Language, OcrError, OcrOptions, RasterQuality, preview, process};

fn options(pages: &[usize]) -> OcrOptions {
    OcrOptions {
        pages: pages.iter().copied().collect::<BTreeSet<_>>(),
        searchable_text: false,
        enhancement: Enhancement::None,
        quality: RasterQuality::Compact,
        language: Language::Automatic,
        minimum_confidence: 0.0,
        crop_margins_percent: 0.0,
        split_double_pages: false,
    }
}

#[cfg(target_os = "macos")]
#[test]
fn recognized_text_makes_rasterized_pages_searchable() {
    let source = testing::text_pdf(&["Quarterly Report", "Untouched page"]);
    let mut options = options(&[0]);
    options.searchable_text = true;
    options.enhancement = Enhancement::CleanScan;
    options.language = Language::EnglishUs;
    let mut reports = Vec::new();
    let result = process(&source, &options, &AtomicBool::new(false), |progress| reports.push(progress)).unwrap();
    assert_eq!(result.source_page_indexes, [0, 1]);
    assert!(result.recognized_lines >= 1);
    assert_eq!(reports.last().map(|progress| (progress.completed, progress.total)), Some((1, 1)));
    let texts = engine::page_texts(&result.pdf_data).unwrap();
    assert!(texts[0].to_lowercase().contains("quarterly"), "OCR text layer: {:?}", texts[0]);
    assert!(texts[1].contains("Untouched page"), "unselected pages stay native");
}

#[test]
fn wide_pages_split_and_forms_on_processed_pages_are_dropped() {
    let mut options = options(&[0]);
    options.split_double_pages = true;
    options.crop_margins_percent = 2.0;
    let result = process(&testing::image_pdf(800, 400), &options, &AtomicBool::new(false), |_| {}).unwrap();
    assert_eq!(result.source_page_indexes, [0, 0]);
    assert_eq!(pdf_core::editor::validated_page_count(&result.pdf_data).unwrap(), 2);

    let form = process(&testing::form_pdf(), &self::options(&[0, 1]), &AtomicBool::new(false), |_| {}).unwrap();
    let document = structure::parse(&form.pdf_data).unwrap();
    assert!(document.catalog().unwrap().get(b"AcroForm").is_err());
}

#[test]
fn invalid_requests_and_cancellation_are_refused() {
    let source = testing::numbered_pdf(2);
    let never = AtomicBool::new(false);
    assert_eq!(process(&source, &options(&[]), &never, |_| {}).unwrap_err(), OcrError::NoPagesSelected);
    assert_eq!(process(&source, &options(&[5]), &never, |_| {}).unwrap_err(), OcrError::InvalidPageSelection);
    let mut cropped = options(&[0]);
    cropped.crop_margins_percent = 30.0;
    assert_eq!(process(&source, &cropped, &never, |_| {}).unwrap_err(), OcrError::InvalidCropMargins);
    assert_eq!(process(&source, &options(&[0]), &AtomicBool::new(true), |_| {}).unwrap_err(), OcrError::Cancelled);
}

#[test]
fn preview_is_small_and_reflects_cropping() {
    let preview = preview(&testing::numbered_pdf(1), 0, Enhancement::Grayscale, 10.0).unwrap();
    assert!(preview.original.width().max(preview.original.height()) <= 521);
    assert!(preview.processed.width() < preview.original.width());
}
