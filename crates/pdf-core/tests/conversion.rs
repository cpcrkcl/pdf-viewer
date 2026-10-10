use std::collections::BTreeSet;
use std::path::Path;

use pdf_core::conversion::{self, ConversionError, ImageFormat};
use pdf_core::{engine, office, testing};

fn pages(indexes: &[usize]) -> BTreeSet<usize> {
    indexes.iter().copied().collect()
}

#[test]
fn pages_render_to_padded_image_files_without_overwriting() {
    let source = testing::numbered_pdf(12);
    let files = conversion::image_files(&source, &pages(&[0, 11]), ImageFormat::Png, 72, "Re/port").unwrap();
    assert_eq!(files.iter().map(|f| f.filename.as_str()).collect::<Vec<_>>(), ["Re-port-page-01.png", "Re-port-page-12.png"]);
    let decoded = image::load_from_memory(&files[0].data).unwrap();
    assert_eq!((decoded.width(), decoded.height()), (612, 792));
    for format in [ImageFormat::Jpeg, ImageFormat::Tiff] {
        let file = &conversion::image_files(&source, &pages(&[0]), format, 144, "x").unwrap()[0];
        assert!(image::load_from_memory(&file.data).is_ok(), "{format:?} decodes");
    }
    assert_eq!(conversion::image_files(&source, &pages(&[0]), ImageFormat::Png, 600, "x"), Err(ConversionError::InvalidResolution));
    assert_eq!(conversion::image_files(&source, &pages(&[]), ImageFormat::Png, 72, "x"), Err(ConversionError::EmptySelection));

    let directory = tempfile::tempdir().unwrap();
    std::fs::write(directory.path().join("Re-port-page-01.png"), b"keep").unwrap();
    let written = conversion::write_image_files(&files, directory.path()).unwrap();
    assert_eq!(written[0].file_name().unwrap(), "Re-port-page-01-2.png");
    assert_eq!(std::fs::read(directory.path().join("Re-port-page-01.png")).unwrap(), b"keep");
    let leftovers = std::fs::read_dir(directory.path()).unwrap().filter(|e| e.as_ref().unwrap().file_name().to_string_lossy().starts_with('.')).count();
    assert_eq!(leftovers, 0, "staging directory is removed");
}

#[test]
fn text_export_has_page_separators_and_requires_text() {
    let text = conversion::searchable_text(&testing::text_pdf(&["Alpha", "Beta"]), &pages(&[1])).unwrap();
    assert!(text.starts_with("--- Page 2 ---\nBeta"));
    assert_eq!(conversion::searchable_text(&testing::image_pdf(40, 40), &pages(&[0])), Err(ConversionError::NoSearchableText));
    let directory = tempfile::tempdir().unwrap();
    let destination = directory.path().join("out.txt");
    conversion::write_text(&text, &destination).unwrap();
    assert_eq!(std::fs::read_to_string(destination).unwrap(), text);
}

#[test]
fn images_become_pages_in_order() {
    let directory = tempfile::tempdir().unwrap();
    let png = directory.path().join("b.png");
    image::RgbaImage::from_pixel(300, 200, image::Rgba([10, 20, 30, 128])).save(&png).unwrap();
    let jpeg = directory.path().join("a.jpg");
    image::RgbImage::from_pixel(100, 400, image::Rgb([200, 0, 0])).save(&jpeg).unwrap();
    let pdf = conversion::pdf_from_images(&[png, jpeg.clone()]).unwrap();
    let infos = pdf_core::text::page_infos(&pdf).unwrap();
    assert_eq!(infos.iter().map(|i| i.geometry.display_size()).collect::<Vec<_>>(), [(300.0, 200.0), (100.0, 400.0)]);
    assert!(pdf.windows(9).any(|w| w == b"DCTDecode"), "upright JPEG is embedded unchanged");
    assert!(engine::load(pdf, None).is_ok());

    let bogus = directory.path().join("c.png");
    std::fs::write(&bogus, b"not an image").unwrap();
    assert_eq!(conversion::pdf_from_images(&[bogus]), Err(ConversionError::InvalidImage("c.png".into())));
    assert_eq!(conversion::pdf_from_images(&[]), Err(ConversionError::NoImages));
}

#[cfg(unix)]
fn fake_soffice(directory: &Path, fixture: &Path, exit: i32) -> std::path::PathBuf {
    use std::os::unix::fs::PermissionsExt;
    let path = directory.join("soffice");
    let script = format!(
        "#!/bin/sh\nwhile [ $# -gt 0 ]; do case \"$1\" in --outdir) shift; out=\"$1\";; esac; last=\"$1\"; shift; done\n\
         name=$(basename \"$last\"); cp '{}' \"$out/${{name%.*}}.pdf\"\nexit {exit}\n",
        fixture.display()
    );
    std::fs::write(&path, script).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
    path
}

#[cfg(unix)]
#[test]
fn office_conversion_validates_inputs_and_output() {
    let directory = tempfile::tempdir().unwrap();
    let fixture = directory.path().join("fixture.pdf");
    std::fs::write(&fixture, testing::numbered_pdf(2)).unwrap();
    let document = directory.path().join("Letter.docx");
    std::fs::write(&document, b"fake docx").unwrap();

    let soffice = fake_soffice(directory.path(), &fixture, 0);
    let pdf = office::convert(&soffice, &document).unwrap();
    assert!(office::validate_output(&pdf).is_ok());

    assert_eq!(office::convert(&fixture, &document), Err(office::OfficeError::InvalidExecutable));
    assert_eq!(office::convert(&soffice, &fixture), Err(office::OfficeError::InvalidSelection));
    let failing_directory = tempfile::tempdir().unwrap();
    let failing = fake_soffice(failing_directory.path(), &fixture, 3);
    assert_eq!(office::convert(&failing, &document), Err(office::OfficeError::ConversionFailed));
    assert!(office::validate_output(b"%PDF-garbage").is_err());
}

#[cfg(target_os = "macos")]
#[test]
fn heic_images_are_converted_locally() {
    let directory = tempfile::tempdir().unwrap();
    let png = directory.path().join("photo.png");
    image::RgbImage::from_pixel(64, 48, image::Rgb([0, 120, 200])).save(&png).unwrap();
    let heic = directory.path().join("photo.heic");
    let made = std::process::Command::new("/usr/bin/sips").args(["-s", "format", "heic"]).arg(&png).arg("--out").arg(&heic).output().unwrap();
    assert!(made.status.success());
    let pdf = conversion::pdf_from_images(&[heic]).unwrap();
    assert_eq!(pdf_core::text::page_infos(&pdf).unwrap()[0].geometry.display_size(), (64.0, 48.0));
}
