# Security and Privacy

## Security model

- PDFs and their metadata, outlines, annotations, actions, and links are untrusted input.
- The sandbox grants only user-selected read/write file access. There is no network entitlement.
- The source URL remains separate from the in-memory working copy, and normal export rejects the source as a destination.
- PDF outputs are staged securely, reopened, structurally validated, and only then moved into place.
- Permanent redaction burns annotations, rasterizes affected pages, clears document metadata, reopens output, and verifies that target pages have no searchable text or interactive annotations.
- OCR, image enhancement, conversion, and compression use Apple frameworks locally.
- URL links require an explicit warning and only `https`, `http`, and `mailto` schemes are eligible. Embedded print requests are blocked.
- Passwords exist only in the active document session. Signature image pixels stay in versioned local Application Support storage.

## Data handling

PDFViewer has no accounts, analytics SDK, crash uploader, remote conversion helper, cloud API, or AI/inference dependency. The app does not log document text, filenames, passwords, form values, recognized OCR text, redaction regions, or signature pixels.

## Limits

PDFKit parsing and rendering remain part of the trusted computing base. Redaction intentionally rasterizes affected pages because a black overlay alone is not secure. Visual signatures are not cryptographic. External Office-format conversion is not present, so no helper can silently upload a file.

## Reporting

Do not include a sensitive PDF in a public issue. Send a minimal reproducer with confidential content removed, the macOS version, the PDFViewer version, and exact steps through a private channel agreed with the maintainer. If a real document is essential, obtain explicit secure-transfer instructions first.
