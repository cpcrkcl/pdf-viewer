import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class DocumentLoaderTests: XCTestCase {
    func testOpenValidPDFPreservesSourceAndReportsPageCount() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writePDF(pageCount: 2, to: sourceURL)
        let originalData = try Data(contentsOf: sourceURL)

        let session = try openedSession(from: DocumentLoader().open(sourceURL))

        XCTAssertEqual(session.sourceURL.standardizedFileURL, sourceURL.standardizedFileURL)
        XCTAssertEqual(session.document.pageCount, 2)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    }

    func testOpenedSessionEditsOnlyItsWorkingCopy() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writePDF(pageCount: 2, to: sourceURL)
        let originalData = try Data(contentsOf: sourceURL)

        let session = try openedSession(from: DocumentLoader().open(sourceURL))
        try session.editor.rotatePages(at: IndexSet(integer: 0), clockwise: true)

        XCTAssertEqual(session.document.page(at: 0)?.rotation, 90)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)

        let reopenedSource = try XCTUnwrap(PDFDocument(url: sourceURL))
        XCTAssertEqual(reopenedSource.page(at: 0)?.rotation, 0)
    }

    func testOpenRejectsNonPDFInput() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("notes.txt")
        try Data("not a PDF".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentLoader().open(sourceURL)) { error in
            XCTAssertEqual(error as? DocumentLoadingError, .unsupportedFileType)
        }
    }

    func testOpenRejectsCorruptPDF() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("corrupt.pdf")
        try Data("not really a PDF".utf8).write(to: sourceURL)

        XCTAssertThrowsError(try DocumentLoader().open(sourceURL)) { error in
            XCTAssertEqual(error as? DocumentLoadingError, .invalidPDF)
        }
    }

    func testOpenRejectsMissingPDF() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("missing.pdf")

        XCTAssertThrowsError(try DocumentLoader().open(sourceURL)) { error in
            XCTAssertEqual(error as? DocumentLoadingError, .fileUnavailable)
        }
    }

    func testOpenReturnsLockedHandleAndSupportsRetryWithUserPassword() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: sourceURL)

        let result = try DocumentLoader().open(sourceURL)
        guard case .passwordRequired(let handle) = result else {
            return XCTFail("Expected a retained locked-document handle")
        }

        XCTAssertNil(try handle.unlock(with: "incorrect"))
        let session = try XCTUnwrap(handle.unlock(with: "fixture-user"))
        XCTAssertEqual(session.document.pageCount, 1)
        XCTAssertTrue(session.securityContext.isEncrypted)
        XCTAssertEqual(session.securityContext.unlockLevel, .user)
        XCTAssertEqual(session.sessionPassword, "fixture-user")
    }

    func testOwnerPasswordReceivesOwnerUnlockLevel() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: sourceURL,
            permissions: []
        )

        guard case .passwordRequired(let handle) = try DocumentLoader().open(sourceURL) else {
            return XCTFail("Expected password prompt")
        }
        let session = try XCTUnwrap(handle.unlock(with: "fixture-owner"))

        XCTAssertEqual(session.securityContext.unlockLevel, .owner)
        XCTAssertTrue(session.securityContext.allowsCommenting)
        XCTAssertTrue(session.securityContext.allowsDocumentAssembly)
        XCTAssertTrue(session.securityContext.allowsContentCopying)
    }

    func testUserPermissionsAreReportedBySecurityContext() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("restricted.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(
            to: sourceURL,
            permissions: [.allowsCommenting]
        )

        guard case .passwordRequired(let handle) = try DocumentLoader().open(sourceURL) else {
            return XCTFail("Expected password prompt")
        }
        let session = try XCTUnwrap(handle.unlock(with: "fixture-user"))

        XCTAssertEqual(session.securityContext.unlockLevel, .user)
        XCTAssertTrue(session.securityContext.allowsCommenting)
        XCTAssertFalse(session.securityContext.allowsDocumentAssembly)
        XCTAssertFalse(session.securityContext.allowsContentCopying)
    }

    func testEmptyPasswordEncryptedPDFOpensWithoutPromptAndRetainsEmptyCredential() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("empty-password.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: sourceURL, userPassword: "")

        let session = try openedSession(from: DocumentLoader().open(sourceURL))

        XCTAssertTrue(session.securityContext.isEncrypted)
        XCTAssertEqual(session.sessionPassword, "")
    }

    func testStartsSecurityScopedAccessBeforeCheckingAnUnavailableFile() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("missing.pdf")
        var accessEvents: [String] = []
        let securityScopedResources = SecurityScopedResourceAccessProvider(
            startAccessing: { url in
                accessEvents.append("start:\(url.lastPathComponent)")
                return true
            },
            stopAccessing: { url in
                accessEvents.append("stop:\(url.lastPathComponent)")
            }
        )

        XCTAssertThrowsError(
            try DocumentLoader(
                securityScopedResources: securityScopedResources
            ).open(sourceURL)
        ) { error in
            XCTAssertEqual(error as? DocumentLoadingError, .fileUnavailable)
        }
        XCTAssertEqual(
            accessEvents,
            ["start:missing.pdf", "stop:missing.pdf"]
        )
    }

    func testOpenSessionKeepsScopedAccessUntilItCloses() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("fixture.pdf")
        try FixturePDFBuilder.writePDF(pageCount: 1, to: sourceURL)
        var startCount = 0
        var stopCount = 0
        let securityScopedResources = SecurityScopedResourceAccessProvider(
            startAccessing: { _ in
                startCount += 1
                return true
            },
            stopAccessing: { _ in
                stopCount += 1
            }
        )

        let session = try openedSession(from: DocumentLoader(
            securityScopedResources: securityScopedResources
        ).open(sourceURL))

        XCTAssertEqual(startCount, 1)
        XCTAssertEqual(stopCount, 0)
        session.close()
        session.close()
        XCTAssertEqual(stopCount, 1)
    }

    func testCancelingLockedHandleReleasesScopedAccess() throws {
        let temporaryDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let sourceURL = temporaryDirectory.appendingPathComponent("protected.pdf")
        try FixturePDFBuilder.writePasswordProtectedPDF(to: sourceURL)
        var stopCount = 0
        let resources = SecurityScopedResourceAccessProvider(
            startAccessing: { _ in true },
            stopAccessing: { _ in stopCount += 1 }
        )

        guard case .passwordRequired(let handle) = try DocumentLoader(
            securityScopedResources: resources
        ).open(sourceURL) else {
            return XCTFail("Expected password prompt")
        }

        handle.cancel()
        handle.cancel()
        XCTAssertEqual(stopCount, 1)
    }

    private func openedSession(from result: DocumentOpenResult) throws -> DocumentSession {
        guard case .opened(let session) = result else {
            throw TestError.expectedOpenedSession
        }
        return session
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private enum TestError: Error {
        case expectedOpenedSession
    }
}
