use pdf_core::engine::page_texts;
use pdf_core::export::{self, Compression, ExportError, Protection};
use pdf_core::loader::{self, AccessPermissions, OpenResult};
use pdf_core::testing;

fn session(dir: &tempfile::TempDir, bytes: &[u8]) -> (std::path::PathBuf, pdf_core::DocumentSession) {
    let path = dir.path().join("source.pdf");
    std::fs::write(&path, bytes).unwrap();
    match loader::open(&path).unwrap() {
        OpenResult::Opened(session) => (path, session),
        OpenResult::PasswordRequired(mut locked) => (path, locked.unlock("secret").unwrap().unwrap()),
    }
}

#[test]
fn export_writes_validated_copy_and_never_replaces_source() {
    let dir = tempfile::tempdir().unwrap();
    let source_bytes = testing::numbered_pdf(3);
    let (source, mut session) = session(&dir, &source_bytes);
    session.editor.delete_pages(&[1]).unwrap();
    session.editor.rotate_pages(&[0], true).unwrap();

    let destination = dir.path().join("out.pdf");
    let result = export::export(&session.editor.pdf_data(), &source, &destination, &Protection::None, Compression::Standard).unwrap();
    assert_eq!(result.page_count, 2);
    assert!(result.file_size > 0);
    let written = std::fs::read(&destination).unwrap();
    let texts: Vec<_> = page_texts(&written).unwrap().into_iter().map(|t| t.trim().to_owned()).collect();
    assert_eq!(texts, vec!["Page 1", "Page 3"]);
    assert_eq!(std::fs::read(&source).unwrap(), source_bytes);

    assert_eq!(
        export::export(&session.editor.pdf_data(), &source, &source, &Protection::None, Compression::Standard),
        Err(ExportError::SourceAndDestinationMatch)
    );
    let alias = dir.path().join("./source.pdf");
    assert_eq!(
        export::export(&session.editor.pdf_data(), &source, &alias, &Protection::None, Compression::Standard),
        Err(ExportError::SourceAndDestinationMatch)
    );
    #[cfg(unix)]
    {
        let link = dir.path().join("link.pdf");
        std::os::unix::fs::symlink(&source, &link).unwrap();
        assert_eq!(
            export::export(&session.editor.pdf_data(), &source, &link, &Protection::None, Compression::Standard),
            Err(ExportError::SourceAndDestinationMatch)
        );
    }
    assert_eq!(
        export::export(&session.editor.pdf_data(), &source, &dir.path().join("out.txt"), &Protection::None, Compression::Standard),
        Err(ExportError::InvalidDestination)
    );
}

#[test]
fn export_replaces_an_existing_destination_atomically() {
    let dir = tempfile::tempdir().unwrap();
    let (source, session) = session(&dir, &testing::numbered_pdf(2));
    let destination = dir.path().join("existing.pdf");
    std::fs::write(&destination, b"old contents").unwrap();
    export::export(&session.editor.pdf_data(), &source, &destination, &Protection::None, Compression::Standard).unwrap();
    assert_eq!(page_texts(&std::fs::read(&destination).unwrap()).unwrap().len(), 2);
    let leftovers: Vec<_> = std::fs::read_dir(dir.path())
        .unwrap()
        .filter_map(|entry| entry.ok())
        .filter(|entry| entry.file_name().to_string_lossy().ends_with(".tmp"))
        .collect();
    assert!(leftovers.is_empty(), "temporary files are cleaned up");
}

#[test]
fn protected_export_reuses_session_password() {
    let dir = tempfile::tempdir().unwrap();
    let protected = testing::protected_pdf(&["Secret"], "secret", "secret", AccessPermissions::PRINT);
    let (source, session) = session(&dir, &protected);
    let destination = dir.path().join("protected-out.pdf");
    let protection = Protection::ReuseSessionPassword {
        password: session.session_password().unwrap().to_owned(),
        permissions: session.security.permissions,
    };
    export::export(&session.editor.pdf_data(), &source, &destination, &protection, Compression::Standard).unwrap();
    match loader::open(&destination).unwrap() {
        OpenResult::PasswordRequired(mut locked) => {
            assert!(locked.unlock("wrong").unwrap().is_none());
            let reopened = locked.unlock("secret").unwrap().unwrap();
            assert!(reopened.security.is_encrypted);
            // The session password is both user and owner password, so the
            // reopened session is owner-level; the /P bits must still survive.
            assert!(reopened.security.permissions.has(AccessPermissions::PRINT));
            assert!(!reopened.security.permissions.has(AccessPermissions::ASSEMBLE));
        }
        OpenResult::Opened(_) => panic!("protected output must require its password"),
    }
}

#[test]
fn compression_profiles_preserve_semantics() {
    let dir = tempfile::tempdir().unwrap();
    let (source, session) = session(&dir, &testing::image_pdf(1200, 900));
    let mut sizes = Vec::new();
    for compression in Compression::ALL {
        let destination = dir.path().join(format!("{compression:?}.pdf"));
        let result = export::export(&session.editor.pdf_data(), &source, &destination, &Protection::None, compression).unwrap();
        assert_eq!(result.page_count, 1);
        sizes.push(result.file_size);
    }
    assert!(sizes[1] < sizes[0], "Reduced Size is smaller than Standard: {sizes:?}");
    assert!(sizes[2] <= sizes[1], "Compact is no larger than Reduced Size: {sizes:?}");
}
