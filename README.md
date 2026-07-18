# PDFViewer

PDFViewer is a local-first native macOS PDF reader and organizer built with SwiftUI, AppKit, and PDFKit. The original scope baseline lives in [`MVP_SPEC.md`](MVP_SPEC.md); implemented post-MVP annotation, security, and navigation requirements live in [`POST_MVP_SPEC.md`](POST_MVP_SPEC.md).

## Implemented features

- Open a local PDF through the macOS file importer.
- Open one local PDF by dropping it from Finder onto the reader.
- Keep the source file open as read-only security-scoped input.
- Display PDF pages with a native PDFKit reader.
- Navigate with synchronized page thumbnails, a page-number field, PDF outlines, local bookmarks, search results, and Back/Forward history.
- Use a three-tab reader sidebar for Thumbnails, Contents, and Bookmarks.
- Collapse the sidebar or resize it between 136 and 260 points without changing the document.
- Use the complete reader and organizer from a 720×520 content area through full screen; compact windows move secondary actions into clear overflow menus.
- Switch between single-page, two-page, and continuous layouts.
- Switch between distinct Day and Night workspace themes without modifying the PDF.
- Fit, zoom in, and zoom out.
- Close the active document without writing to it.
- Reopen one of the ten most recent documents using security-scoped bookmarks.
- Present recoverable errors for missing, unreadable, corrupt, and non-PDF input.
- Unlock password-protected PDFs through a native retryable prompt while preserving the current session on failure or cancellation.
- Keep passwords only in active-session memory and enforce source commenting, assembly, and copying permissions.
- Search existing PDF text case-insensitively, highlight all results, and navigate between matches.
- Explain when an image-only PDF has no searchable text and OCR is not available yet.
- Create a safe in-memory working copy before editing pages.
- Select one or more pages in the page organizer, then move, rotate, or delete them with undo and redo.
- Drag selected organizer rows to reorder one or multiple pages while preserving their relative order.
- Add selected pages from another local PDF or merge an entire local PDF into the working copy.
- Extract selected pages into a separate PDF.
- Export a distinct output PDF through a temporary file that is reopened and validated before completion.
- Confirm successful exports with a persistent receipt and a Show in Finder action.
- Warn before Close, replacement Open, window close, or Quit would discard an unexported revision.
- Treat the original and each validated full-document export as safe revisions; later edits warn again.
- Use native menu shortcuts for Open, Close, undo/redo, search, page navigation, zoom, and viewing modes.
- Keep source PDFs unchanged while working-copy changes are pending and after export.
- Create highlight, underline, strikethrough, freehand ink, and text-note annotations with compact tool symbols and Black as the default color.
- Edit, restyle, and delete PDFViewer-created annotations while leaving third-party annotations visible and read-only.
- Preserve annotations through validated export and reopen.
- Keep encrypted working-copy and extracted output encrypted with the active session password after an explicit security warning.
- Persist local page bookmarks by SHA-256 document identity across launches without embedding them in PDF data.
- Preserve bookmark, outline, and history destinations through page reorder, deletion, undo, and redo using stable working-page identities.
- Bound untrusted outline traversal to 128 levels, 20,000 nodes, and 512-character labels.

## Approved boundaries and deferred capabilities

Local OCR, scan enhancement, forms, signatures, redaction, conversion, compression, cloud synchronization, collaboration, printing, advanced annotation tools, outline editing, bookmark synchronization, and password-protected secondary imports are not implemented. Source PDFs are never replaced or overwritten.

## Permanent product exclusions

PDFViewer will not add AI document assistants, generated summaries, document chat, generative extraction, recommendations, or local or remote inference over document contents. PDF data stays on the Mac and is never sent to an inference service. Local OCR remains a separate deferred capability and is not part of the current milestone.

## Build and test

The repository uses the full Xcode installation at `/Applications/Xcode.app`. The active system developer directory may still point at Command Line Tools, so commands set `DEVELOPER_DIR` explicitly.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -destination 'platform=macOS,arch=arm64' \
  build
```

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild \
  -project PDFViewer.xcodeproj \
  -scheme PDFViewer \
  -destination 'platform=macOS,arch=arm64' \
  test
```

The automated suite covers document validation/source preservation, recent-document persistence, responsive layouts, annotation ownership and round trips, encrypted open/export behavior, permission enforcement, stable page identity, bounded outline parsing, bookmark persistence, navigation-history branching, guarded lifecycle actions, drag reorder, search, export feedback, undo/redo, and page extraction.
