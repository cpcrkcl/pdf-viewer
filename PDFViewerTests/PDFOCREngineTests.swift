import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFOCREngineTests: XCTestCase {
    func testRasterDimensionsRejectNonFiniteGeometryWithoutTrapping() throws {
        XCTAssertThrowsError(
            try PDFOCREngine.rasterDimensions(
                pageSize: CGSize(width: CGFloat.infinity, height: 792),
                rasterDPI: 300
            )
        ) { error in
            XCTAssertEqual(error as? PDFOCRError, .couldNotRenderPage)
        }
    }

    func testLocalOCRCreatesSearchableTextLayerAndPreservesUnselectedPages() async throws {
        let source = try makeDocument(pages: ["OFFLINE OCR SAMPLE 4829", "Untouched vector page"])
        let originalFirstPageText = source.page(at: 0)?.string
        var progressUpdates: [PDFOCRProgress] = []

        let result = try await PDFOCREngine.process(
            document: source,
            pageIndexes: [0],
            addsSearchableText: true,
            enhancement: .none
        ) { progress in
            progressUpdates.append(progress)
        }

        XCTAssertEqual(result.document.pageCount, 2)
        XCTAssertGreaterThan(result.recognizedLineCount, 0)
        XCTAssertTrue(
            result.document.page(at: 0)?.string?.localizedCaseInsensitiveContains("OFFLINE") == true
        )
        XCTAssertTrue(
            result.document.page(at: 0)?.string?.localizedCaseInsensitiveContains("4829") == true
        )
        XCTAssertEqual(
            result.document.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "Untouched vector page"
        )
        XCTAssertEqual(source.page(at: 0)?.string, originalFirstPageText)
        XCTAssertEqual(progressUpdates.last, PDFOCRProgress(completedPages: 1, totalPages: 1))

        let data = try XCTUnwrap(result.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertFalse(reopened.findString("OFFLINE", withOptions: .caseInsensitive).isEmpty)
    }

    func testScanEnhancementCanRasterizeWithoutAddingOCRText() async throws {
        let source = try makeDocument(pages: ["Low contrast scan"])

        let result = try await PDFOCREngine.process(
            document: source,
            pageIndexes: [0],
            addsSearchableText: false,
            enhancement: .cleanScan
        ) { _ in }

        XCTAssertEqual(result.recognizedLineCount, 0)
        XCTAssertNil(result.document.page(at: 0)?.string)
        XCTAssertEqual(result.document.pageCount, 1)
        XCTAssertTrue(result.document.page(at: 0)?.annotations.isEmpty == true)
    }

    func testRasterQualityControlsEmbeddedScanResolution() async throws {
        let source = try makeDocument(pages: ["Resolution control sample with visible details 7391"])
        let compact = try await PDFOCREngine.process(
            document: source,
            pageIndexes: [0],
            addsSearchableText: false,
            enhancement: .none,
            rasterQuality: .compact
        ) { _ in }
        let archival = try await PDFOCREngine.process(
            document: source,
            pageIndexes: [0],
            addsSearchableText: false,
            enhancement: .none,
            rasterQuality: .archival
        ) { _ in }

        let compactData = try XCTUnwrap(compact.document.dataRepresentation())
        let archivalData = try XCTUnwrap(archival.document.dataRepresentation())
        XCTAssertGreaterThan(archivalData.count, compactData.count)
        XCTAssertEqual(PDFOCRRasterQuality.compact.dpi, 150)
        XCTAssertEqual(PDFOCRRasterQuality.archival.dpi, 300)
    }

    func testGrayscaleEnhancementProducesNeutralPixels() throws {
        let bitmap = try XCTUnwrap(
            NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: 12,
                pixelsHigh: 12,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            )
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedRed: 0.8, green: 0.25, blue: 0.1, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 12, height: 12).fill()
        NSGraphicsContext.restoreGraphicsState()
        let input = try XCTUnwrap(bitmap.cgImage)

        let output = try PDFScanEnhancer.enhancedImage(input, preset: .grayscale)
        let representation = NSBitmapImageRep(cgImage: output)
        let color = try XCTUnwrap(representation.colorAt(x: 6, y: 6)?.usingColorSpace(.deviceRGB))

        XCTAssertEqual(color.redComponent, color.greenComponent, accuracy: 0.015)
        XCTAssertEqual(color.greenComponent, color.blueComponent, accuracy: 0.015)
    }

    func testCropMarginsReduceProcessedPageAndPreviewWithoutChangingSource() async throws {
        let source = try makeDocument(pages: ["Crop preview"])
        let sourceBounds = try XCTUnwrap(source.page(at: 0)).bounds(for: .cropBox)

        let preview = try await PDFOCREngine.preview(
            document: source,
            pageIndex: 0,
            enhancement: .none,
            cropMarginsPercent: 10
        )
        XCTAssertLessThan(preview.processed.width, preview.original.width)
        XCTAssertLessThan(preview.processed.height, preview.original.height)

        let result = try await PDFOCREngine.process(
            document: source,
            pageIndexes: [0],
            addsSearchableText: false,
            enhancement: .none,
            cropMarginsPercent: 10
        ) { _ in }

        let outputBounds = try XCTUnwrap(result.document.page(at: 0)).bounds(for: .cropBox)
        XCTAssertEqual(outputBounds.width, sourceBounds.width * 0.8, accuracy: 1)
        XCTAssertEqual(outputBounds.height, sourceBounds.height * 0.8, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(source.page(at: 0)).bounds(for: .cropBox), sourceBounds)
    }

    func testWideScanCanSplitIntoOrderedPagesAsOneUndoableRevision() async throws {
        let source = try makeDocument(pages: ["LEFT PAGE CONTENT     RIGHT PAGE CONTENT"])
        let sourcePage = try XCTUnwrap(source.page(at: 0))
        sourcePage.setBounds(CGRect(x: 0, y: 0, width: 1_000, height: 500), for: .mediaBox)
        sourcePage.setBounds(CGRect(x: 0, y: 0, width: 1_000, height: 500), for: .cropBox)
        let editor = try PDFDocumentEditor(document: source)

        let result = try await PDFOCREngine.process(
            document: editor.document,
            pageIndexes: [0],
            addsSearchableText: false,
            enhancement: .none,
            splitDoublePages: true
        ) { _ in }

        XCTAssertEqual(result.document.pageCount, 2)
        XCTAssertEqual(result.sourcePageIndexes, [0, 0])
        XCTAssertEqual(
            try XCTUnwrap(result.document.page(at: 0)).bounds(for: .cropBox).width,
            500,
            accuracy: 1
        )
        XCTAssertEqual(
            try XCTUnwrap(result.document.page(at: 1)).bounds(for: .cropBox).width,
            500,
            accuracy: 1
        )

        try editor.applyProcessedDocument(
            result.document,
            sourcePageIndexes: result.sourcePageIndexes
        )
        XCTAssertEqual(editor.document.pageCount, 2)
        XCTAssertEqual(Set(editor.pageIDs).count, 2)
        XCTAssertTrue(editor.canUndo)
        try editor.undo()
        XCTAssertEqual(editor.document.pageCount, 1)
    }

    func testProcessingRejectsEmptyAndInvalidSelections() async throws {
        let source = try makeDocument(pages: ["Page"])

        do {
            _ = try await PDFOCREngine.process(
                document: source,
                pageIndexes: [],
                addsSearchableText: true,
                enhancement: .none
            ) { _ in }
            XCTFail("Expected an empty-selection error")
        } catch {
            XCTAssertEqual(error as? PDFOCRError, .noPagesSelected)
        }

        do {
            _ = try await PDFOCREngine.process(
                document: source,
                pageIndexes: [4],
                addsSearchableText: true,
                enhancement: .none
            ) { _ in }
            XCTFail("Expected an invalid-selection error")
        } catch {
            XCTAssertEqual(error as? PDFOCRError, .invalidPageSelection)
        }


        do {
            _ = try await PDFOCREngine.process(
                document: source,
                pageIndexes: [0],
                addsSearchableText: false,
                enhancement: .none,
                cropMarginsPercent: 25
            ) { _ in }
            XCTFail("Expected an invalid-crop error")
        } catch {
            XCTAssertEqual(error as? PDFOCRError, .invalidCropMargins)
        }

        do {
            _ = try await PDFOCREngine.process(
                document: source,
                pageIndexes: [0],
                addsSearchableText: true,
                enhancement: .none,
                language: .englishUS,
                minimumConfidence: 1.1
            ) { _ in }
            XCTFail("Expected an invalid-confidence error")
        } catch {
            XCTAssertEqual(error as? PDFOCRError, .recognitionFailed)
        }
    }

    func testEditorCommitsProcessedPagesAsOneUndoableRevision() async throws {
        let source = try makeDocument(pages: ["OCR UNDO TEST"])
        let editor = try PDFDocumentEditor(document: source)
        let result = try await PDFOCREngine.process(
            document: editor.document,
            pageIndexes: [0],
            addsSearchableText: true,
            enhancement: .grayscale
        ) { _ in }

        try editor.applyProcessedDocument(result.document)

        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.document.page(at: 0)?.string?.contains("OCR") == true)
        try editor.undo()
        XCTAssertEqual(
            editor.document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "OCR UNDO TEST"
        )
        XCTAssertFalse(editor.isDirty)
    }

    private func makeDocument(pages: [String]) throws -> PDFDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFViewerOCRTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }
}
