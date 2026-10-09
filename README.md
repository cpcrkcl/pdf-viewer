# PDFViewer

PDFViewer is an original, local-first macOS PDF utility built with Swift 6, SwiftUI, AppKit, PDFKit, Vision, Core Image, and Core Graphics. It reads and edits a protected in-memory working copy, never silently replaces the source, and performs OCR, enhancement, redaction, and conversion entirely on the Mac.

The implementation follows the attached `pdf-mac-app-gameplan.pdf`. Historical milestone requirements remain in `MVP_SPEC.md`, `POST_MVP_SPEC.md`, and `FEATURE_SPEC.md`; the current support matrix is in `RELEASE_STATUS.md`.

The major feasibility, privacy, redaction, revision, helper, and distribution choices are recorded in `docs/ARCHITECTURE_DECISIONS.md`.

## Supported workflows

- Open, cancel, close, drag in, reopen, and manage recent local PDFs, including password-protected documents; large working copies are prepared away from the main actor behind a visible loading state.
- Use independent windows or tabs, thumbnails, outlines, local bookmarks, Back/Forward history, page-number navigation, custom displayed page labels, three layouts, zoom, and Day/Night/Sepia themes; compare two PDFs side by side with optional page synchronization.
- Search existing or locally OCR-created text with case/whole-word controls, a match list, direct navigation, and search-match-to-redaction selection.
- Select, add, merge, delete, rotate, reorder, and batch-export chosen pages as a PDF or numbered PNG/JPEG/TIFF set with undo/redo.
- Add, select, move, resize, restyle with arbitrary colors and six line widths, erase owned ink, delete, export, and reopen highlights, underlines, strikethroughs, freehand ink, text notes, rectangles, ovals, lines, arrows, built-in or locally imported custom stamps, and visual-signature image stamps; visual signatures can also be rotated.
- Discover and fill AcroForm text, checkbox, radio, and choice fields; validate required fields, reset them, export interactive values, or flatten a sharing copy.
- Mark multiple redaction regions, optionally burn a visible reason label into them, review them, explicitly confirm permanent application, clear metadata, and remove underlying content by rasterizing only affected pages.
- Run Vision OCR and deterministic scan enhancement locally with language and minimum-confidence controls, before/after preview, 150/200/300-DPI output, deskew/perspective correction, noise and shadow reduction, background whitening, grayscale or clean-scan processing, margin cropping, double-page splitting, progress, cancellation, and undo.
- Convert selected PDF pages to PNG, JPEG, or TIFF; export searchable UTF-8 text; create a PDF from local images; and reopen/validate generated PDFs.
- Export/import versioned bookmark and recent-document JSON. Optionally convert user-selected Office documents through a sandboxed XPC service and a user-installed, explicitly selected LibreOffice `soffice` executable; LibreOffice is never bundled or downloaded.
- Print the current working copy and export Standard, Reduced Size, or Compact PDFs, including protected output when the source session requires it.
- Confirm external URL links before opening them and block document-triggered printing.

Every file-producing PDF workflow uses a temporary output, reopens and validates it, then places the completed file at the user-selected destination. Page-image conversion never overwrites an existing output filename. The app sandbox has only user-selected read/write access and no network entitlement.

## Honest boundaries

- Visual signatures are image annotations, not certificate-backed or identity-verified digital signatures.
- AcroForm is supported; XFA is not claimed.
- Text notes and annotations do not provide Word-processor-like editing of existing PDF text. PDFKit cannot reliably reflow arbitrary existing content; see `spikes/README.md`.
- Native conversion covers PDF-to-image, PDF-to-text, images-to-PDF, and page extraction. Optional Office conversion requires a user-installed LibreOffice executable and the restricted XPC workflow described in `docs/CONVERSION_HELPERS.md`; no helper executable is bundled.
- Handwriting-specific OCR guarantees, cryptographic signing, cloud sync, collaboration, and AI document assistants are unsupported.
- The app never automatically replaces the original PDF.

## Build and test

Requires macOS 14 or later and a full Xcode installation.

```sh
xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -destination 'platform=macOS,arch=arm64' \
  build CODE_SIGNING_ALLOWED=NO
```

```sh
xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -destination 'platform=macOS,arch=arm64' \
  test -only-testing:PDFViewerTests CODE_SIGNING_ALLOWED=NO
```

UI tests require macOS Automation Mode and locally signed runners:

```sh
xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -destination 'platform=macOS,arch=arm64' \
  test -only-testing:PDFViewerUITests \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO
```

The suites cover source preservation, asynchronous large-document preparation and cancellation, malformed and protected input, permissions, page operations and selected-page exports, configurable search and redaction candidates, navigation identity and JSON transfer, annotations, custom stamps and visual signatures, forms and flattening, permanent redaction, local configurable OCR/enhancement/cropping, native and optional Office conversion surfaces, compression, encrypted output, multiple windows, lifecycle guards, and responsive reader behavior.

## Package a release

```sh
./scripts/package-release.sh
```

With no Developer ID identity, the script produces a locally verifiable ad-hoc-signed DMG. For distribution, set `CODE_SIGN_IDENTITY` to a Developer ID Application identity and `NOTARY_PROFILE` to a `notarytool` Keychain profile; the script signs, submits, staples, verifies, and emits a SHA-256 checksum. See `RELEASE.md`.

## Privacy and security

There are no accounts, analytics, cloud services, remote OCR calls, or inference dependencies. Document contents, recognized text, page images, passwords, and signatures are not logged or uploaded. Report security issues using the private process in `SECURITY.md` rather than a public issue.
