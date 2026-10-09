import Combine
import Foundation
@preconcurrency import PDFKit

enum PDFSearchFeedback: Equatable {
    case idle
    case matches
    case noMatches
    case textUnavailable
}

struct PDFSearchOptions: Equatable, Sendable {
    var isCaseSensitive = false
    var matchesWholeWords = false
}

struct PDFSearchMatchSummary: Identifiable, Equatable {
    let id: Int
    let pageIndex: Int
    let text: String
    let bounds: CGRect

    var pageNumber: Int { pageIndex + 1 }
}

@MainActor
final class PDFSearchController: NSObject, ObservableObject {
    @Published var query = ""
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var activeMatchIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var feedback: PDFSearchFeedback = .idle
    @Published private(set) var navigationRevision = 0
    @Published var options = PDFSearchOptions()

    var matchCount: Int {
        matches.count
    }

    var activeSelection: PDFSelection? {
        guard let activeMatchIndex, matches.indices.contains(activeMatchIndex) else {
            return nil
        }
        return matches[activeMatchIndex]
    }

    func summaries(in document: PDFDocument) -> [PDFSearchMatchSummary] {
        matches.enumerated().compactMap { index, selection in
            guard let page = selection.pages.first else { return nil }
            let pageIndex = document.index(for: page)
            guard pageIndex != NSNotFound else { return nil }
            return PDFSearchMatchSummary(
                id: index,
                pageIndex: pageIndex,
                text: selection.string ?? query,
                bounds: selection.bounds(for: page)
            )
        }
    }

    func redactionRegions(
        forMatchIndexes indexes: Set<Int>,
        in document: PDFDocument
    ) -> [PDFRedactionRegion] {
        indexes.sorted().flatMap { index -> [PDFRedactionRegion] in
            guard matches.indices.contains(index) else { return [] }
            let selection = matches[index]
            return selection.pages.compactMap { page in
                let pageIndex = document.index(for: page)
                let bounds = selection.bounds(for: page)
                guard pageIndex != NSNotFound, !bounds.isEmpty, !bounds.isNull else { return nil }
                return PDFRedactionRegion(pageIndex: pageIndex, bounds: bounds)
            }
        }
    }

    private weak var observedDocument: PDFDocument?
    private var activeSearchQuery = ""
    private var wholeWordBoundsByPage: [Int: [CGRect]] = [:]

    func startSearch(for query: String, in document: PDFDocument) {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        self.query = query
        matches = []
        activeMatchIndex = nil
        navigationRevision += 1

        guard !trimmedQuery.isEmpty else {
            stopObservingCurrentSearch()
            feedback = .idle
            return
        }

        guard hasSearchableText(document) else {
            stopObservingCurrentSearch()
            feedback = .textUnavailable
            return
        }

        if isSearching {
            stopObservingCurrentSearch(updateSearchingState: false)
        }

        beginSearch(for: trimmedQuery, in: document)
    }

    func updateQuery(_ query: String) {
        guard self.query != query else {
            return
        }
        stopObservingCurrentSearch()
        self.query = query
        matches = []
        activeMatchIndex = nil
        feedback = .idle
        navigationRevision += 1
    }

    private func beginSearch(for query: String, in document: PDFDocument) {
        stopObservingCurrentSearch(cancel: false, updateSearchingState: false)

        activeSearchQuery = query
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

        if !isSearching {
            isSearching = true
        }
        let findOptions: NSString.CompareOptions = options.isCaseSensitive ? [] : .caseInsensitive
        if options.matchesWholeWords {
            wholeWordBoundsByPage = makeWholeWordBounds(
                query: query,
                document: document,
                caseSensitive: options.isCaseSensitive
            )
        }
        document.beginFindString(query, withOptions: findOptions)
    }

    func clear() {
        stopObservingCurrentSearch()
        activeSearchQuery = ""
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

    func selectMatch(at index: Int) {
        guard matches.indices.contains(index) else { return }
        activeMatchIndex = index
        navigationRevision += 1
    }

    @objc
    private func didFindMatch(_ notification: Notification) {
        guard
            notification.object as? PDFDocument === observedDocument,
            let selection = notification.userInfo?[PDFDocumentFoundSelectionKey] as? PDFSelection
        else {
            return
        }

        let comparisonOptions: String.CompareOptions = options.isCaseSensitive
            ? [.diacriticInsensitive]
            : [.caseInsensitive, .diacriticInsensitive]
        guard selection.string?.range(of: activeSearchQuery, options: comparisonOptions) != nil else {
            return
        }

        if options.matchesWholeWords {
            guard
                let page = selection.pages.first,
                let document = observedDocument,
                document.index(for: page) != NSNotFound
            else { return }
            let pageIndex = document.index(for: page)
            let bounds = selection.bounds(for: page)
            guard wholeWordBoundsByPage[pageIndex]?.contains(where: {
                $0.intersects(bounds) && abs($0.midX - bounds.midX) < max(2, bounds.width)
            }) == true else { return }
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

    private func stopObservingCurrentSearch(
        cancel: Bool = true,
        updateSearchingState: Bool = true
    ) {
        let document = observedDocument
        let wasSearching = isSearching
        NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidFindMatch, object: document)
        NotificationCenter.default.removeObserver(self, name: .PDFDocumentDidEndFind, object: document)
        observedDocument = nil
        activeSearchQuery = ""
        wholeWordBoundsByPage = [:]
        if updateSearchingState, wasSearching {
            isSearching = false
        }
        if cancel, wasSearching {
            document?.cancelFindString()
        }
    }

    private func hasSearchableText(_ document: PDFDocument) -> Bool {
        !(document.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func makeWholeWordBounds(
        query: String,
        document: PDFDocument,
        caseSensitive: Bool
    ) -> [Int: [CGRect]] {
        var result: [Int: [CGRect]] = [:]
        let searchOptions: NSString.CompareOptions = caseSensitive ? [] : .caseInsensitive
        let wordCharacters = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_"))
        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex), let text = page.string else { continue }
            let source = text as NSString
            var searchRange = NSRange(location: 0, length: source.length)
            while searchRange.length > 0 {
                let found = source.range(of: query, options: searchOptions, range: searchRange)
                guard found.location != NSNotFound else { break }
                let beforeIsWord = found.location > 0 &&
                    source.substring(with: NSRange(location: found.location - 1, length: 1))
                        .unicodeScalars.contains(where: wordCharacters.contains)
                let afterLocation = found.location + found.length
                let afterIsWord = afterLocation < source.length &&
                    source.substring(with: NSRange(location: afterLocation, length: 1))
                        .unicodeScalars.contains(where: wordCharacters.contains)
                if !beforeIsWord, !afterIsWord, let selection = page.selection(for: found) {
                    let bounds = selection.bounds(for: page)
                    if !bounds.isEmpty { result[pageIndex, default: []].append(bounds) }
                }
                let next = max(found.location + max(found.length, 1), searchRange.location + 1)
                searchRange = NSRange(location: next, length: max(0, source.length - next))
            }
        }
        return result
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}
