import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFDocumentEditorTests: XCTestCase {
    func testAnnotationOperationsRejectNonFiniteCoordinatesWithoutMutating() throws {
        let editor = try PDFDocumentEditor(document: makeDocument(pages: ["Page"]))

        XCTAssertThrowsError(
            try editor.addTextNote(
                pageIndex: 0,
                point: CGPoint(x: CGFloat.nan, y: 20),
                contents: "Unsafe",
                color: .yellow
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentEditorError, .invalidAnnotation)
        }
        XCTAssertThrowsError(
            try editor.addInkStroke(
                InkStroke(
                    pageIndex: 0,
                    points: [
                        CGPoint(x: 10, y: 10),
                        CGPoint(x: CGFloat.infinity, y: 20),
                    ]
                ),
                color: .black,
                lineWidth: .standard
            )
        ) { error in
            XCTAssertEqual(error as? PDFDocumentEditorError, .invalidAnnotation)
        }
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.isDirty)
    }

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

    /// Spike required before the visual-signature implementation: confirm
    /// that PDFKit serializes the custom stamp drawing into an appearance
    /// stream that other readers can render after reopen.
    func testSpikeCustomStampAppearanceSurvivesPDFKitRoundTrip() throws {
        let document = try makeDocument(pages: ["Signature appearance spike"])
        let page = try XCTUnwrap(document.page(at: 0))
        let signatureImage = NSImage(size: NSSize(width: 160, height: 60))
        signatureImage.lockFocus()
        NSColor.systemRed.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 160, height: 60), xRadius: 10, yRadius: 10).fill()
        signatureImage.unlockFocus()

        let annotation = SignatureAppearanceSpikeAnnotation(
            bounds: CGRect(x: 180, y: 320, width: 160, height: 60),
            image: signatureImage
        )
        page.addAnnotation(annotation)

        let data = try XCTUnwrap(document.dataRepresentation())
        XCTAssertNotNil(data.range(of: Data("/Image".utf8)))
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let reopenedPage = try XCTUnwrap(reopened.page(at: 0))

        XCTAssertEqual(reopenedPage.annotations.first?.type, PDFAnnotationSubtype.stamp.pdfTypeName)
        XCTAssertFalse(reopenedPage.annotations.isEmpty)
    }

    func testVisualSignaturePlacementUndoRedoAndOwnershipRoundTrip() throws {
        let editor = try makeEditor(pages: ["Sign here"])
        let imageData = try makeSignatureImageData()

        let identifier = try editor.addVisualSignature(
            pageIndex: 0,
            point: CGPoint(x: 300, y: 300),
            imageData: imageData,
            size: .medium
        )

        let annotation = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first)
        XCTAssertEqual(annotation.type, PDFAnnotationSubtype.stamp.pdfTypeName)
        XCTAssertEqual(AnnotationIdentifier(annotation: annotation), identifier)
        XCTAssertEqual(VisualSignatureAnnotation.imageData(from: annotation), imageData)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.hasUnexportedChanges)

        try editor.undo()
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 0)
        try editor.redo()
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.count, 1)

        let exportedData = try XCTUnwrap(editor.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: exportedData))
        let reopenedAnnotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(AnnotationIdentifier(annotation: reopenedAnnotation), identifier)
        XCTAssertEqual(VisualSignatureAnnotation.imageData(from: reopenedAnnotation), imageData)
        XCTAssertNotNil(exportedData.range(of: Data("/Image".utf8)))
    }

    func testCustomStampIsOwnedClassifiedAndPreservedAcrossRoundTrip() throws {
        let editor = try PDFDocumentEditor(document: makeDocument(pages: ["Page"]))
        let imageData = try makeSignatureImageData()

        let identifier = try editor.addCustomStamp(
            pageIndex: 0,
            point: CGPoint(x: 180, y: 240),
            imageData: imageData,
            displayName: "Local Approval"
        )

        let item = try XCTUnwrap(editor.ownedAnnotations.first)
        XCTAssertEqual(item.identifier, identifier)
        XCTAssertEqual(item.kind, .stamp)
        XCTAssertEqual(item.label, "Local Approval")

        let exported = try XCTUnwrap(editor.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: exported))
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertTrue(VisualSignatureAnnotation.isCustomStamp(annotation))
        XCTAssertEqual(VisualSignatureAnnotation.imageData(from: annotation), imageData)
        XCTAssertEqual(AnnotationIdentifier(annotation: annotation), identifier)
    }

    func testVisualSignatureSizeCanBeRestyledAsOneRevision() throws {
        let editor = try makeEditor(pages: ["Sign here"])
        let identifier = try editor.addVisualSignature(
            pageIndex: 0,
            point: CGPoint(x: 300, y: 300),
            imageData: try makeSignatureImageData(),
            size: .small
        )
        let originalBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)

        try editor.updateVisualSignatureSize(
            pageIndex: 0,
            identifier: identifier,
            size: .large
        )

        let enlargedBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)
        XCTAssertGreaterThan(enlargedBounds.width, originalBounds.width)
        XCTAssertEqual(enlargedBounds.midX, originalBounds.midX, accuracy: 0.5)
        try editor.undo()
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.first?.bounds, originalBounds)
    }

    func testShapeAndBuiltInStampAnnotationsSurviveRoundTrip() throws {
        let editor = try makeEditor(pages: ["Review these shapes"])
        let placements = [
            ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 80, y: 120),
                endPoint: CGPoint(x: 200, y: 190)
            ),
            ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 230, y: 120),
                endPoint: CGPoint(x: 350, y: 190)
            ),
            ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 80, y: 240),
                endPoint: CGPoint(x: 200, y: 300)
            ),
            ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 230, y: 240),
                endPoint: CGPoint(x: 350, y: 300)
            ),
        ]

        let rectangleID = try editor.addShapeAnnotation(
            kind: .rectangle,
            placement: placements[0],
            color: .red,
            lineWidth: .standard
        )
        _ = try editor.addShapeAnnotation(
            kind: .oval,
            placement: placements[1],
            color: .blue,
            lineWidth: .fine
        )
        _ = try editor.addShapeAnnotation(
            kind: .line,
            placement: placements[2],
            color: .black,
            lineWidth: .bold
        )
        _ = try editor.addShapeAnnotation(
            kind: .arrow,
            placement: placements[3],
            color: .green,
            lineWidth: .standard
        )
        let stampID = try editor.addBuiltInStamp(
            pageIndex: 0,
            point: CGPoint(x: 300, y: 400),
            preset: .approved
        )

        let data = try XCTUnwrap(editor.document.dataRepresentation())
        let reopened = try XCTUnwrap(PDFDocument(data: data))
        let annotations = try XCTUnwrap(reopened.page(at: 0)).annotations
        XCTAssertEqual(
            annotations.map(\.type),
            [
                PDFAnnotationSubtype.square.pdfTypeName,
                PDFAnnotationSubtype.circle.pdfTypeName,
                PDFAnnotationSubtype.line.pdfTypeName,
                PDFAnnotationSubtype.line.pdfTypeName,
                PDFAnnotationSubtype.stamp.pdfTypeName,
            ]
        )
        XCTAssertEqual(AnnotationIdentifier(annotation: annotations[0]), rectangleID)
        XCTAssertEqual(annotations[2].endLineStyle, .none)
        XCTAssertEqual(annotations[3].endLineStyle, .closedArrow)
        XCTAssertEqual(
            annotations[4].stampName?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            StampPreset.approved.pdfName
        )
        XCTAssertEqual(AnnotationIdentifier(annotation: annotations[4]), stampID)
        XCTAssertTrue(annotations.allSatisfy(\.shouldPrint))
    }

    func testOwnedAnnotationMoveResizeAndUndoClampToPage() throws {
        let editor = try makeEditor(pages: ["Transform this shape"])
        let identifier = try editor.addShapeAnnotation(
            kind: .rectangle,
            placement: ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 100, y: 100),
                endPoint: CGPoint(x: 220, y: 180)
            ),
            color: .red,
            lineWidth: .standard
        )
        let initialBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)

        try editor.moveAnnotation(
            pageIndex: 0,
            identifier: identifier,
            by: CGSize(width: 1_000, height: 1_000)
        )
        let pageBounds = try XCTUnwrap(editor.document.page(at: 0)?.bounds(for: .cropBox))
        let movedBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)
        XCTAssertEqual(movedBounds.maxX, pageBounds.maxX, accuracy: 0.5)
        XCTAssertEqual(movedBounds.maxY, pageBounds.maxY, accuracy: 0.5)

        try editor.resizeAnnotation(
            pageIndex: 0,
            identifier: identifier,
            scale: 0.5
        )
        let resizedBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)
        XCTAssertEqual(resizedBounds.width, movedBounds.width * 0.5, accuracy: 0.5)
        XCTAssertEqual(resizedBounds.height, movedBounds.height * 0.5, accuracy: 0.5)

        try editor.undo()
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.first?.bounds, movedBounds)
        try editor.undo()
        XCTAssertEqual(editor.document.page(at: 0)?.annotations.first?.bounds, initialBounds)
    }

    func testVisualSignatureRotationPersistsAndIsUndoable() throws {
        let editor = try makeEditor(pages: ["Rotate this visual signature"])
        let identifier = try editor.addVisualSignature(
            pageIndex: 0,
            point: CGPoint(x: 300, y: 300),
            imageData: try makeSignatureImageData(),
            size: .medium
        )
        let initialBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)

        try editor.rotateVisualSignature(
            pageIndex: 0,
            identifier: identifier,
            clockwise: true
        )

        let rotated = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first)
        XCTAssertEqual(VisualSignatureAnnotation.rotationQuarterTurns(from: rotated), 1)
        XCTAssertEqual(rotated.bounds.width, initialBounds.height, accuracy: 0.5)
        XCTAssertEqual(rotated.bounds.height, initialBounds.width, accuracy: 0.5)

        let reopened = try XCTUnwrap(PDFDocument(data: try XCTUnwrap(editor.document.dataRepresentation())))
        XCTAssertEqual(
            VisualSignatureAnnotation.rotationQuarterTurns(
                from: try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
            ),
            1
        )
        XCTAssertNotNil(
            try XCTUnwrap(editor.document.dataRepresentation()).range(of: Data("/Image".utf8))
        )
        try editor.undo()
        XCTAssertEqual(
            VisualSignatureAnnotation.rotationQuarterTurns(
                from: try XCTUnwrap(editor.document.page(at: 0)?.annotations.first)
            ),
            0
        )
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

    private func redPixelCount(on page: PDFPage) -> Int {
        let bounds = page.bounds(for: .mediaBox)
        let image = NSImage(size: bounds.size)
        image.lockFocus()
        NSColor.white.setFill()
        bounds.fill()
        if let context = NSGraphicsContext.current?.cgContext {
            page.draw(with: .mediaBox, to: context)
            for annotation in page.annotations where annotation.shouldDisplay {
                annotation.draw(with: .mediaBox, in: context)
            }
        }
        image.unlockFocus()
        guard
            let data = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: data)
        else {
            return 0
        }

        var count = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                    continue
                }
                if color.redComponent > 0.75,
                   color.greenComponent < 0.35,
                   color.blueComponent < 0.35 {
                    count += 1
                }
            }
        }
        return count
    }

    private func makeSignatureImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 240, height: 80))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSColor.systemRed.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 8
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: 12, y: 16))
        path.curve(
            to: NSPoint(x: 225, y: 58),
            controlPoint1: NSPoint(x: 70, y: 76),
            controlPoint2: NSPoint(x: 150, y: 5)
        )
        path.stroke()
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw TestError.couldNotCreateSignature
        }
        return data
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestError: Error {
        case couldNotOpenFixture
        case couldNotCreateSignature
    }
}

private final class SignatureAppearanceSpikeAnnotation: PDFAnnotation {
    private let signatureImage: NSImage

    init(bounds: CGRect, image: NSImage) {
        self.signatureImage = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        super.draw(with: box, in: context)
        guard let image = signatureImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        context.saveGState()
        context.draw(image, in: bounds)
        context.restoreGState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
