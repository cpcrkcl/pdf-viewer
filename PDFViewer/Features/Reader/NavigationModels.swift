import Combine
import CryptoKit
import Foundation
@preconcurrency import PDFKit

struct WorkingPageID: Hashable, Codable {
    let documentFingerprint: String
    let originalPageIndex: Int
    let occurrenceID: UUID

    static func original(documentFingerprint: String, pageIndex: Int) -> WorkingPageID {
        WorkingPageID(
            documentFingerprint: documentFingerprint,
            originalPageIndex: pageIndex,
            occurrenceID: deterministicOccurrenceID(
                documentFingerprint: documentFingerprint,
                pageIndex: pageIndex
            )
        )
    }

    var representsOriginalOccurrence: Bool {
        occurrenceID == Self.deterministicOccurrenceID(
            documentFingerprint: documentFingerprint,
            pageIndex: originalPageIndex
        )
    }

    private static func deterministicOccurrenceID(
        documentFingerprint: String,
        pageIndex: Int
    ) -> UUID {
        let digest = SHA256.hash(
            data: Data("\(documentFingerprint):\(pageIndex)".utf8)
        )
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }
}

struct DocumentRevision {
    let pdfData: Data
    let pageIDs: [WorkingPageID]
}

enum DocumentFingerprint {
    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum ReaderSidebarTab: String, CaseIterable, Identifiable {
    case thumbnails
    case contents
    case bookmarks

    var id: Self { self }

    var title: String {
        switch self {
        case .thumbnails:
            "Thumbnails"
        case .contents:
            "Contents"
        case .bookmarks:
            "Bookmarks"
        }
    }
}

struct DocumentOutlineNode: Identifiable, Equatable {
    let id: String
    let title: String
    let pageID: WorkingPageID?
    let children: [DocumentOutlineNode]

    var isNavigable: Bool {
        pageID != nil
    }
}

enum DocumentOutlineBuilder {
    static let maximumDepth = 128
    static let maximumNodeCount = 20_000
    static let maximumLabelLength = 512

    static func build(
        from document: PDFDocument,
        pageIDs: [WorkingPageID]
    ) -> [DocumentOutlineNode] {
        guard let root = document.outlineRoot else {
            return []
        }

        var visited: Set<ObjectIdentifier> = []
        var loadedNodeCount = 0
        return (0..<max(0, root.numberOfChildren)).compactMap { childIndex in
            guard let child = root.child(at: childIndex) else {
                return nil
            }
            return makeNode(
                child,
                path: "\(childIndex)",
                depth: 0,
                document: document,
                pageIDs: pageIDs,
                visited: &visited,
                loadedNodeCount: &loadedNodeCount
            )
        }
    }

    private static func makeNode(
        _ outline: PDFOutline,
        path: String,
        depth: Int,
        document: PDFDocument,
        pageIDs: [WorkingPageID],
        visited: inout Set<ObjectIdentifier>,
        loadedNodeCount: inout Int
    ) -> DocumentOutlineNode? {
        guard depth < maximumDepth, loadedNodeCount < maximumNodeCount else {
            return nil
        }

        let identity = ObjectIdentifier(outline)
        guard visited.insert(identity).inserted else {
            return nil
        }
        loadedNodeCount += 1

        let rawLabel = outline.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = String((rawLabel?.isEmpty == false ? rawLabel! : "Untitled Section").prefix(maximumLabelLength))
        let pageID = destinationPageID(
            for: outline,
            document: document,
            pageIDs: pageIDs
        )

        let children: [DocumentOutlineNode] = (0..<max(0, outline.numberOfChildren)).compactMap { childIndex in
            guard
                loadedNodeCount < maximumNodeCount,
                let child = outline.child(at: childIndex)
            else {
                return nil
            }
            return makeNode(
                child,
                path: "\(path).\(childIndex)",
                depth: depth + 1,
                document: document,
                pageIDs: pageIDs,
                visited: &visited,
                loadedNodeCount: &loadedNodeCount
            )
        }

        return DocumentOutlineNode(
            id: path,
            title: label,
            pageID: pageID,
            children: children
        )
    }

