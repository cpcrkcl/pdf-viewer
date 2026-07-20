import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFRedactionEngineTests: XCTestCase {
    func testPermanentRedactionRemovesSearchableContentAndMetadataOnlyFromTargetPages() throws {
        let source = try makeDocument(pages: ["SECRET account 1234", "Public appendix"])
        source.documentAttributes = [
            PDFDocumentAttribute.subjectAttribute: "SECRET metadata",
            PDFDocumentAttribute.authorAttribute: "Fixture Author",
        ]
        let regions = [
            PDFRedactionRegion(
                pageIndex: 0,
                bounds: CGRect(x: 60, y: 640, width: 300, height: 70)
            ),
        ]

        let redacted = try PDFRedactionEngine.redactedDocument(from: source, regions: regions)

        XCTAssertEqual(redacted.pageCount, 2)
        XCTAssertNil(redacted.page(at: 0)?.string)
        XCTAssertEqual(redacted.page(at: 1)?.string?.trimmingCharacters(in: .whitespacesAndNewlines), "Public appendix")
        XCTAssertTrue(redacted.findString("SECRET", withOptions: .caseInsensitive).isEmpty)
        XCTAssertNil(redacted.documentAttributes?[PDFDocumentAttribute.subjectAttribute])
        XCTAssertNil(redacted.documentAttributes?[PDFDocumentAttribute.authorAttribute])
        XCTAssertEqual(
            source.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines),
            "SECRET account 1234"
        )
        XCTAssertEqual(
            source.documentAttributes?[PDFDocumentAttribute.subjectAttribute] as? String,
            "SECRET metadata"
        )

        let redactedData = try XCTUnwrap(redacted.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: redactedData))
        XCTAssertTrue(reopened.findString("SECRET", withOptions: .caseInsensitive).isEmpty)
        XCTAssertNoThrow(try PDFRedactionEngine.verifySanitized(reopened, pageIndexes: [0]))
    }

    func testRedactionProducesAnOpaqueRasterCoverAndBurnsPageAnnotations() throws {
        let source = try makeDocument(pages: ["Visible text"])
        let note = PDFAnnotation(
            bounds: CGRect(x: 80, y: 500, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        note.contents = "Annotation secret"
        source.page(at: 0)?.addAnnotation(note)
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 200, y: 280, width: 120, height: 120)
        )

        let redacted = try PDFRedactionEngine.redactedDocument(from: source, regions: [region])

        let page = try XCTUnwrap(redacted.page(at: 0))
        XCTAssertTrue(page.annotations.isEmpty)
        XCTAssertNil(page.string)
        let thumbnail = page.thumbnail(of: NSSize(width: 612, height: 792), for: .cropBox)
        let representation = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
        var darkPixelCount = 0
        for y in stride(from: 0, to: representation.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: representation.pixelsWide, by: 2) {
                guard let color = representation.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent < 0.05,
                   color.greenComponent < 0.05,
                   color.blueComponent < 0.05,
                   color.alphaComponent > 0.99 {
                    darkPixelCount += 1
                }
            }
        }
        XCTAssertGreaterThan(darkPixelCount, 2_000)
    }

    func testOptionalReasonLabelIsBurnedIntoRasterWithoutBecomingSearchable() throws {
        let source = try makeDocument(pages: ["Sensitive record"])
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 120, y: 280, width: 360, height: 100)
        )
        let plain = try PDFRedactionEngine.redactedDocument(
            from: source,
            regions: [region]
        )
        let labeled = try PDFRedactionEngine.redactedDocument(
            from: source,
            regions: [region],
            reasonLabel: "PERSONAL DATA"
        )

        XCTAssertNil(labeled.page(at: 0)?.string)
        XCTAssertTrue(labeled.findString("PERSONAL DATA", withOptions: []).isEmpty)
        let plainImage = try bitmap(of: try XCTUnwrap(plain.page(at: 0)))
        let labeledImage = try bitmap(of: try XCTUnwrap(labeled.page(at: 0)))
        var changedPixels = 0
        for y in 0..<min(plainImage.pixelsHigh, labeledImage.pixelsHigh) {
            for x in 0..<min(plainImage.pixelsWide, labeledImage.pixelsWide) {
                guard
                    let left = plainImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                    let right = labeledImage.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB)
                else {
                    continue
                }
                if abs(left.redComponent - right.redComponent) > 0.2 ||
                    abs(left.greenComponent - right.greenComponent) > 0.2 ||
                    abs(left.blueComponent - right.blueComponent) > 0.2 {
                    changedPixels += 1
                }
            }
        }
        XCTAssertGreaterThan(changedPixels, 100)
    }

    func testInvalidOrOutOfBoundsSelectionsFailWithoutProducingOutput() throws {
        let source = try makeDocument(pages: ["Secret"])

        XCTAssertThrowsError(
            try PDFRedactionEngine.redactedDocument(from: source, regions: [])
        ) { error in
            XCTAssertEqual(error as? PDFRedactionError, .noRegions)
        }
        XCTAssertThrowsError(
            try PDFRedactionEngine.redactedDocument(
                from: source,
                regions: [PDFRedactionRegion(pageIndex: 4, bounds: .zero)]
            )
        ) { error in
            XCTAssertEqual(error as? PDFRedactionError, .invalidRegion)
        }
        XCTAssertThrowsError(
            try PDFRedactionEngine.redactedDocument(
                from: source,
                regions: [
                    PDFRedactionRegion(
                        pageIndex: 0,
                        bounds: CGRect(x: 900, y: 900, width: 20, height: 20)
                    ),
                ]
            )
        ) { error in
            XCTAssertEqual(error as? PDFRedactionError, .invalidRegion)
        }
    }

    func testEditorAppliesEveryRegionAsOneUndoableRevision() throws {
        let source = try makeDocument(pages: ["First secret", "Second secret"])
        let editor = try PDFDocumentEditor(document: source)
        let regions = [
            PDFRedactionRegion(pageIndex: 0, bounds: CGRect(x: 60, y: 640, width: 240, height: 70)),
            PDFRedactionRegion(pageIndex: 1, bounds: CGRect(x: 60, y: 640, width: 240, height: 70)),
        ]

        try editor.applyPermanentRedactions(regions)

        XCTAssertTrue(editor.isDirty)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.document.findString("secret", withOptions: .caseInsensitive).isEmpty)
        XCTAssertTrue(editor.canUndo)

        try editor.undo()
        XCTAssertEqual(editor.document.findString("secret", withOptions: .caseInsensitive).count, 2)
        XCTAssertFalse(editor.isDirty)

        try editor.redo()
        XCTAssertTrue(editor.document.findString("secret", withOptions: .caseInsensitive).isEmpty)
    }

    private func makeDocument(pages: [String]) throws -> PDFDocument {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PDFViewerRedactionTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        return try XCTUnwrap(PDFDocument(url: url))
    }

    private func bitmap(of page: PDFPage) throws -> NSBitmapImageRep {
        let thumbnail = page.thumbnail(of: NSSize(width: 612, height: 792), for: .cropBox)
        return try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(thumbnail.tiffRepresentation)))
    }
}
