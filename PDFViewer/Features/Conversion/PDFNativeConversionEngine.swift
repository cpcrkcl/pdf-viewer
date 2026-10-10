import AppKit
import Combine
import Foundation
import ImageIO
@preconcurrency import PDFKit
import UniformTypeIdentifiers

@objc protocol OfficeConversionXPCProtocol {
    func convert(
        executableBookmark: Data,
        inputBookmark: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
}

@MainActor
final class OfficeConversionManager: ObservableObject {
    @Published private(set) var executableName: String?
    @Published private(set) var isConverting = false
    @Published private(set) var statusMessage: String?

    private let defaults: UserDefaults
    private let bookmarkKey = "libreOfficeExecutableBookmark.v1"
    private var connection: NSXPCConnection?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        executableName = Self.resolvedExecutable(from: defaults.data(forKey: bookmarkKey))?.lastPathComponent
    }

    func chooseLibreOfficeExecutable() {
        let panel = NSOpenPanel()
        panel.title = "Choose the LibreOffice soffice Executable"
        panel.message = "Select a user-installed soffice executable. PDFViewer never downloads or bundles LibreOffice."
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            do {
                try Self.validateExecutable(url)
                let bookmark = try url.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                    relativeTo: nil
                )
                self.defaults.set(bookmark, forKey: self.bookmarkKey)
                self.executableName = url.lastPathComponent
                self.statusMessage = "LibreOffice helper configured."
            } catch {
                self.statusMessage = error.localizedDescription
            }
        }
    }

    func clearExecutable() {
        defaults.removeObject(forKey: bookmarkKey)
        executableName = nil
        statusMessage = nil
    }

    func convertOfficeDocument() {
        guard let executableBookmark = defaults.data(forKey: bookmarkKey) else {
            statusMessage = "Choose the LibreOffice soffice executable first."
            return
        }
        let panel = NSOpenPanel()
        panel.title = "Choose an Office Document"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "doc")!, UTType(filenameExtension: "docx")!,
            UTType(filenameExtension: "ppt")!, UTType(filenameExtension: "pptx")!,
            UTType(filenameExtension: "xls")!, UTType(filenameExtension: "xlsx")!,
            UTType(filenameExtension: "odt")!, UTType(filenameExtension: "ods")!,
            UTType(filenameExtension: "odp")!,
        ]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let inputURL = panel.url, let self else { return }
            do {
                let inputBookmark = try inputURL.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: [.fileSizeKey],
                    relativeTo: nil
                )
                self.startConversion(
                    executableBookmark: executableBookmark,
                    inputBookmark: inputBookmark,
                    suggestedName: inputURL.deletingPathExtension().lastPathComponent + ".pdf"
                )
            } catch { self.statusMessage = error.localizedDescription }
        }
    }

    private func startConversion(
        executableBookmark: Data,
        inputBookmark: Data,
        suggestedName: String
    ) {
        guard !isConverting else { return }
        isConverting = true
        statusMessage = "Converting locally in the restricted helper…"
        let connection = NSXPCConnection(
            serviceName: "com.christopherrego.PDFViewer.OfficeConversionHelper"
        )
        connection.remoteObjectInterface = NSXPCInterface(with: OfficeConversionXPCProtocol.self)
        connection.interruptionHandler = { [weak self] in
            Task { @MainActor in self?.finishWithError("The conversion helper was interrupted.") }
        }
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in
                if self?.isConverting == true { self?.finishWithError("The conversion helper stopped unexpectedly.") }
            }
        }
        connection.resume()
        self.connection = connection
        guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] error in
            Task { @MainActor in self?.finishWithError(error.localizedDescription) }
        }) as? OfficeConversionXPCProtocol else {
            finishWithError("The conversion helper is unavailable.")
            return
        }
        proxy.convert(executableBookmark: executableBookmark, inputBookmark: inputBookmark) {
            [weak self] data, errorMessage in
            Task { @MainActor in
                guard let self, self.isConverting else { return }
                if let errorMessage { self.finishWithError(errorMessage); return }
                guard
                    let data,
                    data.count <= 268_435_456,
                    data.starts(with: Data("%PDF".utf8)),
                    let document = PDFDocument(data: data),
                    document.pageCount > 0
                else { self.finishWithError("The helper returned an invalid PDF."); return }
                self.presentSavePanel(data: data, suggestedName: suggestedName)
            }
        }
    }

    private func presentSavePanel(data: Data, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Save Converted PDF"
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = suggestedName
        panel.begin { [weak self] response in
            guard let self else { return }
            if response == .OK, let url = panel.url {
                do {
                    try data.write(to: url, options: .atomic)
                    self.statusMessage = "Converted PDF saved as \(url.lastPathComponent)."
                } catch { self.statusMessage = error.localizedDescription }
            } else {
                self.statusMessage = "Conversion completed; saving was cancelled."
            }
            self.isConverting = false
            self.connection?.invalidate()
            self.connection = nil
        }
    }

    private func finishWithError(_ message: String) {
        isConverting = false
        statusMessage = message
        connection?.invalidate()
        connection = nil
    }

    private static func validateExecutable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard
            url.isFileURL,
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            url.lastPathComponent == "soffice",
            FileManager.default.isExecutableFile(atPath: url.path)
        else { throw CocoaError(.fileReadUnsupportedScheme) }
    }

    private static func resolvedExecutable(from bookmark: Data?) -> URL? {
        guard let bookmark else { return nil }
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale, (try? validateExecutable(url)) != nil else { return nil }
        return url
    }
}

