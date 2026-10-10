import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFNativeConversionEngineTests: XCTestCase {
    func testPDFToTextPreservesSelectedPageOrderUnicodeAndSeparators() throws {
        let document = try makeTextDocument(pages: ["First page", "Résumé مرحبا", "Last page"])

        let text = try PDFNativeConversionEngine.searchableText(
            from: document,
            pageIndexes: [0, 2]
        )

        XCTAssertTrue(text.contains("--- Page 1 ---\nFirst page"))
        XCTAssertTrue(text.contains("--- Page 3 ---\nLast page"))
        XCTAssertFalse(text.contains("Résumé"))

        let unicodeText = try PDFNativeConversionEngine.searchableText(
            from: document,
            pageIndexes: [1]
        )
        XCTAssertTrue(unicodeText.contains("Résumé"))
        XCTAssertTrue(unicodeText.contains("مرحبا"))
    }

    func testPDFToImageProducesDecodableFilesAtRequestedResolution() throws {
        let document = try makeTextDocument(pages: ["Rendered page", "Second page"])

        for format in PDFImageExportFormat.allCases {
            let files = try PDFNativeConversionEngine.imageFiles(
                from: document,
                pageIndexes: [0],
                format: format,
                dpi: 144,
                baseName: "Quarterly/Report"
            )

            XCTAssertEqual(files.count, 1)
            XCTAssertEqual(files[0].filename, "Quarterly-Report-page-1.\(format.filenameExtension)")
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: files[0].data))
            XCTAssertGreaterThanOrEqual(bitmap.pixelsWide, 1_200)
            XCTAssertGreaterThanOrEqual(bitmap.pixelsHigh, 1_500)
        }
    }

    func testImagesToPDFPreservesInputOrderAndReopens() throws {
        let red = try makePNG(color: .systemRed, size: NSSize(width: 80, height: 120))
        let blue = try makePNG(color: .systemBlue, size: NSSize(width: 120, height: 80))
        let inputs = [
            PDFImageInput(filename: "red.png", data: red),
            PDFImageInput(filename: "blue.png", data: blue),
        ]

        let document = try PDFNativeConversionEngine.document(from: inputs)

        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(inputs[0].data, red)
        XCTAssertEqual(inputs[1].data, blue)
        XCTAssertGreaterThan(
            try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).height,
            try XCTUnwrap(document.page(at: 0)).bounds(for: .mediaBox).width
        )
        XCTAssertGreaterThan(
            try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox).width,
            try XCTUnwrap(document.page(at: 1)).bounds(for: .mediaBox).height
        )

        let data = try XCTUnwrap(document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(reopened.pageCount, 2)
    }

    func testImageFileWritingNeverOverwritesExistingOutput() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let existingURL = directory.appendingPathComponent("Page.png")
        try Data("existing".utf8).write(to: existingURL)

        let outputURLs = try PDFNativeConversionEngine.writeImageFiles(
            [PDFConvertedFile(filename: "Page.png", data: Data("new".utf8))],
            to: directory
        )

        XCTAssertEqual(outputURLs.map(\.lastPathComponent), ["Page-2.png"])
        XCTAssertEqual(try Data(contentsOf: existingURL), Data("existing".utf8))
        XCTAssertEqual(try Data(contentsOf: outputURLs[0]), Data("new".utf8))
    }

    func testImageFileWritingReservesUniqueNamesWithinOneBatch() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURLs = try PDFNativeConversionEngine.writeImageFiles(
            [
                PDFConvertedFile(filename: "Page.png", data: Data("first".utf8)),
                PDFConvertedFile(filename: "Page.png", data: Data("second".utf8)),
            ],
            to: directory
        )

        XCTAssertEqual(outputURLs.map(\.lastPathComponent), ["Page.png", "Page-2.png"])
        XCTAssertEqual(try Data(contentsOf: outputURLs[0]), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: outputURLs[1]), Data("second".utf8))
    }

    func testImagesToPDFRejectsDimensionsAboveSafePixelLimitBeforeDecoding() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 6_000,
                pixelsHigh: 5_000,
                bitsPerSample: 1,
                samplesPerPixel: 1,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceWhite,
                bytesPerRow: 750,
                bitsPerPixel: 1
            )
        )
        let oversizedTIFF = try XCTUnwrap(bitmap.representation(using: .tiff, properties: [:]))

        XCTAssertThrowsError(
            try PDFNativeConversionEngine.document(
                from: [PDFImageInput(filename: "oversized.tiff", data: oversizedTIFF)]
            )
        ) { error in
            XCTAssertEqual(
                error as? PDFNativeConversionError,
                .imageTooLarge("oversized.tiff")
            )
        }
    }

    func testConversionFailuresAreTypedAndRecoverable() throws {
        let textDocument = try makeTextDocument(pages: ["Page"])
        XCTAssertThrowsError(
            try PDFNativeConversionEngine.imageFiles(
                from: textDocument,
                pageIndexes: [],
                format: .png,
                dpi: 144,
                baseName: "PDF"
            )
        ) { error in
            XCTAssertEqual(error as? PDFNativeConversionError, .emptySelection)
        }
        XCTAssertThrowsError(
            try PDFNativeConversionEngine.imageFiles(
                from: textDocument,
                pageIndexes: [0],
                format: .png,
                dpi: 600,
                baseName: "PDF"
            )
        ) { error in
            XCTAssertEqual(error as? PDFNativeConversionError, .invalidResolution)
        }

        let imageOnly = try PDFNativeConversionEngine.document(
            from: [PDFImageInput(filename: "scan.png", data: makePNG(color: .white))]
        )
        XCTAssertThrowsError(
            try PDFNativeConversionEngine.searchableText(from: imageOnly, pageIndexes: [0])
        ) { error in
            XCTAssertEqual(error as? PDFNativeConversionError, .noSearchableText)
        }
        XCTAssertThrowsError(
            try PDFNativeConversionEngine.document(
                from: [PDFImageInput(filename: "bad.png", data: Data("not an image".utf8))]
            )
        ) { error in
            XCTAssertEqual(error as? PDFNativeConversionError, .invalidImage("bad.png"))
        }
    }

    private func makeTextDocument(pages: [String]) throws -> PDFDocument {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func makePNG(
        color: NSColor,
        size: NSSize = NSSize(width: 100, height: 100)
    ) throws -> Data {
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSRect(origin: .zero, size: size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: tiff))
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFViewerConversionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
