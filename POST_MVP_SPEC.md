# PDFViewer Post-MVP Specification

**Version:** 1.0  
**Status:** Implemented product baseline  
**Scope:** Basic annotations, password-protected PDFs, and reading navigation  
**Related baseline:** `MVP_SPEC.md`; later implemented expansion: `FEATURE_SPEC.md`

## 1. Purpose and boundaries

This specification extends the original PDFViewer MVP without changing its historical scope. PDFViewer remains a native, local-only, sandboxed, account-free, and network-free macOS application. It never replaces or overwrites a source PDF.

The post-MVP scope contains three ordered milestones:

1. Basic annotations.
2. Password-protected PDF support.
3. Document outlines, local bookmarks, and navigation history.

AI document features and inference are permanently excluded. OCR, forms, redaction, conversion, cloud synchronization, and collaboration remain deferred. Printing, optimized export, and visual signatures were approved later and are specified separately in `FEATURE_SPEC.md`.

## 2. Approved product decisions

- PDFViewer-created annotations are editable and removable after export and reopen.
- Existing third-party annotations remain visible and read-only.
- A password supplied to unlock an encrypted source is held only in active-session memory and is reused for encrypted output.
- Encrypted output uses the session password for both user and owner access. Before export, PDFViewer warns that original owner credentials and user/owner permission separation cannot be reproduced.
- Passwords are never written to Keychain, UserDefaults, logs, analytics, the clipboard, crash-report fields, or synchronization storage. Closing or replacing the session discards the retained password. No secure-zeroization claim is made for Swift `String` memory.
- Bookmark metadata is local presentation state. It is stored in UserDefaults and is never embedded in a PDF.
- No PDF content may be sent to an inference or other network service.

## 3. Milestone 1 — Basic annotations

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `ANN-001` | Create highlight annotations from native PDF text selection. | A valid selection produces highlight annotations over every selected text region as one undoable operation. |
| `ANN-002` | Create underline annotations from selected text. | A valid selection produces underline annotations over the selected regions. |
| `ANN-003` | Create strikethrough annotations from selected text. | A valid selection produces strikethrough annotations over the selected regions. |
| `ANN-004` | Draw freehand ink with a mouse or trackpad. | One completed drag that begins on a page produces one page-coordinate ink annotation and one history revision. |
| `ANN-005` | Place text-note annotations. | Placement mode accepts a page location and up to 10,000 characters; cancellation or empty content creates no revision. |
| `ANN-006` | Select, restyle, edit, and delete PDFViewer-owned annotations. | Owned annotations support applicable color, ink-width, note-content, and delete actions. |
| `ANN-007` | Display third-party annotations read-only. | Unowned annotations remain visible; attempted modification is blocked with an explanation. |
| `ANN-008` | Make annotation changes independently undoable and redoable. | Each completed create, style, content, or delete action is one document-history revision. |
| `ANN-009` | Treat annotation changes as unexported document revisions. | A changed annotation triggers the same guarded lifecycle behavior as a page mutation. |
| `ANN-010` | Preserve annotations through validated export and reopen. | Subtype, content, color, geometry, ink width, and ownership survive output validation and reopen. |
| `ANN-011` | Keep annotation controls usable from 720×520 through full screen. | Regular controls adapt to labeled compact Tool and Style menus without truncated actions. |
| `ANN-012` | Never modify the source PDF. | Annotation work occurs only in the in-memory working document and distinct exported output. |

### 3.1 Ownership

Every created annotation has:

- A standard PDF annotation name beginning with `pdfviewer:` followed by a lowercase UUID.
- `userName` equal to `PDFViewer`.
- A modification date.

The annotation name is authoritative. PDFViewer also writes a compatible custom ownership key so PDFKit round-trips that do not retain the standard name can still preserve the marker. An annotation without a valid marker is not editable.

### 3.2 Tools and styles

