import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFDocumentEditorTests: XCTestCase {
    func testDeleteUndoAndRedoPreserveTheSourceFile() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo", "Charlie"], to: sourceURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let sourceDocument = try openDocument(at: sourceURL)
        let editor = try PDFDocumentEditor(document: sourceDocument)

        try editor.deletePages(at: IndexSet(integer: 1))

        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Charlie"])
        XCTAssertTrue(editor.canUndo)
        XCTAssertFalse(editor.canRedo)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)

        try editor.undo()
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Bravo", "Charlie"])
        XCTAssertFalse(editor.isDirty)

        try editor.redo()
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Charlie"])
        XCTAssertTrue(editor.isDirty)
    }

    func testRotateAndMoveSelectedPages() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo", "Charlie", "Delta"])

        try editor.rotatePages(at: IndexSet([0, 2]), clockwise: true)
        XCTAssertEqual(editor.document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(editor.document.page(at: 2)?.rotation, 90)

        try editor.movePages(at: IndexSet([0, 2]), to: 4)

        XCTAssertEqual(pageTexts(in: editor.document), ["Bravo", "Delta", "Alpha", "Charlie"])
        XCTAssertEqual(editor.document.page(at: 2)?.rotation, 90)
        XCTAssertEqual(editor.document.page(at: 3)?.rotation, 90)
    }

    func testRejectsDeletingTheOnlyPage() throws {
        let editor = try makeEditor(pages: ["Only page"])

        XCTAssertThrowsError(try editor.deletePages(at: IndexSet(integer: 0))) { error in
            XCTAssertEqual(error as? PDFDocumentEditorError, .cannotDeleteOnlyPage)
        }
        XCTAssertEqual(pageTexts(in: editor.document), ["Only page"])
        XCTAssertFalse(editor.canUndo)
    }

    func testInsertExtractAndNewMutationClearRedoHistory() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo"])
        let insertedDocument = try makeDocument(pages: ["Xray", "Yankee"])

        try editor.insertPages(from: insertedDocument, at: 1)
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Xray", "Yankee", "Bravo"])

        let extracted = try editor.extractPages(at: IndexSet([1, 3]))
        XCTAssertEqual(pageTexts(in: extracted), ["Xray", "Bravo"])
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Xray", "Yankee", "Bravo"])

        try editor.undo()
        XCTAssertTrue(editor.canRedo)
        try editor.rotatePages(at: IndexSet(integer: 0), clockwise: true)
        XCTAssertFalse(editor.canRedo)
    }

    func testInsertCanUseOnlySelectedPagesFromAnotherPDF() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo"])
        let insertedDocument = try makeDocument(pages: ["Xray", "Yankee", "Zulu"])

        try editor.insertPages(
            from: insertedDocument,
            selecting: IndexSet([0, 2]),
            at: 1
        )

        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Xray", "Zulu", "Bravo"])
        XCTAssertTrue(editor.canUndo)
    }

    func testExportedRevisionsRemainSafeAcrossMutationsUndoAndRedo() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo", "Charlie"])

        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertFalse(editor.isDirty)

        try editor.rotatePages(at: IndexSet(integer: 0), clockwise: true)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.isDirty)

        editor.markCurrentRevisionExported()
        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.isDirty)

        try editor.deletePages(at: IndexSet(integer: 2))
        XCTAssertTrue(editor.hasUnexportedChanges)

        try editor.undo()
        XCTAssertFalse(editor.hasUnexportedChanges)
        try editor.undo()
        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertFalse(editor.isDirty)

        try editor.redo()
        XCTAssertFalse(editor.hasUnexportedChanges)
        try editor.redo()
        XCTAssertTrue(editor.hasUnexportedChanges)
    }

    func testExtractionDoesNotProtectTheWorkingRevision() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo"])
        try editor.rotatePages(at: IndexSet(integer: 0), clockwise: true)

        _ = try editor.extractPages(at: IndexSet(integer: 0))

        XCTAssertTrue(editor.hasUnexportedChanges)
    }

    func testCreatesEverySupportedAnnotationWithOwnershipMetadata() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo"])
        let markupBounds = CGRect(x: 70, y: 670, width: 90, height: 30)

        try editor.addTextMarkup(
            kind: .highlight,
            regions: [TextMarkupRegion(pageIndex: 0, bounds: markupBounds)],
            color: .yellow
        )
        try editor.addTextMarkup(
            kind: .underline,
            regions: [TextMarkupRegion(pageIndex: 0, bounds: markupBounds)],
            color: .blue
        )
        try editor.addTextMarkup(
            kind: .strikethrough,
            regions: [TextMarkupRegion(pageIndex: 1, bounds: markupBounds)],
            color: .red
        )
        try editor.addInkStroke(
            InkStroke(
                pageIndex: 0,
                points: [CGPoint(x: 100, y: 100), CGPoint(x: 120, y: 125)]
            ),
            color: .black,
            lineWidth: .standard
        )
        let noteIdentifier = try editor.addTextNote(
            pageIndex: 1,
            point: CGPoint(x: 200, y: 200),
            contents: "Review this section",
            color: .yellow
        )

        let annotations = (0..<editor.document.pageCount).flatMap { index in
            editor.document.page(at: index)?.annotations ?? []
        }
        let primaryAnnotations = annotations.filter {
            $0.type != PDFAnnotationSubtype.popup.pdfTypeName
        }
        XCTAssertEqual(primaryAnnotations.count, 5)
        XCTAssertEqual(
            Set(primaryAnnotations.compactMap(\.type)),
            Set([
                PDFAnnotationSubtype.highlight.pdfTypeName,
                PDFAnnotationSubtype.underline.pdfTypeName,
                PDFAnnotationSubtype.strikeOut.pdfTypeName,
                PDFAnnotationSubtype.ink.pdfTypeName,
                PDFAnnotationSubtype.text.pdfTypeName,
            ])
        )
        for annotation in primaryAnnotations {
            XCTAssertNotNil(AnnotationIdentifier(annotation: annotation))
            XCTAssertEqual(annotation.userName, "PDFViewer")
            XCTAssertNotNil(annotation.modificationDate)
        }
        XCTAssertEqual(
            editor.textNoteContents(pageIndex: 1, identifier: noteIdentifier),
            "Review this section"
        )
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.isDirty)
    }

    func testAnnotationMutationsUndoRedoAndProtectedRevision() throws {
        let editor = try makeEditor(pages: ["Alpha"])
        let identifier = try editor.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 150, y: 150),
            contents: "Original note",
            color: .yellow
        )
        XCTAssertEqual(
            editor.document.page(at: 0)?.annotations.filter {
                $0.type != PDFAnnotationSubtype.popup.pdfTypeName
            }.count,
            1
        )

        editor.markCurrentRevisionExported()
        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.isDirty)

        try editor.updateTextNote(
            pageIndex: 0,
            identifier: identifier,
            contents: "Updated note"
        )
        try editor.updateAnnotationColor(
            pageIndex: 0,
            identifier: identifier,
            color: .green
        )
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertEqual(
            editor.textNoteContents(pageIndex: 0, identifier: identifier),
            "Updated note"
        )

        try editor.undo()
        XCTAssertEqual(
            editor.textNoteContents(pageIndex: 0, identifier: identifier),
            "Updated note"
        )
        try editor.undo()
        XCTAssertEqual(
            editor.textNoteContents(pageIndex: 0, identifier: identifier),
            "Original note"
        )
        XCTAssertFalse(editor.hasUnexportedChanges)

        try editor.redo()
        try editor.redo()
        XCTAssertTrue(editor.hasUnexportedChanges)
        try editor.deleteAnnotation(pageIndex: 0, identifier: identifier)
        XCTAssertEqual(
            editor.document.page(at: 0)?.annotations.filter {
                $0.type != PDFAnnotationSubtype.popup.pdfTypeName
            }.count,
            0
        )
    }

    func testAnnotationCommitsKeepTheLivePDFDocumentAttached() throws {
        let editor = try makeEditor(pages: ["Alpha"])
        let attachedDocument = editor.document

        try editor.addTextMarkup(
            kind: .highlight,
            regions: [
                TextMarkupRegion(
                    pageIndex: 0,
                    bounds: CGRect(x: 50, y: 650, width: 100, height: 24)
                ),
            ],
            color: .yellow
        )
        XCTAssertTrue(editor.document === attachedDocument)

        try editor.addInkStroke(
            InkStroke(
                pageIndex: 0,
                points: [CGPoint(x: 80, y: 80), CGPoint(x: 120, y: 120)]
            ),
            color: .black,
            lineWidth: .standard
        )
        XCTAssertTrue(editor.document === attachedDocument)
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 2)
        XCTAssertTrue(editor.canUndo)

        // Undo still restores the exact serialized prior revision.
        try editor.undo()
        XCTAssertFalse(editor.document === attachedDocument)
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 1)
    }

    func testAnnotationRoundTripsThroughPDFDataAndLeavesThirdPartyAnnotationsUnowned() throws {
        let sourceDocument = try makeDocument(pages: ["Alpha"])
        let thirdParty = PDFAnnotation(
            bounds: CGRect(x: 50, y: 50, width: 24, height: 24),
            forType: .text,
            withProperties: nil
        )
        thirdParty.contents = "Existing note"
        sourceDocument.page(at: 0)?.addAnnotation(thirdParty)
        let editor = try PDFDocumentEditor(document: sourceDocument)

        let identifier = try editor.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 200, y: 200),
            contents: "PDFViewer note",
            color: .pink
        )
        let exportedData = try XCTUnwrap(editor.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: exportedData))
        let reopenedAnnotations = try XCTUnwrap(reopened.page(at: 0)?.annotations).filter {
            $0.type != PDFAnnotationSubtype.popup.pdfTypeName
        }

        XCTAssertEqual(reopenedAnnotations.count, 2)
        let identifiers = reopenedAnnotations.compactMap(AnnotationIdentifier.init(annotation:))
        XCTAssertEqual(identifiers, [identifier])
    }

    func testMultiPageMarkupCreatesOneUndoableRevision() throws {
        let editor = try makeEditor(pages: ["Alpha", "Bravo"])
        let regions = [
            TextMarkupRegion(
                pageIndex: 0,
                bounds: CGRect(x: 50, y: 650, width: 120, height: 24)
            ),
            TextMarkupRegion(
                pageIndex: 0,
                bounds: CGRect(x: 50, y: 620, width: 140, height: 24)
            ),
            TextMarkupRegion(
                pageIndex: 1,
                bounds: CGRect(x: 60, y: 650, width: 100, height: 24)
            ),
        ]

        try editor.addTextMarkup(kind: .highlight, regions: regions, color: .yellow)

        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 2)
        XCTAssertEqual(editor.document.page(at: 1)?.annotations.count, 1)
        XCTAssertTrue(editor.canUndo)

        try editor.undo()

        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 0)
        XCTAssertEqual(editor.document.page(at: 1)?.annotations.count, 0)
        XCTAssertFalse(editor.canUndo)
    }

    private func makeEditor(pages: [String]) throws -> PDFDocumentEditor {
        try PDFDocumentEditor(document: makeDocument(pages: pages))
    }

    private func makeDocument(pages: [String]) throws -> PDFDocument {
        let temporaryDirectory = try makeTemporaryDirectory()
        let url = temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("pdf")
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        let document = try openDocument(at: url)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        return document
    }

    private func openDocument(at url: URL) throws -> PDFDocument {
        guard let document = PDFDocument(url: url) else {
            throw TestError.couldNotOpenFixture
        }
        return document
    }

    private func pageTexts(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestError: Error {
        case couldNotOpenFixture
    }
}
