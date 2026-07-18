import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFExporterTests: XCTestCase {
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

        let result = try PDFExporter(stagingDirectory: stagingDirectory).export(
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

        _ = try PDFExporter().export(
            document: editor.document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .reuseSessionPassword,
            sessionPassword: "fixture-user",
            accessPermissions: unlockedSource.accessPermissions
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

        _ = try PDFExporter().export(
            document: extracted,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .reuseSessionPassword,
            sessionPassword: "fixture-user",
            accessPermissions: unlockedSource.accessPermissions
        )

        let output = try XCTUnwrap(PDFDocument(url: destinationURL))
        XCTAssertTrue(output.isEncrypted)
        XCTAssertTrue(output.isLocked)
        XCTAssertTrue(output.unlock(withPassword: "fixture-user"))
        XCTAssertEqual(output.pageCount, 1)
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
                accessPermissions: document.accessPermissions
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

    private enum TestError: Error {
        case couldNotOpenFixture
    }
}