The committed tools are Select, Highlight, Underline, Strikethrough, Freehand, and Text Note. The curated palette is Yellow, Green, Blue, Pink, Red, and Black. Black is the default selected color; highlight opacity remains 35%, and default ink width is 3 points. Ink widths are Fine (1.5 points), Standard (3 points), and Bold (5 points).

There is no arbitrary color picker, pressure sensitivity, eraser, shape, move, or resize tool in this milestone. Visual-signature stamps were approved as a later, narrowly defined feature in `FEATURE_SPEC.md`. Escape leaves drawing or placement mode. Opening the page organizer ends annotation interaction and clears the annotation selection without discarding revisions.

## 4. Milestone 2 — Password-protected PDFs

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `SEC-001` | Detect locked PDFs and request a password. | A locked local PDF opens a native secure prompt without releasing the current session. |
| `SEC-002` | Keep incorrect-password errors recoverable. | A failed attempt shows inline feedback and leaves the prompt ready for another attempt. |
| `SEC-003` | Preserve the current document when unlock is cancelled. | Cancelling a replacement unlock releases the pending handle and leaves the existing working state intact. |
| `SEC-004` | Retain passwords only for the active session. | No persistent, clipboard, analytics, logging, or synchronization storage contains the password. |
| `SEC-005` | Respect source assembly, commenting, and copying permissions. | A user-level unlock disables prohibited actions and explains the relevant source restriction. |
| `SEC-006` | Keep working-copy output encrypted. | Export from an encrypted active source cannot silently produce an unencrypted output. |
| `SEC-007` | Keep extracted output encrypted. | Extraction from an encrypted source uses the same output-protection path. |
| `SEC-008` | Validate encrypted output credentials and content. | Temporary output rejects an incorrect password, unlocks with the session password, and matches expected pages, rotations, and annotations before placement. |
| `SEC-009` | Never offer silent decryption. | There is no Export Unencrypted path for an encrypted active document. |

### 4.1 Unlock flow

The secure prompt shows the filename, a secure password field, Unlock, Cancel, and inline incorrect-password feedback. Return submits. The locked document handle retains security-scoped access until success or cancellation. The active session is replaced only after the candidate PDF unlocks and produces a valid working session. Opening the same encrypted file later requires a new password entry.

### 4.2 Permission enforcement

- Annotation actions require commenting permission.
- Add, merge, delete, rotate, reorder, and drag-reorder require document-assembly permission.
- Extraction requires document assembly and content-copy permission.
- Owner-level unlocks use PDFKit owner permissions.
- Password-protected secondary Add Pages and Merge inputs are rejected recoverably.
- Unencrypted pages may be added to an encrypted active document when assembly is allowed; its output remains encrypted.

### 4.3 Encrypted output

Before the save panel, PDFViewer states that output remains password-protected, the session password will grant both user and owner access, and original owner credentials and permission separation cannot be reproduced. Confirmed output supplies the session password as both PDF user and owner passwords, carries available source permission flags, writes to a secure temporary file, validates encryption and content, then atomically places the completed output.

## 5. Milestone 3 — Outlines, local bookmarks, and navigation history

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `NAV-001` | Display a valid PDF outline/table of contents. | The Contents tab shows a bounded hierarchy or a clear no-table-of-contents state. |
| `NAV-002` | Navigate to outline destinations. | A valid destination selects the corresponding current working page; unavailable destinations remain visible but disabled. |
| `NAV-003` | Add, rename, navigate to, and delete local page bookmarks. | Bookmark labels are limited to 120 characters and all committed actions are available in the sidebar. |
| `NAV-004` | Persist bookmarks locally across launches. | Original-source bookmarks reload from the versioned `pageBookmarks.v1` UserDefaults store. |
| `NAV-005` | Preserve bookmark targets through reorder and undo/redo. | Bookmark resolution follows stable working-page identity rather than mutable page numbers. |
| `NAV-006` | Provide Back and Forward for explicit reader jumps. | Toolbar, menu, Command-[, and Command-] navigation skip unavailable entries and expose correct disabled states. |
| `NAV-007` | Keep the reader sidebar usable at every supported size. | Thumbnails, Contents, and Bookmarks share the resizable 136–260 point sidebar from 720×520 through full screen. |
| `NAV-008` | Keep navigation presentation state non-dirty. | Sidebar tab/visibility/width, outlines, bookmarks, and history never alter the PDF revision. |

