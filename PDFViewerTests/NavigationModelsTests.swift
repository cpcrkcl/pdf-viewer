import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class NavigationModelsTests: XCTestCase {
    func testWorkingPageIdentitiesFollowReorderDeleteAndUndo() throws {
        let document = try makeDocument(pageCount: 3)
        let editor = try PDFDocumentEditor(
            document: document,
            documentFingerprint: "source-fingerprint"
        )
        let originalIDs = editor.pageIDs

        try editor.movePages(at: IndexSet(integer: 0), to: 3)
        XCTAssertEqual(editor.pageIDs, [originalIDs[1], originalIDs[2], originalIDs[0]])

        try editor.deletePages(at: IndexSet(integer: 1))
        XCTAssertNil(editor.index(for: originalIDs[2]))

        try editor.undo()
        XCTAssertEqual(editor.index(for: originalIDs[2]), 1)
        try editor.undo()
        XCTAssertEqual(editor.pageIDs, originalIDs)

        let importedDocument = try makeDocument(pageCount: 2)
        try editor.insertPages(
            from: importedDocument,
            selecting: IndexSet(integer: 1),
            sourceFingerprint: "import-fingerprint",
            at: 1
        )
        let importedID = try XCTUnwrap(editor.pageID(at: 1))
        XCTAssertEqual(importedID.documentFingerprint, "import-fingerprint")
        XCTAssertEqual(importedID.originalPageIndex, 1)
        XCTAssertFalse(importedID.representsOriginalOccurrence)
    }

    func testOriginalPageIdentityIsDeterministic() throws {
        let first = try PDFDocumentEditor(
            document: makeDocument(pageCount: 2),
            documentFingerprint: "same-bytes"
        )
        let second = try PDFDocumentEditor(
            document: makeDocument(pageCount: 2),
            documentFingerprint: "same-bytes"
        )

        XCTAssertEqual(first.pageIDs, second.pageIDs)
        XCTAssertTrue(first.pageIDs.allSatisfy(\.representsOriginalOccurrence))
    }

    func testOutlineConstructionMapsDestinationsAndLimitsUntrustedData() throws {
        let document = try makeDocument(pageCount: 2)
        let editor = try PDFDocumentEditor(
            document: document,
            documentFingerprint: "outline-source"
        )
        let root = PDFOutline()

        let valid = PDFOutline()
        valid.label = String(repeating: "A", count: 600)
        valid.destination = PDFDestination(
            page: try XCTUnwrap(document.page(at: 1)),
            at: .zero
        )
        root.insertChild(valid, at: 0)

        let invalid = PDFOutline()
        invalid.label = "Unavailable"
        root.insertChild(invalid, at: 1)

        var parent = valid
        for depth in 0..<(DocumentOutlineBuilder.maximumDepth + 8) {
            let child = PDFOutline()
            child.label = "Depth \(depth)"
            parent.insertChild(child, at: 0)
            parent = child
        }
        document.outlineRoot = root

        let nodes = DocumentOutlineBuilder.build(
            from: document,
            pageIDs: editor.pageIDs
        )

        XCTAssertEqual(nodes.count, 2)
        XCTAssertEqual(nodes[0].title.count, DocumentOutlineBuilder.maximumLabelLength)
        XCTAssertEqual(nodes[0].pageID, editor.pageID(at: 1))
        XCTAssertNil(nodes[1].pageID)
        XCTAssertLessThanOrEqual(maximumDepth(in: nodes), DocumentOutlineBuilder.maximumDepth)
    }

    func testOutlineNodeLimitStopsOversizedTrees() throws {
        let document = try makeDocument(pageCount: 1)
        let editor = try PDFDocumentEditor(
            document: document,
            documentFingerprint: "oversized-outline"
        )
        let root = PDFOutline()
        for index in 0..<(DocumentOutlineBuilder.maximumNodeCount + 5) {
            let child = PDFOutline()
            child.label = "Node \(index)"
            root.insertChild(child, at: index)
        }
        document.outlineRoot = root

        let nodes = DocumentOutlineBuilder.build(
            from: document,
            pageIDs: editor.pageIDs
        )

        XCTAssertEqual(nodes.count, DocumentOutlineBuilder.maximumNodeCount)
    }

    func testBookmarkPersistenceRenameAndRemoval() throws {
        let suiteName = "NavigationModelsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let pageID = WorkingPageID.original(
            documentFingerprint: "bookmark-document",
            pageIndex: 4
        )
        let store = PageBookmarkStore(defaults: defaults)
        let bookmark = store.add(
            documentFingerprint: "bookmark-document",
            pageID: pageID,
            label: "Page 5"
        )
        store.rename(bookmark.id, to: String(repeating: "Long", count: 40))

        let reloaded = PageBookmarkStore(defaults: defaults)
        let persisted = try XCTUnwrap(reloaded.bookmarks(for: "bookmark-document").first)
        XCTAssertEqual(persisted.id, bookmark.id)
        XCTAssertEqual(persisted.pageID, pageID)
        XCTAssertEqual(persisted.label.count, 120)

        reloaded.remove(bookmark.id)
        XCTAssertTrue(PageBookmarkStore(defaults: defaults).bookmarks.isEmpty)
    }

    func testNavigationHistoryBranchesCapsAndSkipsDeletedLocations() {
        let IDs = (0..<6).map {
            WorkingPageID.original(documentFingerprint: "history", pageIndex: $0)
        }
        let history = NavigationHistory(maximumEntryCount: 4)
        history.reset(initialPageID: IDs[0])
        for pageID in IDs[1...4] {
            history.record(NavigationLocation(pageID: pageID))
        }

        XCTAssertEqual(history.entries.count, 4)
        XCTAssertEqual(history.entries.first?.pageID, IDs[1])
        XCTAssertEqual(
            history.goBack(validPageIDs: [IDs[1], IDs[2], IDs[4]])?.pageID,
            IDs[2]
        )

        history.record(NavigationLocation(pageID: IDs[5]))
        XCTAssertFalse(history.entries.contains(NavigationLocation(pageID: IDs[4])))
        XCTAssertFalse(history.canGoForward(validPageIDs: Set(IDs)))
    }

    func testByteIdenticalFilesShareFingerprintAndChangedContentsDoNot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstURL = directory.appendingPathComponent("First.pdf")
        let renamedURL = directory.appendingPathComponent("Renamed.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Original"], to: firstURL)
        try FileManager.default.copyItem(at: firstURL, to: renamedURL)

        let loader = DocumentLoader(
            securityScopedResources: SecurityScopedResourceAccessProvider(
                startAccessing: { _ in false },
                stopAccessing: { _ in }
            )
        )
        let firstSession = try openedSession(from: loader.open(firstURL))
        let renamedSession = try openedSession(from: loader.open(renamedURL))
        XCTAssertEqual(firstSession.documentFingerprint, renamedSession.documentFingerprint)
        firstSession.close()
        renamedSession.close()

        try FixturePDFBuilder.writeTextPDF(pages: ["Externally changed"], to: renamedURL)
        let changedSession = try openedSession(from: loader.open(renamedURL))
        XCTAssertNotEqual(firstSession.documentFingerprint, changedSession.documentFingerprint)
        changedSession.close()
    }

    private func openedSession(from result: DocumentOpenResult) throws -> DocumentSession {
        guard case .opened(let session) = result else {
            return try XCTUnwrap(nil as DocumentSession?)
        }
        return session
    }

    private func makeDocument(pageCount: Int) throws -> PDFDocument {
        let document = PDFDocument()
        for _ in 0..<pageCount {
            document.insert(PDFPage(), at: document.pageCount)
        }
        return document
    }

    private func maximumDepth(in nodes: [DocumentOutlineNode], depth: Int = 0) -> Int {
        nodes.reduce(depth) { currentMaximum, node in
            max(currentMaximum, maximumDepth(in: node.children, depth: depth + 1))
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerNavigationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
