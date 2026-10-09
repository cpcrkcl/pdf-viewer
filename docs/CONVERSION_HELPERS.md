# External Conversion Helper Evaluation

PDFViewer bundles no external conversion executable. Native conversion covers PDF-to-image, PDF-to-text, images-to-PDF, and page extraction. Optional Office-to-PDF conversion is available only after the user explicitly selects a locally installed LibreOffice `soffice` executable.

## Evaluated options

| Helper | Candidate use | License finding | Shipping decision |
| --- | --- | --- | --- |
| LibreOffice | User-initiated DOC/DOCX, PPT/PPTX, XLS/XLSX, ODT/ODS/ODP to PDF | LibreOffice is provided under MPL 2.0 and includes separately licensed third-party components. | Optional user-installed integration through the separate `PDFViewerOfficeHelper` process (Swift: the sandboxed `PDFViewerOfficeConversionHelper` XPC target); never bundled or downloaded. |
| qpdf | Structural PDF transformations and repair | qpdf 12 documentation states Apache License 2.0. | Not needed for shipped native conversions. Re-evaluate only for a concrete operation PDFKit cannot validate. |
| Ghostscript | PDF/PostScript rendering, optimization, or some conversions | Ghostscript is offered under AGPL or a commercial Artifex license. | Do not bundle without legal approval and an explicit compatible distribution choice. |

Official references:

- LibreOffice licensing: https://api.libreoffice.org/share/readme/LICENSE.html
- qpdf licensing: https://qpdf.readthedocs.io/en/12.0/license.html
- Ghostscript licensing FAQ: https://ghostscript.com/faq/index.html

## Implemented helper boundary

The Rust app (`crates/pdf-core/src/office.rs`, `crates/app/src/bin/office_helper.rs`) runs the helper as a child process with the chosen paths as arguments; it writes the PDF to standard output and short generic errors to standard error. It also gives LibreOffice a private profile directory so a running LibreOffice instance can't interfere. The Swift XPC design below applies until the Swift target is removed; the Rust bundle should give the helper equivalent sandbox entitlements.

1. Installation is explicit and user-controlled. PDFViewer accepts only a selected regular, executable, non-symlink file named `soffice` and stores its security-scoped bookmark.
2. The app sends security-scoped bookmarks for only that executable and the selected Office document to an embedded XPC service.
3. The XPC target is sandboxed, has user-selected file access, and has no network entitlement. It writes only to a fresh mode-0700 temporary directory.
4. Inputs are restricted by extension, regular-file status, symlink status, and a 1 GiB ceiling. The process has a 120-second timeout and no standard input.
5. Diagnostics returned to the app are bounded, generic errors and never include document contents, form values, or passwords.
6. The helper accepts exactly one regular PDF output under 256 MiB with a PDF signature. The app independently enforces the same ceiling, verifies the signature, reopens it with PDFKit, requires at least one page, and only then offers a save destination.
7. The source Office document is never overwritten, and there is no online fallback.

## User-visible unavailable behavior

Office conversion remains disabled until the user selects a valid `soffice` executable. If LibreOffice is absent, incompatible, crashes, hangs, or returns invalid output, conversion fails locally and recoverably; the app does not rename extensions or use an online service.
