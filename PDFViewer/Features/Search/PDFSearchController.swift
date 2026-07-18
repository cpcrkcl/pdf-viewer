import Combine
import Foundation
@preconcurrency import PDFKit

enum PDFSearchFeedback: Equatable {
    case idle
    case matches
    case noMatches
    case textUnavailable
}

@MainActor
final class PDFSearchController: NSObject, ObservableObject {
    @Published var query = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var activeMatchIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var feedback: PDFSearchFeedback = .idle
    @Published private(set) var navigationRevision = 0

    var matchCount: Int {
        matches.count
    }

    var activeSelection: PDFSelection? {
        guard let activeMatchIndex, matches.indices.contains(activeMatchIndex) else {
            return nil
        }
        return matches[activeMatchIndex]
    }

    private weak var observedDocument: PDFDocument?

    func startSearch(for query: String, in document: PDFDocument) {
        stopObservingCurrentSearch()

        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        matches = []
        activeMatchIndex = nil
        navigationRevision += 1

        guard !trimmedQuery.isEmpty else {
            feedback = .idle
            return
        }

        guard hasSearchableText(document) else {
            feedback = .textUnavailable
            return
        }

        observedDocument = document
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFindMatch(_:)),
            name: .PDFDocumentDidFindMatch,
            object: document
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(didFinishSearch(_:)),
            name: .PDFDocumentDidEndFind,
            object: document
        )

        isSearching = true
        document.beginFindString(trimmedQuery, withOptions: .caseInsensitive)
    }

    func clear() {
        stopObservingCurrentSearch()
        query = ""
        matches = []
        activeMatchIndex = nil
        isSearching = false
        feedback = .idle
        navigationRevision += 1
    }

    func selectNextMatch() {
        selectMatch(offset: 1)
    }

    func selectPreviousMatch() {
        selectMatch(offset: -1)
    }

    @objc
    private func didFindMatch(_ notification: Notification) {
        guard
            notification.object as? PDFDocument === observedDocument,
            let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection
        else {
            return
        }

        matches.append(selection)
    }

    @objc
    private func didFinishSearch(_ notification: Notification) {
        guard notification.object as? PDFDocument === observedDocument else {
            return
        }

        isSearching = false
        activeMatchIndex = matches.isEmpty ? nil : 0
        feedback = matches.isEmpty ? .noMatches : .matches
        navigationRevision += 1
        stopObservingCurrentSearch(cancel: false)
    }

    private func selectMatch(offset: Int) {
        guard !matches.isEmpty else {
            return
        }

        let currentIndex = activeMatchIndex ?? 0
        let nextIndex = (currentIndex + offset + matches.count) % matches.count
        activeMatchIndex = nextIndex
        navigationRevision += 1
    }

    private func stopObservingCurrentSearch(cancel: Bool = true) {
        if cancel, isSearching {
            observedDocument?.cancelFindString()
        }
        NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidFindMatch, object: observedDocument)
        NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidEndFind, object: observedDocument)
        observedDocument = nil
        if isSearching {
            isSearching = false
        }
    }

    private func hasSearchableText(_ document: PDFDocument) -> Bool {
        !(document.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
