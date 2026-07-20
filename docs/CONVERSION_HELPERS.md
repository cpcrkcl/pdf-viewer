# External Conversion Helper Evaluation

PDFViewer 1.0 bundles no external conversion executable. Native conversion covers PDF-to-image, PDF-to-text, images-to-PDF, and page extraction. This decision prevents a helper from escaping the app's file-access boundary, uploading a document, or changing behavior outside the app update process.

## Evaluated options

| Helper | Candidate use | License finding | Shipping decision |
| --- | --- | --- | --- |
| LibreOffice | User-initiated DOCX/PPTX/XLSX to PDF | LibreOffice is provided under MPL 2.0 and includes separately licensed third-party components. | Do not bundle in 1.0. A future integration should require a user-installed, explicitly selected executable and a dedicated sandboxed XPC/helper design. |
| qpdf | Structural PDF transformations and repair | qpdf 12 documentation states Apache License 2.0. | Not needed for shipped native conversions. Re-evaluate only for a concrete operation PDFKit cannot validate. |
| Ghostscript | PDF/PostScript rendering, optimization, or some conversions | Ghostscript is offered under AGPL or a commercial Artifex license. | Do not bundle without legal approval and an explicit compatible distribution choice. |

Official references:

- LibreOffice licensing: https://api.libreoffice.org/share/readme/LICENSE.html
- qpdf licensing: https://qpdf.readthedocs.io/en/12.0/license.html
- Ghostscript licensing FAQ: https://ghostscript.com/faq/index.html

## Required design before adding any helper

1. Make installation explicit and user-controlled; never download a binary in response to opening a document.
2. Pin and verify the executable identity and version. Reject an unexpected path, symlink escape, or changed code signature.
3. Give a sandboxed helper access only to security-scoped input and a fresh temporary output directory.
4. Disable network access for the helper and make the privacy implication visible before conversion.
5. Apply CPU, memory, file-size, page-count, timeout, and cancellation limits.
6. Capture only bounded diagnostics that exclude document contents, filenames, form values, and passwords.
7. Validate the result by format signature and independent reopen before placing it at the user destination.
8. Test unavailable, incompatible, crashing, hanging, malicious, and low-disk helper behavior.

## User-visible unavailable behavior

Office conversion controls must remain absent until a helper meets every requirement above. The app must not imply that renaming an extension is conversion or send a file to an online service as fallback.
