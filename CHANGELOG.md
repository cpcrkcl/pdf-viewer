# Changelog

## Unreleased

- Added case-sensitive and whole-word search, a navigable match list, and selection of search hits as reviewable redaction candidates.
- Added an annotation/form navigator, owned-ink eraser and deletion, six ink widths, arbitrary annotation colors, and a local custom-stamp artwork library.
- Expanded page organization with selected-page PDF and PNG/JPEG/TIFF export.
- Added OCR language and minimum-confidence controls.
- Added versioned JSON import/export for bookmarks and recent documents.
- Added side-by-side PDF comparison with optional synchronized page navigation and configurable page labels/numbering.
- Added optional local Office-to-PDF conversion through a sandboxed XPC service and an explicitly selected user-installed LibreOffice executable; no converter is bundled or downloaded.
- Expanded UI coverage across forms, OCR, redaction, and conversion surfaces.
- Fixed laggy live window resizing by replacing the reader toolbar's `ViewThatFits` tiers with a width-tracking container that measures the wide layout once instead of re-measuring every candidate on each resize frame.
- Fixed the welcome-screen and File > Open PDF picker not appearing because multiple SwiftUI `.fileImporter` modifiers were stacked on the same view.

## 1.0.0 - 2026-07-20

- Shipped the local-first reader, search, page organizer, safe export, optimized compression, printing, protected-PDF, multi-window, and navigation foundations.
- Moved large-document reading, validation, page copying, outline extraction, and working-copy serialization off the main actor with visible progress, cancellation, and security-scope cleanup.
- Added owned text markup, ink, notes, rectangle/oval/line/arrow shapes, built-in stamps, selection movement/resizing, and local visual-signature images with rotation, undo/redo, and validated round trips.
- Added AcroForm discovery, typed filling, validation, reset, interactive export, and flattened-copy export.
- Added permanent confirmed redaction with optional burned reason labels, affected-page rasterization, metadata removal, and reopened-output verification.
- Added local Vision OCR, 150/200/300-DPI scan enhancement, before/after preview, perspective/deskew, noise and shadow reduction, whitening, margin cropping, double-page splitting, progress, cancellation, and searchable output.
- Added native PDF-to-image, PDF-to-text, images-to-PDF, and page-extraction conversion.
- Added external-link confirmation, embedded-print blocking, hardened/sandboxed release settings, CI, DMG packaging, notarization support, security guidance, and an explicit support matrix.
