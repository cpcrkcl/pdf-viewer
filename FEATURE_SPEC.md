# PDFViewer Feature Expansion Specification

**Version:** 1.0  
**Status:** Implemented historical milestone; superseded for current support by `RELEASE_STATUS.md`  
**Scope:** Printing, optimized export, visual signatures, and multiple windows/tabs  
**Related specifications:** `MVP_SPEC.md`, `POST_MVP_SPEC.md`

## 1. Product boundary

These features extend PDFViewer without changing its safety model. All document processing remains local, sandboxed, account-free, and network-free. The source PDF is read-only: printing uses the in-memory working document, and every file-producing operation creates a distinct validated output.

Visual signatures are images placed by the user. They are not cryptographic signatures, identity verification, certificates, or legal-signature claims. AI document features remain permanently excluded.

## 2. Printing

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `PRT-001` | Print the active working document with the native macOS print workflow. | File > Print… and Command-P print the live PDFKit document, including in-memory page edits and annotations. |
| `PRT-002` | Respect source printing permissions. | Unencrypted and owner-unlocked documents may print; user-unlocked encrypted documents require low- or high-quality printing permission. |
| `PRT-003` | Keep printing revision-neutral. | Requesting, cancelling, or completing printing does not dirty the PDF or protect an unexported revision. |
| `PRT-004` | Expose correct command state. | Print is disabled when no document is active or source permissions prohibit printing. |

## 3. Optimized export

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `CMP-001` | Offer Standard, Reduced Size, and Compact output profiles. | Every working-copy and extraction save panel includes a labeled compression picker defaulting to Standard. |
| `CMP-002` | Preserve PDF semantics while optimizing images. | Reduced Size writes images as JPEG; Compact also optimizes oversized images for screen use without re-rendering PDF pages. |
| `CMP-003` | Compose compression and encryption. | Compression write options and session-password protection are supplied in one PDFKit write operation. |
| `CMP-004` | Validate optimized output before placement. | Page count, order, rotations, searchable text, annotations, ownership, and required encryption survive temporary-file reopen validation. |
| `CMP-005` | Report completed output size. | The non-blocking export receipt displays the validated destination file size. |
| `CMP-006` | Preserve source safety. | Compression never modifies or replaces the source PDF. |

## 4. Visual signatures

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `SIG-001` | Maintain a local visual-signature library. | Users can draw or import PNG/JPEG signatures, preview them, and delete them from versioned Application Support storage. |
| `SIG-002` | Place a selected signature on a PDF page. | The Signature annotation tool places the chosen image at the clicked page-space point. |
| `SIG-003` | Offer Small, Medium, and Large placement sizes plus quarter-turn rotation. | Presets change width while preserving image aspect ratio; rotate-left and rotate-right preserve the visible appearance through reopen. |
| `SIG-004` | Reuse annotation ownership and history. | Every placed signature has a `pdfviewer:` ownership marker and supports selection, drag or arrow-key movement, deletion, one-step undo, and redo. |
| `SIG-005` | Respect commenting permission. | Signature placement and modification are disabled when an encrypted user-level session does not allow commenting. |
| `SIG-006` | Preserve appearance through export and reopen. | The validated output retains signature subtype, identifier, bounds, image data, and visible appearance. |
| `SIG-007` | Avoid legal or cryptographic claims. | UI and documentation identify the feature as a visual image only; no certificate, verification, or legal-validity claim is shown. |
| `SIG-008` | Keep signature data local. | Library pixels and metadata are never sent to a network, analytics, or inference service. |

The signature annotation uses the same protected-revision rules as other annotations. Placement changes remain in the working copy until a distinct export succeeds, and the source hash remains unchanged.

## 5. Multiple windows and tabs

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `WIN-001` | Give every window independent document state. | Each window owns its session, editor, reader, search, annotation, organizer, and navigation history. |
| `WIN-002` | Share only application-level services. | Recents, bookmarks, signature storage, loading, and exporting are shared safely across window states. |
| `WIN-003` | Route commands to the focused window. | File, Edit, Find, Navigate, View, Print, and monitored keyboard actions operate on the key window and use its disabled states. |
| `WIN-004` | Create native windows and tabs. | Command-N opens a new window; automatic macOS window tabbing and standard Window-menu tab actions are enabled. |
| `WIN-005` | Open recent files in a new window. | Every Recent Documents row includes a discoverable Open in New Window action. |
| `WIN-006` | Keep same-file sessions independent. | Opening one source PDF in two windows creates two working copies; changes, undo history, selection, and export safety do not leak between them. |
| `WIN-007` | Aggregate protected quit handling. | Quit reviews every window with unexported changes; each can Export and Continue, Discard, or Cancel, and one Cancel stops termination. |
| `WIN-008` | Preserve per-window replacement safety. | Opening a PDF in the frontmost window uses that window's existing guarded replacement flow and does not affect other windows. |

The registry that maps native windows to `AppState` instances holds weak references, so closing a window releases its working session and in-memory password. Exporting in one window protects only that window's exact revision.

## 6. Acceptance workflows

### `FEATURE-FLOW-001`: Permission-aware printing

Print an edited unencrypted document, then owner- and user-unlocked encrypted fixtures with printing allowed and denied. Confirm the native panel prints the working copy, command disabled states are correct, and no revision state changes.

### `FEATURE-FLOW-002`: Optimized and encrypted output

Export an image-heavy annotated PDF with all three profiles, compare output sizes, reopen each file, and verify text, pages, rotations, and annotations. Repeat Compact export with an encrypted session and verify the wrong password fails while the session password succeeds.

### `FEATURE-FLOW-003`: Visual-signature round trip

Draw and import signatures, relaunch the library, place all three sizes, undo/redo and delete placements, export, reopen, and compare ownership, bounds, pixels, and appearance. Verify commenting-denied sessions cannot place one and the UI makes no cryptographic claim.

### `FEATURE-FLOW-004`: Independent windows and guarded quit

Open the same PDF in two windows, mutate only one, and verify the other remains unchanged. Exercise focused commands in both windows, open a Recent item in a third window, merge windows into tabs, then quit with multiple dirty sessions. Confirm every dirty session is reviewed and Cancel stops the quit.

## 7. Explicit non-goals for this historical milestone

- Cryptographic or certificate-backed signatures.
- Signature identity verification, legal-validity assessment, or remote signing.
- Freeform handle-based signature resizing and pressure-sensitive signature placement.
- Printing to an app-managed cloud service.
- Re-rendering pages to raster images for compression.
- Cross-window shared undo history or synchronized working copies.
- Automatic conflict resolution when the same source is open twice.
- Replacing or overwriting source PDFs.
- OCR, forms, redaction, and conversion were outside this milestone and were implemented later as documented in `RELEASE_STATUS.md`. Cloud collaboration and AI features remain unsupported.

## 8. Verification

The feature expansion requires complete unit and UI suites, a Debug build, static analysis, `git diff --check`, code-sign and sandbox-entitlement inspection, representative native GUI checks, export/reopen validation, and source-hash verification. Verification must confirm that no network, cloud, or AI dependency, call, or entitlement was added.
