import Combine
import Foundation

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

    var id: Self { self }

    var title: String {
        rawValue.capitalized
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
    @Published private(set) var isDocumentDirty: Bool
    @Published private(set) var zoomRequest: ReaderZoomRequest

    init(pageCount: Int = 0) {
        let safePageCount = max(0, pageCount)
        self.pageCount = safePageCount
        self.selectedPageIndex = 0
        self.selectedPageIndexes = safePageCount > 0 ? [0] : []
        self.displayMode = .continuous
        self.theme = .day
        self.isReaderSidebarVisible = true
        self.selectedSidebarTab = .thumbnails
        self.isDocumentDirty = false
        self.zoomRequest = ReaderZoomRequest(sequence: 0, action: .fit)
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
        theme = .day
        isReaderSidebarVisible = true
        selectedSidebarTab = .thumbnails
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
}
