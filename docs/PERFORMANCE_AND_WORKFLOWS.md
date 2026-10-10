# Rust performance and workflow improvements

The Rust app now has a command palette (⌘K; also View → Commands), split
reading (⇧⌘\; also the View popup), drag-to-reorder thumbnails, cross-page
text selection, and session restoration with recovery of edited copies.

## Everyday use

- The command palette filters available actions as you type. Use ↑/↓ and
  Enter; Escape closes it. Actions use the existing menu dispatcher and PDF
  permission checks.
- Select thumbnails with ⌘ or Shift, then drag the selection between pages.
  The insertion line shows the destination. Rotate, Extract and Delete act
  on the selection and retain their existing undo and confirmation behavior.
- Double-click a word or triple-click a paragraph. Text selection can cross
  pages; dragging near the canvas edge scrolls. Copy waits until all selected
  pages have text. PDF permissions still control copying.
- Split reading opens an independent reference pane. Choose the same PDF
  for a second location or another open tab for comparison. The reference
  has its own page/zoom controls. Editing commands target the main pane;
  selection can be copied from either pane.
- Background opening, conversion, export and OCR show a nonmodal task window.
  Reading, searching, zooming and switching tabs remain available. Editing
  stays disabled until the operation finishes. Opening and OCR can be cancelled;
  operations whose writers do not support cancellation show progress without
  a Cancel button.

## Session restoration and recovery

A worker coalesces checkpoints in `Application Support/PDFViewer/Recovery`.
The app checks for changes every two seconds and checkpoints on normal shutdown.
It restores tabs, the active document, reader settings, page and zoom. Split
pane state is currently per launch.

Edited copies, including copies already exported, are saved separately from
source PDFs. Protected recovery PDFs are re-encrypted with the in-memory
session password and original permissions. Passwords are never written to the
session manifest. Reopening a protected original still asks for its password.
Recovery files use a private directory and private file permissions on macOS.

If an original is missing, the saved PDF can be opened from recovery. If the
original changed externally, the app keeps the recovery copy and reports its
location rather than applying edits to the changed source. Discard-and-close
removes that tab's checkpoint; Discard-and-Quit removes edited recovery copies.
A crash can lose work newer than the last completed checkpoint. Recovery
restores the working copy with one undo back to the reopened original; it does
not persist the entire undo history.

## Rendering and memory

- Visible pages and quick previews outrank nearby-page prefetch and thumbnails.
  The queue discards work that hasn't been requested for two frames.
- Text pages get a small first render before the full-resolution image. Image-only
  pages skip that pass: the optimized benchmark showed too little benefit to
  justify decoding the scan twice.
- Layouts and fit widths are cached. A binary search locates visible rows,
  including mixed-size two-page spreads. Thumbnail height is cached as well.
- The page image cache uses a 192 MiB RGBA budget, with least-recently-used
  eviction. Finished renders are bounded to three waiting results. Each bitmap
  is limited to approximately 16 megapixels and 8,192 pixels on either axis.
- Text extraction publishes the current page first and follows updated viewport
  priority. Search uses that same index instead of launching a duplicate build.
- Annotation/form edits preserve geometry and text. Appearance fingerprints
  include dependent appearance streams and inherited form values, so only
  changed pages lose their rendered images. Structural edits use full invalidation.
- Undo keeps all snapshots. Above a 256 MiB resident history budget, a bounded
  worker encrypts older snapshots into temporary files. The current and preceding
  snapshots stay resident, so two very large PDFs can exceed the budget. The
  random encryption key is held only in the editor session. Temporary archives
  are removed on release; after a crash any remnants are ciphertext without the
  session key. Disk failures retain snapshots in memory. Undo of an archived step
  includes disk read/decryption time.

## Measurements

Measured locally on 2026-10-09, using deterministic fixtures and optimized builds.
These isolate the affected operations; they are not whole-app frame-rate claims.

- 2,000-page layout, 1,000 iterations: uncached layout about **10.4 ms**;
  cached layout plus visible-row lookup about **0.025 ms**. The original debug
  layout baseline, before adding the row index, was 109 ms for 1,000 iterations.
- Text-page rendering, 12 iterations at 512 versus 2,304 pixels wide:
  about **3.4 ms versus 61 ms**. The scan fixture was **630 ms versus 779 ms**;
  its small improvement caused image-only previews to be disabled.
- Text availability in a 2,000-page PDF: whole index **63 ms**; prioritized
  page 2,000 available in **5.3 ms**.
- 20 metadata refreshes on 2,000 pages: full geometry/links/annotation refresh
  **318 ms**; annotation-only refresh with appearance fingerprints **102 ms**.
- 20 edits with an intentionally small 2 MiB undo budget: resident snapshot data
  decreased from **25.9 MB to 2.47 MB**. Edit time was **16.6 ms without archiving
  versus 14.4 ms with background archiving** in that run; the archive settled
  about 109 ms later. Those edit timings are close enough to treat as no observed
  regression, rather than a claimed speedup. The initial synchronous archive
  experiment took 133 ms and was replaced.

Reproduce with Homebrew rustup on PATH:

```sh
cargo test -p pdfviewer --bin PDFViewer --release benchmark -- --ignored --nocapture --test-threads=1
cargo test -p pdf-core --lib --release benchmark -- --ignored --nocapture --test-threads=1
cargo run -p pdf-core --example performance_fixture -- /tmp/large-reader.pdf 2000
cargo run -p pdfviewer -- /tmp/large-reader.pdf
```

The normal suite includes regression coverage for mixed-size spread lookup,
viewport text priority, protected recovery, undo after archiving, unchanged-page
reuse, form appearance invalidation, cross-page selection ranges, palette
keyboard dispatch, scan-preview bypass and batch output preservation. Native
window captures were inspected for the palette and split reader. An isolated
app instance was driven through the native menu, killed to simulate a crash,
and relaunched: its rotation, page identities, reading page and zoom recovered,
and Undo returned it to the original.

## Local batch companion

```sh
cargo run -p pdfviewer --bin pdfviewer-cli -- --help
cargo run -p pdfviewer --bin pdfviewer-cli -- text input.pdf output.txt
cargo run -p pdfviewer --bin pdfviewer-cli -- images output.pdf scan1.png scan2.jpg
cargo run -p pdfviewer --bin pdfviewer-cli -- batch text ./PDFs ./Text
cargo run -p pdfviewer --bin pdfviewer-cli -- batch png ./PDFs ./Images --dpi 144
cargo run -p pdfviewer --bin pdfviewer-cli -- batch ocr ./Scans ./Searchable
cargo run -p pdfviewer --bin pdfviewer-cli -- watch text ./Inbox ./Text
```

Batch kinds are `text`, `png`, `jpeg`, `tiff`, `ocr` and `images`. Image batches
create one PDF per source image; the separate `images` command combines images.
Folder processing is nonrecursive, skips existing output, and never changes
inputs. The watcher waits for a stable file size/modification time before processing.
Ctrl-C stops the watcher and cancels OCR between pages. Image conversion checks
cancellation before writing its results. A password-protected PDF that requires
a password must be opened in the GUI; CLI arguments never accept passwords.
OCR continues to use Apple Vision on macOS. Other operating systems have not
been validated by this work.
