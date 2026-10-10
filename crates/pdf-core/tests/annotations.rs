use pdf_core::annotations::{self, AnnotationKind, LineWidth, MarkupKind, ShapeKind, SignatureSize, StampPreset, palette};
use pdf_core::geometry::PdfBox;
use pdf_core::loader::{self, OpenResult};
use pdf_core::{CoreError, DocumentEditor, DocumentSession, testing};
use pdfium_render::prelude::*;

fn open(bytes: &[u8]) -> (tempfile::TempDir, DocumentSession) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("doc.pdf");
    std::fs::write(&path, bytes).unwrap();
    match loader::open(&path).unwrap() {
        OpenResult::Opened(session) => (dir, session),
        OpenResult::PasswordRequired(_) => unreachable!(),
    }
}

fn owned(editor: &DocumentEditor) -> Vec<annotations::AnnotationInfo> {
    annotations::owned_annotations(&editor.parse().unwrap())
}

fn add_one_of_each(editor: &mut DocumentEditor) {
    let line = vec![PdfBox::new(72.0, 676.0, 160.0, 704.0)];
    editor.mutate(|d| annotations::add_text_markup(d, MarkupKind::Highlight, &[(0, line.clone())], palette::YELLOW).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_text_markup(d, MarkupKind::Underline, &[(0, line.clone())], palette::GREEN).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_text_markup(d, MarkupKind::Strikethrough, &[(0, line.clone())], palette::RED).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_ink(d, 0, &[(100.0, 100.0), (150.0, 140.0), (200.0, 120.0)], palette::BLUE, LineWidth::Bold).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_text_note(d, 0, (300.0, 500.0), "  Review this  ", palette::YELLOW).map(|_| ())).unwrap();
    for kind in [ShapeKind::Rectangle, ShapeKind::Oval, ShapeKind::Line, ShapeKind::Arrow] {
        editor.mutate(|d| annotations::add_shape(d, kind, 0, (300.0, 300.0), (380.0, 360.0), palette::PINK, LineWidth::Standard).map(|_| ())).unwrap();
    }
    editor.mutate(|d| annotations::add_stamp(d, 0, (400.0, 200.0), StampPreset::Approved).map(|_| ())).unwrap();
    let png = testing::signature_png(120, 40);
    editor.mutate(|d| annotations::add_image_stamp(d, 0, (200.0, 400.0), &png, SignatureSize::Medium, None).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_image_stamp(d, 0, (450.0, 600.0), &png, SignatureSize::Small, Some("My Stamp")).map(|_| ())).unwrap();
}

#[test]
fn creates_every_supported_annotation_with_ownership_and_round_trips() {
    let (dir, mut session) = open(&testing::text_pdf(&["Hello annotations"]));
    add_one_of_each(&mut session.editor);
    let kinds: Vec<AnnotationKind> = owned(&session.editor).iter().map(|info| info.kind).collect();
    assert_eq!(
        kinds,
        vec![
            AnnotationKind::Highlight,
            AnnotationKind::Underline,
            AnnotationKind::Strikethrough,
            AnnotationKind::Ink,
            AnnotationKind::TextNote,
            AnnotationKind::Rectangle,
            AnnotationKind::Oval,
            AnnotationKind::Line,
            AnnotationKind::Arrow,
            AnnotationKind::Stamp,
            AnnotationKind::Signature,
            AnnotationKind::Stamp,
        ]
    );
    let note = owned(&session.editor).into_iter().find(|i| i.kind == AnnotationKind::TextNote).unwrap();
    assert_eq!(note.contents.as_deref(), Some("Review this"));
    let custom = owned(&session.editor).into_iter().last().unwrap();
    assert_eq!(custom.label, "My Stamp");

    // Export and reopen: ownership, kinds and signature image survive.
    let out = dir.path().join("out.pdf");
    pdf_core::export::export(&session.editor.pdf_data(), &session.source_path, &out, &pdf_core::export::Protection::None, Default::default()).unwrap();
    let (_dir2, reopened) = open(&std::fs::read(&out).unwrap());
    let reopened_kinds: Vec<_> = owned(&reopened.editor).iter().map(|info| (info.kind, info.owned)).collect();
    let original_kinds: Vec<_> = owned(&session.editor).iter().map(|info| (info.kind, info.owned)).collect();
    assert_eq!(reopened_kinds, original_kinds);
    let document = reopened.editor.parse().unwrap();
    let signature = owned(&reopened.editor).into_iter().find(|i| i.kind == AnnotationKind::Signature).unwrap();
    let dictionary = document.get_object(signature.object).unwrap().as_dict().unwrap();
    assert_eq!(annotations::signature_image_data(dictionary), Some(testing::signature_png(120, 40)));
}

