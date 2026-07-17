# PDFViewer MVP Specification

**Version:** 1.0

**Status:** Section 0-1 scope baseline

**Product name:** PDFViewer (working name)

**Source:** `pdf-mac-app-gameplan.pdf`, sections 0 and 1

**Scope boundary:** This specification stops before section 2, "Resolve technical feasibility with spikes."

## 1. Purpose

PDFViewer is an original, native macOS PDF reader and page organizer for people who need to safely read, search, rearrange, and export local PDF documents.

The MVP establishes a dependable reading and page-organization workflow. It does not attempt to deliver the broader editing, conversion, signing, redaction, OCR, collaboration, or AI feature set described as future work in the source game plan.

### Intended audience

The MVP is for Mac users who work with local PDF files and need to:

- Read and navigate PDFs.
- Search PDFs that already contain searchable text.
- Rearrange, add, delete, rotate, extract, or merge whole pages.
- Export their changes without risking the original file.

No account, cloud service, or network connection is required for an MVP workflow.

## 2. Product boundaries

The MVP is:

- Local-first and privacy-preserving.
- Limited to local PDF input and PDF output.
- Independent of cloud services and user accounts.
- Visually and linguistically original.
- Safe against accidental source-file modification.
- Organized around reversible page operations.

The MVP is not a general-purpose PDF content editor. Page organization changes the selection, order, and orientation of whole pages; it does not edit the text, images, links, or other content within a page.

## 3. Normative terminology

The words **must**, **must not**, **should**, and **may** express requirement strength.

- **Source PDF:** The local PDF selected by the user to open. The MVP must treat this file as read-only during normal workflows.
- **Working document:** The in-memory state derived from a source PDF, including any page mutations that have not been exported.
- **Open:** Load a user-selected local PDF as a working document.
- **Close:** End the active working session. Closing must not write changes into the source PDF.
- **Reopen:** Open a PDF again after it has been closed, either through normal file selection or a Recent Documents entry. Restoring unsaved in-memory mutations is not part of this term.
- **Recent Documents:** A list of local PDFs that were opened successfully. An entry is a reference to a file, not a copy of its contents.
- **Add pages:** Insert one or more selected pages from another PDF into the working document at a user-selected position.
- **Merge:** Insert all pages of another PDF into the working document in their original order at a user-selected position.
- **Extract:** Create a new PDF containing copies of selected pages in their current working order. Extraction must not remove those pages from the working document.
- **Export:** Create a new PDF at a user-selected output location. In the MVP, export never means overwriting or replacing the source PDF.
- **Save:** This term is not used for a distinct MVP action. User-facing language and future implementation tasks must use **Export** when creating output.
- **Page mutation:** Adding, deleting, rotating, reordering, or merging pages in the working document.
- **Distinct output:** An output whose resolved file location differs from the source PDF's resolved file location.
- **Textless PDF:** A PDF with no searchable text available to the MVP, including an image-only scan without an existing OCR text layer.

## 4. Non-negotiable principles

| ID | Requirement |
| --- | --- |
| `PRINC-001` | PDFViewer must use original branding, assets, wording, interaction design, and layout. It must not copy PDF Expert's branding, assets, exact layout, wording, or proprietary implementation. |
| `PRINC-002` | Only features explicitly listed as in scope in this specification are committed for the MVP. |
| `PRINC-003` | Document contents must remain on the Mac. MVP document workflows must not upload document contents, derived text, thumbnails, metadata, or page images. |
| `PRINC-004` | Normal MVP workflows must never overwrite or modify the source PDF. |
| `PRINC-005` | Every page mutation must support undo and redo during the active working session. |
| `PRINC-006` | Export and extraction must always create output distinct from the source PDF. |
| `PRINC-007` | All imported PDFs, their metadata, links, and embedded content must be treated as untrusted input. |
| `PRINC-008` | PDFViewer must not execute embedded scripts or automatically open embedded or external links. A link may only be opened after an explicit user action. |
| `PRINC-009` | Future implementation work must use test-first development and must provide actual build, automated-test, and manual-smoke-test evidence before a milestone is accepted. |

## 5. In-scope MVP requirements

### 5.1 Document lifecycle

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `MVP-001` | Open a local PDF. | A user-selected, valid local PDF becomes the active working document and reports its pages without changing the file. |
| `MVP-002` | Close the active PDF. | The active working session ends without writing to the source PDF. If page mutations are pending, the user receives a clear opportunity to cancel closing or discard the working changes. |
| `MVP-003` | Reopen a previously opened PDF. | A closed PDF can be opened again from its local file and presents the content stored in that file. Unsaved working mutations are not implied. |
| `MVP-004` | Display recently opened documents. | The ten most recently and successfully opened distinct PDFs, or all such PDFs when fewer than ten exist, appear once each in most-recent-first order. A failed open must not create a recent entry. |
| `MVP-005` | Handle unavailable recent documents safely. | Selecting a missing, moved, permission-denied, or otherwise inaccessible recent item produces a recoverable explanation without crashing, changing other entries, or silently claiming success. |

