import Foundation

struct RecentDocument: Codable, Equatable, Identifiable {
    let id: String
    let displayName: String
    let bookmark: Data
    let lastOpenedAt: Date
}

@MainActor
protocol RecentDocumentsPersisting {
    func load() throws -> [RecentDocument]
    func save(_ documents: [RecentDocument]) throws
}

@MainActor
protocol SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data
    func resolve(_ bookmark: Data) throws -> URL
}

@MainActor
final class RecentDocumentsStore: ObservableObject {
    @Published private(set) var documents: [RecentDocument]

    private let persistence: any RecentDocumentsPersisting
    private let bookmarkCoder: any SecurityScopedBookmarkCoding
    private let limit: Int

    init(
        persistence: any RecentDocumentsPersisting = UserDefaultsRecentDocumentsPersistence(),
        bookmarkCoder: any SecurityScopedBookmarkCoding = SecurityScopedBookmarkCoder(),
        limit: Int = 10
    ) {
        precondition(limit > 0)

        self.persistence = persistence
        self.bookmarkCoder = bookmarkCoder
        self.limit = limit
        let loadedDocuments = (try? persistence.load()) ?? []
        var seenIdentifiers: Set<String> = []
        self.documents = Array(
            loadedDocuments
                .sorted { $0.lastOpenedAt > $1.lastOpenedAt }
                .filter { seenIdentifiers.insert($0.id).inserted }
                .prefix(limit)
        )
    }

    func record(_ url: URL, openedAt date: Date = Date()) throws {
        let standardizedURL = url.standardizedFileURL
        let bookmark = try bookmarkCoder.bookmark(for: standardizedURL)
        let identifier = standardizedURL.resolvingSymlinksInPath().path
        let recentDocument = RecentDocument(
            id: identifier,
            displayName: standardizedURL.lastPathComponent,
            bookmark: bookmark,
            lastOpenedAt: date
        )

        var updatedDocuments = documents.filter { $0.id != identifier }
        updatedDocuments.insert(recentDocument, at: 0)
        updatedDocuments = Array(updatedDocuments.prefix(limit))

        try persistence.save(updatedDocuments)
        documents = updatedDocuments
    }

    func resolve(_ document: RecentDocument) throws -> URL {
        try bookmarkCoder.resolve(document.bookmark)
    }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(RecentDocumentTransfer(version: 1, documents: documents))
    }

    func importJSON(_ data: Data) throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let transfer = try decoder.decode(RecentDocumentTransfer.self, from: data)
        guard transfer.version == 1, transfer.documents.count <= 1_000 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var merged = Dictionary(uniqueKeysWithValues: documents.map { ($0.id, $0) })
        for document in transfer.documents where
            !document.id.isEmpty && document.displayName.count <= 512 && document.bookmark.count <= 1_048_576
        {
            if merged[document.id]?.lastOpenedAt ?? .distantPast < document.lastOpenedAt {
                merged[document.id] = document
            }
        }
        let updated = Array(merged.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }.prefix(limit))
        try persistence.save(updated)
        documents = updated
    }
}

private struct RecentDocumentTransfer: Codable {
    let version: Int
    let documents: [RecentDocument]
}

@MainActor
private struct UserDefaultsRecentDocumentsPersistence: RecentDocumentsPersisting {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "recentDocuments.v1"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() throws -> [RecentDocument] {
        guard let data = defaults.data(forKey: key) else {
            return []
        }
        return try JSONDecoder().decode([RecentDocument].self, from: data)
    }

    func save(_ documents: [RecentDocument]) throws {
        let data = try JSONEncoder().encode(documents)
        defaults.set(data, forKey: key)
    }
}

@MainActor
private struct SecurityScopedBookmarkCoder: SecurityScopedBookmarkCoding {
    func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: [.nameKey],
            relativeTo: nil
        )
    }

    func resolve(_ bookmark: Data) throws -> URL {
        var isStale = false
        return try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
    }
}
