import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFExporterTests: XCTestCase {
    func testValidationTextAcceptsEquivalentPDFKitPageSeparators() {
        XCTAssertEqual(PDFExporter.validationText(nil), PDFExporter.validationText("\n"))
        XCTAssertEqual(
            PDFExporter.validationText("\nAlpha\r\nBravo\r\n"),
            PDFExporter.validationText("Alpha\nBravo")
        )
    }

    func testValidationTextStillDetectsChangedContentsAndInternalWhitespace() {
        XCTAssertNotEqual(PDFExporter.validationText("Alpha"), PDFExporter.validationText("Alph"))
        XCTAssertNotEqual(PDFExporter.validationText("A B"), PDFExporter.validationText("AB"))
        XCTAssertNotEqual(PDFExporter.validationText("A\nB"), PDFExporter.validationText("A B"))
    }

    func testExportCreatesAValidatedDistinctPDFAndLeavesSourceBytesUnchanged() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("exported.pdf")
        let stagingDirectory = temporaryDirectory.appendingPathComponent(
            "app-owned-staging",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: stagingDirectory,
            withIntermediateDirectories: true
        )
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo", "Charlie"], to: sourceURL)
        let originalSourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))
        try editor.rotatePages(at: IndexSet(integer: 1), clockwise: true)
        try editor.movePages(at: IndexSet(integer: 2), to: 0)

        let result = try PDFExporter(stagingDirectory: stagingDirectory, validationFailure: { XCTFail($0) }).export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL
        )

        XCTAssertEqual(result.url, destinationURL.standardizedFileURL)
        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceData)

        let exportedDocument = try openDocument(at: destinationURL)
        XCTAssertEqual(pageTexts(in: exportedDocument), ["Charlie", "Alpha", "Bravo"])
        XCTAssertEqual(exportedDocument.page(at: 2)?.rotation, 90)
        XCTAssertFalse(
            try FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)
                .contains { $0.hasPrefix(".pdfviewer-export-") }
        )
    }

    func testExportRejectsTheOriginalPDFAsDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha"], to: sourceURL)
        let originalSourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))

        XCTAssertThrowsError(
            try PDFExporter().export(
                document: editor.document,
                sourceURL: sourceURL,
                to: sourceURL
            )
        ) { error in
            XCTAssertEqual(error as? PDFExportError, .sourceAndDestinationMatch)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalSourceData)
    }

    func testExportRejectsAHardLinkToTheOriginalPDF() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let hardLinkURL = temporaryDirectory.appendingPathComponent("hard-link.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha"], to: sourceURL)
        try FileManager.default.linkItem(at: sourceURL, to: hardLinkURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let document = try openDocument(at: sourceURL)

        XCTAssertThrowsError(
            try PDFExporter().export(
                document: document,
                sourceURL: sourceURL,
                to: hardLinkURL
            )
        ) { error in
            XCTAssertEqual(error as? PDFExportError, .sourceAndDestinationMatch)
        }
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportCanReplaceAnExplicitlyChosenNonSourceOutput() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("chosen-output.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        try FixturePDFBuilder.writeTextPDF(pages: ["Old output"], to: destinationURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))

        _ = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL
        )

        XCTAssertEqual(pageTexts(in: try openDocument(at: destinationURL)), ["Alpha", "Bravo"])
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testExportReopensOwnedAnnotationsWithoutChangingSourceBytes() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("annotated.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha"], to: sourceURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))
        let identifier = try editor.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 160, y: 180),
            contents: "Persistent note",
            color: .yellow
        )

        _ = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL
        )

        let reopened = try openDocument(at: destinationURL)
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first {
            AnnotationIdentifier(annotation: $0) == identifier
        })
        XCTAssertEqual(annotation.type, PDFAnnotationSubtype.text.pdfTypeName)
        XCTAssertEqual(annotation.contents, "Persistent note")
        XCTAssertEqual(annotation.userName, "PDFViewer")
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testEncryptedExportRemainsLockedAndReopensOnlyWithSessionPassword() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("encrypted-output.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: sourceURL,
            permissions: [.allowsDocumentAssembly, .allowsCommenting, .allowsContentCopying]
        )
        let sourceData = try Data(contentsOf: sourceURL)
        let unlockedSource = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(unlockedSource.unlock(withPassword: "fixture-user"))
        let editor = try PDFDocumentEditor(document: unlockedSource)
        try editor.rotatePages(at: IndexSet(integer: 0), clockwise: true)
        let identifier = try editor.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 140, y: 160),
            contents: "Encrypted note",
            color: .yellow
        )

        _ = try PDFExporter(validationFailure: { XCTFail($0) }).export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .reuseSessionPassword,
            sessionPassword: "fixture-user",
            accessPermissions: unlockedSource.accessPermissions,
            compression: .standard
        )

        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
        let output = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(output.isEncrypted)
        XCTAssertTrue(output.isLocked)
        XCTAssertFalse(output.unlock(withPassword: "incorrect"))
        XCTAssertTrue(output.unlock(withPassword: "fixture-user"))
        XCTAssertEqual(output.pageCount, 1)
        XCTAssertEqual(output.page(at: 0)?.rotation, 90)
        XCTAssertNotNil(output.page(at: 0)?.annotations.first {
            AnnotationIdentifier(annotation: $0) == identifier && $0.contents == "Encrypted note"
        })
    }

    func testEncryptedExtractionUsesTheSameOutputProtection() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("encrypted-extract.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: sourceURL)
        let unlockedSource = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(unlockedSource.unlock(withPassword: "fixture-user"))
        let editor = try PDFDocumentEditor(document: unlockedSource)
        let extracted = try editor.extractPages(at: IndexSet(integer: 0))

        _ = try PDFExporter(validationFailure: { XCTFail($0) }).export(
            document: extracted,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .reuseSessionPassword,
            sessionPassword: "fixture-user",
            accessPermissions: unlockedSource.accessPermissions,
            compression: .standard
        )

        let output = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(output.isEncrypted)
        XCTAssertTrue(output.isLocked)
        XCTAssertTrue(output.unlock(withPassword: "fixture-user"))
        XCTAssertEqual(output.pageCount, 1)
    }

    func testCompressionProfilesShrinkImageHeavyOutputWithoutChangingPages() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("image-heavy.pdf")
        try FixturePDFBuilder.writeLargeImagePDF(to: sourceURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))

        var outputSizes: [PDFExportCompression: Int] = [:]
        for compression in PDFExportCompression.allCases {
            let destinationURL = temporaryDirectory.appendingPathComponent(
                "output-\(compression.rawValue).pdf"
            )
            let result = try PDFExporter().export(
                document: editor.document,
                sourceURL: sourceURL,
                to: destinationURL,
                protection: .none,
                sessionPassword: nil,
                accessPermissions: editor.document.accessPermissions,
                compression: compression
            )

            let writtenData = try Data(contentsOf: destinationURL)
            XCTAssertEqual(result.fileSizeInBytes, writtenData.count)
            XCTAssertEqual(result.pageCount, 1)
            XCTAssertEqual(try openDocument(at: destinationURL).pageCount, 1)
            outputSizes[compression] = writtenData.count
        }

        let standardSize = try XCTUnwrap(outputSizes[.standard])
        let reducedSize = try XCTUnwrap(outputSizes[.reducedSize])
        let compactSize = try XCTUnwrap(outputSizes[.compact])
        XCTAssertLessThan(reducedSize, standardSize)
        XCTAssertLessThan(compactSize, standardSize)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testCompactCompressionPreservesTextRotationsAndAnnotations() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("compact.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))
        try editor.rotatePages(at: IndexSet(integer: 1), clockwise: true)
        let identifier = try editor.addTextNote(
            pageIndex: 0,
            point: CGPoint(x: 150, y: 170),
            contents: "Compressed note",
            color: .blue
        )

        _ = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .none,
            sessionPassword: nil,
            accessPermissions: editor.document.accessPermissions,
            compression: .compact
        )

        let reopened = try openDocument(at: destinationURL)
        XCTAssertEqual(pageTexts(in: reopened), ["Alpha", "Bravo"])
        XCTAssertEqual(reopened.page(at: 1)?.rotation, 90)
        XCTAssertNotNil(reopened.page(at: 0)?.annotations.first {
            AnnotationIdentifier(annotation: $0) == identifier && $0.contents == "Compressed note"
        })
    }

    func testEncryptedExportComposesWithCompression() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("encrypted-reduced.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: sourceURL)
        let unlockedSource = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertTrue(unlockedSource.unlock(withPassword: "fixture-user"))
        let editor = try PDFDocumentEditor(document: unlockedSource)

        let result = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .reuseSessionPassword,
            sessionPassword: "fixture-user",
            accessPermissions: unlockedSource.accessPermissions,
            compression: .reducedSize
        )

        XCTAssertGreaterThan(result.fileSizeInBytes, 0)
        let output = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(output.isEncrypted)
        XCTAssertTrue(output.isLocked)
        XCTAssertFalse(output.unlock(withPassword: "incorrect"))
        XCTAssertTrue(output.unlock(withPassword: "fixture-user"))
        XCTAssertEqual(output.pageCount, 1)
    }

    func testVisualSignatureOwnershipAndImageSurviveValidatedExport() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("signed-copy.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Signature export"], to: sourceURL)
        let sourceData = try Data(contentsOf: sourceURL)
        let editor = try PDFDocumentEditor(document: try openDocument(at: sourceURL))
        let imageData = try makeSignatureImageData()
        let identifier = try editor.addVisualSignature(
            pageIndex: 0,
            point: CGPoint(x: 300, y: 300),
            imageData: imageData,
            size: .medium
        )

        _ = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .none,
            sessionPassword: nil,
            accessPermissions: editor.document.accessPermissions,
            compression: .reducedSize
        )

        let reopened = try openDocument(at: destinationURL)
        let annotation = try XCTUnwrap(reopened.page(at: 0)?.annotations.first)
        XCTAssertEqual(annotation.type, PDFAnnotationSubtype.stamp.pdfTypeName)
        XCTAssertEqual(AnnotationIdentifier(annotation: annotation), identifier)
        XCTAssertEqual(VisualSignatureAnnotation.imageData(from: annotation), imageData)
        XCTAssertEqual(try Data(contentsOf: sourceURL), sourceData)
    }

    func testMissingSessionPasswordDoesNotReplaceExistingDestination() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("existing.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha"], to: sourceURL)
        let destinationData = Data("existing destination".utf8)
        try destinationData.write(to: destinationURL)
        let document = try openDocument(at: sourceURL)

        XCTAssertThrowsError(
            try PDFExporter().export(
                document: document,
                sourceURL: sourceURL,
                to: destinationURL,
                protection: .reuseSessionPassword,
                sessionPassword: nil,
                accessPermissions: document.accessPermissions,
                compression: .standard
            )
        ) { error in
            XCTAssertEqual(error as? PDFExportError, .missingSessionPassword)
        }
        XCTAssertEqual(try Data(contentsOf: destinationURL), destinationData)
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

    private func makeSignatureImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 180, height: 60))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill(using: .copy)
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 6
        path.move(to: NSPoint(x: 8, y: 12))
        path.curve(
            to: NSPoint(x: 172, y: 48),
            controlPoint1: NSPoint(x: 55, y: 58),
            controlPoint2: NSPoint(x: 120, y: 5)
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

    private enum TestError: Error {
        case couldNotOpenFixture
        case couldNotCreateSignature
    }
}
