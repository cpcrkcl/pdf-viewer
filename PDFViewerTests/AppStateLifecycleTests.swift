import AppKit
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class AppStateLifecycleTests: XCTestCase {
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

    func testProductionOpenPathPublishesLoadingThenActivatesDocument() async throws {
        let sourceURL = try writePDF(
            named: "async-source.pdf",
            pages: (0..<40).map { "Page \($0 + 1)" }
        )
        let appState = makeAppState(loadDocumentsAsynchronously: true)

        appState.requestOpenDocument(at: sourceURL)

        XCTAssertTrue(appState.isLoadingDocument)
        try await waitUntil { appState.session != nil || appState.presentedError != nil }
        XCTAssertNil(appState.presentedError)
        XCTAssertEqual(appState.session?.document.pageCount, 40)
        XCTAssertFalse(appState.isLoadingDocument)
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

    func testShapeStampMoveAndResizeFlowThroughAppState() throws {
        let sourceURL = try writePDF(named: "source.pdf", pages: ["Alpha"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.toggleAnnotationMode()
        appState.selectAnnotationTool(.rectangle)

        appState.addShapeAnnotation(
            ShapeAnnotationPlacement(
                pageIndex: 0,
                startPoint: CGPoint(x: 100, y: 100),
                endPoint: CGPoint(x: 220, y: 180)
            )
        )

        let editor = try XCTUnwrap(appState.session?.editor)
        let selection = try XCTUnwrap(appState.annotationState.selectedAnnotation)
        XCTAssertEqual(selection.kind, .rectangle)
        XCTAssertEqual(appState.annotationState.selectedTool, .select)
        let initialBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)

        appState.moveAnnotation(selection, by: CGSize(width: 20, height: 10))
        let movedBounds = try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds)
        XCTAssertEqual(movedBounds.minX, initialBounds.minX + 20, accuracy: 0.5)
        XCTAssertEqual(movedBounds.minY, initialBounds.minY + 10, accuracy: 0.5)

        appState.resizeSelectedAnnotation(scale: 1.25)
        XCTAssertGreaterThan(
            try XCTUnwrap(editor.document.page(at: 0)?.annotations.first?.bounds.width),
            movedBounds.width
        )

        appState.setStampPreset(.confidential)
        appState.selectAnnotationTool(.stamp)
        appState.requestBuiltInStamp(
            at: AnnotationPlacement(pageIndex: 0, point: CGPoint(x: 300, y: 300))
        )
        let stamp = try XCTUnwrap(editor.document.page(at: 0)?.annotations.last)
        XCTAssertEqual(stamp.type, PDFAnnotationSubtype.stamp.pdfTypeName)
        XCTAssertEqual(
            stamp.stampName?.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            StampPreset.confidential.pdfName
        )
        XCTAssertEqual(appState.annotationState.selectedAnnotation?.kind, .stamp)
        XCTAssertTrue(appState.readerState.isDocumentDirty)
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
        appState.selectAnnotationTool(.signature)
        XCTAssertTrue(appState.isSignatureLibraryPresented)
        appState.dismissVisualSignatureLibrary()
        XCTAssertEqual(appState.annotationState.selectedTool, .select)
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

    func testFormWorkflowFillsResetsAndTracksProtectedRevisions() throws {
        let sourceURL = try writeFormPDF(named: "form.pdf")
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)

        XCTAssertTrue(appState.canFillFormsInActiveDocument)
        appState.presentFormEditor()
        XCTAssertTrue(appState.isFormEditorPresented)

        appState.updateFormField(named: "fullName", value: .text("Ada"))
        appState.updateFormField(named: "consent", value: .checked(true))
        XCTAssertEqual(editor.formFields.first { $0.name == "fullName" }?.value, .text("Ada"))
        XCTAssertEqual(editor.formFields.first { $0.name == "consent" }?.value, .checked(true))
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertTrue(appState.readerState.isDocumentDirty)

        appState.resetFormFields()
        XCTAssertEqual(
            editor.formFields.first { $0.name == "fullName" }?.value,
            .text("Original")
        )
        XCTAssertEqual(
            editor.formFields.first { $0.name == "consent" }?.value,
            .checked(false)
        )
        XCTAssertTrue(editor.canUndo)

        appState.dismissFormEditor()
        XCTAssertFalse(appState.isFormEditorPresented)
    }

    func testUserPasswordWithoutFormPermissionBlocksFormChanges() throws {
        let sourceURL = try writeFormPDF(
            named: "restricted-form.pdf",
            password: "fixture-user",
            permissions: []
        )
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        appState.submitDocumentPassword("fixture-user")
        let editor = try XCTUnwrap(appState.session?.editor)

        XCTAssertFalse(appState.canFillFormsInActiveDocument)
        appState.presentFormEditor()
        XCTAssertFalse(appState.isFormEditorPresented)
        XCTAssertEqual(appState.presentedError?.title, "Form Filling Not Permitted")

        appState.updateFormField(named: "fullName", value: .text("Blocked"))
        XCTAssertEqual(
            editor.formFields.first { $0.name == "fullName" }?.value,
            .text("Original")
        )
        XCTAssertFalse(editor.canUndo)
    }

    func testRedactionRequiresExplicitConfirmationAndRemainsUndoableBeforeExport() throws {
        let sourceURL = try writePDF(named: "redaction.pdf", pages: ["SECRET account 1234"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)
        let region = PDFRedactionRegion(
            pageIndex: 0,
            bounds: CGRect(x: 60, y: 640, width: 300, height: 70)
        )

        XCTAssertTrue(appState.canRedactActiveDocument)
        appState.toggleRedactionMode()
        XCTAssertTrue(appState.redactionState.isActive)
        appState.addRedactionRegion(region)
        appState.redactionState.updateReasonLabel("PERSONAL DATA")
        appState.requestApplyPermanentRedactions()

        XCTAssertEqual(appState.pendingPermanentRedaction?.regionCount, 1)
        XCTAssertEqual(appState.pendingPermanentRedaction?.reasonLabel, "PERSONAL DATA")
        XCTAssertFalse(editor.canUndo)
        XCTAssertFalse(editor.document.findString("SECRET", withOptions: .caseInsensitive).isEmpty)

        appState.cancelPermanentRedaction()
        XCTAssertNil(appState.pendingPermanentRedaction)
        XCTAssertEqual(appState.redactionState.regions, [region])

        appState.requestApplyPermanentRedactions()
        appState.confirmPermanentRedaction()
        XCTAssertNil(appState.pendingPermanentRedaction)
        XCTAssertFalse(appState.redactionState.isActive)
        XCTAssertTrue(appState.redactionState.regions.isEmpty)
        XCTAssertTrue(appState.redactionState.reasonLabel.isEmpty)
        XCTAssertTrue(editor.document.findString("SECRET", withOptions: .caseInsensitive).isEmpty)
        XCTAssertTrue(editor.hasUnexportedChanges)

        appState.undoPageOperation()
        XCTAssertEqual(editor.document.findString("SECRET", withOptions: .caseInsensitive).count, 1)
    }

    func testUserPasswordWithoutDocumentChangePermissionBlocksRedaction() throws {
        let protectedURL = temporaryDirectory.appendingPathComponent("restricted-redaction.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: protectedURL, permissions: [])
        let appState = makeAppState()
        appState.requestOpenDocument(at: protectedURL)
        appState.submitDocumentPassword("fixture-user")

        XCTAssertFalse(appState.canRedactActiveDocument)
        appState.toggleRedactionMode()
        XCTAssertFalse(appState.redactionState.isActive)
        XCTAssertEqual(appState.presentedError?.title, "Redaction Not Permitted")
    }

    func testLocalOCRWorkflowAppliesOneRevisionAndReportsProgress() async throws {
        let sourceURL = try writePDF(named: "ocr.pdf", pages: ["LOCAL OCR WORKFLOW 7391"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)

        appState.presentLocalProcessing()
        XCTAssertTrue(appState.isLocalProcessingPresented)
        appState.startLocalProcessing(
            pageIndexes: [0],
            addsSearchableText: true,
            enhancement: .grayscale
        )

        for _ in 0..<100 where appState.isLocalProcessing {
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTAssertFalse(appState.isLocalProcessing)
        XCTAssertFalse(appState.isLocalProcessingPresented)
        XCTAssertTrue(editor.hasUnexportedChanges)
        XCTAssertTrue(editor.canUndo)
        XCTAssertTrue(editor.document.page(at: 0)?.string?.contains("7391") == true)
        XCTAssertEqual(appState.localProcessingProgress, PDFOCRProgress(completedPages: 1, totalPages: 1))
        XCTAssertEqual(appState.presentedError?.title, "Local Processing Complete")
    }

    func testLocalProcessingCanBeCancelledWithoutChangingTheDocument() throws {
        let sourceURL = try writePDF(named: "cancel-ocr.pdf", pages: ["No change"])
        let appState = makeAppState()
        appState.requestOpenDocument(at: sourceURL)
        let editor = try XCTUnwrap(appState.session?.editor)

        appState.presentLocalProcessing()
        appState.cancelLocalProcessing()

        XCTAssertFalse(appState.isLocalProcessingPresented)
        XCTAssertFalse(appState.isLocalProcessing)
        XCTAssertFalse(editor.canUndo)
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
        bookmarkStore: PageBookmarkStore? = nil,
        loadDocumentsAsynchronously: Bool = false
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
            signatureLibrary: SignatureLibrary(
                storageDirectory: temporaryDirectory.appendingPathComponent(
                    "Signatures-\(UUID().uuidString)",
                    isDirectory: true
                )
            ),
            pdfExporter: exporter,
            loadDocumentsAsynchronously: loadDocumentsAsynchronously
        )
    }

    private func waitUntil(
        timeoutIterations: Int = 500,
        condition: @MainActor () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Timed out waiting for the asynchronous document operation.")
    }

    private func writePDF(named name: String, pages: [String]) throws -> URL {
        let url = temporaryDirectory.appendingPathComponent(name)
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        return url
    }

    private func writeFormPDF(
        named name: String,
        password: String? = nil,
        permissions: [PDFAccessPermissions] = [.allowsFormFieldEntry]
    ) throws -> URL {
        let image = NSImage(size: NSSize(width: 612, height: 792))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()

        let document = PDFDocument()
        let page = try XCTUnwrap(PDFPage(image: image))
        document.insert(page, at: 0)

        let text = PDFAnnotation(
            bounds: CGRect(x: 72, y: 650, width: 240, height: 28),
            forType: .widget,
            withProperties: nil
        )
        text.widgetFieldType = .text
        text.fieldName = "fullName"
        text.widgetDefaultStringValue = "Original"
        text.widgetStringValue = "Original"
        page.addAnnotation(text)

        let checkbox = PDFAnnotation(
            bounds: CGRect(x: 72, y: 610, width: 24, height: 24),
            forType: .widget,
            withProperties: nil
        )
        checkbox.widgetFieldType = .button
        checkbox.fieldName = "consent"
        checkbox.widgetControlType = .checkBoxControl
        checkbox.widgetDefaultStringValue = "Off"
        checkbox.buttonWidgetState = .offState
        page.addAnnotation(checkbox)

        let url = temporaryDirectory.appendingPathComponent(name)
        if let password {
            let permissionBits = permissions.reduce(UInt(0)) { result, permission in
                result | permission.rawValue
            }
            let options: [PDFDocumentWriteOption: Any] = [
                .ownerPasswordOption: "fixture-owner",
                .userPasswordOption: password,
                .accessPermissionsOption: NSNumber(value: permissionBits),
            ]
            guard document.write(to: url, withOptions: options) else {
                throw LifecycleTestError.couldNotWritePDF
            }
        } else {
            guard document.write(to: url) else {
                throw LifecycleTestError.couldNotWritePDF
            }
        }
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
    private(set) var lastCompression: PDFExportCompression?

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
        accessPermissions: PDFAccessPermissions,
        compression: PDFExportCompression
    ) throws -> PDFExportResult {
        lastProtection = protection
        lastSessionPassword = sessionPassword
        lastAccessPermissions = accessPermissions
        lastCompression = compression
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
    case couldNotWritePDF
}
