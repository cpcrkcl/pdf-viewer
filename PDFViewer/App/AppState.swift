import AppKit
import Combine
import Foundation
@preconcurrency import PDFKit
import UniformTypeIdentifiers

struct PresentedError: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum PendingDocumentAction: Equatable {
    case closeDocument
    case closeWindow
    case openURL(URL)
    case terminateApplication
}

struct PendingUnsavedChanges: Identifiable, Equatable {
    let id = UUID()
    let action: PendingDocumentAction
}

enum UnsavedChangesResolution {
    case exportAndContinue
    case discard
    case cancel
}

enum ExportKind: Equatable {
    case workingCopy
    case extractedPages
}

struct ExportReceipt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let pageCount: Int
    let kind: ExportKind

    var displayName: String {
        url.lastPathComponent
    }
}

enum PDFDropError: LocalizedError, Equatable {
    case requiresSingleFile
    case requiresLocalPDF

    var errorDescription: String? {
        switch self {
        case .requiresSingleFile:
            "Drop one PDF at a time."
        case .requiresLocalPDF:
            "Choose a local PDF file to open."
        }
    }
}

struct PendingPageDeletion: Identifiable {
    let id = UUID()
    let pageIndexes: IndexSet
    let pageCount: Int

    var selectedPageCount: Int {
        pageIndexes.count
    }

    var confirmationTitle: String {
        selectedPageCount == 1 ? "Delete Page" : "Delete \(selectedPageCount) Pages"
    }
}

struct PendingDocumentUnlock: Identifiable {
    let id: UUID
    let handle: LockedDocumentHandle
    var hasIncorrectPassword: Bool

    init(handle: LockedDocumentHandle, hasIncorrectPassword: Bool = false) {
        self.id = handle.id
        self.handle = handle
        self.hasIncorrectPassword = hasIncorrectPassword
    }
}

struct PendingBookmarkRename: Identifiable {
    let bookmark: PageBookmark

    var id: UUID { bookmark.id }
}

enum BookmarkError: LocalizedError, Equatable {
    case importedPageNotPersistent
    case pageUnavailable

    var errorDescription: String? {
        switch self {
        case .importedPageNotPersistent:
            "Pages added only to this working copy can be bookmarked after you export and reopen the PDF."
        case .pageUnavailable:
            "That bookmarked page is not available in the current document revision. Undoing its deletion may restore it."
        }
    }
}

@MainActor
struct PendingEncryptedExport: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let sourceURL: URL
    let suggestedFileName: String
    let title: String
    let kind: ExportKind
    let continuation: PendingDocumentAction?
}

enum DocumentPermissionError: LocalizedError, Equatable {
    case commentingDenied
    case documentAssemblyDenied
    case extractionDenied
    case protectedSecondaryPDFUnsupported

    var errorDescription: String? {
        switch self {
        case .commentingDenied:
            "The source PDF does not permit adding or changing annotations with this password."
        case .documentAssemblyDenied:
            "The source PDF does not permit adding, deleting, rotating, or reordering pages with this password."
        case .extractionDenied:
            "The source PDF does not permit both page assembly and content copying, which are required for extraction."
        case .protectedSecondaryPDFUnsupported:
            "Password-protected PDFs cannot be used as secondary Add Pages or Merge inputs. Open and export that PDF separately first."
        }
    }
}

