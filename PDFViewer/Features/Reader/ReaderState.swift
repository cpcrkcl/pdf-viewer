import Combine
import Foundation
@preconcurrency import PDFKit

enum ReaderDisplayMode: String, CaseIterable, Identifiable {
    case singlePage
    case twoPage
    case continuous

    var id: Self { self }

    var title: String {
        switch self {
        case .singlePage:
            "Single Page"
        case .twoPage:
            "Two Page"
        case .continuous:
            "Continuous"
        }
    }
}

enum ReaderTheme: String, CaseIterable, Identifiable {
    case day
    case night
    case sepia

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }
}

enum PageLabelStyle: String, CaseIterable, Identifiable {
    case document
    case decimal
    case romanUpper
    case romanLower
    case letters

    var id: Self { self }
    var title: String {
        switch self {
        case .document: "Document Labels"
        case .decimal: "Decimal"
        case .romanUpper: "Roman (I, II, III)"
        case .romanLower: "Roman (i, ii, iii)"
        case .letters: "Letters (A, B, C)"
        }
    }
}

enum ReaderZoomAction: Equatable {
    case fit
    case zoomIn
    case zoomOut
}

struct ReaderZoomRequest: Equatable {
    let sequence: Int
    let action: ReaderZoomAction
}

@MainActor
final class ReaderState: ObservableObject {
    @Published private(set) var pageCount: Int
    @Published private(set) var selectedPageIndex: Int
    @Published private(set) var selectedPageIndexes: Set<Int>
    @Published var displayMode: ReaderDisplayMode
    @Published var theme: ReaderTheme
    @Published var isReaderSidebarVisible: Bool
    @Published var selectedSidebarTab: ReaderSidebarTab
    @Published var pageLabelStyle: PageLabelStyle
    @Published var pageLabelStart: Int
    @Published var pageLabelPrefix: String
    @Published private(set) var isDocumentDirty: Bool
    @Published private(set) var zoomRequest: ReaderZoomRequest
    @Published private(set) var printRequestSequence: Int

    init(pageCount: Int = 0) {
        let safePageCount = max(0, pageCount)
        self.pageCount = safePageCount
        self.selectedPageIndex = 0
        self.selectedPageIndexes = safePageCount > 0 ? [0] : []
        self.displayMode = .continuous
        self.theme = .night
        self.isReaderSidebarVisible = true
        self.selectedSidebarTab = .thumbnails
        self.pageLabelStyle = .document
        self.pageLabelStart = 1
        self.pageLabelPrefix = ""
        self.isDocumentDirty = false
        self.zoomRequest = ReaderZoomRequest(sequence: 0, action: .fit)
        self.printRequestSequence = 0
    }

    @discardableResult
    func goToPage(number: Int) -> Bool {
        selectPage(at: number - 1)
    }

    @discardableResult
    func selectPage(at index: Int) -> Bool {
        guard (0..<pageCount).contains(index) else {
            return false
        }

        selectedPageIndex = index
        selectedPageIndexes = [index]
        return true
    }

    @discardableResult
    func selectPages(
        at indexes: Set<Int>,
        preferredPageIndex: Int? = nil
    ) -> Bool {
        guard indexes.allSatisfy({ (0..<pageCount).contains($0) }) else {
            return false
        }

        selectedPageIndexes = indexes

        guard !indexes.isEmpty else {
            return true
        }

        if
            let preferredPageIndex,
            indexes.contains(preferredPageIndex)
        {
            selectedPageIndex = preferredPageIndex
        } else if !indexes.contains(selectedPageIndex), let firstSelectedPageIndex = indexes.min() {
            selectedPageIndex = firstSelectedPageIndex
        }

        return true
    }

    var selectedPageIndexSet: IndexSet {
        IndexSet(selectedPageIndexes)
    }

    func reset(pageCount: Int) {
        synchronize(pageCount: pageCount, isDirty: false)
        displayMode = .continuous
        theme = .night
        isReaderSidebarVisible = true
        selectedSidebarTab = .thumbnails
        pageLabelStyle = .document
        pageLabelStart = 1
        pageLabelPrefix = ""
        requestZoom(.fit)
    }