#[test]
fn third_party_annotations_are_listed_but_never_owned_or_editable() {
    let (_dir, mut session) = open(&testing::third_party_annotated_pdf());
    let index = annotations::annotation_index(&session.editor.parse().unwrap());
    assert_eq!(index[0].len(), 1);
    assert_eq!(index[0][0].kind, AnnotationKind::Rectangle);
    assert!(index[0][0].owned.is_none());
    assert!(owned(&session.editor).is_empty());
    let fake = annotations::AnnotationId::new();
    assert_eq!(
        session.editor.mutate(|d| annotations::delete_annotation(d, 0, fake)),
        Err(CoreError::InvalidAnnotation)
    );
    assert!(!session.editor.can_undo());
}

#[test]
fn non_finite_and_degenerate_input_is_rejected_without_mutating() {
    let (_dir, mut session) = open(&testing::numbered_pdf(1));
    let editor = &mut session.editor;
    assert!(editor.mutate(|d| annotations::add_ink(d, 0, &[(f32::NAN, 1.0), (2.0, 2.0)], palette::BLUE, LineWidth::Fine).map(|_| ())).is_err());
    assert!(editor.mutate(|d| annotations::add_ink(d, 0, &[(1.0, 1.0)], palette::BLUE, LineWidth::Fine).map(|_| ())).is_err());
    assert!(editor.mutate(|d| annotations::add_shape(d, ShapeKind::Rectangle, 0, (1.0, 1.0), (2.0, 2.0), palette::RED, LineWidth::Fine).map(|_| ())).is_err());
    assert!(editor.mutate(|d| annotations::add_text_note(d, 0, (1.0, 1.0), "   ", palette::RED).map(|_| ())).is_err());
    assert!(editor.mutate(|d| annotations::add_stamp(d, 3, (1.0, 1.0), StampPreset::Draft).map(|_| ())).is_err());
    assert!(editor.mutate(|d| annotations::add_image_stamp(d, 0, (1.0, 1.0), b"not an image", SignatureSize::Small, None).map(|_| ())).is_err());
    assert!(!editor.can_undo());
    assert!(!editor.is_dirty());
}

#[test]
fn annotation_edits_are_undoable_and_clamped_to_the_page() {
    let (_dir, mut session) = open(&testing::numbered_pdf(1));
    let editor = &mut session.editor;
    let mut id = None;
    editor.mutate(|d| {
        id = Some(annotations::add_shape(d, ShapeKind::Rectangle, 0, (500.0, 700.0), (580.0, 760.0), palette::RED, LineWidth::Fine)?);
        Ok(())
    }).unwrap();
    let id = id.unwrap();
    editor.mutate(|d| annotations::move_annotation(d, 0, id, 500.0, 500.0)).unwrap();
    let rect = owned(editor)[0].rect;
    assert!((rect.x1 - 612.0).abs() < 0.01 && (rect.y1 - 792.0).abs() < 0.01, "moved into the top-right corner: {rect:?}");
    editor.mutate(|d| annotations::resize_annotation(d, 0, id, 2.0)).unwrap();
    let resized = owned(editor)[0].rect;
    assert!((resized.width() - 160.0).abs() < 0.01 && resized.x1 <= 612.0 + 0.01);
    assert_eq!(editor.mutate(|d| annotations::resize_annotation(d, 0, id, 9.0)), Err(CoreError::InvalidAnnotation));
    editor.mutate(|d| annotations::set_color(d, 0, id, palette::GREEN)).unwrap();
    editor.mutate(|d| annotations::set_line_width(d, 0, id, LineWidth::Marker)).unwrap();
    assert_eq!(owned(editor)[0].line_width, Some(12.0));

    editor.undo().unwrap();
    editor.undo().unwrap();
    editor.undo().unwrap();
    assert_eq!(owned(editor)[0].rect, rect);
    editor.mutate(|d| annotations::delete_annotation(d, 0, id)).unwrap();
    assert!(owned(editor).is_empty());
    editor.undo().unwrap();
    assert_eq!(owned(editor).len(), 1);
}