enum PDFImageExportFormat: String, CaseIterable, Identifiable, Sendable {
    case png
    case jpeg
    case tiff

    var id: Self { self }

    var title: String {
        switch self {
        case .png:
            "PNG"
        case .jpeg:
            "JPEG"
        case .tiff:
            "TIFF"
        }
    }

    var filenameExtension: String {
        switch self {
        case .png:
            "png"
        case .jpeg:
            "jpg"
        case .tiff:
            "tiff"
        }
    }

    var contentType: UTType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .tiff:
            .tiff
        }
    }

    fileprivate var bitmapFileType: NSBitmapImageRep.FileType {
        switch self {
        case .png:
            .png
        case .jpeg:
            .jpeg
        case .tiff:
            .tiff
        }
    }

    fileprivate var bitmapProperties: [NSBitmapImageRep.PropertyKey: Any] {
        switch self {
        case .jpeg:
            [.compressionFactor: 0.9]
        case .png, .tiff:
            [:]
        }
    }
}

struct PDFImageInput: Equatable, Sendable {
    let filename: String
    let data: Data
}

struct PDFConvertedFile: Equatable, Sendable {
    let filename: String
    let data: Data
}

enum PDFNativeConversionError: LocalizedError, Equatable {
    case emptySelection
    case invalidPageSelection
    case invalidResolution
    case pageTooLarge
    case couldNotRenderPage(Int)
    case noSearchableText
    case noImages
    case tooManyImages
    case invalidImage(String)
    case imageTooLarge(String)
    case couldNotCreatePDF
    case couldNotCreateOutputDirectory
    case couldNotWriteOutput

    var errorDescription: String? {
        switch self {
        case .emptySelection:
            "Choose one or more pages first."
        case .invalidPageSelection:
            "One or more selected pages are no longer available."
        case .invalidResolution:
            "Choose an image resolution from 72 to 300 DPI."
        case .pageTooLarge:
            "A requested page would exceed the safe image size limit. Choose a lower resolution."
        case .couldNotRenderPage(let pageNumber):
            "Page \(pageNumber) could not be rendered as an image."
        case .noSearchableText:
            "The selected pages contain no searchable text. Run local OCR first, then try again."
        case .noImages:
            "Choose one or more PNG, JPEG, HEIC, or TIFF images."
        case .tooManyImages:
            "A single conversion can contain at most 500 images."
        case .invalidImage(let filename):
            "\(filename) is not a readable image."
        case .imageTooLarge(let filename):
            "\(filename) exceeds the safe per-image size limit."
        case .couldNotCreatePDF:
            "PDFViewer could not create a valid PDF from those images."
        case .couldNotCreateOutputDirectory:
            "PDFViewer could not create a secure temporary output directory."
        case .couldNotWriteOutput:
            "PDFViewer could not write one or more converted files."
        }
    }
}

@MainActor
enum PDFNativeConversionEngine {
    static let minimumDPI = 72
    static let maximumDPI = 300
    static let maximumImageCount = 500
    static let maximumInputImageBytes = 100 * 1_024 * 1_024
    static let maximumInputImagePixels = 25_000_000
    static let maximumRenderedPixels = 25_000_000