    func synchronize(
        pageCount: Int,
        preferredPageIndex: Int? = nil,
        isDirty: Bool
    ) {
        let synchronizedPageCount = max(0, pageCount)
        let desiredIndex = preferredPageIndex ?? selectedPageIndex
        var synchronizedPageIndex: Int
        var synchronizedPageIndexes: Set<Int>

        if synchronizedPageCount == 0 {
            synchronizedPageIndex = 0
            synchronizedPageIndexes = []
        } else {
            synchronizedPageIndex = min(max(0, desiredIndex), synchronizedPageCount - 1)
            let validSelections = selectedPageIndexes.filter {
                (0..<synchronizedPageCount).contains($0)
            }
            synchronizedPageIndexes = validSelections.isEmpty
                ? [synchronizedPageIndex]
                : validSelections

            if !synchronizedPageIndexes.contains(synchronizedPageIndex) {
                synchronizedPageIndex = synchronizedPageIndexes.min() ?? synchronizedPageIndex
            }
        }

        if self.pageCount != synchronizedPageCount {
            self.pageCount = synchronizedPageCount
        }
        if selectedPageIndex != synchronizedPageIndex {
            selectedPageIndex = synchronizedPageIndex
        }
        if selectedPageIndexes != synchronizedPageIndexes {
            selectedPageIndexes = synchronizedPageIndexes
        }
        if isDocumentDirty != isDirty {
            isDocumentDirty = isDirty
        }
    }

    func markDocumentDirty() {
        if !isDocumentDirty {
            isDocumentDirty = true
        }
    }

    func markDocumentClean() {
        if isDocumentDirty {
            isDocumentDirty = false
        }
    }

    func requestZoom(_ action: ReaderZoomAction) {
        zoomRequest = ReaderZoomRequest(
            sequence: zoomRequest.sequence + 1,
            action: action
        )
    }

    /// Printing is presentation-only output of the working copy; the request
    /// sequence is never treated as a document mutation.
    func requestPrint() {
        printRequestSequence += 1
    }

    func toggleReaderSidebar() {
        isReaderSidebarVisible.toggle()
    }

    // Kept as a source-compatible bridge for existing reader tests and views
    // while the product language has moved from “thumbnails” to “sidebar.”
    var isThumbnailSidebarVisible: Bool {
        get { isReaderSidebarVisible }
        set { isReaderSidebarVisible = newValue }
    }

    func toggleThumbnailSidebar() {
        toggleReaderSidebar()
    }

    func pageLabel(for index: Int, in document: PDFDocument) -> String {
        guard (0..<document.pageCount).contains(index) else { return "" }
        if pageLabelStyle == .document {
            return document.page(at: index)?.label ?? "\(index + 1)"
        }
        let value = max(1, pageLabelStart + index)
        let body: String = switch pageLabelStyle {
        case .document, .decimal: "\(value)"
        case .romanUpper: Self.roman(value)
        case .romanLower: Self.roman(value).lowercased()
        case .letters: Self.letters(value)
        }
        return String(pageLabelPrefix.prefix(20)) + body
    }

    private static func roman(_ value: Int) -> String {
        guard value <= 3999 else { return "\(value)" }
        let symbols = [(1000,"M"),(900,"CM"),(500,"D"),(400,"CD"),(100,"C"),(90,"XC"),(50,"L"),(40,"XL"),(10,"X"),(9,"IX"),(5,"V"),(4,"IV"),(1,"I")]
        var remaining = value
        var result = ""
        for (number, symbol) in symbols {
            while remaining >= number { result += symbol; remaining -= number }
        }
        return result
    }

    private static func letters(_ value: Int) -> String {
        var remaining = value
        var result = ""
        while remaining > 0 {
            remaining -= 1
            result = String(UnicodeScalar(65 + remaining % 26)!) + result
            remaining /= 26
        }
        return result
    }
}
