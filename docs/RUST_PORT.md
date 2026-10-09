# Rust port status

Branch: `rust-rewrite`. The Swift sources stay in the tree as the reference
implementation until every row of `RELEASE_STATUS.md` works in Rust.

## Build and run

```sh
export PATH=/opt/homebrew/opt/rustup/bin:$PATH   # Homebrew rustup is keg-only
./scripts/fetch-pdfium.sh                          # once; populates vendor/pdfium
cargo test --workspace
cargo run -p pdfviewer -- some.pdf
```

`PDFVIEWER_CAPTURE=/tmp/shot.png` makes the app save a screenshot of its own
window and quit (see `crates/app/src/debug_capture.rs` for scenario flags).

## Architecture

- `crates/pdf-core`: lopdf for the working copy and every structural edit;
  PDFium (pdfium-render) for rendering, text, search and output validation.
  Revisions are validated byte snapshots, as in the Swift editor.
- `crates/app`: egui/eframe UI.

## Done

- Open, password/permissions, protected working copy, undo/redo, page
  operations (rotate, move, delete, insert, extract), validated atomic export
  with compression profiles and re-encryption, recents, bookmarks, history.
- Reader: tabs, continuous/single/two-page, zoom, themes, thumbnails,
  outline, page labels, drag-and-drop, unsaved-changes protection.
- Search (case, whole word, diacritics), text selection and copy, links with
  confirmation for external URLs.
- Annotations (all Swift tools), generated appearances, stamps, visual
  signatures, signature and stamp libraries, owned-annotation navigator.
  Swift `pdfviewer:` IDs and signature keys are kept, so documents round-trip.
- AcroForm fill, validate, reset, JSON value export, flattening.
- Redaction core (`redaction.rs`): tested, **not yet wired into the UI**.

## Remaining

1. Redaction UI: a redact tool that draws regions, "mark search matches for
   redaction" (the checkboxes already exist in Search results), reason label,
   and a confirmation dialog, applied via `editor.apply_processed_document`.
2. OCR via Vision (`objc2-vision`) and scan enhancement with `image`/`imageproc`
   (deskew, whitening, crop, split); `raster.rs` has the page-replacement
   helpers.
3. Conversion: PDF to PNG/JPEG/TIFF and text, images to PDF, and the Office
   helper as a small Rust binary.
4. Printing (NSPrintOperation through objc2), a native macOS menu bar, and
   Finder open-file events.
5. Packaging: an `.app` bundle with `libpdfium.dylib` in `Contents/Frameworks`,
   entitlements, and an updated `scripts/package-release.sh`.
6. Remove the Swift sources and the Xcode project once at parity.