### 5.2 Reading and navigation

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `MVP-010` | Display every page of a successfully opened PDF. | The number of accessible pages in the reader matches the source PDF's page count at open. |
| `MVP-011` | Show page thumbnails. | The reader presents one identifiable thumbnail for each current working page, in working-document order. |
| `MVP-012` | Navigate by selecting a thumbnail. | Selecting a thumbnail makes its corresponding page the active visible page. |
| `MVP-013` | Navigate directly to a page number. | A valid page number selects that page; invalid input is rejected without changing the current page. |
| `MVP-014` | Support single-page viewing. | One page is presented as the primary page at a time. |
| `MVP-015` | Support two-page viewing. | Two adjacent pages can be presented together, with first/last-page edge cases handled without inventing pages. |
| `MVP-016` | Support continuous viewing. | Pages can be scrolled in their current working order without requiring a separate page-selection action for every transition. |
| `MVP-017` | Support Day, Night, and Sepia reading themes. | A user can select each named theme and observe the reading presentation change. |
| `MVP-018` | Keep presentation state separate from document content. | Changing a theme or viewing mode does not mark the working document as modified, alter page contents, or affect exported page contents. |

### 5.3 Search

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `MVP-020` | Search textual content in the active PDF. | A query returns occurrences found in the PDF's existing searchable text. |
| `MVP-021` | Search case-insensitively by default. | Queries match the same text regardless of letter case unless a later, explicitly scoped option changes this behavior. |
| `MVP-022` | Display and navigate between results. | The user can see the number of matches and move forward and backward through them without changing the PDF. |
| `MVP-023` | Highlight the active result. | The current result is visually distinguishable in the reader, and clearing search removes search-only highlighting. |
| `MVP-024` | Explain unavailable search for textless PDFs. | An image-only or otherwise textless PDF presents a clear message that searchable text is unavailable and OCR is not included in the MVP. It must not claim that zero matches proves the text is absent from the page image. |

### 5.4 Page organization

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `MVP-030` | Select one or multiple pages. | The working selection identifies the exact pages to which the next page operation applies. |
| `MVP-031` | Add pages from another PDF. | Selected pages are inserted at the chosen position in their source order, and the original files remain unchanged. |
| `MVP-032` | Delete selected pages. | Selected working pages are removed after any required confirmation, while the source PDF remains unchanged. |
| `MVP-033` | Preserve at least one working page. | A deletion that would leave zero pages is blocked with a recoverable explanation. |
| `MVP-034` | Rotate selected pages. | Each selected page can be rotated clockwise or counterclockwise in 90-degree increments without changing unselected pages. |
| `MVP-035` | Reorder selected pages. | Selected pages can move to a new valid position while preserving their relative order unless the user explicitly changes that order. |
| `MVP-036` | Extract selected pages. | A new PDF contains only the selected pages in current working order; the working document and source PDF retain those pages. |
| `MVP-037` | Merge another PDF. | All pages from a selected valid PDF are inserted into the working document at the chosen position in their original order. Neither input PDF is modified. |
| `MVP-038` | Undo and redo page mutations. | Each successful add, delete, rotate, reorder, or merge operation can be undone and redone in sequence during the active session. A new mutation after undo clears the invalid redo branch. |

### 5.5 Export safety

| ID | Requirement | Acceptance condition |
| --- | --- | --- |
| `MVP-040` | Export the working result as a new PDF. | Export produces a PDF representing the current working page selection, order, and rotations. The destination is either unused or an existing non-source file that the user explicitly confirms may be replaced. |
| `MVP-041` | Keep source and output locations distinct. | The export is rejected if the resolved output location is the source PDF's resolved location. |
| `MVP-042` | Use a safe temporary-file strategy. | Output is first written to a securely created temporary file, validated as a reopenable PDF, and only then placed at the selected destination. Partial output is not presented as a successful export. |
| `MVP-043` | Preserve the source on cancellation or failure. | Canceling or failing any page operation, extraction, merge, or export leaves every source PDF byte-for-byte unchanged. Temporary artifacts are not treated as completed output. |
| `MVP-044` | Verify exported output. | A successful exported PDF can be reopened and has the expected page count, order, and rotations. |

## 6. Required acceptance workflows

These workflows define product acceptance behavior for future implementation. They are not implementation instructions or architecture decisions.

### `FLOW-001`: Read without modification

