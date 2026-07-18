import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class AppStateLifecycleTests: XCTestCase {
    private var temporaryDirectory: URL!

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

    func testCleanCloseDoesNotPrompt() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)

        appState.requestCloseDocument()

        XCTAssertNil(appState.session)
        XCTAssertNil(appState.pendingUnsavedChanges)

        appState.requestOpenDocument(at: sourceURL)
        XCTAssertTrue(appState.requestWindowClose())
        XCTAssertNil(appState.pendingUnsavedChanges)
    }

    func testEditedDocumentQueuesCloseReplacementAndQuit() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let replacementURL = try writePDF(named: "replacement.pdf", pages: ["Replacement"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)

        appState.requestCloseDocument()
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .closeDocument)

        appState.resolveUnsavedChanges(.cancel)
        appState.requestOpenDocument(at: replacementURL)
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .openURL(replacementURL))

        appState.resolveUnsavedChanges(.cancel)
        XCTAssertFalse(appState.requestApplicationTermination())
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .terminateApplication)
    }

    func testCancelRetainsDocumentAndDiscardPerformsQueuedClose() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)

        appState.requestCloseDocument()
        appState.resolveUnsavedChanges(.cancel)

        XCTAssertEqual(appState.session?.sourceURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(appState.session?.editor.hasUnexportedChanges == true)

        appState.requestCloseDocument()
        appState.resolveUnsavedChanges(.discard)

        XCTAssertNil(appState.session)
    }

    func testQuitCancelAndDiscardSendDelayedTerminationReplies() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let appState = makeAppState()
        var replies: [Bool] = []
        appState.terminationReplyHandler = { replies.append($0) }
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)

        XCTAssertFalse(appState.requestApplicationTermination())
        appState.resolveUnsavedChanges(.cancel)
        XCTAssertEqual(replies, [false])
        XCTAssertNotNil(appState.session)

        XCTAssertFalse(appState.requestApplicationTermination())
        appState.resolveUnsavedChanges(.discard)
        XCTAssertEqual(replies, [false, true])
    }

    func testValidatedWorkingExportProtectsRevisionAndContinues() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let destinationURL = temporaryDirectory.appendingPathComponent("exported.pdf")
        let exporter = RecordingExporter()
        let appState = makeAppState(exporter: exporter)
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)
        let editor = try XCTUnwrap(appState.session?.editor)

        appState.performExport(
            document: editor.document,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            kind: .workingCopy,
            continuation: .closeDocument
        )

        XCTAssertNil(appState.session)
        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.isDirty)
        XCTAssertEqual(appState.exportReceipt?.url, destinationURL)
        XCTAssertEqual(appState.exportReceipt?.kind, .workingCopy)
    }

    func testFailedExportPreservesDocumentAndCancelsQueuedAction() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let destinationURL = temporaryDirectory.appendingPathComponent("failed.pdf")
        let appState = makeAppState(exporter: FailingExporter())
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)
        let editor = try XCTUnwrap(appState.session?.editor)

        appState.performExport(
            document: editor.document,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            kind: .workingCopy,
            continuation: .closeDocument
        )

        XCTAssertNotNil(appState.session)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertNil(appState.exportReceipt)
        XCTAssertNotNil(appState.presentedError)
    }

    func testExtractionDoesNotSuppressLaterCloseWarning() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let destinationURL = temporaryDirectory.appendingPathComponent("extracted.pdf")
        let appState = makeAppState(exporter: RecordingExporter())
        appState.requestOpenDocument(at: sourceURL)
        appState.rotateSelectedPages(clockwise: true)
        let editor = try XCTUnwrap(appState.session?.editor)
        let extracted = try editor.extractPages(at: IndexSet(integer: 0))

        appState.performExport(
            document: extracted,
            sourceURL: sourceURL,
            destinationURL: destinationURL,
            kind: .extractedPages
        )
        appState.requestCloseDocument()

        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .closeDocument)
        XCTAssertEqual(appState.exportReceipt?.kind, .extractedPages)
    }

    func testInvalidDropsAndFailedReplacementPreserveCurrentSession() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let missingURL = temporaryDirectory.appendingPathComponent("missing.pdf")
        let textURL = temporaryDirectory.appendingPathComponent("notes.txt")
        let directoryURL = temporaryDirectory.appendingPathComponent("folder.pdf", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)

        XCTAssertFalse(appState.handleDroppedURLs([]))
        XCTAssertEqual(appState.session?.sourceURL, sourceURL.standardizedFileURL)
        XCTAssertFalse(appState.handleDroppedURLs([sourceURL, textURL]))
        XCTAssertFalse(appState.handleDroppedURLs([textURL]))
        XCTAssertFalse(appState.handleDroppedURLs([directoryURL]))
        XCTAssertEqual(appState.session?.sourceURL, sourceURL.standardizedFileURL)

        appState.rotateSelectedPages(clockwise: true)
        appState.requestOpenDocument(at: missingURL)
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .openURL(missingURL))
        appState.resolveUnsavedChanges(.discard)

        XCTAssertEqual(appState.session?.sourceURL, sourceURL.standardizedFileURL)
        XCTAssertTrue(appState.session?.editor.hasUnexportedChanges == true)
        XCTAssertNotNil(appState.presentedError)
    }

    func testMultiPageDragDestinationPreservesOrderSelectionAndOneUndoStep() throws {
        let sourceURL = try writePDF(
            named: "source.pdf",
            pages: ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.selectPageIndexes([1, 2])

        appState.moveSelectedPages(to: 5)

        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Delta", "Echo", "Bravo", "Charlie"])
        XCTAssertEqual(appState.readerState.selectedPageIndexes, [3, 4])
        XCTAssertTrue(editor.canUndo)

        appState.undoPageOperation()
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Bravo", "Charlie", "Delta", "Echo"])
        XCTAssertFalse(editor.canUndo)
    }

    func testDropInsideSelectedRangeIsANoOp() throws {
        let sourceURL = try writePDF(
            named: "source.pdf",
            pages: ["Alpha", "Bravo", "Charlie", "Delta", "Echo"]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.selectPageIndexes([1, 3])

        appState.moveSelectedPages(to: 2)

        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertEqual(pageTexts(in: editor.document), ["Alpha", "Bravo", "Charlie", "Delta", "Echo"])
        XCTAssertEqual(appState.readerState.selectedPageIndexes, [1, 3])
        XCTAssertFalse(editor.canUndo)
    }

    func testAnnotationMutationQueuesCloseAndUndoRestoresSafeRevision() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.toggleAnnotationMode()
        appState.updateTextMarkupRegions([
            TextMarkupRegion(
                pageIndex: 0,
                bounds: CGRect(x: 60, y: 650, width: 120, height: 28)
            ),
        ])

        appState.selectAnnotationTool(.highlight)

        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertEqual(
            editor.document.page(at: 0)?.annotations.filter {
                $0.type == PDFAnnotationSubtype.highlight.pdfTypeName
            }.count,
            1
        )

        appState.requestCloseDocument()
        XCTAssertEqual(appState.pendingUnsavedChanges?.action, .closeDocument)
        appState.resolveUnsavedChanges(.cancel)
        appState.undoPageOperation()

        XCTAssertFalse(editor.hasUnexportedChanges)
        XCTAssertFalse(editor.canUndo)
        XCTAssertTrue(appState.annotationState.textMarkupRegions.isEmpty)
    }

    func testTextMarkupToolCanBeChosenBeforeSelectingText() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha", "Bravo"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.toggleAnnotationMode()

        appState.selectAnnotationTool(.strikethrough)
        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertFalse(editor.canUndo)

        appState.updateTextMarkupRegions([
            TextMarkupRegion(
                pageIndex: 0,
                bounds: CGRect(x: 60, y: 650, width: 120, height: 28)
            ),
        ])
        appState.commitSelectedTextMarkup()

        XCTAssertEqual(
            editor.document.page(at: 0)?.annotations.filter {
                $0.type == PDFAnnotationSubtype.strikeOut.pdfTypeName
            }.count,
            1
        )
        XCTAssertTrue(editor.canUndo)
        XCTAssertEqual(appState.annotationState.selectedTool, .strikethrough)
        XCTAssertFalse(appState.annotationState.hasTextSelection)
    }

    func testTextNoteCancellationEditingDeletionAndThirdPartyReadOnlySelection() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.toggleAnnotationMode()

        appState.requestTextNote(at: AnnotationPlacement(pageIndex: 0, point: CGPoint(x: 140, y: 140)))
        appState.cancelPendingTextNote()
        let editor = try XCTUnwrap(appState.session?.editor)
        XCTAssertFalse(editor.hasUnexportedChanges)

        appState.requestTextNote(at: AnnotationPlacement(pageIndex: 0, point: CGPoint(x: 140, y: 140)))
        appState.submitPendingTextNote(contents: "   ")
        XCTAssertFalse(editor.hasUnexportedChanges)

        appState.requestTextNote(at: AnnotationPlacement(pageIndex: 0, point: CGPoint(x: 140, y: 140)))
        appState.submitPendingTextNote(contents: "Review this page")
        let selection = try XCTUnwrap(appState.annotationState.selectedAnnotation)
        let identifier = try XCTUnwrap(selection.identifier)
        XCTAssertEqual(editor.textNoteContents(pageIndex: 0, identifier: identifier), "Review this page")

        appState.requestEditSelectedTextNote()
        XCTAssertEqual(appState.pendingTextNote?.initialText, "Review this page")
        appState.submitPendingTextNote(contents: "Updated note")
        XCTAssertEqual(editor.textNoteContents(pageIndex: 0, identifier: identifier), "Updated note")

        appState.selectAnnotation(
            SelectedAnnotation(pageIndex: 0, identifier: nil, kind: .textNote)
        )
        XCTAssertEqual(appState.presentedError?.title, "Read-Only Annotation")
        let historyCountBeforeReadOnlyDelete = editor.canUndo
        appState.deleteSelectedAnnotation()
        XCTAssertEqual(editor.canUndo, historyCountBeforeReadOnlyDelete)

        appState.selectAnnotation(
            SelectedAnnotation(pageIndex: 0, identifier: identifier, kind: .textNote)
        )
        appState.deleteSelectedAnnotation()
        XCTAssertNil(editor.textNoteContents(pageIndex: 0, identifier: identifier))
        appState.undoPageOperation()
        XCTAssertEqual(editor.textNoteContents(pageIndex: 0, identifier: identifier), "Updated note")
    }

    func testPasswordRetryAndCancelPreserveCurrentReplacementSession() throws {
        let currentURL = try writePDF(named: "current.pdf", pages: ["Current"])
        let protectedURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: protectedURL)
        let appState = makeAppState()
        appState.requestOpenDocument(at: currentURL)

        appState.requestOpenDocument(at: protectedURL)

        XCTAssertEqual(appState.session?.sourceURL, currentURL.standardizedFileURL)
        XCTAssertEqual(appState.pendingDocumentUnlock?.handle.sourceURL, protectedURL.standardizedFileURL)
        appState.submitDocumentPassword("wrong")
        XCTAssertTrue(appState.pendingDocumentUnlock?.hasIncorrectPassword == true)
        XCTAssertEqual(appState.session?.sourceURL, currentURL.standardizedFileURL)

        appState.cancelDocumentUnlock()
        XCTAssertNil(appState.pendingDocumentUnlock)
        XCTAssertEqual(appState.session?.sourceURL, currentURL.standardizedFileURL)

        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        XCTAssertEqual(appState.session?.sourceURL, protectedURL.standardizedFileURL)
        XCTAssertTrue(appState.session?.securityContext.isEncrypted == true)
    }

    func testClosingEncryptedSessionClearsInMemoryPassword() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: protectedURL)
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        let encryptedSession = try XCTUnwrap(appState.session)

        XCTAssertEqual(encryptedSession.sessionPassword, "fixture-user")
        appState.requestCloseDocument()

        XCTAssertNil(appState.session)
        XCTAssertNil(encryptedSession.sessionPassword)
    }

    func testUserPermissionsBlockAssemblyAndAllowCommentingOnlyWhenGranted() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("restricted.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: protectedURL,
            permissions: [.allowsCommenting]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        let editor = try XCTUnwrap(appState.session?.editor)

        XCTAssertTrue(appState.canCommentOnActiveDocument)
        XCTAssertFalse(appState.canAssembleActiveDocument)
        XCTAssertFalse(appState.canExtractFromActiveDocument)

        appState.rotateSelectedPages(clockwise: true)
        XCTAssertEqual(editor.document.page(at: 0)?.rotation, 0)
        XCTAssertEqual(appState.presentedError?.title, "Page Changes Not Permitted")

        appState.toggleAnnotationMode()
        appState.requestTextNote(at: AnnotationPlacement(pageIndex: 0, point: CGPoint(x: 100, y: 100)))
        appState.submitPendingTextNote(contents: "Allowed comment")
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertEqual(
            editor.document.page(at: 0)?.annotations.filter {
                $0.type == PDFAnnotationSubtype.text.pdfTypeName
            }.count,
            1
        )

        appState.extractSelectedPages()
        XCTAssertEqual(appState.presentedError?.title, "Extraction Not Permitted")
    }

    func testEncryptedExportRequestAlwaysUsesSessionProtection() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        let destinationURL = temporaryDirectory.appendingPathComponent("output.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: protectedURL)
        let exporter = RecordingExporter()
        let appState = makeAppState(exporter: exporter)
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")
        let session = try XCTUnwrap(appState.session)

        appState.performExport(
            document: session.editor.document,
            sourceURL: session.sourceURL,
            destinationURL: destinationURL,
            kind: .workingCopy
        )

        XCTAssertEqual(exporter.lastProtection, .reuseSessionPassword)
        XCTAssertEqual(exporter.lastSessionPassword, "fixture-user")
        XCTAssertEqual(exporter.lastAccessPermissions, session.securityContext.accessPermissions)
        XCTAssertFalse(session.editor.hasUnexportedChanges)
    }

    func testBookmarkTargetsSurviveReorderDeleteAndUndoWithoutDirtyingOnAdd() throws {
        let sourceURL = try writePDF(
            named: "bookmarks.pdf",
            pages: ["Alpha", "Bravo", "Charlie"]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.navigateToPage(number: 2)
        appState.addBookmarkForCurrentPage()

        let editor = try XCTUnwrap(appState.session?.editor)
        let bookmark = try XCTUnwrap(appState.resolvedBookmarks.first?.bookmark)
        XCTAssertFalse(editor.isDirty)
        XCTAssertEqual(appState.resolvedBookmarks.first?.pageIndex, 1)

        appState.navigateToPage(number: 1)
        appState.navigateToBookmark(bookmark)
        XCTAssertEqual(appState.readerState.selectedPageIndex, 1)

        appState.selectPageIndexes([1])
        appState.moveSelectedPages(to: 3)
        XCTAssertEqual(appState.resolvedBookmarks.first?.pageIndex, 2)

        appState.selectPageIndexes([2])
        appState.requestDeleteSelectedPages()
        appState.confirmPendingPageDeletion()
        XCTAssertNil(appState.resolvedBookmarks.first?.pageIndex)

        appState.undoPageOperation()
        XCTAssertEqual(appState.resolvedBookmarks.first?.pageIndex, 2)
        appState.deleteBookmark(bookmark)
        XCTAssertTrue(appState.resolvedBookmarks.isEmpty)
    }

    func testNavigationHistoryBackForwardAndBranching() throws {
        let sourceURL = try writePDF(
            named: "history.pdf",
            pages: ["One", "Two", "Three", "Four"]
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)

        appState.navigateToPage(number: 4)
        appState.navigateToPage(number: 2)
        XCTAssertTrue(appState.canNavigateBack)
        XCTAssertFalse(appState.canNavigateForward)

        appState.navigateBack()
        XCTAssertEqual(appState.readerState.selectedPageIndex, 3)
        XCTAssertTrue(appState.canNavigateForward)

        appState.navigateToPage(number: 3)
        XCTAssertEqual(appState.readerState.selectedPageIndex, 2)
        XCTAssertFalse(appState.canNavigateForward)
    }

    func testImportedWorkingPageCannotReceivePersistentBookmark() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Source"])
        let importedURL = try writePDF(named: "imported.pdf", pages: ["Imported"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)
        let importedDocument = try XCTUnwrap(PDFDocument(url: importedURL))
        let importedFingerprint = DocumentFingerprint.sha256(of: try Data(contentsOf: importedURL))
        try editor.insertPages(
            from: importedDocument,
            sourceFingerprint: importedFingerprint,
            at: 1
        )
        appState.readerState.synchronize(
            pageCount: editor.document.pageCount,
            preferredPageIndex: 1,
            isDirty: editor.isDirty
        )
        _ = appState.readerState.selectPage(at: 1)

        appState.addBookmarkForCurrentPage()

        XCTAssertTrue(appState.resolvedBookmarks.isEmpty)
        XCTAssertEqual(appState.presentedError?.title, "Bookmark After Export")
    }

    private func makeAppState(
        exporter: any PDFExporting = RecordingExporter(),
        bookmarkStore: PageBookmarkStore? = nil
    ) -> AppState {
        let effectiveBookmarkStore = bookmarkStore ?? PageBookmarkStore(
            defaults: UserDefaults(
                suiteName: "AppStateLifecycleTests.\(UUID().uuidString)"
            )!
        )
        return AppState(
            documentLoader: DocumentLoader(
                securityScopedResources: SecurityScopedResourceAccessProvider(
                    startAccessing: { _ in false },
                    stopAccessing: { _ in }
                )
            ),
            recentDocuments: RecentDocumentsStore(
                persistence: LifecycleRecentDocumentsPersistence(),
                bookmarkCoder: LifecycleBookmarkCoder()
            ),
            bookmarkStore: effectiveBookmarkStore,
            pdfExporter: exporter
        )
    }

    private func writePDF(named name: String, pages: [String]) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        return url
    }

    private func pageTexts(in document: PDFDocument) -> [String] {
        (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

@MainActor
private final class RecordingExporter: PDFExporting {
    private(set) var lastProtection: PDFOutputProtection?
    private(set) var lastSessionPassword: String?
    private(set) var lastAccessPermissions: PDFAccessPermissions?

    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL
    ) throws -> PDFExportResult {
        PDFExportResult(url: destinationURL, pageCount: document.pageCount)
    }

    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL,
        protection: PDFOutputProtection,
        sessionPassword: String?,
        accessPermissions: PDFAccessPermissions
    ) throws -> PDFExportResult {
        lastProtection = protection
        lastSessionPassword = sessionPassword
        lastAccessPermissions = accessPermissions
        return PDFExportResult(url: destinationURL, pageCount: document.pageCount)
    }
}

@MainActor
private struct FailingExporter: PDFExporting {
    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL
    ) throws -> PDFExportResult {
        throw PDFExportError.couldNotValidateTemporaryFile
    }
}

@MainActor
private final class LifecycleRecentDocumentsPersistence: RecentDocumentsPersisting {
    private var documents: [RecentDocument] = []

    func load() throws -> [RecentDocument] {
        documents
    }

    func save(_ documents: [RecentDocument]) throws {
        self.documents = documents
    }
}

@MainActor
private struct LifecycleBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard
            let value = String(data: bookmark, encoding: .utf8),
            let url = URL(string: value)
        else {
            throw LifecycleTestError.invalidBookmark
        }
        return url
    }
}

private enum LifecycleTestError: Error {
    case invalidBookmark
}
