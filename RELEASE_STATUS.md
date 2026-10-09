# Release Status

This matrix is the authoritative support statement for PDFViewer 1.0.0.

## Supported

| Area | Status | Evidence |
| --- | --- | --- |
| Reader and search | Supported | Native PDFKit reader, cancellable off-main large-document preparation, custom page labels, case/whole-word search, match navigation, and redaction-candidate creation |
| Page organization | Supported | Add, merge, delete, rotate, reorder, multi-page PDF/image export, undo/redo, and export/reopen tests |
| Annotations | Supported | Text markup, six ink widths, arbitrary colors, owned-ink eraser, notes, shapes, built-in and local custom stamps, navigator, selection movement/resizing, and visual image signatures |
| AcroForm | Supported subset | Text, checkbox, radio, and choice widgets; validation, reset, interactive export, flattening |
| Visual signatures | Supported | Local draw/import library, size presets, drag/keyboard movement, rotation, and owned image annotation round trips |
| Permanent redaction | Supported | Optional burned reason label, confirmation, affected-page rasterization, metadata removal, reopen verification, undo before export |
| OCR | Supported | Local Vision OCR with language and confidence controls, 150/200/300-DPI searchable output, progress, cancellation, and mixed vector/processed output |
| Scan enhancement | Supported | Preview, perspective/deskew, noise/shadow reduction, whitening, contrast, sharpening, margin crop, and wide double-page splitting |
| Conversion | Supported subset | Native PDF to PNG/JPEG/TIFF, PDF to UTF-8 text, images to PDF, extraction; optional Office-to-PDF through a sandboxed XPC service and explicitly selected user-installed LibreOffice executable |
| Compression | Supported profiles | Standard, Reduced Size, Compact; semantic reopen validation |
| Protected PDFs | Supported subset | Password open, permission enforcement, protected output; protected secondary merge input rejected |
| Multiple windows/tabs | Supported | Independent state, focused commands, aggregate dirty-session quit protection |
| Local navigation data | Supported | Versioned JSON import/export for bookmarks and recent documents, with merge, validation, and deduplication |
| Side-by-side comparison | Supported | Independent two-pane PDF viewing with optional synchronized page navigation |

## Partial or intentionally constrained

- OCR is best effort. Handwriting, complex multi-column reading order, and every language are not guaranteed.
- Clean Scan uses deterministic Vision/Core Image rectangle detection and filters; it does not guarantee correction of every skewed or damaged scan.
- Compression validation covers pages, rotations, text, owned annotations, forms, and encryption represented by fixtures; fidelity should still be visually reviewed for publication-critical PDFs.
- Link activation is supported only after an explicit warning for `https`, `http`, or `mailto` URLs.

## Unsupported

- True reflow editing of existing PDF text, images, or page content.
- XFA forms.
- Certificate-backed digital signatures or legal identity verification.
- PDF-to-Office conversion. Office-to-PDF requires a separately installed, user-selected LibreOffice executable and is unavailable otherwise.
- Cloud storage, sync, collaboration, accounts, analytics, remote OCR, or AI document features.
- Silent source replacement or automatic opening of external links.

## Distribution state

The project has a Release configuration, hardened runtime, sandbox entitlements, file association, automated CI workflow, and a reproducible DMG packaging/notarization script. A public distribution build still requires the release operator's Apple Developer ID Application certificate and notarization credentials; those secrets are intentionally not stored in this repository.

The local 1.0.0 release candidate was archived as a universal `arm64`/`x86_64` app, ad-hoc signed with hardened-runtime and sandbox flags, packaged as `dist/PDFViewer-1.0.0.dmg`, and verified with `codesign`, `hdiutil`, and SHA-256 on July 20, 2026. Its checksum is `657fbc59342b2bfcb1b9fc7b5dd8908476c481cb6c4f1a3044ab692151ba9850`.

Distribution remains pending because this Mac has no Developer ID Application identity and no `notarytool` Keychain profile. Notarization, stapling, Gatekeeper acceptance, upgrade testing, and a clean-user installation smoke test must be performed by the release operator after those credentials and a clean test account are available. The ad-hoc candidate is for local QA, not public distribution.