#[test]
fn visual_signature_size_and_rotation_persist() {
    let (_dir, mut session) = open(&testing::numbered_pdf(1));
    let editor = &mut session.editor;
    let png = testing::signature_png(200, 50);
    let mut id = None;
    editor.mutate(|d| {
        id = Some(annotations::add_image_stamp(d, 0, (300.0, 300.0), &png, SignatureSize::Small, None)?);
        Ok(())
    }).unwrap();
    let id = id.unwrap();
    let small = owned(editor)[0].rect;
    assert!((small.width() - 96.0).abs() < 0.01 && (small.height() - 24.0).abs() < 0.01);
    editor.mutate(|d| annotations::set_image_stamp_size(d, 0, id, SignatureSize::Large)).unwrap();
    let large = owned(editor)[0].rect;
    assert!((large.width() - 216.0).abs() < 0.01);
    editor.mutate(|d| annotations::rotate_image_stamp(d, 0, id, true)).unwrap();
    let rotated = owned(editor)[0].clone();
    assert_eq!(rotated.rotation_quarter_turns, 1);
    assert!((rotated.rect.width() - large.height()).abs() < 0.01, "rotation swaps width and height");
    editor.mutate(|d| annotations::set_image_stamp_size(d, 0, id, SignatureSize::Medium)).unwrap();
    let resized = owned(editor)[0].rect;
    assert!((resized.width() - 144.0).abs() < 0.01 || (resized.height() - 576.0).abs() > 0.0);
    editor.undo().unwrap();
    editor.undo().unwrap();
    assert_eq!(owned(editor)[0].rotation_quarter_turns, 0);
}

#[test]
fn eraser_removes_only_owned_ink_it_touches() {
    let (_dir, mut session) = open(&testing::numbered_pdf(1));
    let editor = &mut session.editor;
    editor.mutate(|d| annotations::add_ink(d, 0, &[(100.0, 100.0), (200.0, 100.0)], palette::BLUE, LineWidth::Standard).map(|_| ())).unwrap();
    editor.mutate(|d| annotations::add_ink(d, 0, &[(100.0, 400.0), (200.0, 400.0)], palette::BLUE, LineWidth::Standard).map(|_| ())).unwrap();
    let mut erased = 0;
    editor.mutate(|d| {
        erased = annotations::erase_ink(d, 0, &[(150.0, 104.0)], 6.0)?;
        Ok(())
    }).unwrap();
    assert_eq!(erased, 1);
    let remaining = owned(editor);
    assert_eq!(remaining.len(), 1);
    assert!(remaining[0].rect.y0 > 300.0);
}

#[test]
fn generated_appearances_render() {
    let (_dir, mut session) = open(&testing::numbered_pdf(1));
    session.editor.mutate(|d| annotations::add_shape(d, ShapeKind::Rectangle, 0, (100.0, 100.0), (300.0, 300.0), palette::RED, LineWidth::Marker).map(|_| ())).unwrap();
    session.editor.mutate(|d| annotations::add_text_markup(d, MarkupKind::Highlight, &[(0, vec![PdfBox::new(400.0, 400.0, 500.0, 450.0)])], palette::YELLOW).map(|_| ())).unwrap();
    let document = pdf_core::engine::load(session.editor.pdf_data().to_vec(), None).unwrap();
    let page = document.pages().get(0).unwrap();
    let image = page
        .render_with_config(&PdfRenderConfig::new().set_target_width(612).render_annotations(true))
        .unwrap()
        .as_image()
        .unwrap()
        .into_rgb8();
    // PDF (106, 200) lies on the rectangle's left stroke; y flips for images.
    let stroke = image.get_pixel(106, 792 - 200);
    assert!(stroke[0] > 200 && stroke[1] < 120 && stroke[2] < 120, "red stroke rendered: {stroke:?}");
    let highlight = image.get_pixel(450, 792 - 425);
    assert!(highlight[2] < 200 && highlight[0] > 200 && highlight[1] > 180, "yellow highlight rendered: {highlight:?}");
    let blank = image.get_pixel(200, 792 - 200);
    assert!(blank[0] > 240 && blank[1] > 240 && blank[2] > 240, "rectangle interior stays clear: {blank:?}");
}
