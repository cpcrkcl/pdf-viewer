use std::collections::HashSet;

use pdf_core::engine::page_texts;
use pdf_core::loader::{self, AccessPermissions, OpenResult, UnlockLevel};
use pdf_core::testing;
use pdf_core::{CoreError, DocumentSession, WorkingPageId, sha256_hex};

fn write(dir: &tempfile::TempDir, name: &str, bytes: &[u8]) -> std::path::PathBuf {
    let path = dir.path().join(name);
    std::fs::write(&path, bytes).unwrap();
    path
}

fn open_session(path: &std::path::Path) -> DocumentSession {
    match loader::open(path).unwrap() {
        OpenResult::Opened(session) => session,
        OpenResult::PasswordRequired(_) => panic!("unexpected password prompt"),
    }
}

fn texts(session: &DocumentSession) -> Vec<String> {
    page_texts(&session.editor.pdf_data()).unwrap().into_iter().map(|t| t.trim().to_owned()).collect()
}

#[test]
fn open_valid_pdf_preserves_source_and_reports_page_count() {
    let dir = tempfile::tempdir().unwrap();
    let source = testing::numbered_pdf(3);
    let path = write(&dir, "three.pdf", &source);
    let mut session = open_session(&path);
    assert_eq!(session.editor.page_count(), 3);
    assert_eq!(session.fingerprint, sha256_hex(&source));
    assert!(!session.editor.is_dirty());
    assert!(!session.security.is_encrypted);

    session.editor.delete_pages(&[0]).unwrap();
    assert!(session.editor.is_dirty());
    assert_eq!(std::fs::read(&path).unwrap(), source, "the source file is never written");
}

#[test]
fn open_rejects_non_pdf_corrupt_and_missing_input() {
    let dir = tempfile::tempdir().unwrap();
    let text = write(&dir, "notes.txt", b"hello");
    assert!(matches!(loader::open(&text), Err(CoreError::UnsupportedFileType)));
    let corrupt = write(&dir, "corrupt.pdf", b"%PDF-1.7\nnot really a pdf");
    assert!(matches!(loader::open(&corrupt), Err(CoreError::InvalidPdf)));
    let missing = dir.path().join("missing.pdf");
    assert!(matches!(loader::open(&missing), Err(CoreError::FileUnavailable)));
}

#[test]
fn locked_handle_supports_retry_with_user_password() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "locked.pdf", &testing::protected_pdf(&["Secret"], "user", "owner", AccessPermissions::PRINT));
    let OpenResult::PasswordRequired(mut locked) = loader::open(&path).unwrap() else {
        panic!("expected a password prompt");
    };
    assert_eq!(locked.display_name(), "locked.pdf");
    assert!(locked.unlock("wrong").unwrap().is_none(), "a wrong password keeps the handle usable");
    let session = locked.unlock("user").unwrap().expect("user password unlocks");
    assert_eq!(session.security.unlock_level, UnlockLevel::User);
    assert!(session.security.is_encrypted);
    assert!(session.security.allows_printing());
    assert!(!session.security.allows_document_assembly());
    assert!(!session.security.allows_commenting());
    assert_eq!(session.session_password(), Some("user"));
    assert_eq!(texts(&session), vec!["Secret"]);
    assert!(matches!(locked.unlock("user"), Err(CoreError::LockedHandleUnavailable)));
}

#[test]
fn owner_password_receives_owner_unlock_level() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "locked.pdf", &testing::protected_pdf(&["Secret"], "user", "owner", 0));
    let OpenResult::PasswordRequired(mut locked) = loader::open(&path).unwrap() else {
        panic!("expected a password prompt");
    };
    let session = locked.unlock("owner").unwrap().unwrap();
    assert_eq!(session.security.unlock_level, UnlockLevel::Owner);
    assert!(session.security.allows_document_assembly());
}

#[test]
fn empty_user_password_opens_without_prompt_and_keeps_empty_credential() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "restricted.pdf", &testing::protected_pdf(&["Open"], "", "owner", AccessPermissions::PRINT));
    let session = open_session(&path);
    assert!(session.security.is_encrypted);
    assert_eq!(session.security.unlock_level, UnlockLevel::User);
    assert_eq!(session.session_password(), Some(""));
    assert!(!session.security.allows_document_changes());
}

#[test]
fn delete_undo_redo_preserve_identity_and_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "five.pdf", &testing::numbered_pdf(5));
    let mut session = open_session(&path);
    let original_ids = session.editor.page_ids().to_vec();
    let editor = &mut session.editor;

    editor.delete_pages(&[1, 3]).unwrap();
    assert_eq!(editor.page_ids(), &[original_ids[0].clone(), original_ids[2].clone(), original_ids[4].clone()]);
    assert!(editor.can_undo() && !editor.can_redo());
    editor.undo().unwrap();
    assert_eq!(editor.page_ids(), original_ids.as_slice());
    assert!(!editor.is_dirty(), "undo restores the opened snapshot byte-for-byte");
    editor.redo().unwrap();
    assert_eq!(editor.page_count(), 3);
    assert_eq!(texts(&session), vec!["Page 1", "Page 3", "Page 5"]);

    assert_eq!(session.editor.delete_pages(&[0, 1, 2]), Err(CoreError::CannotDeleteOnlyPage));
    assert_eq!(session.editor.delete_pages(&[]), Err(CoreError::InvalidPageSelection));
    assert_eq!(session.editor.delete_pages(&[9]), Err(CoreError::InvalidPageSelection));
}

