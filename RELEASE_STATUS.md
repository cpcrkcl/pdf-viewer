# Release Status

This matrix is the authoritative support statement for PDFViewer 1.0.0.

## Supported

| Area | Status | Evidence |
| --- | --- | --- |
| Reader and search | Supported | Native PDFKit reader, cancellable off-main large-document preparation, responsive layouts, text search, UI and unit coverage |
| Page organization | Supported | Add, merge, delete, rotate, reorder, extract, undo/redo, export/reopen tests |
| Annotations | Supported | Text markup, freehand, notes, rectangle/oval/line/arrow shapes, built-in stamps, selection movement/resizing, and visual image signatures |
| AcroForm | Supported subset | Text, checkbox, radio, and choice widgets; validation, reset, interactive export, flattening |
| Visual signatures | Supported | Local draw/import library, size presets, drag/keyboard movement, rotation, and owned image annotation round trips |
| Permanent redaction | Supported | Optional burned reason label, confirmation, affected-page rasterization, metadata removal, reopen verification, undo before export |
| OCR | Supported | Local Vision OCR, 150/200/300-DPI searchable output, progress, cancellation, mixed vector/processed output |
| Scan enhancement | Supported | Preview, perspective/deskew, noise/shadow reduction, whitening, contrast, sharpening, margin crop, and wide double-page splitting |
| Native conversion | Supported | PDF to PNG/JPEG/TIFF, PDF to UTF-8 text, images to PDF, extraction |
| Compression | Supported profiles | Standard, Reduced Size, Compact; semantic reopen validation |
| Protected PDFs | Supported subset | Password open, permission enforcement, protected output; protected secondary merge input rejected |
| Multiple windows/tabs | Supported | Independent state, focused commands, aggregate dirty-session quit protection |

## Partial or intentionally constrained

- Imported custom stamp artwork is not included; the standard Approved, Draft, Confidential, Final, and Top Secret stamps are supported.
- OCR is best effort. Handwriting, complex multi-column reading order, and every language are not guaranteed.
- Clean Scan uses deterministic Vision/Core Image rectangle detection and filters; it does not guarantee correction of every skewed or damaged scan.
- Compression validation covers pages, rotations, text, owned annotations, forms, and encryption represented by fixtures; fidelity should still be visually reviewed for publication-critical PDFs.
- Link activation is supported only after an explicit warning for `https`, `http`, or `mailto` URLs.

## Unsupported

- True reflow editing of existing PDF text, images, or page content.
- XFA forms.
- Certificate-backed digital signatures or legal identity verification.
- DOCX/PPTX/XLSX import or PDF-to-Office conversion.
- Cloud storage, sync, collaboration, accounts, analytics, remote OCR, or AI document features.
- Silent source replacement or automatic opening of external links.

## Distribution state

The project has a Release configuration, hardened runtime, sandbox entitlements, file association, automated CI workflow, and a reproducible DMG packaging/notarization script. A public distribution build still requires the release operator's Apple Developer ID Application certificate and notarization credentials; those secrets are intentionally not stored in this repository.

The local 1.0.0 release candidate was archived as a universal `arm64`/`x86_64` app, ad-hoc signed with hardened-runtime and sandbox flags, packaged as `dist/PDFViewer-1.0.0.dmg`, and verified with `codesign`, `hdiutil`, and SHA-256 on July 20, 2026. Its checksum is `657fbc59342b2bfcb1b9fc7b5dd8908476c481cb6c4f1a3044ab692151ba9850`.

Distribution remains pending because this Mac has no Developer ID Application identity and no `notarytool` Keychain profile. Notarization, stapling, Gatekeeper acceptance, upgrade testing, and a clean-user installation smoke test must be performed by the release operator after those credentials and a clean test account are available. The ad-hoc candidate is for local QA, not public distribution.
