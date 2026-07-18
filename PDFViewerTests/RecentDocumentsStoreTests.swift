import Foundation
import XCTest
@testable import PDFViewer

@MainActor
final class RecentDocumentsStoreTests: XCTestCase {
    func testRecordKeepsTenUniqueDocumentsInMostRecentFirstOrder() throws {
        let persistence = InMemoryRecentDocumentsPersistence()
        let store = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: TestBookmarkCoder(),
            limit: 10
        )
        let baseDate = Date(timeIntervalSince1970: 1_000)

        for index in 0..<12 {
            try store.record(
                URL(fileURLWithPath: "/tmp/document-\(index).pdf"),
                openedAt: baseDate.addingTimeInterval(TimeInterval(index))
            )
        }

        XCTAssertEqual(store.documents.count, 10)
        XCTAssertEqual(store.documents.first?.displayName, "document-11.pdf")
        XCTAssertEqual(store.documents.last?.displayName, "document-2.pdf")

        try store.record(
            URL(fileURLWithPath: "/tmp/document-5.pdf"),
            openedAt: baseDate.addingTimeInterval(100)
        )

        XCTAssertEqual(store.documents.count, 10)
        XCTAssertEqual(store.documents.first?.displayName, "document-5.pdf")
        XCTAssertEqual(store.documents.filter { $0.displayName == "document-5.pdf" }.count, 1)
        XCTAssertEqual(persistence.savedDocuments, store.documents)
    }

    func testFailedBookmarkDoesNotChangeExistingDocuments() throws {
        let persistence = InMemoryRecentDocumentsPersistence()
        let store = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: FailingBookmarkCoder(),
            limit: 10
        )

        XCTAssertThrowsError(
            try store.record(
                URL(fileURLWithPath: "/tmp/unavailable.pdf"),
                openedAt: Date()
            )
        )
        XCTAssertTrue(store.documents.isEmpty)
        XCTAssertTrue(persistence.savedDocuments.isEmpty)
    }

    func testResolveUsesStoredBookmark() throws {
        let persistence = InMemoryRecentDocumentsPersistence()
        let store = RecentDocumentsStore(
            persistence: persistence,
            bookmarkCoder: TestBookmarkCoder(),
            limit: 10
        )
        let url = URL(fileURLWithPath: "/tmp/reopen.pdf")
        try store.record(url, openedAt: Date())

        let resolvedURL = try store.resolve(store.documents[0])

        XCTAssertEqual(resolvedURL, url)
    }
}

@MainActor
private final class InMemoryRecentDocumentsPersistence: RecentDocumentsPersisting {
    var savedDocuments: [RecentDocument] = []

    func load() throws -> [RecentDocument] {
        savedDocuments
    }

    func save(_ documents: [RecentDocument]) throws {
        savedDocuments = documents
    }
}

@MainActor
private struct TestBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        Data(url.absoluteString.utf8)
    }

    func resolve(_ bookmark: Data) throws -> URL {
        guard
            let value = String(data: bookmark, encoding: .utf8),
            let url = URL(string: value)
        else {
            throw TestError.invalidBookmark
        }
        return url
    }
}

@MainActor
private struct FailingBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        throw TestError.invalidBookmark
    }

    func resolve(_ bookmark: Data) throws -> URL {
        throw TestError.invalidBookmark
    }
}

private enum TestError: Error {
    case invalidBookmark
}