### 5.1 Stable page and document identity

Each editor revision contains PDF snapshot data and an ordered `[WorkingPageID]`. Original pages receive deterministic IDs derived from the source SHA-256 fingerprint and original page index. Inserted pages carry their source fingerprint and a unique occurrence ID. Reorder preserves IDs, delete removes them, and undo/redo restore both PDF data and IDs.

The document fingerprint is SHA-256 of the original source bytes. Renaming, moving, or opening a byte-identical copy retains bookmark identity. Externally changed bytes form a different identity and do not inherit stale bookmarks.

Persistent bookmarks apply only to original pages of the active source. A page existing only in the working copy becomes eligible after the result is exported and reopened as its own document. A deleted bookmark target appears unavailable; undo restores its destination. Users may rename or remove unavailable bookmarks.

### 5.2 Outline safety

Outline data is untrusted. Traversal tracks visited object identities, stops at 128 levels and 20,000 nodes, limits displayed labels to 512 characters, and disables invalid destinations. A deleted target remains unavailable until undo restores it. Outline parse problems do not prevent the PDF itself from opening. Outline editing is not included.

### 5.3 Navigation history

History stores at most 100 stable page locations. Page-number entry, explicit thumbnail selection, outline selection, bookmark selection, and search-result navigation record jumps. Passive continuous scrolling does not. Back and Forward do not create duplicate entries, a new jump after Back removes the forward branch, deleted locations are skipped, and opening another document resets history.

## 6. Acceptance workflows

### `POST-FLOW-001`: Annotation round trip

Create every supported annotation type, modify and delete owned annotations, verify a third-party annotation is read-only, undo and redo each action, export, reopen, and compare subtype, contents, geometry, styles, and ownership. Confirm the source hash is unchanged.

### `POST-FLOW-002`: Protected lifecycle and output

Open an encrypted PDF, retry an incorrect password, cancel a replacement unlock, then unlock with user and owner credentials. Verify permission-driven disabled states. Export a working copy and extraction, confirm the warning, reject an incorrect output password, reopen with the session password, and verify content and encryption. Confirm no credential persistence and no source change.

### `POST-FLOW-003`: Reader navigation

At 720×520 and a regular window size, switch among all sidebar tabs, navigate a nested outline, create/rename/open/delete a bookmark, relaunch and restore it, reorder and delete its page, undo and verify restoration, and exercise Back/Forward plus disabled states. Hide, restore, and resize the sidebar without changing document state.

## 7. Verification requirements

Each milestone requires its complete unit and UI suite, Debug build, static analysis, `git diff --check`, code-sign verification, sandbox-entitlement verification, native GUI smoke testing at 720×520, 800×550, 900×600, 1100×720, and full screen, source-hash verification, and representative export/reopen validation. Verification must also confirm that no network, cloud, or AI dependency, call, or entitlement was added.

## 8. Explicit non-goals for this historical milestone

- Editing third-party annotations.
- Annotation shapes, arrows, erasers, pressure sensitivity, moving, or arbitrary resizing.
- Flattening or burning annotations into page content.
- Remembering passwords, Keychain storage, or reproducing original owner passwords.
- Password-protected secondary imports.
- Outline editing or embedding page bookmarks in PDFs.
- Bookmark synchronization.
- OCR, scan enhancement, AcroForm, permanent redaction, and native conversion were outside this milestone and were implemented later as documented in `RELEASE_STATUS.md`.
- Cryptographic signatures remain unsupported.
- Cloud services or collaboration.
- AI document features or local/remote inference of any kind.
- Replacing or overwriting source PDFs.
