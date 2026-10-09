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
- `crates/pdf-ocr`: Apple Vision text recognition and page-edge detection
  (objc2-vision), scan enhancement with `image`/`imageproc`, and the
  invisible text layer for searchable pages.
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
- Permanent redaction: redact tool, marked search matches, reason label,
  confirmation, applied as one undoable revision.
- OCR & scan enhancement (Pages ▸ OCR & Scan Enhancement…, or the toolbar
  OCR button): selected or all pages, language, minimum confidence, Clean
  Scan (perspective correction, shadow flattening, whitening, sharpening),
  raster quality, crop margins, double-page splitting, live before/after
  preview, cancellable progress. The text layer is a Type0 font whose CIDs
  are Unicode values, so any BMP script is searchable.
- Conversion (File ▸ Convert…): PDF pages to PNG/JPEG/TIFF at 72–300 DPI
  (never overwriting, all-or-nothing), PDF to UTF-8 text, images (PNG, JPEG,
  TIFF, HEIC via `sips`) to a new PDF, and Office to PDF through the
  `PDFViewerOfficeHelper` binary and a user-chosen LibreOffice `soffice`.

## Remaining

1. Printing (NSPrintOperation through objc2), a native macOS menu bar, and
   Finder open-file events.
2. Packaging: an `.app` bundle with `libpdfium.dylib` in `Contents/Frameworks`,
   `PDFViewerOfficeHelper` next to the app binary in `Contents/MacOS` (it
   should get its own sandbox entitlements: user-selected files, no network),
   entitlements, and an updated `scripts/package-release.sh`.
3. Remove the Swift sources and the Xcode project once at parity.