#[test]
fn rotate_and_move_selected_pages() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "four.pdf", &testing::numbered_pdf(4));
    let mut session = open_session(&path);

    session.editor.rotate_pages(&[0, 2], true).unwrap();
    session.editor.rotate_pages(&[2], true).unwrap();
    session.editor.rotate_pages(&[3], false).unwrap();
    let document = session.editor.parse().unwrap();
    let pages = pdf_core::structure::page_ids(&document);
    let rotations: Vec<i64> = pages.iter().map(|page| pdf_core::structure::rotation(&document, *page)).collect();
    assert_eq!(rotations, vec![90, 0, 180, 270]);

    session.editor.move_pages(&[0, 1], 4).unwrap();
    assert_eq!(texts(&session), vec!["Page 3", "Page 4", "Page 1", "Page 2"]);
    session.editor.move_pages(&[3], 0).unwrap();
    assert_eq!(texts(&session), vec!["Page 2", "Page 3", "Page 4", "Page 1"]);
    assert_eq!(session.editor.move_pages(&[0], 9), Err(CoreError::InvalidInsertionIndex));
}

#[test]
fn insert_extract_and_new_mutation_clear_redo_history() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "two.pdf", &testing::numbered_pdf(2));
    let mut session = open_session(&path);
    let other = testing::text_pdf(&["Inserted A", "Inserted B", "Inserted C"]);

    session.editor.insert_pages(&other, Some(&[2, 0]), None, 1).unwrap();
    assert_eq!(texts(&session), vec!["Page 1", "Inserted A", "Inserted C", "Page 2"]);
    let inserted = session.editor.page_id(1).unwrap().clone();
    assert_eq!(inserted.document_fingerprint, sha256_hex(&other));
    assert!(!inserted.represents_original_occurrence());

    session.editor.insert_pages(&other, None, None, 4).unwrap();
    assert_eq!(session.editor.page_count(), 7);
    session.editor.undo().unwrap();
    assert!(session.editor.can_redo());
    session.editor.rotate_pages(&[0], true).unwrap();
    assert!(!session.editor.can_redo(), "a new mutation discards redo history");

    let extracted = session.editor.extract_pages(&[1, 3]).unwrap();
    let extracted_texts: Vec<String> = page_texts(&extracted).unwrap().into_iter().map(|t| t.trim().to_owned()).collect();
    assert_eq!(extracted_texts, vec!["Inserted A", "Page 2"]);
    assert!(session.editor.has_unexported_changes(), "extraction does not protect the working revision");

    assert_eq!(
        session.editor.insert_pages(&other, None, None, 99),
        Err(CoreError::InvalidInsertionIndex)
    );
}

#[test]
fn exported_revisions_remain_protected_across_undo_and_redo() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "three.pdf", &testing::numbered_pdf(3));
    let mut session = open_session(&path);
    let editor = &mut session.editor;
    assert!(!editor.has_unexported_changes());
    editor.delete_pages(&[0]).unwrap();
    assert!(editor.has_unexported_changes());
    editor.mark_current_revision_exported();
    assert!(!editor.has_unexported_changes());
    editor.rotate_pages(&[0], true).unwrap();
    assert!(editor.has_unexported_changes());
    editor.undo().unwrap();
    assert!(!editor.has_unexported_changes());
    editor.undo().unwrap();
    assert!(!editor.has_unexported_changes(), "the opened revision is always protected");
}

#[test]
fn processed_documents_keep_identities_and_split_pages_get_new_ones() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "two.pdf", &testing::numbered_pdf(2));
    let mut session = open_session(&path);
    let ids = session.editor.page_ids().to_vec();
    let processed = testing::text_pdf(&["A left", "A right", "B"]);
    session.editor.apply_processed_document(processed, Some(&[0, 0, 1])).unwrap();
    let new_ids = session.editor.page_ids();
    assert_eq!(new_ids[0], ids[0]);
    assert_ne!(new_ids[1], ids[0]);
    assert_eq!(new_ids[1].original_page_index, 0);
    assert_eq!(new_ids[2], ids[1]);
    assert_eq!(
        session.editor.apply_processed_document(testing::numbered_pdf(2), Some(&[1, 0])),
        Err(CoreError::CouldNotCopyDocument)
    );
}

#[test]
fn outline_maps_destinations_to_working_page_ids() {
    let dir = tempfile::tempdir().unwrap();
    let path = write(&dir, "outlined.pdf", &testing::outlined_pdf(&["One", "Two", "Three"]));
    let session = open_session(&path);
    let titles: Vec<&str> = session.outline.iter().map(|node| node.title.as_str()).collect();
    assert_eq!(titles, vec!["Section 1", "Section 2", "Section 3"]);
    assert_eq!(session.outline[2].page_id.as_ref(), session.editor.page_id(2));
    assert_eq!(session.outline[1].id, "1");
}

#[test]
fn byte_identical_files_share_fingerprints_and_page_ids() {
    let dir = tempfile::tempdir().unwrap();
    let bytes = testing::numbered_pdf(2);
    let a = open_session(&write(&dir, "a.pdf", &bytes));
    let b = open_session(&write(&dir, "b.pdf", &bytes));
    let c = open_session(&write(&dir, "c.pdf", &testing::numbered_pdf(3)));
    assert_eq!(a.fingerprint, b.fingerprint);
    assert_eq!(a.editor.page_ids(), b.editor.page_ids());
    assert_ne!(a.fingerprint, c.fingerprint);
    assert_eq!(a.editor.page_ids()[0], WorkingPageId::original(&a.fingerprint, 0));
    let valid: HashSet<_> = a.editor.page_ids().iter().cloned().collect();
    assert_eq!(valid.len(), 2);
}
