# Architecture Decisions

These decisions constrain PDFViewer 1.0 and explain where feasibility work changed the product boundary.

## Local-only processing

PDFKit, Vision, Core Image, Core Graphics, and AppKit perform all document work in-process. The app has no network entitlement, analytics SDK, account system, or remote OCR path. Unified logging accepts only a closed enum of coarse lifecycle events; its API cannot accept filenames, URLs, recognized text, passwords, signatures, page images, or arbitrary strings.

## Originals and revisions

Opening a PDF creates a working document and retains scoped access only for the session. The production open path reads, validates, copies pages, extracts outlines, and serializes the independent working copy on a detached user-initiated task; only value metadata and bytes return to the main actor. A visible loading overlay can cancel the operation, and cancellation releases any security-scoped access. Mutations commit complete, validated PDF snapshots so undo/redo can restore dependable revisions. Export rejects the source URL, writes through a same-directory temporary file, reopens the output for semantic validation, and atomically replaces only the user-selected destination.

## Permanent redaction

A black annotation is not a redaction. Confirmed redaction rasterizes only affected pages, burns opaque covers into their pixels, removes those pages' annotations and searchable content, clears document metadata, and verifies the result after reopening. Unaffected pages remain native PDF pages. This preserves more fidelity while making the selected content unrecoverable from normal PDF objects.

## OCR and enhancement

Vision OCR and deterministic Core Image filters are local and cancellable. Users choose 150, 200, or 300 DPI. Processed pages become page images with an invisible recognized-text layer; unselected pages remain unchanged. Wide scan splitting produces ordered left/right pages with distinct working-page identities in the same undoable revision. Before/after previews make the fidelity tradeoff visible before mutation.

## Existing PDF content editing

The PDFKit spike demonstrated dependable annotation/widget editing but not general reflow of arbitrary existing page content. Word-processor-style editing is therefore unsupported instead of being represented by a misleading overlay UI. The spike record is in `spikes/README.md`.

## Conversion helpers

The shipped app uses only native PDF/image/text conversion. LibreOffice, qpdf, and Ghostscript remain optional operator-reviewed ideas and are neither downloaded nor executed by PDFViewer 1.0. Licensing and sandbox implications are recorded in `docs/CONVERSION_HELPERS.md`.

## Untrusted document actions

The PDF view uses a separate policy delegate. Embedded print requests are blocked, and external `http`, `https`, or `mailto` links require explicit confirmation. Other URL schemes are rejected. Keeping the delegate separate from the `PDFView` subclass also avoids PDFKit delegate re-entry during scale changes.

## Distribution

Release builds enable the App Sandbox and hardened runtime. The repository can produce and verify an ad-hoc signed DMG for local QA. Public distribution is a release-operator action because Developer ID and notarization credentials must not be stored in source control.
