use pdf_core::forms::{self, FieldKind, FieldValue, FormError};
use pdf_core::loader::{self, OpenResult};
use pdf_core::{CoreError, DocumentSession, testing};

fn open(bytes: &[u8]) -> (tempfile::TempDir, DocumentSession) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("form.pdf");
    std::fs::write(&path, bytes).unwrap();
    match loader::open(&path).unwrap() {
        OpenResult::Opened(session) => (dir, session),
        OpenResult::PasswordRequired(_) => unreachable!(),
    }
}

fn fields(session: &DocumentSession) -> Vec<forms::FormField> {
    forms::fields(&session.editor.parse().unwrap())
}

#[test]
fn discovers_supported_fields_in_page_order() {
    let (_dir, session) = open(&testing::form_pdf());
    let found = fields(&session);
    let summary: Vec<(&str, FieldKind, usize)> = found.iter().map(|f| (f.name.as_str(), f.kind, f.page)).collect();
    assert_eq!(
        summary,
        vec![
            ("name", FieldKind::Text, 0),
            ("agree", FieldKind::Checkbox, 0),
            ("color", FieldKind::Radio, 0),
            ("size", FieldKind::Choice, 0),
            ("locked", FieldKind::Text, 1),
        ]
    );
    assert_eq!(found[0].display_name(), "Full Name");
    assert!(found[0].is_required);
    assert_eq!(found[0].maximum_length, Some(10));
    assert_eq!(found[2].options, vec!["red", "blue"]);
    assert_eq!(found[3].options, vec!["S", "M", "L"]);
    assert_eq!(found[3].value, Some(FieldValue::Choice(Some("M".into()))));
    assert!(found[4].is_read_only);
}

#[test]
fn typed_updates_and_reset_restore_defaults() {
    let (_dir, mut session) = open(&testing::form_pdf());
    let editor = &mut session.editor;
    editor.mutate(|d| forms::set_value(d, "name", &FieldValue::Text("Grace".into()))).unwrap();
    editor.mutate(|d| forms::set_value(d, "agree", &FieldValue::Checked(true))).unwrap();
    editor.mutate(|d| forms::set_value(d, "color", &FieldValue::Radio(Some("red".into())))).unwrap();
    editor.mutate(|d| forms::set_value(d, "size", &FieldValue::Choice(Some("L".into())))).unwrap();
    let values: Vec<_> = fields(&session).into_iter().map(|f| f.value).collect();
    assert_eq!(
        values[..4],
        [
            Some(FieldValue::Text("Grace".into())),
            Some(FieldValue::Checked(true)),
            Some(FieldValue::Radio(Some("red".into()))),
            Some(FieldValue::Choice(Some("L".into()))),
        ]
    );
    let json = forms::values_json(&session.editor.parse().unwrap());
    assert_eq!(json["name"], "Grace");
    assert_eq!(json["agree"], true);

    session.editor.mutate(forms::reset).unwrap();
    let values: Vec<_> = fields(&session).into_iter().map(|f| f.value).collect();
    assert_eq!(
        values[..4],
        [
            Some(FieldValue::Text("Ada".into())),
            Some(FieldValue::Checked(false)),
            Some(FieldValue::Radio(Some("blue".into()))),
            Some(FieldValue::Choice(Some("M".into()))),
        ]
    );
}

#[test]
fn validation_and_read_only_fields_fail_recoverably() {
    let (_dir, mut session) = open(&testing::form_pdf());
    let editor = &mut session.editor;
    let too_long = editor.mutate(|d| forms::set_value(d, "name", &FieldValue::Text("A very long name".into())));
    assert!(matches!(too_long, Err(CoreError::Form(message)) if message.contains("at most 10")));
    assert!(editor.mutate(|d| forms::set_value(d, "locked", &FieldValue::Text("x".into()))).is_err());
    assert!(editor.mutate(|d| forms::set_value(d, "size", &FieldValue::Choice(Some("XL".into())))).is_err());
    assert!(editor.mutate(|d| forms::set_value(d, "agree", &FieldValue::Text("yes".into()))).is_err());
    assert!(editor.mutate(|d| forms::set_value(d, "missing", &FieldValue::Text("x".into()))).is_err());
    assert!(!editor.can_undo(), "failed updates never create revisions");
    assert_eq!(
        forms::validate_required(&editor.parse().unwrap()),
        Err(FormError::RequiredFieldsMissing(vec!["Full Name".into()]))
    );
    editor.mutate(|d| forms::set_value(d, "name", &FieldValue::Text("Ada".into()))).unwrap();
    assert_eq!(forms::validate_required(&editor.parse().unwrap()), Ok(()));
    editor.undo().unwrap();
    assert_eq!(fields(&session)[0].value, Some(FieldValue::Text(String::new())));
}

#[test]
fn export_reopen_preserves_values_and_flatten_removes_widgets() {
    let (dir, mut session) = open(&testing::form_pdf());
    session.editor.mutate(|d| forms::set_value(d, "name", &FieldValue::Text("Lovelace".into()))).unwrap();
    session.editor.mutate(|d| forms::set_value(d, "agree", &FieldValue::Checked(true))).unwrap();
    let out = dir.path().join("filled.pdf");
    pdf_core::export::export(&session.editor.pdf_data(), &session.source_path, &out, &pdf_core::export::Protection::None, Default::default()).unwrap();
    let (_dir2, reopened) = open(&std::fs::read(&out).unwrap());
    let reopened_fields = fields(&reopened);
    assert_eq!(reopened_fields[0].value, Some(FieldValue::Text("Lovelace".into())));
    assert_eq!(reopened_fields[1].value, Some(FieldValue::Checked(true)));

    let flat = forms::flattened(&session.editor.pdf_data()).unwrap();
    let parsed = pdf_core::structure::parse(&flat).unwrap();
    assert!(forms::fields(&parsed).is_empty());
    assert_eq!(pdf_core::structure::page_count(&parsed), 2);
    let text = pdf_core::engine::page_texts(&flat).unwrap();
    assert!(text[0].contains("Lovelace"), "flattened value is page content: {:?}", text[0]);

    let (_dir3, empty) = open(&testing::form_pdf());
    assert!(forms::flattened(&empty.editor.pdf_data()).is_err(), "required fields block flattening");
}
