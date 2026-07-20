import SwiftUI

private enum PDFProcessingPageScope: String, CaseIterable, Identifiable {
    case selected
    case all

    var id: Self { self }

    var title: String {
        switch self {
        case .selected:
            "Selected Pages"
        case .all:
            "All Pages"
        }
    }
}

struct PDFOCRSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var editor: PDFDocumentEditor
    @State private var scope: PDFProcessingPageScope = .selected
    @State private var addsSearchableText = true
    @State private var enhancement: PDFScanEnhancementPreset = .cleanScan
    @State private var rasterQuality: PDFOCRRasterQuality = .balanced
    @State private var cropMarginsPercent: Double = 0
    @State private var splitDoublePages = false
    @State private var preview: PDFScanPreview?
    @State private var previewError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            settings
            previewSection
            processingStatus
            Divider()
            actions
        }
        .padding(22)
        .frame(minWidth: 500, idealWidth: 560)
        .interactiveDismissDisabled(appState.isLocalProcessing)
        .task(id: previewRequest) {
            await loadPreview()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("OCR & Scan Enhancement", systemImage: "doc.text.viewfinder")
                .font(.title2.weight(.semibold))
            Label("Runs entirely on this Mac. Pages and recognized text are never uploaded.", systemImage: "lock.shield")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settings: some View {
        Form {
            Picker("Pages", selection: $scope) {
                ForEach(PDFProcessingPageScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)

            Text(pageCountDescription)
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Add searchable text with local OCR", isOn: $addsSearchableText)

            Picker("Scan Appearance", selection: $enhancement) {
                ForEach(PDFScanEnhancementPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }

            Text(enhancement.summary)
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Raster Quality", selection: $rasterQuality) {
                ForEach(PDFOCRRasterQuality.allCases) { quality in
                    Text(quality.title).tag(quality)
                }
            }

            Text("Higher DPI improves fine text recognition but uses more memory and produces larger files.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Crop Margins", selection: $cropMarginsPercent) {
                Text("None").tag(0.0)
                Text("2% per edge").tag(2.0)
                Text("5% per edge").tag(5.0)
                Text("10% per edge").tag(10.0)
            }

            Text("Cropping removes the chosen percentage from every edge of each processed page.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Toggle("Split wide double-page scans into left and right pages", isOn: $splitDoublePages)

            Text("Only pages at least 30% wider than they are tall are split. Left pages remain before right pages.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Label(
                "Processed pages are rasterized at high resolution. Existing form fields and annotations on those pages become part of the page image. The operation is undoable before export.",
                systemImage: "info.circle"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .formStyle(.grouped)
        .disabled(appState.isLocalProcessing)
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Before / After Preview")
                    .font(.headline)
                Spacer()
                if let pageIndexForPreview {
                    Text("Page \(pageIndexForPreview + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let preview {
                HStack(spacing: 12) {
                    previewImage(preview.original, title: "Before")
                    previewImage(preview.processed, title: "After")
                }
            } else if let previewError {
                Label(previewError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 130)
            } else {
                ProgressView("Preparing local preview…")
                    .frame(maxWidth: .infinity, minHeight: 130)
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func previewImage(_ image: CGImage, title: String) -> some View {
        VStack(spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
            Image(decorative: image, scale: 1)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, minHeight: 100, maxHeight: 165)
                .background(.quaternary.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel("\(title) scan preview")
        }
    }

    @ViewBuilder
    private var processingStatus: some View {
        if appState.isLocalProcessing, let progress = appState.localProcessingProgress {
            VStack(alignment: .leading, spacing: 7) {
                ProgressView(
                    value: Double(progress.completedPages),
                    total: Double(max(progress.totalPages, 1))
                )
                Text("Processed \(progress.completedPages) of \(progress.totalPages) pages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var actions: some View {
        HStack {
            if appState.isLocalProcessing {
                Button("Cancel Processing", role: .cancel) {
                    appState.cancelLocalProcessing()
                }
            } else {
                Button("Cancel", role: .cancel) {
                    appState.cancelLocalProcessing()
                }
                .keyboardShortcut(.cancelAction)
            }

            Spacer()

            Button("Process Locally") {
                appState.startLocalProcessing(
                    pageIndexes: pageIndexes,
                    addsSearchableText: addsSearchableText,
                    enhancement: enhancement,
                    rasterQuality: rasterQuality,
                    cropMarginsPercent: cropMarginsPercent,
                    splitDoublePages: splitDoublePages
                )
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(appState.isLocalProcessing || !hasRequestedWork)
        }
    }

    private var pageIndexes: IndexSet {
        switch scope {
        case .selected:
            return appState.readerState.selectedPageIndexSet
        case .all:
            return IndexSet(integersIn: 0..<editor.document.pageCount)
        }
    }

    private var pageCountDescription: String {
        let count = pageIndexes.count
        return "\(count) \(count == 1 ? "page" : "pages") will be processed."
    }

    private var hasRequestedWork: Bool {
        addsSearchableText || enhancement != .none || cropMarginsPercent > 0 || splitDoublePages
    }

    private var pageIndexForPreview: Int? {
        pageIndexes.first
    }

    private var previewRequest: PreviewRequest {
        PreviewRequest(
            pageIndex: pageIndexForPreview,
            enhancement: enhancement,
            cropMarginsPercent: cropMarginsPercent
        )
    }

    private func loadPreview() async {
        preview = nil
        previewError = nil
        guard let pageIndexForPreview else {
            previewError = "Select a page to preview."
            return
        }
        do {
            preview = try await PDFOCREngine.preview(
                document: editor.document,
                pageIndex: pageIndexForPreview,
                enhancement: enhancement,
                cropMarginsPercent: cropMarginsPercent
            )
        } catch is CancellationError {
            return
        } catch {
            previewError = (error as? LocalizedError)?.errorDescription
                ?? "The preview could not be generated."
        }
    }
}

private struct PreviewRequest: Hashable {
    let pageIndex: Int?
    let enhancement: PDFScanEnhancementPreset
    let cropMarginsPercent: Double
}
