import AppKit
import Foundation
@preconcurrency import PDFKit
import UniformTypeIdentifiers

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
            for file in files {
                let safeName = safeFilenameComponent(
                    (file.filename as NSString).deletingPathExtension,
                    fallback: "Page"
                )
                let fileExtension = (file.filename as NSString).pathExtension
                let destination = availableDestination(
                    in: destinationDirectory,
                    baseName: safeName,
                    pathExtension: fileExtension,
                    fileManager: fileManager
                )
                let temporary = temporaryDirectory.appendingPathComponent(destination.lastPathComponent)
                try file.data.write(to: temporary, options: [.atomic])
                stagedFiles.append((temporary, destination))
            }

            for stagedFile in stagedFiles {
                try fileManager.moveItem(
                    at: stagedFile.temporary,
                    to: stagedFile.destination
                )
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
        return sanitized.isEmpty ? fallback : String(sanitized.prefix(120))
    }

    private static func availableDestination(
        in directory: URL,
        baseName: String,
        pathExtension: String,
        fileManager: FileManager
    ) -> URL {
        func destination(suffix: String) -> URL {
            directory.appendingPathComponent("\(baseName)\(suffix).\(pathExtension)")
        }

        let initial = destination(suffix: "")
        guard fileManager.fileExists(atPath: initial.path) else {
            return initial
        }
        for sequence in 2...10_000 {
            let candidate = destination(suffix: "-\(sequence)")
            if !fileManager.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        return destination(suffix: "-\(UUID().uuidString)")
    }
}