1. Record the source PDF's file hash.
2. Open the PDF.
3. Navigate by thumbnail and page number.
4. Exercise single-page, two-page, and continuous viewing.
5. Exercise Day, Night, and Sepia themes.
6. Close the PDF.
7. Verify the source hash is unchanged and no presentation action was treated as a document mutation.

### `FLOW-002`: Reopen from Recent Documents

1. Open and close a valid local PDF.
2. Select it from Recent Documents.
3. Verify that the same local file opens successfully.
4. Make the file unavailable and select its recent entry again.
5. Verify a recoverable explanation appears and unrelated recent entries remain intact.

### `FLOW-003`: Search existing text

1. Open a PDF containing searchable mixed-case text.
2. Search using different letter casing.
3. Verify the expected match count.
4. Navigate forward and backward through matches.
5. Verify the active match is highlighted.
6. Clear search and verify search-only highlighting is removed.

### `FLOW-004`: Handle a textless PDF

1. Open an image-only PDF without an OCR text layer.
2. Attempt a text search.
3. Verify the reader explains that searchable text is unavailable and OCR is outside the MVP.
4. Verify the document remains readable and unchanged.

### `FLOW-005`: Mutate, undo, and redo pages

1. Open a multi-page PDF and record its hash.
2. Select multiple pages and reorder them.
3. Rotate selected pages.
4. Delete a page.
5. Undo each operation in reverse order and verify the original working state is restored.
6. Redo each operation and verify the edited working state is restored.
7. Undo once, perform a new mutation, and verify the abandoned redo branch is unavailable.
8. Verify the source PDF's hash is unchanged.

### `FLOW-006`: Add and merge pages

1. Open a destination PDF and record the hashes of both destination and source PDFs.
2. Add selected pages from another PDF at a chosen position.
3. Merge all pages from a second PDF at a chosen position.
4. Verify inserted page order and working page count.
5. Undo and redo both operations.
6. Verify all input hashes are unchanged.

### `FLOW-007`: Prevent an empty document

1. Open a one-page PDF.
2. Attempt to delete its only page.
3. Verify the deletion is blocked with a recoverable explanation.
4. Verify the working document and source PDF remain unchanged.

### `FLOW-008`: Extract pages

1. Select non-contiguous pages from a working document.
2. Extract them to a distinct output location.
3. Reopen the extracted PDF.
4. Verify it contains only the selected pages in their current working order.
5. Verify the working document and source PDF still contain the selected pages.

### `FLOW-009`: Export and reopen

1. Record the source PDF's hash.
2. Apply reorder, delete, and rotate operations.
3. Export to a location distinct from the source.
4. Verify the temporary result is validated before the destination is finalized.
5. Reopen the exported PDF.
6. Verify its expected page count, order, and rotations.
7. Verify the source hash is unchanged.

### `FLOW-010`: Recover from invalid input or export failure

1. Attempt to open a corrupt, inaccessible, or unsupported file.
2. Verify the failure is explained without a crash or false success state.
3. Attempt an export that is canceled, targets the source, or cannot be completed.
4. Verify no partial output is reported as successful and the source remains unchanged.

## 7. Safety, privacy, and data-loss rules

The following rules apply across all MVP requirements and acceptance workflows:

1. Document data, derived text, thumbnails, and page images stay on the Mac.
2. The MVP makes no document-content network requests and requires no account.
3. The source PDF is read-only during normal MVP workflows.
4. A page mutation changes only the working document until export.
5. Export and extraction require output distinct from the source.
6. An existing non-source destination is replaced only after explicit user confirmation.
7. Export success is reported only after the output reopens as a valid PDF.
8. Cancellation and failure must not produce a false success state, and temporary artifacts must be cleaned up when they are no longer needed.
9. Imported metadata, scripts, links, and embedded content are untrusted.
10. Embedded scripts are not executed.
11. Links are not opened without an explicit user action.
12. Page mutations remain reversible for the active working session.
13. Errors must be understandable and recoverable; they must not silently discard or modify a source file.

## 8. Deferred features and non-goals

The following capabilities are explicitly outside the MVP. They must not appear in MVP acceptance criteria, navigation promises, marketing claims, or release claims.