@MainActor
struct PendingPDFImport: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let sourceName: String
    let sourceFingerprint: String
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: DocumentSession?
    @Published var isFileImporterPresented = false
    @Published var isPageOrganizerPresented = false
    @Published var presentedError: PresentedError?
    @Published var pendingPageDeletion: PendingPageDeletion?
    @Published var isPageDeletionConfirmationPresented = false
    @Published var pendingPDFImport: PendingPDFImport?
    @Published var pendingTextNote: PendingTextNote?
    @Published var pendingDocumentUnlock: PendingDocumentUnlock?
    @Published var pendingEncryptedExport: PendingEncryptedExport?
    @Published var pendingBookmarkRename: PendingBookmarkRename?
    @Published var pendingUnsavedChanges: PendingUnsavedChanges?
    @Published var exportReceipt: ExportReceipt?
    @Published private(set) var searchFocusRevision = 0
    @Published private(set) var windowCloseRequestRevision = 0

    let readerState: ReaderState
    let recentDocuments: RecentDocumentsStore
    let searchController: PDFSearchController
    let annotationState: AnnotationState
    let bookmarkStore: PageBookmarkStore
    let navigationHistory: NavigationHistory

    private let documentLoader: DocumentLoader
    private let pdfExporter: any PDFExporting
    private var childObservations: Set<AnyCancellable> = []
    private var editorObservation: AnyCancellable?
    var terminationReplyHandler: ((Bool) -> Void)?

    var canCommentOnActiveDocument: Bool {
        session?.securityContext.allowsCommenting == true
    }

    var canAssembleActiveDocument: Bool {
        session?.securityContext.allowsDocumentAssembly == true
    }

    var canExtractFromActiveDocument: Bool {
        guard let securityContext = session?.securityContext else {
            return false
        }
        return securityContext.allowsDocumentAssembly && securityContext.allowsContentCopying
    }

    init(
        documentLoader: DocumentLoader = DocumentLoader(),
        recentDocuments: RecentDocumentsStore = RecentDocumentsStore(),
        readerState: ReaderState = ReaderState(),
        searchController: PDFSearchController = PDFSearchController(),
        annotationState: AnnotationState = AnnotationState(),
        bookmarkStore: PageBookmarkStore = PageBookmarkStore(),
        navigationHistory: NavigationHistory = NavigationHistory(),
        pdfExporter: any PDFExporting = PDFExporter()
    ) {
        self.documentLoader = documentLoader
        self.recentDocuments = recentDocuments
        self.readerState = readerState
        self.searchController = searchController
        self.annotationState = annotationState
        self.bookmarkStore = bookmarkStore
        self.navigationHistory = navigationHistory
        self.pdfExporter = pdfExporter

        readerState.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        searchController.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        annotationState.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        bookmarkStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        navigationHistory.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
    }

    func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            requestOpenDocument(at: url)
        case .failure(let error):
            if (error as NSError).code != NSUserCancelledError {
                present(error, title: "Could Not Choose PDF")
            }
        }
    }

    func requestOpenDocument(at url: URL) {
        requestDocumentAction(.openURL(url))
    }

    private func openDocumentNow(at url: URL) {
        do {
            pendingDocumentUnlock?.handle.cancel()
            pendingDocumentUnlock = nil
            switch try documentLoader.open(url) {
            case .opened(let newSession):
                activate(newSession)
            case .passwordRequired(let lockedHandle):
                pendingDocumentUnlock = PendingDocumentUnlock(handle: lockedHandle)
            }
        } catch {
            present(error, title: "Could Not Open PDF")
        }
    }

    func submitDocumentPassword(_ password: String) {
        guard let pendingDocumentUnlock else {
            return
        }

        do {
            guard let unlockedSession = try pendingDocumentUnlock.handle.unlock(with: password) else {
                self.pendingDocumentUnlock = PendingDocumentUnlock(
                    handle: pendingDocumentUnlock.handle,
                    hasIncorrectPassword: true
                )
                return
            }
            self.pendingDocumentUnlock = nil
            activate(unlockedSession)
        } catch {
            pendingDocumentUnlock.handle.cancel()
            self.pendingDocumentUnlock = nil
            present(error, title: "Could Not Unlock PDF")
        }
    }

    func cancelDocumentUnlock() {
        pendingDocumentUnlock?.handle.cancel()
        pendingDocumentUnlock = nil
    }

    private func activate(_ newSession: DocumentSession) {
        searchController.clear()
        session?.close()
        session = newSession
        editorObservation = newSession.editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        pendingPDFImport = nil
        pendingPageDeletion = nil
        isPageDeletionConfirmationPresented = false
        isPageOrganizerPresented = false
        exportReceipt = nil
        pendingTextNote = nil
        pendingEncryptedExport = nil
        pendingBookmarkRename = nil
        annotationState.reset()
        readerState.reset(pageCount: newSession.document.pageCount)
        _ = readerState.selectPage(at: 0)
        navigationHistory.reset(initialPageID: newSession.editor.pageID(at: 0))

        do {
            try recentDocuments.record(newSession.sourceURL)
        } catch {
            present(
                error,
                title: "PDF Opened Without Recent Access",
                fallbackMessage: "The PDF is open, but PDFViewer could not add it to Recent Documents."
            )
        }
    }

    func openRecentDocument(_ document: RecentDocument) {
        do {
            let url = try recentDocuments.resolve(document)
            requestOpenDocument(at: url)
        } catch {
            present(
                error,
                title: "Recent PDF Is Unavailable",
                fallbackMessage: "The file may have moved, been deleted, or no longer be accessible."
            )
        }
    }

    func requestCloseDocument() {
        requestDocumentAction(.closeDocument)
    }

    func requestWindowClose() -> Bool {
        guard session?.editor.hasUnexportedChanges == true else {
            return true
        }

        pendingUnsavedChanges = PendingUnsavedChanges(action: .closeWindow)
        return false
    }

    func requestApplicationTermination() -> Bool {
        guard session?.editor.hasUnexportedChanges == true else {
            return true
        }

        pendingUnsavedChanges = PendingUnsavedChanges(action: .terminateApplication)
        return false
    }

    func resolveUnsavedChanges(_ resolution: UnsavedChangesResolution) {
        guard let action = pendingUnsavedChanges?.action else {
            return
        }

        pendingUnsavedChanges = nil
        switch resolution {
        case .exportAndContinue:
            presentWorkingCopyExport(continuation: action)
        case .discard:
            performDocumentAction(action)
        case .cancel:
            cancelDocumentAction(action)
        }
    }

    private func closeDocumentNow() {
        searchController.clear()
        pendingPDFImport = nil
        pendingPageDeletion = nil
        isPageDeletionConfirmationPresented = false
        isPageOrganizerPresented = false
        pendingTextNote = nil
        pendingDocumentUnlock?.handle.cancel()
        pendingDocumentUnlock = nil
        pendingEncryptedExport = nil
        pendingBookmarkRename = nil
        annotationState.reset()
        editorObservation = nil
        session?.close()
        session = nil
        readerState.reset(pageCount: 0)
        navigationHistory.reset()
    }

    func handleDroppedURLs(_ urls: [URL]) -> Bool {
        guard urls.count == 1, let url = urls.first else {
            present(PDFDropError.requiresSingleFile, title: "Could Not Open Dropped Items")
            return false
        }

        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        guard
            url.isFileURL,
            !url.hasDirectoryPath,
            !isDirectory,
            url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        else {
            present(PDFDropError.requiresLocalPDF, title: "Could Not Open Dropped Item")
            return false
        }

        requestOpenDocument(at: url)
        return true
    }

    func dismissExportReceipt() {
        exportReceipt = nil
    }

    func requestSearchFocus() {
        searchFocusRevision += 1
    }

    func goToAdjacentPage(offset: Int) {
        _ = readerState.selectPage(at: readerState.selectedPageIndex + offset)
    }

    var canNavigateBack: Bool {
        guard let editor = session?.editor else {
            return false
        }
        return navigationHistory.canGoBack(validPageIDs: Set(editor.pageIDs))
    }

    var canNavigateForward: Bool {
        guard let editor = session?.editor else {
            return false
        }
        return navigationHistory.canGoForward(validPageIDs: Set(editor.pageIDs))
    }

    var resolvedBookmarks: [ResolvedPageBookmark] {
        guard let session else {
            return []
        }
        return bookmarkStore.bookmarks(for: session.documentFingerprint).map { bookmark in
            ResolvedPageBookmark(
                bookmark: bookmark,
                pageIndex: session.editor.index(for: bookmark.pageID)
            )
        }
    }

    func navigateToPage(number: Int) {
        navigateToPageIndex(number - 1, recordsHistory: true)
    }

    func navigateFromThumbnail(to pageIndex: Int) {
        navigateToPageIndex(pageIndex, recordsHistory: true)
    }

    func navigateToOutlinePage(_ pageID: WorkingPageID) {
        navigate(to: pageID, recordsHistory: true)
    }

    func navigateToBookmark(_ bookmark: PageBookmark) {
        guard navigate(to: bookmark.pageID, recordsHistory: true) else {
            present(BookmarkError.pageUnavailable, title: "Bookmark Unavailable")
            return
        }
        readerState.selectedSidebarTab = .bookmarks
    }

    func navigateBack() {
        guard let editor = session?.editor else {
            return
        }
        guard let location = navigationHistory.goBack(validPageIDs: Set(editor.pageIDs)) else {
            return
        }
        _ = navigate(to: location.pageID, recordsHistory: false)
    }

    func navigateForward() {
        guard let editor = session?.editor else {
            return
        }
        guard let location = navigationHistory.goForward(validPageIDs: Set(editor.pageIDs)) else {
            return
        }
        _ = navigate(to: location.pageID, recordsHistory: false)
    }

    func selectNextSearchResult() {
        searchController.selectNextMatch()
        navigateToActiveSearchResult()
    }

    func selectPreviousSearchResult() {
        searchController.selectPreviousMatch()
        navigateToActiveSearchResult()
    }

    func addBookmarkForCurrentPage() {
        guard
            let session,
            let pageID = session.editor.pageID(at: readerState.selectedPageIndex)
        else {
            return
        }
        guard
            pageID.documentFingerprint == session.documentFingerprint,
            pageID.representsOriginalOccurrence
        else {
            present(BookmarkError.importedPageNotPersistent, title: "Bookmark After Export")
            return
        }

        _ = bookmarkStore.add(
            documentFingerprint: session.documentFingerprint,
            pageID: pageID,
            label: defaultBookmarkLabel(for: pageID)
        )
        readerState.selectedSidebarTab = .bookmarks
    }

    func requestRenameBookmark(_ bookmark: PageBookmark) {
        pendingBookmarkRename = PendingBookmarkRename(bookmark: bookmark)
    }

    func renamePendingBookmark(to label: String) {
        guard let pendingBookmarkRename else {
            return
        }
        bookmarkStore.rename(pendingBookmarkRename.bookmark.id, to: label)
        self.pendingBookmarkRename = nil
    }

    func cancelBookmarkRename() {
        pendingBookmarkRename = nil
    }

    func deleteBookmark(_ bookmark: PageBookmark) {
        bookmarkStore.remove(bookmark.id)
        if pendingBookmarkRename?.bookmark.id == bookmark.id {
            pendingBookmarkRename = nil
        }
    }

    @discardableResult
    private func navigate(
        to pageID: WorkingPageID,
        recordsHistory: Bool
    ) -> Bool {
        guard
            let editor = session?.editor,
            let pageIndex = editor.index(for: pageID)
        else {
            return false
        }
        navigateToPageIndex(pageIndex, recordsHistory: recordsHistory)
        return true
    }

    private func navigateToPageIndex(_ pageIndex: Int, recordsHistory: Bool) {
        guard
            let editor = session?.editor,
            let pageID = editor.pageID(at: pageIndex),
            readerState.selectPage(at: pageIndex)
        else {
            return
        }
        if recordsHistory {
            navigationHistory.record(NavigationLocation(pageID: pageID))
        }
    }

    private func navigateToActiveSearchResult() {
        guard
            let document = session?.editor.document,
            let page = searchController.activeSelection?.pages.first
        else {
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else {
            return
        }
        navigateToPageIndex(pageIndex, recordsHistory: true)
    }

    private func defaultBookmarkLabel(for pageID: WorkingPageID) -> String {
        guard let session else {
            return "Page \(readerState.selectedPageIndex + 1)"
        }
        let flattenedOutline = flatten(session.outlineNodes)
        if let exactTitle = flattenedOutline.first(where: { $0.pageID == pageID })?.title {
            return exactTitle
        }
        let nearestTitle = flattenedOutline
            .compactMap { node -> (Int, String)? in
                guard
                    let outlinePageID = node.pageID,
                    outlinePageID.documentFingerprint == pageID.documentFingerprint,
                    outlinePageID.originalPageIndex <= pageID.originalPageIndex
                else {
                    return nil
                }
                return (outlinePageID.originalPageIndex, node.title)
            }
            .max { $0.0 < $1.0 }?.1
        return nearestTitle ?? "Page \(readerState.selectedPageIndex + 1)"
    }

    private func flatten(_ nodes: [DocumentOutlineNode]) -> [DocumentOutlineNode] {
        nodes.flatMap { node in
            [node] + flatten(node.children)
        }
    }

    func setDisplayMode(_ displayMode: ReaderDisplayMode) {
        guard session != nil else {
            return
        }
        readerState.displayMode = displayMode
    }

    func startSearch(for query: String) {
        guard let document = session?.editor.document else {
            return
        }
        searchController.startSearch(for: query, in: document)
    }

    func clearSearch() {
        searchController.clear()
    }

    func selectPageIndexes(_ indexes: Set<Int>) {
        _ = readerState.selectPages(at: indexes)
    }

    func presentPageOrganizer() {
        annotationState.end()
        pendingTextNote = nil
        isPageOrganizerPresented = true
    }

    func toggleAnnotationMode() {
        if annotationState.isActive {
            annotationState.end()
        } else {
            guard requireCommentingPermission() else {
                return
            }
            isPageOrganizerPresented = false
            annotationState.begin()
        }
    }

    func endAnnotationMode() {
        annotationState.end()
        pendingTextNote = nil
    }

    func cancelAnnotationInteraction() {
        guard annotationState.isActive else {
            return
        }
        annotationState.selectedTool = .select
        annotationState.clearTransientSelection()
    }

    func selectAnnotationTool(_ tool: AnnotationTool) {
        guard annotationState.isActive, requireCommentingPermission() else {
            return
        }
        annotationState.selectedTool = tool

        guard tool.requiresTextSelection, annotationState.hasTextSelection else {
            return
        }
        applyTextMarkup(tool: tool)
    }

    func updateTextMarkupRegions(_ regions: [TextMarkupRegion]) {
        annotationState.updateTextMarkupRegions(regions)
    }

    func commitSelectedTextMarkup() {
        guard annotationState.isActive else {
            return
        }
        applyTextMarkup(tool: annotationState.selectedTool)
    }

    func selectAnnotation(_ selection: SelectedAnnotation?) {
        annotationState.selectAnnotation(selection)
        guard let selection, !selection.isOwnedByPDFViewer else {
            return
        }
        present(
            PDFDocumentEditorError.annotationIsReadOnly,
            title: "Read-Only Annotation"
        )
    }

    func addInkStroke(_ stroke: InkStroke) {
        guard requireCommentingPermission() else {
            return
        }
        performAnnotationOperation { editor in
            try editor.addInkStroke(
                stroke,
                color: annotationState.selectedColor,
                lineWidth: annotationState.selectedLineWidth
            )
        }
    }

    func requestTextNote(at placement: AnnotationPlacement) {
        guard requireCommentingPermission() else {
            return
        }
        pendingTextNote = PendingTextNote(
            pageIndex: placement.pageIndex,
            point: placement.point,
            annotationIdentifier: nil,
            initialText: ""
        )
    }

    func requestEditSelectedTextNote() {
        guard requireCommentingPermission() else {
            return
        }
        guard
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            selection.kind == .textNote,
            let identifier = selection.identifier,
            let contents = editor.textNoteContents(
                pageIndex: selection.pageIndex,
                identifier: identifier
            )
        else {
            return
        }

        pendingTextNote = PendingTextNote(
            pageIndex: selection.pageIndex,
            point: nil,
            annotationIdentifier: identifier,
            initialText: contents
        )
    }

    func submitPendingTextNote(contents: String) {
        guard requireCommentingPermission() else {
            pendingTextNote = nil
            return
        }
        guard let pendingTextNote, let editor = session?.editor else {
            return
        }
        self.pendingTextNote = nil

        let trimmedContents = String(contents.prefix(10_000))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContents.isEmpty else {
            return
        }

        do {
            if let identifier = pendingTextNote.annotationIdentifier {
                try editor.updateTextNote(
                    pageIndex: pendingTextNote.pageIndex,
                    identifier: identifier,
                    contents: trimmedContents
                )
                synchronizeAfterDocumentMutation()
            } else if let point = pendingTextNote.point {
                let identifier = try editor.addTextNote(
                    pageIndex: pendingTextNote.pageIndex,
                    point: point,
                    contents: trimmedContents,
                    color: annotationState.selectedColor
                )
                synchronizeAfterDocumentMutation()
                annotationState.selectAnnotation(
                    SelectedAnnotation(
                        pageIndex: pendingTextNote.pageIndex,
                        identifier: identifier,
                        kind: .textNote
                    )
                )
                annotationState.selectedTool = .select
            }
        } catch {
            present(error, title: "Could Not Change Annotation")
        }
    }

    func cancelPendingTextNote() {
        pendingTextNote = nil
    }

    func setAnnotationColor(_ color: AnnotationPaletteColor) {
        annotationState.selectedColor = color
        guard requireCommentingPermission() else {
            return
        }
        guard
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            let identifier = selection.identifier
        else {
            return
        }

        do {
            try editor.updateAnnotationColor(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                color: color
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Restyle Annotation")
        }
    }

    func setAnnotationLineWidth(_ lineWidth: AnnotationLineWidth) {
        annotationState.selectedLineWidth = lineWidth
        guard requireCommentingPermission() else {
            return
        }
        guard
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            selection.kind == .freehand,
            let identifier = selection.identifier
        else {
            return
        }

        do {
            try editor.updateInkLineWidth(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                lineWidth: lineWidth
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Restyle Annotation")
        }
    }

    func deleteSelectedAnnotation() {
        guard requireCommentingPermission() else {
            return
        }
        guard
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            let identifier = selection.identifier
        else {
            return
        }

        do {
            try editor.deleteAnnotation(
                pageIndex: selection.pageIndex,
                identifier: identifier
            )
            synchronizeAfterDocumentMutation()
            annotationState.clearTransientSelection()
        } catch {
            present(error, title: "Could Not Delete Annotation")
        }
    }

    private func applyTextMarkup(tool: AnnotationTool) {
        let kind: TextMarkupKind
        switch tool {
        case .highlight:
            kind = .highlight
        case .underline:
            kind = .underline
        case .strikethrough:
            kind = .strikethrough
        case .select, .freehand, .textNote:
            return
        }

        let regions = annotationState.textMarkupRegions
        guard !regions.isEmpty else {
            return
        }
        performAnnotationOperation { editor in
            try editor.addTextMarkup(
                kind: kind,
                regions: regions,
                color: annotationState.selectedColor
            )
        }
        annotationState.clearTransientSelection()
    }

    private func performAnnotationOperation(
        _ operation: (PDFDocumentEditor) throws -> Void
    ) {
        guard requireCommentingPermission(), let editor = session?.editor else {
            return
        }

        do {
            try operation(editor)
            if editor.isDirty {
                readerState.markDocumentDirty()
            } else {
                readerState.markDocumentClean()
            }
        } catch {
            present(error, title: "Could Not Change Annotation")
        }
    }

    private func synchronizeAfterDocumentMutation() {
        guard let editor = session?.editor else {
            return
        }
        readerState.synchronize(
            pageCount: editor.document.pageCount,
            preferredPageIndex: readerState.selectedPageIndex,
            isDirty: editor.isDirty
        )
        searchController.clear()
    }

    func rotateSelectedPages(clockwise: Bool) {
        let selectedPageIndexes = readerState.selectedPageIndexSet
        guard !selectedPageIndexes.isEmpty else {
            present(PDFDocumentEditorError.invalidPageSelection, title: "Could Not Change Pages")
            return
        }

        performPageOperation(
            preferredPageIndex: readerState.selectedPageIndex,
            selectedPageIndexes: readerState.selectedPageIndexes
        ) { editor in
            try editor.rotatePages(at: selectedPageIndexes, clockwise: clockwise)
        }
    }

    func moveSelectedPage(up: Bool) {
        guard readerState.selectedPageIndexes.count == 1 else {
            return
        }

        let selectedPageIndex = readerState.selectedPageIndex
        guard
            selectedPageIndex >= 0,
            selectedPageIndex < readerState.pageCount,
            (up && selectedPageIndex > 0) || (!up && selectedPageIndex < readerState.pageCount - 1)
        else {
            return
        }

        let destination = up ? selectedPageIndex - 1 : selectedPageIndex + 2
        let newSelectedPageIndex = up ? selectedPageIndex - 1 : selectedPageIndex + 1
        performPageOperation(
            preferredPageIndex: newSelectedPageIndex,
            selectedPageIndexes: [newSelectedPageIndex]
        ) { editor in
            try editor.movePages(
                at: IndexSet(integer: selectedPageIndex),
                to: destination
            )
        }
    }

    func moveSelectedPagesToBeginning() {
        moveSelectedPages(to: 0)
    }

    func moveSelectedPagesToEnd() {
        guard let editor = session?.editor else {
            return
        }

        moveSelectedPages(to: editor.document.pageCount)
    }

    func moveSelectedPages(to destination: Int) {
        guard let editor = session?.editor else {
            return
        }

        let selectedPageIndexes = readerState.selectedPageIndexSet
        guard
            !selectedPageIndexes.isEmpty,
            (0...editor.document.pageCount).contains(destination)
        else {
            return
        }

        if
            let firstSelectedPageIndex = selectedPageIndexes.first,
            let lastSelectedPageIndex = selectedPageIndexes.last,
            (firstSelectedPageIndex...(lastSelectedPageIndex + 1)).contains(destination)
        {
            return
        }

        let removedBeforeDestination = selectedPageIndexes.filter { $0 < destination }.count
        let firstMovedPageIndex = destination - removedBeforeDestination
        let movedPageIndexes = Set(
            firstMovedPageIndex..<(firstMovedPageIndex + selectedPageIndexes.count)
        )

        if selectedPageIndexes == IndexSet(movedPageIndexes) {
            return
        }

        performPageOperation(
            preferredPageIndex: firstMovedPageIndex,
            selectedPageIndexes: movedPageIndexes
        ) { editor in
            try editor.movePages(
                at: selectedPageIndexes,
                to: destination
            )
        }
    }

    func requestDeleteSelectedPages() {
        guard requireDocumentAssemblyPermission() else {
            return
        }
        guard let editor = session?.editor else {
            return
        }

        let selectedPageIndexes = readerState.selectedPageIndexSet
        guard !selectedPageIndexes.isEmpty else {
            present(PDFDocumentEditorError.invalidPageSelection, title: "Could Not Delete Pages")
            return
        }

        guard selectedPageIndexes.count < editor.document.pageCount else {
            present(
                PDFDocumentEditorError.cannotDeleteOnlyPage,
                title: "Cannot Delete Every Page"
            )
            return
        }

        pendingPageDeletion = PendingPageDeletion(
            pageIndexes: selectedPageIndexes,
            pageCount: editor.document.pageCount
        )
        isPageDeletionConfirmationPresented = true
    }

    func confirmPendingPageDeletion() {
        guard let pendingPageDeletion else {
            return
        }

        self.pendingPageDeletion = nil
        isPageDeletionConfirmationPresented = false

        let remainingPageCount = pendingPageDeletion.pageCount - pendingPageDeletion.selectedPageCount
        let preferredPageIndex = min(
            pendingPageDeletion.pageIndexes.first ?? 0,
            max(0, remainingPageCount - 1)
        )
        performPageOperation(
            preferredPageIndex: preferredPageIndex,
            selectedPageIndexes: [preferredPageIndex]
        ) { editor in
            try editor.deletePages(at: pendingPageDeletion.pageIndexes)
        }
    }

    func cancelPendingPageDeletion() {
        pendingPageDeletion = nil
        isPageDeletionConfirmationPresented = false
    }

    func undoPageOperation() {
        performPageOperation(
            preferredPageIndex: readerState.selectedPageIndex,
            requiresDocumentAssembly: false
        ) { editor in
            try editor.undo()
        }
    }

    func redoPageOperation() {
        performPageOperation(
            preferredPageIndex: readerState.selectedPageIndex,
            requiresDocumentAssembly: false
        ) { editor in
            try editor.redo()
        }
    }

    func requestAddPages() {
        guard requireDocumentAssemblyPermission() else {
            return
        }
        choosePDFForImport(purpose: .addPages)
    }

    func requestMergePDF() {
        guard requireDocumentAssemblyPermission() else {
            return
        }
        choosePDFForImport(purpose: .merge)
    }

    func addPendingImportedPages(selectedPageIndexes: Set<Int>) {
        guard requireDocumentAssemblyPermission() else {
            return
        }
        guard let pendingPDFImport else {
            return
        }

        let indexes = IndexSet(selectedPageIndexes)
        guard !indexes.isEmpty else {
            present(PDFDocumentEditorError.invalidPageSelection, title: "Could Not Add Pages")
            return
        }

        guard let editor = session?.editor else {
            return
        }

        let insertionIndex = min(readerState.selectedPageIndex + 1, editor.document.pageCount)
        let insertedPageIndexes = Set(
            insertionIndex..<(insertionIndex + indexes.count)
        )
        self.pendingPDFImport = nil
        performPageOperation(
            preferredPageIndex: insertionIndex,
            selectedPageIndexes: insertedPageIndexes
        ) { editor in
            try editor.insertPages(
                from: pendingPDFImport.document,
                selecting: indexes,
                sourceFingerprint: pendingPDFImport.sourceFingerprint,
                at: insertionIndex
            )
        }
    }

    func cancelPendingPDFImport() {
        pendingPDFImport = nil
    }

    func extractSelectedPages() {
        guard canExtractFromActiveDocument else {
            present(DocumentPermissionError.extractionDenied, title: "Extraction Not Permitted")
            return
        }
        guard let session else {
            return
        }

        do {
            let extractedDocument = try session.editor.extractPages(
                at: readerState.selectedPageIndexSet
            )
            presentExportPanel(
                document: extractedDocument,
                sourceURL: session.sourceURL,
                suggestedFileName: suggestedOutputFileName(
                    for: session.sourceURL,
                    suffix: "Extracted Pages"
                ),
                title: "Extract Pages",
                kind: .extractedPages,
                continuation: nil
            )
        } catch {
            present(error, title: "Could Not Extract Pages")
        }
    }

    func exportWorkingCopy() {
        presentWorkingCopyExport(continuation: nil)
    }

    private func presentWorkingCopyExport(continuation: PendingDocumentAction?) {
        guard let session else {
            if let continuation {
                cancelDocumentAction(continuation)
            }
            return
        }

        presentExportPanel(
            document: session.editor.document,
            sourceURL: session.sourceURL,
            suggestedFileName: suggestedOutputFileName(
                for: session.sourceURL,
                suffix: "Edited"
            ),
            title: "Export PDF",
            kind: .workingCopy,
            continuation: continuation
        )
    }

    private func choosePDFForImport(purpose: PDFImportPurpose) {
        let panel = NSOpenPanel()
        panel.title = purpose.panelTitle
        panel.message = purpose.panelMessage
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else {
                return
            }
            self?.loadImportedPDF(at: url, purpose: purpose)
        }
    }

    private func loadImportedPDF(at url: URL, purpose: PDFImportPurpose) {
        do {
            let result = try documentLoader.open(url)
            guard case .opened(let importedSession) = result else {
                if case .passwordRequired(let handle) = result {
                    handle.cancel()
                }
                throw DocumentPermissionError.protectedSecondaryPDFUnsupported
            }
            defer { importedSession.close() }
            let importedDocument = try independentCopy(of: importedSession.document)

            switch purpose {
            case .addPages:
                pendingPDFImport = PendingPDFImport(
                    document: importedDocument,
                    sourceName: url.lastPathComponent,
                    sourceFingerprint: importedSession.documentFingerprint
                )
            case .merge:
                merge(
                    importedDocument,
                    sourceFingerprint: importedSession.documentFingerprint
                )
            }
        } catch {
            present(error, title: purpose.failureTitle)
        }
    }

    private func merge(
        _ importedDocument: PDFDocument,
        sourceFingerprint: String
    ) {
        guard let editor = session?.editor else {
            return
        }

        let insertionIndex = min(readerState.selectedPageIndex + 1, editor.document.pageCount)
        let insertedPageIndexes = Set(
            insertionIndex..<(insertionIndex + importedDocument.pageCount)
        )
        performPageOperation(
            preferredPageIndex: insertionIndex,
            selectedPageIndexes: insertedPageIndexes
        ) { editor in
            try editor.insertPages(
                from: importedDocument,
                sourceFingerprint: sourceFingerprint,
                at: insertionIndex
            )
        }
    }

    private func presentExportPanel(
        document: PDFDocument,
        sourceURL: URL,
        suggestedFileName: String,
        title: String,
        kind: ExportKind,
        continuation: PendingDocumentAction?,
        encryptedExportConfirmed: Bool = false
    ) {
        if session?.securityContext.isEncrypted == true, !encryptedExportConfirmed {
            pendingEncryptedExport = PendingEncryptedExport(
                document: document,
                sourceURL: sourceURL,
                suggestedFileName: suggestedFileName,
                title: title,
                kind: kind,
                continuation: continuation
            )
            return
        }

        let panel = NSSavePanel()
        panel.title = title
        panel.message = "Choose a new PDF output. The original document will remain unchanged."
        panel.allowedContentTypes = [.pdf]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedFileName
        panel.directoryURL = sourceURL.deletingLastPathComponent()

        panel.begin { [weak self] response in
            guard let self else {
                return
            }
            guard response == .OK else {
                if let continuation {
                    self.cancelDocumentAction(continuation)
                }
                return
            }
            guard let destinationURL = panel.url else {
                if let continuation {
                    self.cancelDocumentAction(continuation)
                }
                self.present(PDFExportError.invalidDestination, title: "Could Not Export PDF")
                return
            }
            self.performExport(
                document: document,
                sourceURL: sourceURL,
                destinationURL: destinationURL,
                kind: kind,
                continuation: continuation
            )
        }
    }

    func confirmEncryptedExport() {
        guard let pendingEncryptedExport else {
            return
        }
        self.pendingEncryptedExport = nil
        presentExportPanel(
            document: pendingEncryptedExport.document,
            sourceURL: pendingEncryptedExport.sourceURL,
            suggestedFileName: pendingEncryptedExport.suggestedFileName,
            title: pendingEncryptedExport.title,
            kind: pendingEncryptedExport.kind,
            continuation: pendingEncryptedExport.continuation,
            encryptedExportConfirmed: true
        )
    }

    func cancelEncryptedExport() {
        guard let pendingEncryptedExport else {
            return
        }
        self.pendingEncryptedExport = nil
        if let continuation = pendingEncryptedExport.continuation {
            cancelDocumentAction(continuation)
        }
    }

    func performExport(
        document: PDFDocument,
        sourceURL: URL,
        destinationURL: URL,
        kind: ExportKind,
        continuation: PendingDocumentAction? = nil
    ) {
        do {
            let securityContext = session?.securityContext
            let outputProtection: PDFOutputProtection = securityContext?.isEncrypted == true
                ? .reuseSessionPassword
                : .none
            let result = try pdfExporter.export(
                document: document,
                sourceURL: sourceURL,
                to: destinationURL,
                protection: outputProtection,
                sessionPassword: outputProtection == .reuseSessionPassword
                    ? session?.sessionPassword
                    : nil,
                accessPermissions: securityContext?.accessPermissions ?? document.accessPermissions
            )

            if
                kind == .workingCopy,
                let editor = session?.editor,
                editor.document === document
            {
                editor.markCurrentRevisionExported()
            }

            exportReceipt = ExportReceipt(
                url: result.url,
                pageCount: result.pageCount,
                kind: kind
            )

            if let continuation {
                performDocumentAction(continuation)
            }
        } catch {
            if let continuation {
                cancelDocumentAction(continuation)
            }
            present(error, title: "Could Not Export PDF")
        }
    }

    private func independentCopy(of document: PDFDocument) throws -> PDFDocument {
        guard
            let data = document.dataRepresentation(),
            !data.isEmpty,
            let copy = PDFDocument(data: data),
            copy.pageCount > 0
        else {
            throw PDFDocumentEditorError.couldNotCopyDocument
        }

        return copy
    }

    private func suggestedOutputFileName(for sourceURL: URL, suffix: String) -> String {
        let baseName = sourceURL.deletingPathExtension().lastPathComponent
        let safeBaseName = baseName.isEmpty ? "PDF" : baseName
        return "\(safeBaseName) \(suffix).pdf"
    }

    private func requestDocumentAction(_ action: PendingDocumentAction) {
        guard session?.editor.hasUnexportedChanges == true else {
            performDocumentAction(action)
            return
        }

        pendingUnsavedChanges = PendingUnsavedChanges(action: action)
    }

    private func performDocumentAction(_ action: PendingDocumentAction) {
        switch action {
        case .closeDocument:
            closeDocumentNow()
        case .closeWindow:
            windowCloseRequestRevision += 1
        case .openURL(let url):
            openDocumentNow(at: url)
        case .terminateApplication:
            terminationReplyHandler?(true)
        }
    }

    private func cancelDocumentAction(_ action: PendingDocumentAction) {
        if action == .terminateApplication {
            terminationReplyHandler?(false)
        }
    }

    private func present(
        _ error: any Error,
        title: String,
        fallbackMessage: String = "Please choose a different local PDF and try again."
    ) {
        let message = (error as? LocalizedError)?.errorDescription ?? fallbackMessage
        presentedError = PresentedError(title: title, message: message)
    }

    private func performPageOperation(
        preferredPageIndex: Int,
        selectedPageIndexes: Set<Int>? = nil,
        requiresDocumentAssembly: Bool = true,
        _ operation: (PDFDocumentEditor) throws -> Void
    ) {
        if requiresDocumentAssembly, !requireDocumentAssemblyPermission() {
            return
        }
        guard let editor = session?.editor else {
            return
        }

        do {
            try operation(editor)
            readerState.synchronize(
                pageCount: editor.document.pageCount,
                preferredPageIndex: preferredPageIndex,
                isDirty: editor.isDirty
            )
            if let selectedPageIndexes {
                _ = readerState.selectPages(
                    at: selectedPageIndexes,
                    preferredPageIndex: preferredPageIndex
                )
            }
            searchController.clear()
            annotationState.clearTransientSelection()
        } catch {
            present(error, title: "Could Not Change Pages")
        }
    }

    private func requireCommentingPermission() -> Bool {
        guard canCommentOnActiveDocument else {
            present(DocumentPermissionError.commentingDenied, title: "Annotations Not Permitted")
            return false
        }
        return true
    }

    private func requireDocumentAssemblyPermission() -> Bool {
        guard canAssembleActiveDocument else {
            present(DocumentPermissionError.documentAssemblyDenied, title: "Page Changes Not Permitted")
            return false
        }
        return true
    }

    private enum PDFImportPurpose {
        case addPages
        case merge

        var panelTitle: String {
            switch self {
            case .addPages:
                "Add Pages From PDF"
            case .merge:
                "Merge PDF"
            }
        }

        var panelMessage: String {
            switch self {
            case .addPages:
                "Choose a local PDF, then select the pages to add to the working copy."
            case .merge:
                "Choose a local PDF to append after the current page in the working copy."
            }
        }

        var failureTitle: String {
            switch self {
            case .addPages:
                "Could Not Add Pages"
            case .merge:
                "Could Not Merge PDF"
            }
        }
    }
}
