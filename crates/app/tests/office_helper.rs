//! Runs the real `PDFViewerOfficeHelper` binary against a stand-in `soffice`.
#![cfg(unix)]

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

fn fake_soffice(directory: &Path, fixture: &Path) -> std::path::PathBuf {
    let path = directory.join("soffice");
    let script = format!(
        "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in --outdir) shift; out=\"$1\";; esac; last=\"$1\"; shift; done\n\
         name=$(basename \"$last\"); cp '{}' \"$out/${{name%.*}}.pdf\"\n",
        fixture.display()
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[test]
fn helper_returns_a_validated_pdf_and_reports_errors() {
    let helper = Path::new(env!("CARGO_BIN_EXE_PDFViewerOfficeHelper"));
    let directory = tempfile::tempdir().unwrap();
    let fixture = directory.path().join("fixture.pdf");
    std::fs::write(&fixture, pdf_core::testing::numbered_pdf(3)).unwrap();
    let document = directory.path().join("Deck.pptx");
    std::fs::write(&document, b"fake pptx").unwrap();
    let soffice = fake_soffice(directory.path(), &fixture);

    let pdf = pdf_core::office::convert_with_helper(helper, &soffice, &document).unwrap();
    assert_eq!(pdf_core::editor::validated_page_count(&pdf).unwrap(), 3);

    let unsupported = directory.path().join("notes.txt");
    std::fs::write(&unsupported, b"x").unwrap();
    let error = pdf_core::office::convert_with_helper(helper, &soffice, &unsupported).unwrap_err();
    assert_eq!(error, "Choose a supported local Office document.");
}