| ID | Deferred capability | MVP boundary |
| --- | --- | --- |
| `DEF-001` | Editing existing PDF text | The MVP searches existing text but does not change it. |
| `DEF-002` | Editing images or links | Existing page content is not edited. |
| `DEF-003` | General document-format conversion | MVP input and output are PDF only. |
| `DEF-004` | Fillable forms | Form completion, validation, reset, and flattening are not included. |
| `DEF-005` | Visual or cryptographic signatures | The MVP provides neither signature placement nor certificate-based signing. It makes no digital-signature claims. |
| `DEF-006` | Redaction | The MVP does not mark, preview, cover, or permanently remove content. |
| `DEF-007` | OCR and scan enhancement | The MVP does not recognize text in page images or enhance scanned pages. |
| `DEF-008` | Compression optimization | The MVP defines no compression profiles or output-size promises. |
| `DEF-009` | Cloud synchronization | The MVP has no cloud storage or synchronization. |
| `DEF-010` | Collaboration | The MVP has no shared editing, commenting, or presence features. |
| `DEF-011` | AI document features | The MVP has no AI summaries, chat, extraction, or remote inference. |
| `DEF-012` | Annotations | Highlighting search results is temporary reader presentation, not creation or editing of PDF annotations. |

## 9. Source-to-requirement traceability

Each section 1 source bullet has one canonical requirement anchor. Related requirements refine the anchor's acceptance behavior without adding a separate source feature.

### MVP release target

| Section 1 source bullet | Canonical anchor | Refining requirements |
| --- | --- | --- |
| Open, close, and reopen PDFs | `MVP-001` | `MVP-002`, `MVP-003` |
| Recent documents | `MVP-004` | `MVP-005` |
| Page thumbnails and page navigation | `MVP-011` | `MVP-010`, `MVP-012`, `MVP-013` |
| Single-page, two-page, and continuous viewing | `MVP-014` | `MVP-015`, `MVP-016` |
| Day, Night, and Sepia reading themes | `MVP-017` | `MVP-018` |
| Text search within a PDF | `MVP-020` | `MVP-021` through `MVP-024` |
| Add, delete, rotate, reorder, extract, and merge pages | `MVP-030` | `MVP-031` through `MVP-037` |
| Export the result as a new PDF | `MVP-040` | `MVP-041`, `MVP-044` |
| Undo/redo for page operations | `MVP-038` | None |
| Save/export using a safe temporary-file strategy | `MVP-042` | `MVP-043` |

### Deferred until after MVP

| Section 1 source bullet | Canonical deferred requirement |
| --- | --- |
| Full text editing | `DEF-001` |
| Image and link editing | `DEF-002` |
| Broad format conversion | `DEF-003` |
| Fillable forms | `DEF-004` |
| Digital signatures | `DEF-005` |
| Redaction | `DEF-006` |
| OCR and scan enhancement | `DEF-007` |
| Compression optimization | `DEF-008` |
| Cloud sync | `DEF-009` |
| Collaboration | `DEF-010` |
| AI document features | `DEF-011` |

`DEF-012` makes the absence of annotations explicit because annotations are not included in the section 1 MVP list and later work must not infer them from temporary search highlighting.

## 10. Public interfaces and types

This phase introduces no code-level APIs, data schemas, Swift types, application architecture, or project configuration.

The `PRINC-*`, `MVP-*`, `FLOW-*`, and `DEF-*` identifiers are the stable product interface between later planning, implementation tasks, automated tests, manual smoke tests, release documentation, and scope review. Later work may add traceability details but must not silently change the meaning of an existing identifier.

## 11. MVP scope approval

Section 1 is scope-approved when all of the following remain true:

- [x] The product goal and intended audience are explicit.
- [x] Every section 0 principle is represented by a stable requirement.
- [x] Every section 1 MVP bullet maps to one canonical requirement anchor.
- [x] Every explicitly deferred section 1 feature is listed as out of scope.
- [x] Annotations are also excluded from the MVP.
- [x] No MVP requirement depends on OCR, conversion helpers, cloud services, forms, annotations, signatures, redaction, compression, collaboration, or AI features.
- [x] Every page mutation is reversible during the active session.
- [x] Normal workflows never overwrite the source PDF.
- [x] Export and extraction produce distinct output.
- [x] Export/reopen verification is required.
- [x] Privacy and untrusted-input principles are explicit.
- [x] Ambiguous terms including save, merge, reopen, export, and digital signature have defined boundaries.
- [x] Acceptance workflows are testable without selecting an implementation architecture.
- [x] There are no unresolved product-scope decisions required before section 2 begins.

## 12. Assumptions and explicitly deferred decisions

- Completing section 1 means approving this MVP specification, not implementing the application.
- Work for this milestone stops before feasibility spikes.
- `PDFViewer` is a working product name; final branding is deferred.
- Exact macOS deployment targets, supported hardware, measurable performance thresholds, application architecture, sandbox entitlements, file-access mechanisms, and toolchain configuration belong to later technical planning.
- The absence of a selected full Xcode installation does not block this documentation-only milestone.
- Deferring a technical choice does not leave the MVP product scope undecided; later technical work must satisfy the requirements and acceptance workflows defined here.
