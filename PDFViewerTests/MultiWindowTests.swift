import AppKit
import Foundation
import XCTest
@testable import PDFViewer

@MainActor
final class MultiWindowTests: XCTestCase {
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

    func testTwoWindowsOpeningTheSameFileHaveIndependentWorkingCopies() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("shared.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        let services = makeSharedServices()
        let first = services.makeAppState()
        let second = services.makeAppState()

        first.requestOpenDocument(at: sourceURL)
        second.requestOpenDocument(at: sourceURL)
        first.rotateSelectedPages(clockwise: true)

        XCTAssertNotIdentical(first, second)
        XCTAssertNotIdentical(first.session?.editor, second.session?.editor)
        XCTAssertTrue(first.session?.editor.hasUnexportedChanges == true)
        XCTAssertFalse(second.session?.editor.hasUnexportedChanges == true)
        XCTAssertEqual(first.session?.document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(second.session?.document.page(at: 0)?.rotation, 0)
    }

    func testRegistryRoutesAWindowToItsOwnState() {
        let services = makeSharedServices()
        let registry = WindowStateRegistry()
        let first = services.makeAppState()
        let second = services.makeAppState()
        let firstID = UUID()
        let secondID = UUID()
        let firstWindow = NSWindow()
        let secondWindow = NSWindow()

        registry.register(first, id: firstID)
        registry.register(second, id: secondID)
        registry.attach(firstWindow, to: firstID)
        registry.attach(secondWindow, to: secondID)

        XCTAssertTrue(registry.state(for: firstWindow) === first)
        XCTAssertTrue(registry.state(for: secondWindow) === second)

        registry.unregister(id: firstID)
        XCTAssertNil(registry.state(for: firstWindow))
        XCTAssertTrue(registry.state(for: secondWindow) === second)
    }

    func testTerminationReviewsEveryDirtyWindowAndCancelStopsQuit() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("dirty.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        let services = makeSharedServices()
        let registry = WindowStateRegistry()
        let states = [services.makeAppState(), services.makeAppState()]

        for state in states {
            state.requestOpenDocument(at: sourceURL)
            state.rotateSelectedPages(clockwise: true)
            registry.register(state, id: UUID())
        }

        var replies: [Bool] = []
        XCTAssertFalse(registry.requestApplicationTermination { replies.append($0) })

        let firstPrompt = try XCTUnwrap(states.first { $0.pendingUnsavedChanges != nil })
        firstPrompt.resolveUnsavedChanges(.discard)
        let secondPrompt = try XCTUnwrap(
            states.first { $0 !== firstPrompt && $0.pendingUnsavedChanges != nil }
        )
        secondPrompt.resolveUnsavedChanges(.cancel)

        XCTAssertEqual(replies, [false])
        XCTAssertNotNil(secondPrompt.session)
    }

    func testTerminationCompletesOnlyAfterEveryDirtyWindowContinues() throws {
        let sourceURL = temporaryDirectory.appendingPathComponent("dirty.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: ["Alpha", "Bravo"], to: sourceURL)
        let services = makeSharedServices()
        let registry = WindowStateRegistry()
        let states = [services.makeAppState(), services.makeAppState()]

        for state in states {
            state.requestOpenDocument(at: sourceURL)
            state.rotateSelectedPages(clockwise: true)
            registry.register(state, id: UUID())
        }

        var replies: [Bool] = []
        XCTAssertFalse(registry.requestApplicationTermination { replies.append($0) })

        for _ in states {
            let prompted = try XCTUnwrap(states.first { $0.pendingUnsavedChanges != nil })
            prompted.resolveUnsavedChanges(.discard)
        }

        XCTAssertEqual(replies, [true])
    }

    private func makeSharedServices() -> SharedServices {
        SharedServices(
            documentLoader: DocumentLoader(
                securityScopedResources: SecurityScopedResourceAccessProvider(
                    startAccessing: { _ in false },
                    stopAccessing: { _ in }
                )
            ),
            recentDocuments: RecentDocumentsStore(
                persistence: MultiWindowRecentDocumentsPersistence(),
                bookmarkCoder: MultiWindowBookmarkCoder()
            ),
            bookmarkStore: PageBookmarkStore(
                defaults: UserDefaults(
                    suiteName: "MultiWindowTests.\(UUID().uuidString)"
                )!
            ),
            signatureLibrary: SignatureLibrary(
                storageDirectory: temporaryDirectory.appendingPathComponent(
                    "Signatures",
                    isDirectory: true
                )
            ),
            pdfExporter: PDFExporter(
                stagingDirectory: temporaryDirectory.appendingPathComponent(
                    "Staging",
                    isDirectory: true
                )
            ),
            loadDocumentsAsynchronously: false
        )
    }
}

@MainActor
private final class MultiWindowRecentDocumentsPersistence: RecentDocumentsPersisting {
    private var stored: [RecentDocument] = []

    func load() throws -> [RecentDocument] { stored }
    func save(_ documents: [RecentDocument]) throws { stored = documents }
}

@MainActor
private struct MultiWindowBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data { Data(url.path.utf8) }

    func resolve(_ bookmark: Data) throws -> URL {
        URL(fileURLWithPath: String(decoding: bookmark, as: UTF8.self))
    }
}
