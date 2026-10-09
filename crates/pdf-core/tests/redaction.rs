use pdf_core::geometry::PdfBox;
use pdf_core::redaction::{RedactionRegion, redact};
use pdf_core::{engine, structure, testing};

#[test]
fn redaction_removes_text_only_from_target_pages_and_scrubs_metadata() {
    let source = testing::outlined_pdf(&["Secret plan", "Public page"]);
    let region = RedactionRegion { page: 0, rect: PdfBox::new(60.0, 660.0, 300.0, 720.0) };
    let output = redact(&source, &[region], Some("Privileged")).unwrap();
    let texts = engine::page_texts(&output).unwrap();
    assert!(texts[0].trim().is_empty(), "redacted page has no extractable text");
    assert!(texts[1].contains("Public page"), "other pages stay native");
    let document = structure::parse(&output).unwrap();
    assert!(document.catalog().unwrap().get(b"Outlines").is_err());
    assert!(!document.trailer.has(b"Info"));
    assert!(redact(&source, &[], None).is_err());
    let outside = RedactionRegion { page: 0, rect: PdfBox::new(900.0, 900.0, 950.0, 950.0) };
    assert!(redact(&source, &[outside], None).is_err());
}