    private static func destinationPageID(
        for outline: PDFOutline,
        document: PDFDocument,
        pageIDs: [WorkingPageID]
    ) -> WorkingPageID? {
        let destination = outline.destination ?? (outline.action as? PDFActionGoTo)?.destination
        guard let page = destination?.page else {
            return nil
        }
        let index = document.index(for: page)
        guard index != NSNotFound, pageIDs.indices.contains(index) else {
            return nil
        }
        return pageIDs[index]
    }
}

struct PageBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    let documentFingerprint: String
    let pageID: WorkingPageID
    var label: String
    let createdAt: Date
}

struct ResolvedPageBookmark: Identifiable, Equatable {
    let bookmark: PageBookmark
    let pageIndex: Int?

    var id: UUID { bookmark.id }
}

@MainActor
final class PageBookmarkStore: ObservableObject {
    @Published private(set) var bookmarks: [PageBookmark]

    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "pageBookmarks.v1") {
        self.defaults = defaults
        self.key = key
        if
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([PageBookmark].self, from: data)
        {
            bookmarks = decoded
        } else {
            bookmarks = []
        }
    }

    func bookmarks(for documentFingerprint: String) -> [PageBookmark] {
        bookmarks
            .filter { $0.documentFingerprint == documentFingerprint }
            .sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func add(
        documentFingerprint: String,
        pageID: WorkingPageID,
        label: String,
        now: Date = Date()
    ) -> PageBookmark {
        let bookmark = PageBookmark(
            id: UUID(),
            documentFingerprint: documentFingerprint,
            pageID: pageID,
            label: sanitizedLabel(label),
            createdAt: now
        )
        bookmarks.append(bookmark)
        persist()
        return bookmark
    }

    func rename(_ bookmarkID: UUID, to label: String) {
        guard let index = bookmarks.firstIndex(where: { $0.id == bookmarkID }) else {
            return
        }
        bookmarks[index].label = sanitizedLabel(label)
        persist()
    }

    func remove(_ bookmarkID: UUID) {
        bookmarks.removeAll { $0.id == bookmarkID }
        persist()
    }

    private func sanitizedLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Bookmark" : trimmed).prefix(120))
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(bookmarks) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct NavigationLocation: Equatable {
    let pageID: WorkingPageID
}

@MainActor
final class NavigationHistory: ObservableObject {
    @Published private(set) var entries: [NavigationLocation] = []
    @Published private(set) var currentIndex = -1

    let maximumEntryCount: Int

    init(maximumEntryCount: Int = 100) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    func reset(initialPageID: WorkingPageID? = nil) {
        if let initialPageID {
            entries = [NavigationLocation(pageID: initialPageID)]
            currentIndex = 0
        } else {
            entries = []
            currentIndex = -1
        }
    }

    func record(_ location: NavigationLocation) {
        if entries.indices.contains(currentIndex), entries[currentIndex] == location {
            return
        }

        if currentIndex + 1 < entries.count {
            entries.removeSubrange((currentIndex + 1)..<entries.count)
        }
        entries.append(location)

        if entries.count > maximumEntryCount {
            entries.removeFirst(entries.count - maximumEntryCount)
        }
        currentIndex = entries.count - 1
    }

    func canGoBack(validPageIDs: Set<WorkingPageID>) -> Bool {
        previousValidIndex(validPageIDs: validPageIDs) != nil
    }

    func canGoForward(validPageIDs: Set<WorkingPageID>) -> Bool {
        nextValidIndex(validPageIDs: validPageIDs) != nil
    }

    func goBack(validPageIDs: Set<WorkingPageID>) -> NavigationLocation? {
        guard let index = previousValidIndex(validPageIDs: validPageIDs) else {
            return nil
        }
        currentIndex = index
        return entries[index]
    }

    func goForward(validPageIDs: Set<WorkingPageID>) -> NavigationLocation? {
        guard let index = nextValidIndex(validPageIDs: validPageIDs) else {
            return nil
        }
        currentIndex = index
        return entries[index]
    }

    private func previousValidIndex(validPageIDs: Set<WorkingPageID>) -> Int? {
        guard currentIndex > 0 else {
            return nil
        }
        return stride(from: currentIndex - 1, through: 0, by: -1).first {
            validPageIDs.contains(entries[$0].pageID)
        }
    }

    private func nextValidIndex(validPageIDs: Set<WorkingPageID>) -> Int? {
        guard currentIndex + 1 < entries.count else {
            return nil
        }
        return ((currentIndex + 1)..<entries.count).first {
            validPageIDs.contains(entries[$0].pageID)
        }
    }
}
