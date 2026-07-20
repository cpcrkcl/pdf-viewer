import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PrintingTests: XCTestCase {
    nonisolated(unsafe) private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testPrintingWithoutSessionIsUnavailableAndDoesNothing() {
        let appState = makeAppState()

        XCTAssertFalse(appState.canPrintActiveDocument)
        appState.printWorkingDocument()

        XCTAssertEqual(appState.readerState.printRequestSequence, 0)
        XCTAssertNil(appState.presentedError)
    }

    func testUnencryptedDocumentAllowsPrintingAndRequestsOnePrintPerAction() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("source.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)

        XCTAssertTrue(appState.canPrintActiveDocument)
        appState.printWorkingDocument()
        appState.printWorkingDocument()

        XCTAssertEqual(appState.readerState.printRequestSequence, 2)
        XCTAssertNil(appState.presentedError)
        XCTAssertFalse(editor.isDirty)
        XCTAssertFalse(editor.hasUnexportedChanges)
    }

    func testUserUnlockWithoutPrintingPermissionBlocksPrintingRecoverably() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("restricted.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: protectedURL,
            permissions: [.allowsCommenting]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        XCTAssertNotNil(appState.session)

        XCTAssertFalse(appState.canPrintActiveDocument)
        appState.printWorkingDocument()

        XCTAssertEqual(appState.readerState.printRequestSequence, 0)
        XCTAssertEqual(appState.presentedError?.title, "Printing Not Permitted")
        XCTAssertFalse(appState.session?.editor.isDirty == true)
    }

    func testUserUnlockWithLowQualityPrintingPermissionAllowsPrinting() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("printable.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: protectedURL,
            permissions: [.allowsLowQualityPrinting]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        XCTAssertNotNil(appState.session)

        XCTAssertTrue(appState.canPrintActiveDocument)
        appState.printWorkingDocument()

        XCTAssertEqual(appState.readerState.printRequestSequence, 1)
        XCTAssertNil(appState.presentedError)
    }

    func testOwnerUnlockAlwaysAllowsPrinting() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("owner.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: protectedURL,
            permissions: [.allowsCommenting]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-owner")
        XCTAssertNotNil(appState.session)

        XCTAssertTrue(appState.canPrintActiveDocument)
        appState.printWorkingDocument()

        XCTAssertEqual(appState.readerState.printRequestSequence, 1)
        XCTAssertNil(appState.presentedError)
    }

    func testPrintRequestsAreTemporaryPresentationStateAcrossDocuments() throws {
        let firstURL = temporaryDirectory.appendingPathComponent("first.pdf")
        let secondURL = temporaryDirectory.appendingPathComponent("second.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["First"], to: firstURL)
        try FixturePDFBuilder.writeTextPDF(pages: ["Second"], to: secondURL)
        let appState = makeAppState()
        appState.requestOpenDocument(at: firstURL)
        appState.printWorkingDocument()

        appState.requestOpenDocument(at: secondURL)

        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertFalse(editor.isDirty)
        appState.printWorkingDocument()
        XCTAssertEqual(appState.readerState.printRequestSequence, 2)
        XCTAssertFalse(editor.isDirty)
    }

    private func makeAppState() -> AppState {
        AppState(
            documentLoader: DocumentLoader(
                securityScopedResources: SecurityScopedResourceAccessProvider(
                    startAccessing: { _ in false },
                    stopAccessing: { _ in }
                )
            ),
            recentDocuments: RecentDocumentsStore(
                persistence: PrintingTestsRecentDocumentsPersistence(),
                bookmarkCoder: PrintingTestsBookmarkCoder()
            ),
            bookmarkStore: PageBookmarkStore(
                defaults: UserDefaults(
                    suiteName: "PrintingTests.\(UUID().uuidString)"
                )!
            ),
            pdfExporter: PrintingTestsExporter(),
            loadDocumentsAsynchronously: false
        )
    }
}

@MainActor
private struct PrintingTestsExporter: PDFExporting {
    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL
    ) throws -> PDFExportResult {
        PDFExportResult(url: destinationURL, pageCount: document.pageCount)
    }
}

@MainActor
private final class PrintingTestsRecentDocumentsPersistence: RecentDocumentsPersisting {
    private var documents: [RecentDocument] = []

    func load() throws -> [RecentDocument] {
        documents
    }

    func save(_ documents: [RecentDocument]) throws {
        self.documents = documents
    }
}

@MainActor
private struct PrintingTestsBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard
            let value = String(data: bookmark, encoding: .utf8),
            let url = URL(string: value)
        else {
            throw PrintingTestsError.invalidBookmark
        }
        return url
    }
}

private enum PrintingTestsError: Error {
    case invalidBookmark
}
