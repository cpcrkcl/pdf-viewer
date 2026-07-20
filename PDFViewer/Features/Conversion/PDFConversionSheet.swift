import SwiftUI

private enum PDFConversionMode: String, CaseIterable, Identifiable {
    case images
    case text
    case createPDF

    var id: Self { self }

    var title: String {
        switch self {
        case .images:
            "PDF to Images"
        case .text:
            "PDF to Text"
        case .createPDF:
            "Images to PDF"
        }
    }
}

private enum PDFConversionPageScope: String, CaseIterable, Identifiable {
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

struct PDFConversionSheet: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var editor: PDFDocumentEditor
    @State private var mode: PDFConversionMode = .images
    @State private var scope: PDFConversionPageScope = .selected
    @State private var imageFormat: PDFImageExportFormat = .png
    @State private var imageDPI = 144

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Divider()
            Picker("Conversion", selection: $mode) {
                ForEach(PDFConversionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Conversion type")

            conversionSettings
                .frame(minHeight: 210, alignment: .top)

            Divider()
            actions
        }
        .padding(22)
        .frame(minWidth: 540, idealWidth: 600)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Conversion", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
                .font(.title2.weight(.semibold))
            Label(
                "Conversion runs entirely on this Mac. The source PDF and imported images are never uploaded or overwritten.",
                systemImage: "lock.shield"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var conversionSettings: some View {
        switch mode {
        case .images:
            Form {
                pageScopePicker
                Picker("Image Format", selection: $imageFormat) {
                    ForEach(PDFImageExportFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
                Picker("Resolution", selection: $imageDPI) {
                    Text("72 DPI").tag(72)
                    Text("144 DPI").tag(144)
                    Text("300 DPI").tag(300)
                }
                Text("Each selected page is rendered into a separate image. Existing visible annotations are included in the rendering.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

        case .text:
            Form {
                pageScopePicker
                Label(
                    "Exports searchable text in UTF-8 with page separators. Image-only pages need local OCR first.",
                    systemImage: "text.alignleft"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .formStyle(.grouped)

        case .createPDF:
            VStack(alignment: .leading, spacing: 12) {
                Label("Create a New PDF From Images", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                Text(
                    "Choose up to 500 PNG, JPEG, HEIC, or TIFF images. Their selection order becomes the PDF page order, and the image files remain unchanged."
                )
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Button("Choose Images…") {
                    appState.chooseImagesForPDFCreation()
                }
                .buttonStyle(.borderedProminent)
                .accessibilityLabel("Choose images to create a PDF")
            }
            .padding(.top, 18)
        }
    }

    private var pageScopePicker: some View {
        Group {
            Picker("Pages", selection: $scope) {
                ForEach(PDFConversionPageScope.allCases) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .pickerStyle(.segmented)
            Text(pageCountDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var actions: some View {
        HStack {
            Button("Cancel", role: .cancel) {
                appState.dismissConversion()
            }
            .keyboardShortcut(.cancelAction)

            Spacer()

            switch mode {
            case .images:
                Button("Export Images…") {
                    appState.exportPagesAsImages(
                        pageIndexes: pageIndexes,
                        format: imageFormat,
                        dpi: imageDPI
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pageIndexes.isEmpty)

            case .text:
                Button("Export Text…") {
                    appState.exportPagesAsText(pageIndexes: pageIndexes)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(pageIndexes.isEmpty)

            case .createPDF:
                EmptyView()
            }
        }
    }

    private var pageIndexes: IndexSet {
        switch scope {
        case .selected:
            appState.readerState.selectedPageIndexSet
        case .all:
            IndexSet(integersIn: 0..<editor.document.pageCount)
        }
    }

    private var pageCountDescription: String {
        let count = pageIndexes.count
        return "\(count) \(count == 1 ? "page" : "pages") will be converted."
    }
}
