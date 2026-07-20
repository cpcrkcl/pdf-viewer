# Technical Feasibility Verdicts

These verdicts close the disposable-spike phase from `pdf-mac-app-gameplan.pdf`. Production tests now carry the validated behaviors, so no unsupported prototype binary is shipped.

## Spike A - PDFKit baseline: VALIDATED

PDFKit reliably supports local rendering, thumbnails, search, page insertion/deletion/rotation/reordering, annotations, AcroForm widgets, protected PDFs, printing, and serialized working revisions for this product scope. Stable page IDs are stored alongside each revision because PDFKit page objects are not durable identity.

## Spike B - arbitrary existing-text editing: INVALIDATED

PDFKit does not expose a dependable model for editing and reflowing arbitrary existing page text. Rebuilding selected pages would discard or approximate fonts, shaping, reading order, links, forms, and graphics. PDFViewer therefore supports honest annotations and text notes, not Word-processor-like editing. A future true-content editor requires a separately vetted lower-level or commercial engine plus representative fidelity tests.

## Spike C - format conversion: PARTIAL

Native PDF-to-image, PDF-to-text, images-to-PDF, and page extraction are validated and shipped. Office conversions require a helper with a separate license, install/update lifecycle, sandbox boundary, resource limits, and fidelity fixture suite. No helper is silently invoked or bundled. See `docs/CONVERSION_HELPERS.md`.

## Spike D - OCR and enhancement: VALIDATED

Vision OCR produces searchable copyable text layers for representative scans at user-selected 150, 200, or 300 DPI. Core Image/Vision enhancement provides previewed deskew/perspective correction, grayscale, noise and shadow reduction, background whitening, contrast, sharpening, margin crop, and ordered wide double-page splitting. Processing is incremental, cancellable, local, and undoable before export. Accuracy remains best effort.

## Spike E - visual signatures and redaction: VALIDATED

Local drawn/imported visual signatures survive movement, resizing, quarter-turn rotation, export, and reopen as owned image appearances. They are explicitly non-cryptographic. Permanent redaction removes searchable content by rasterizing only affected pages, optionally burns a visible reason label, burns annotations, clears metadata, and verifies the reopened result.