    static func imageFiles(
        from document: PDFDocument,
        pageIndexes: IndexSet,
        format: PDFImageExportFormat,
        dpi: Int,
        baseName: String
    ) throws -> [PDFConvertedFile] {
        try validate(pageIndexes: pageIndexes, in: document)
        guard (minimumDPI...maximumDPI).contains(dpi) else {
            throw PDFNativeConversionError.invalidResolution
        }

        let sanitizedBaseName = safeFilenameComponent(baseName, fallback: "PDF")
        let pageNumberWidth = max(1, String(document.pageCount).count)

        return try pageIndexes.map { pageIndex in
            let pageNumber = pageIndex + 1
            let data = try imageData(
                from: document,
                pageIndex: pageIndex,
                format: format,
                dpi: dpi
            )
            let paddedPageNumber = String(
                format: "%0\(pageNumberWidth)d",
                pageNumber
            )
            return PDFConvertedFile(
                filename: "\(sanitizedBaseName)-page-\(paddedPageNumber).\(format.filenameExtension)",
                data: data
            )
        }
    }

    static func imageData(
        from document: PDFDocument,
        pageIndex: Int,
        format: PDFImageExportFormat,
        dpi: Int
    ) throws -> Data {
        guard
            (0..<document.pageCount).contains(pageIndex),
            let page = document.page(at: pageIndex)
        else {
            throw PDFNativeConversionError.invalidPageSelection
        }
        guard (minimumDPI...maximumDPI).contains(dpi) else {
            throw PDFNativeConversionError.invalidResolution
        }

        let pageBounds = page.bounds(for: .cropBox)
        guard
            pageBounds.width.isFinite,
            pageBounds.height.isFinite,
            pageBounds.width > 0,
            pageBounds.height > 0
        else {
            throw PDFNativeConversionError.couldNotRenderPage(pageIndex + 1)
        }

        let scale = CGFloat(dpi) / 72
        let requestedSize = CGSize(
            width: ceil(pageBounds.width * scale),
            height: ceil(pageBounds.height * scale)
        )
        let pixelCount = requestedSize.width * requestedSize.height
        guard
            requestedSize.width <= CGFloat(Int.max),
            requestedSize.height <= CGFloat(Int.max),
            pixelCount.isFinite,
            pixelCount <= CGFloat(maximumRenderedPixels)
        else {
            throw PDFNativeConversionError.pageTooLarge
        }

        let image = page.thumbnail(of: requestedSize, for: .cropBox)
        guard
            let tiffRepresentation = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffRepresentation),
            let output = bitmap.representation(
                using: format.bitmapFileType,
                properties: format.bitmapProperties
            ),
            !output.isEmpty
        else {
            throw PDFNativeConversionError.couldNotRenderPage(pageIndex + 1)
        }
        return output
    }

    static func searchableText(
        from document: PDFDocument,
        pageIndexes: IndexSet
    ) throws -> String {
        try validate(pageIndexes: pageIndexes, in: document)

        var containsText = false
        let sections = pageIndexes.map { pageIndex in
            let pageText = (document.page(at: pageIndex)?.string ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            containsText = containsText || !pageText.isEmpty
            return "--- Page \(pageIndex + 1) ---\n\(pageText)"
        }

        guard containsText else {
            throw PDFNativeConversionError.noSearchableText
        }
        return sections.joined(separator: "\n\n") + "\n"
    }

    static func document(from inputs: [PDFImageInput]) throws -> PDFDocument {
        guard !inputs.isEmpty else {
            throw PDFNativeConversionError.noImages
        }
        guard inputs.count <= maximumImageCount else {
            throw PDFNativeConversionError.tooManyImages
        }

        let output = PDFDocument()
        for (index, input) in inputs.enumerated() {
            guard input.data.count <= maximumInputImageBytes else {
                throw PDFNativeConversionError.imageTooLarge(input.filename)
            }
            guard let pixelCount = imagePixelCount(in: input.data) else {
                throw PDFNativeConversionError.invalidImage(input.filename)
            }
            guard pixelCount <= maximumInputImagePixels else {
                throw PDFNativeConversionError.imageTooLarge(input.filename)
            }
            guard
                let image = NSImage(data: input.data),
                image.isValid,
                let page = PDFPage(image: image)
            else {
                throw PDFNativeConversionError.invalidImage(input.filename)
            }
            output.insert(page, at: index)
        }

        guard
            output.pageCount == inputs.count,
            let data = output.dataRepresentation(),
            !data.isEmpty,
            let reopened = PDFDocument(data: data),
            reopened.pageCount == inputs.count
        else {
            throw PDFNativeConversionError.couldNotCreatePDF
        }
        return reopened
    }

    static func writeImageFiles(
        _ files: [PDFConvertedFile],
        to destinationDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> [URL] {
        guard !files.isEmpty else {
            throw PDFNativeConversionError.emptySelection
        }

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("PDFViewer-Conversion-\(UUID().uuidString)", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: temporaryDirectory,
                withIntermediateDirectories: false
            )
        } catch {
            throw PDFNativeConversionError.couldNotCreateOutputDirectory
        }
        defer { try? fileManager.removeItem(at: temporaryDirectory) }

        do {
            var stagedFiles: [(temporary: URL, destination: URL)] = []
            var reservedDestinations: Set<URL> = []
            for file in files {
                let safeName = safeFilenameComponent(
                    (file.filename as NSString).deletingPathExtension,
                    fallback: "Page"
                )
                let fileExtension = safeFilenameExtension(
                    (file.filename as NSString).pathExtension
                )
                let destination = availableDestination(
                    in: destinationDirectory,
                    baseName: safeName,
                    pathExtension: fileExtension,
                    fileManager: fileManager,
                    reservedDestinations: reservedDestinations
                )
                reservedDestinations.insert(destination)
                let temporary = temporaryDirectory.appendingPathComponent(destination.lastPathComponent)
                try file.data.write(to: temporary, options: [.atomic])
                stagedFiles.append((temporary, destination))
            }

            var completedDestinations: [URL] = []
            for stagedFile in stagedFiles {
                do {
                    try fileManager.moveItem(
                        at: stagedFile.temporary,
                        to: stagedFile.destination
                    )
                    completedDestinations.append(stagedFile.destination)
                } catch {
                    for completedDestination in completedDestinations {
                        try? fileManager.removeItem(at: completedDestination)
                    }
                    throw error
                }
            }
            return stagedFiles.map(\.destination)
        } catch {
            throw PDFNativeConversionError.couldNotWriteOutput
        }
    }

    static func writeText(_ text: String, to destination: URL) throws {
        guard let data = text.data(using: .utf8), !data.isEmpty else {
            throw PDFNativeConversionError.noSearchableText
        }
        do {
            try data.write(to: destination, options: [.atomic])
        } catch {
            throw PDFNativeConversionError.couldNotWriteOutput
        }
    }

    private static func validate(
        pageIndexes: IndexSet,
        in document: PDFDocument
    ) throws {
        guard !pageIndexes.isEmpty else {
            throw PDFNativeConversionError.emptySelection
        }
        guard pageIndexes.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            throw PDFNativeConversionError.invalidPageSelection
        }
    }

    private static func safeFilenameComponent(
        _ candidate: String,
        fallback: String
    ) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\")
            .union(.controlCharacters)
        let sanitized = candidate.components(separatedBy: forbidden).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let safeCandidate = sanitized == "." || sanitized == ".." ? "" : sanitized
        return safeCandidate.isEmpty ? fallback : String(safeCandidate.prefix(120))
    }

    private static func safeFilenameExtension(_ candidate: String) -> String {
        let filtered = candidate.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0)
        }
        let result = String(String.UnicodeScalarView(filtered)).lowercased()
        return result.isEmpty ? "bin" : String(result.prefix(12))
    }

    private static func availableDestination(
        in directory: URL,
        baseName: String,
        pathExtension: String,
        fileManager: FileManager,
        reservedDestinations: Set<URL> = []
    ) -> URL {
        func destination(suffix: String) -> URL {
            directory.appendingPathComponent("\(baseName)\(suffix).\(pathExtension)")
        }

        let initial = destination(suffix: "")
        guard
            !fileManager.fileExists(atPath: initial.path),
            !reservedDestinations.contains(initial)
        else {
            for sequence in 2...10_000 {
                let candidate = destination(suffix: "-\(sequence)")
                if
                    !fileManager.fileExists(atPath: candidate.path),
                    !reservedDestinations.contains(candidate)
                {
                    return candidate
                }
            }
            return destination(suffix: "-\(UUID().uuidString)")
        }
        return initial
    }

    private static func imagePixelCount(in data: Data) -> Int? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let typeIdentifier = CGImageSourceGetType(source) as String?,
            [
                UTType.png.identifier,
                UTType.jpeg.identifier,
                UTType.heic.identifier,
                UTType.tiff.identifier,
            ].contains(typeIdentifier),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue.isFinite,
            height.doubleValue.isFinite,
            width.doubleValue > 0,
            height.doubleValue > 0
        else {
            return nil
        }
        let pixelCount = width.doubleValue * height.doubleValue
        guard pixelCount.isFinite, pixelCount <= Double(Int.max) else {
            return nil
        }
        return Int(pixelCount)
    }
}
