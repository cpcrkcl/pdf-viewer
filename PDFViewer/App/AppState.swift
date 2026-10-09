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
    case flattenedForm
    case createdFromImages
    case convertedImages
    case convertedText
}

struct ExportReceipt: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    let pageCount: Int
    let kind: ExportKind
    let fileSizeInBytes: Int

    var displayName: String {
        url.lastPathComponent
    }

    var formattedFileSize: String? {
        guard fileSizeInBytes > 0 else {
            return nil
        }
        return ByteCountFormatter.string(
            fromByteCount: Int64(fileSizeInBytes),
            countStyle: .file
        )
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

struct PendingPermanentRedaction: Identifiable {
    let id = UUID()
    let regions: [PDFRedactionRegion]
    let reasonLabel: String?

    var regionCount: Int { regions.count }
    var pageCount: Int { Set(regions.map(\.pageIndex)).count }
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
    let usesActiveSessionProtection: Bool
}

enum DocumentPermissionError: LocalizedError, Equatable {
    case commentingDenied
    case documentAssemblyDenied
    case extractionDenied
    case printingDenied
    case formFieldEntryDenied
    case redactionDenied
    case documentProcessingDenied
    case conversionDenied
    case protectedSecondaryPDFUnsupported

    var errorDescription: String? {
        switch self {
        case .commentingDenied:
            "The source PDF does not permit adding or changing annotations with this password."
        case .documentAssemblyDenied:
            "The source PDF does not permit adding, deleting, rotating, or reordering pages with this password."
        case .extractionDenied:
            "The source PDF does not permit both page assembly and content copying, which are required for extraction."
        case .printingDenied:
            "The source PDF does not permit printing with this password."
        case .formFieldEntryDenied:
            "The source PDF does not permit filling form fields with this password."
        case .redactionDenied:
            "The source PDF does not permit changing page content with this password."
        case .documentProcessingDenied:
            "The source PDF does not permit replacing pages with locally processed versions using this password."
        case .conversionDenied:
            "The source PDF does not permit copying page content for conversion with this password."
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
struct PendingPDFComparison: Identifiable {
    let id = UUID()
    let document: PDFDocument
    let displayName: String
}

@MainActor
final class AppState: ObservableObject {
    @Published private(set) var session: DocumentSession?
    @Published var isPageOrganizerPresented = false
    @Published var presentedError: PresentedError?
    @Published var pendingPageDeletion: PendingPageDeletion?
    @Published var pendingPermanentRedaction: PendingPermanentRedaction?
    @Published var isPageDeletionConfirmationPresented = false
    @Published var pendingPDFImport: PendingPDFImport?
    @Published var pendingTextNote: PendingTextNote?
    @Published var pendingDocumentUnlock: PendingDocumentUnlock?
    @Published var pendingEncryptedExport: PendingEncryptedExport?
    @Published var pendingBookmarkRename: PendingBookmarkRename?
    @Published var pendingUnsavedChanges: PendingUnsavedChanges?
    @Published var exportReceipt: ExportReceipt?
    @Published var isSignatureLibraryPresented = false
    @Published var isStampLibraryPresented = false
    @Published var isFormEditorPresented = false
    @Published var isLocalProcessingPresented = false
    @Published var isConversionPresented = false
    @Published var pendingPDFComparison: PendingPDFComparison?
    private var comparisonLoadingGeneration = UUID()
    @Published private(set) var isLocalProcessing = false
    @Published private(set) var isLoadingDocument = false
    @Published private(set) var localProcessingProgress: PDFOCRProgress?
    @Published private(set) var searchFocusRevision = 0
    @Published private(set) var windowCloseRequestRevision = 0

    let readerState: ReaderState
    let recentDocuments: RecentDocumentsStore
    let searchController: PDFSearchController
    let annotationState: AnnotationState
    let bookmarkStore: PageBookmarkStore
    let navigationHistory: NavigationHistory
    let signatureLibrary: SignatureLibrary
    let stampLibrary: SignatureLibrary
    let redactionState: RedactionState
    let officeConversionManager: OfficeConversionManager

    private let documentLoader: DocumentLoader
    private let pdfExporter: any PDFExporting
    private let loadDocumentsAsynchronously: Bool
    private var childObservations: Set<AnyCancellable> = []
    private var editorObservation: AnyCancellable?
    private var documentLoadingTask: Task<Void, Never>?
    private var documentLoadingGeneration = UUID()
    private var localProcessingTask: Task<Void, Never>?
    private var localProcessingGeneration = UUID()
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

    var canPrintActiveDocument: Bool {
        session?.securityContext.allowsPrinting == true
    }

    var canFillFormsInActiveDocument: Bool {
        guard
            session?.securityContext.allowsFormFieldEntry == true,
            let editor = session?.editor
        else {
            return false
        }
        return !editor.formFields.isEmpty
    }

    var canRedactActiveDocument: Bool {
        session?.securityContext.allowsDocumentChanges == true
    }

    var canProcessActiveDocument: Bool {
        session?.securityContext.allowsDocumentChanges == true
    }

    var canConvertActiveDocument: Bool {
        session?.securityContext.allowsContentCopying == true
    }

    init(
        documentLoader: DocumentLoader = DocumentLoader(),
        recentDocuments: RecentDocumentsStore = RecentDocumentsStore(),
        readerState: ReaderState = ReaderState(),
        searchController: PDFSearchController = PDFSearchController(),
        annotationState: AnnotationState = AnnotationState(),
        bookmarkStore: PageBookmarkStore = PageBookmarkStore(),
        navigationHistory: NavigationHistory = NavigationHistory(),
        signatureLibrary: SignatureLibrary = SignatureLibrary(),
        stampLibrary: SignatureLibrary = SignatureLibrary(libraryFolder: "Stamps"),
        redactionState: RedactionState = RedactionState(),
        officeConversionManager: OfficeConversionManager = OfficeConversionManager(),
        pdfExporter: any PDFExporting = PDFExporter(),
        loadDocumentsAsynchronously: Bool = true
    ) {
        self.documentLoader = documentLoader
        self.recentDocuments = recentDocuments
        self.readerState = readerState
        self.searchController = searchController
        self.annotationState = annotationState
        self.bookmarkStore = bookmarkStore
        self.navigationHistory = navigationHistory
        self.signatureLibrary = signatureLibrary
        self.stampLibrary = stampLibrary
        self.redactionState = redactionState
        self.officeConversionManager = officeConversionManager
        self.pdfExporter = pdfExporter
        self.loadDocumentsAsynchronously = loadDocumentsAsynchronously

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
        signatureLibrary.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        stampLibrary.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservations)
        redactionState.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &childObservations)
        officeConversionManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &childObservations)
    }

    func presentOpenPDFPanel() {
        presentOpenPanel(
            title: "Open PDF",
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            handle: handleFileImport
        )
    }

    func presentComparePDFPanel() {
        presentOpenPanel(
            title: "Compare PDF",
            message: "Choose a second PDF to compare with the open document.",
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false,
            handle: handleCompareImport
        )
    }

    func handleFileImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            requestOpenDocument(at: url)
        case .failure(let error):
            let nsError = error as NSError
            let isUserCancellation = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSUserCancelledError
            if !isUserCancellation {
                present(error, title: "Could Not Choose PDF")
            }
        }
    }

    func handleCompareImport(_ result: Result<[URL], any Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let generation = UUID()
        comparisonLoadingGeneration = generation
        let primaryDocument = session?.document
        Task { [weak self] in
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let accessed = url.startAccessingSecurityScopedResource()
                    defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                    let values = try url.resourceValues(forKeys: [
                        .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                    ])
                    guard
                        url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame,
                        values.isRegularFile == true,
                        values.isSymbolicLink != true,
                        let size = values.fileSize,
                        size > 4,
                        size <= 1_073_741_824
                    else { throw DocumentLoadingError.fileUnavailable }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                guard
                    let self,
                    self.comparisonLoadingGeneration == generation,
                    self.session?.document === primaryDocument,
                    let document = PDFDocument(data: data),
                    document.pageCount > 0
                else { return }
                self.pendingPDFComparison = PendingPDFComparison(
                    document: document,
                    displayName: url.lastPathComponent
                )
            } catch {
                guard let self, self.comparisonLoadingGeneration == generation else { return }
                self.present(error, title: "Could Not Open Comparison PDF")
            }
        }
    }

    func requestOpenDocument(at url: URL) {
        requestDocumentAction(.openURL(url))
    }

    func cancelDocumentOpen() {
        cancelDocumentLoading()
    }

    private func openDocumentNow(at url: URL) {
        cancelDocumentLoading()
        pendingDocumentUnlock?.handle.cancel()
        pendingDocumentUnlock = nil

        guard loadDocumentsAsynchronously else {
            openDocumentSynchronously(at: url)
            return
        }

        let generation = UUID()
        documentLoadingGeneration = generation
        isLoadingDocument = true
        documentLoadingTask = Task { [weak self] in
            guard let self else {
                return
            }
            do {
                let result = try await documentLoader.openAsync(url)
                guard
                    !Task.isCancelled,
                    documentLoadingGeneration == generation
                else {
                    release(result)
                    return
                }
                finishDocumentLoading(generation: generation)
                handleDocumentOpenResult(result)
            } catch is CancellationError {
                finishDocumentLoading(generation: generation)
            } catch {
                guard documentLoadingGeneration == generation else {
                    return
                }
                finishDocumentLoading(generation: generation)
                present(error, title: "Could Not Open PDF")
            }
        }
    }

    private func openDocumentSynchronously(at url: URL) {
        do {
            handleDocumentOpenResult(try documentLoader.open(url))
        } catch {
            present(error, title: "Could Not Open PDF")
        }
    }

    private func handleDocumentOpenResult(_ result: DocumentOpenResult) {
        switch result {
        case .opened(let newSession):
            activate(newSession)
        case .passwordRequired(let lockedHandle):
            pendingDocumentUnlock = PendingDocumentUnlock(handle: lockedHandle)
        }
    }

    private func finishDocumentLoading(generation: UUID) {
        guard documentLoadingGeneration == generation else {
            return
        }
        isLoadingDocument = false
        documentLoadingTask = nil
    }

    private func cancelDocumentLoading() {
        documentLoadingGeneration = UUID()
        documentLoadingTask?.cancel()
        documentLoadingTask = nil
        isLoadingDocument = false
    }

    private func release(_ result: DocumentOpenResult) {
        switch result {
        case .opened(let session):
            session.close()
        case .passwordRequired(let handle):
            handle.cancel()
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
        cancelLocalProcessing()
        searchController.clear()
        session?.close()
        session = newSession
        AppDiagnostics.record(.documentOpened)
        editorObservation = newSession.editor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        pendingPDFImport = nil
        pendingPageDeletion = nil
        pendingPermanentRedaction = nil
        isPageDeletionConfirmationPresented = false
        isPageOrganizerPresented = false
        exportReceipt = nil
        pendingTextNote = nil
        pendingEncryptedExport = nil
        pendingBookmarkRename = nil
        isSignatureLibraryPresented = false
        isStampLibraryPresented = false
        pendingPDFComparison = nil
        comparisonLoadingGeneration = UUID()
        isFormEditorPresented = false
        isConversionPresented = false
        annotationState.reset()
        redactionState.end()
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
        guard let url = resolveRecentDocumentURL(document) else {
            return
        }
        requestOpenDocument(at: url)
    }

    func resolveRecentDocumentURL(_ document: RecentDocument) -> URL? {
        do {
            return try recentDocuments.resolve(document)
        } catch {
            present(
                error,
                title: "Recent PDF Is Unavailable",
                fallbackMessage: "The file may have moved, been deleted, or no longer be accessible."
            )
            return nil
        }
    }

    func requestCloseDocument() {
        requestDocumentAction(.closeDocument)
    }

    func requestWindowClose() -> Bool {
        if isLoadingDocument {
            cancelDocumentLoading()
        }
        guard session?.editor.hasUnexportedChanges == true else {
            return true
        }

        pendingUnsavedChanges = PendingUnsavedChanges(action: .closeWindow)
        return false
    }

    func requestApplicationTermination() -> Bool {
        if isLoadingDocument {
            cancelDocumentLoading()
        }
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
        let hadOpenDocument = session != nil
        cancelDocumentLoading()
        cancelLocalProcessing()
        searchController.clear()
        pendingPDFImport = nil
        pendingPageDeletion = nil
        pendingPermanentRedaction = nil
        isPageDeletionConfirmationPresented = false
        isPageOrganizerPresented = false
        pendingTextNote = nil
        pendingDocumentUnlock?.handle.cancel()
        pendingDocumentUnlock = nil
        pendingEncryptedExport = nil
        pendingBookmarkRename = nil
        isSignatureLibraryPresented = false
        isStampLibraryPresented = false
        pendingPDFComparison = nil
        comparisonLoadingGeneration = UUID()
        isFormEditorPresented = false
        isConversionPresented = false
        annotationState.reset()
        redactionState.end()
        editorObservation = nil
        session?.close()
        session = nil
        if hadOpenDocument {
            AppDiagnostics.record(.documentClosed)
        }
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

    /// Prints the in-memory working copy (including pending page edits and
    /// annotations) through the reader's native print panel. The source PDF is
    /// never written and the document revision never changes.
    func printWorkingDocument() {
        guard session != nil else {
            return
        }
        guard canPrintActiveDocument else {
            present(DocumentPermissionError.printingDenied, title: "Printing Not Permitted")
            return
        }
        readerState.requestPrint()
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

    func updateSearchOptions(caseSensitive: Bool, wholeWords: Bool) {
        searchController.options = PDFSearchOptions(
            isCaseSensitive: caseSensitive,
            matchesWholeWords: wholeWords
        )
        if !searchController.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            startSearch(for: searchController.query)
        }
    }

    func selectSearchResult(at index: Int) {
        searchController.selectMatch(at: index)
    }

    func markSearchMatchesForRedaction(_ indexes: Set<Int>) {
        guard
            requireRedactionPermission(),
            let document = session?.editor.document,
            !indexes.isEmpty
        else { return }

        let regions = searchController.redactionRegions(
            forMatchIndexes: indexes,
            in: document
        )
        guard !regions.isEmpty else {
            present(PDFRedactionError.noRegions, title: "No Search Matches Selected")
            return
        }

        annotationState.end()
        pendingTextNote = nil
        isPageOrganizerPresented = false
        isFormEditorPresented = false
        if !redactionState.isActive { redactionState.begin() }

        let existing = Set(redactionState.regions.map {
            "\($0.pageIndex):\($0.bounds.integral.debugDescription)"
        })
        var inserted = existing
        for region in regions where inserted.count < 500 {
            let key = "\(region.pageIndex):\(region.bounds.integral.debugDescription)"
            guard inserted.insert(key).inserted else { continue }
            redactionState.add(region)
        }
        if let first = regions.first {
            navigateToPage(number: first.pageIndex + 1)
        }
    }

    func clearSearch() {
        searchController.clear()
    }

    func exportBookmarksJSON() { exportLibraryJSON(
        data: { try bookmarkStore.exportJSON() },
        suggestedName: "PDFViewer Bookmarks.json",
        title: "Export Bookmarks"
    ) }

    func exportRecentDocumentsJSON() { exportLibraryJSON(
        data: { try recentDocuments.exportJSON() },
        suggestedName: "PDFViewer Recent Documents.json",
        title: "Export Recent Documents"
    ) }

    func importBookmarksJSON() { importLibraryJSON(title: "Import Bookmarks") { [bookmarkStore] data in
        try bookmarkStore.importJSON(data)
    } }

    func importRecentDocumentsJSON() { importLibraryJSON(title: "Import Recent Documents") { [recentDocuments] data in
        try recentDocuments.importJSON(data)
    } }

    private func exportLibraryJSON(
        data: () throws -> Data,
        suggestedName: String,
        title: String
    ) {
        do {
            let output = try data()
            let panel = NSSavePanel()
            panel.title = title
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = suggestedName
            panel.begin { [weak self] response in
                guard response == .OK, let url = panel.url else { return }
                do { try output.write(to: url, options: .atomic) }
                catch { self?.present(error, title: "Could Not Export JSON") }
            }
        } catch { present(error, title: "Could Not Prepare JSON") }
    }

    private func importLibraryJSON(
        title: String,
        apply: @escaping @MainActor (Data) throws -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            do {
                let values = try url.resourceValues(forKeys: [.fileSizeKey])
                guard (values.fileSize ?? 0) <= 10 * 1_024 * 1_024 else {
                    throw CocoaError(.fileReadTooLarge)
                }
                try apply(Data(contentsOf: url))
            } catch { self?.present(error, title: "Could Not Import JSON") }
        }
    }

    func selectPageIndexes(_ indexes: Set<Int>) {
        _ = readerState.selectPages(at: indexes)
    }

    func presentPageOrganizer() {
        annotationState.end()
        pendingTextNote = nil
        isPageOrganizerPresented = true
    }

    func presentFormEditor() {
        guard requireFormFieldEntryPermission() else {
            return
        }
        guard session?.editor.formFields.isEmpty == false else {
            return
        }
        annotationState.end()
        pendingTextNote = nil
        isPageOrganizerPresented = false
        isFormEditorPresented = true
    }

    func dismissFormEditor() {
        isFormEditorPresented = false
    }

    func updateFormField(named name: String, value: PDFFormFieldValue) {
        guard requireFormFieldEntryPermission(), let editor = session?.editor else {
            return
        }

        do {
            try editor.updateFormField(named: name, value: value)
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Fill Form Field")
        }
    }

    func resetFormFields() {
        guard requireFormFieldEntryPermission(), let editor = session?.editor else {
            return
        }

        do {
            try editor.resetFormFields()
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Reset Form")
        }
    }

    func toggleRedactionMode() {
        if redactionState.isActive {
            pendingPermanentRedaction = nil
            redactionState.end()
            return
        }
        guard requireRedactionPermission() else {
            return
        }
        annotationState.end()
        pendingTextNote = nil
        isPageOrganizerPresented = false
        isFormEditorPresented = false
        redactionState.begin()
    }

    func addRedactionRegion(_ region: PDFRedactionRegion) {
        guard redactionState.isActive, requireRedactionPermission() else {
            return
        }
        redactionState.add(region)
    }

    func removeLastRedactionRegion() {
        redactionState.removeLast()
    }

    func clearRedactionRegions() {
        redactionState.clear()
    }

    func requestApplyPermanentRedactions() {
        guard redactionState.isActive, requireRedactionPermission() else {
            return
        }
        guard !redactionState.regions.isEmpty else {
            present(PDFRedactionError.noRegions, title: "No Redaction Areas")
            return
        }
        pendingPermanentRedaction = PendingPermanentRedaction(
            regions: redactionState.regions,
            reasonLabel: redactionState.reasonLabel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : redactionState.reasonLabel
        )
    }

    func cancelPermanentRedaction() {
        pendingPermanentRedaction = nil
    }

    func confirmPermanentRedaction() {
        guard
            let pendingPermanentRedaction,
            requireRedactionPermission(),
            let editor = session?.editor
        else {
            return
        }
        self.pendingPermanentRedaction = nil

        do {
            try editor.applyPermanentRedactions(
                pendingPermanentRedaction.regions,
                reasonLabel: pendingPermanentRedaction.reasonLabel
            )
            redactionState.end()
            synchronizeAfterDocumentMutation()
            annotationState.clearTransientSelection()
        } catch {
            present(error, title: "Could Not Apply Redactions")
        }
    }

    func presentLocalProcessing() {
        guard requireDocumentProcessingPermission() else {
            return
        }
        annotationState.end()
        redactionState.end()
        isPageOrganizerPresented = false
        isFormEditorPresented = false
        localProcessingProgress = nil
        isLocalProcessingPresented = true
    }

    func startLocalProcessing(
        pageIndexes: IndexSet,
        addsSearchableText: Bool,
        enhancement: PDFScanEnhancementPreset,
        rasterQuality: PDFOCRRasterQuality = .balanced,
        language: PDFOCRLanguage = .automatic,
        minimumConfidence: Float = 0,
        cropMarginsPercent: Double = 0,
        splitDoublePages: Bool = false
    ) {
        guard
            !isLocalProcessing,
            requireDocumentProcessingPermission(),
            let session,
            !pageIndexes.isEmpty
        else {
            return
        }

        let editor = session.editor
        let sourceDocument = editor.document
        let sourceRevisionData = editor.currentRevision.pdfData
        let generation = UUID()
        localProcessingGeneration = generation
        localProcessingProgress = PDFOCRProgress(
            completedPages: 0,
            totalPages: pageIndexes.count
        )
        isLocalProcessing = true

        localProcessingTask = Task { [weak self, weak editor] in
            do {
                let result = try await PDFOCREngine.process(
                    document: sourceDocument,
                    pageIndexes: pageIndexes,
                    addsSearchableText: addsSearchableText,
                    enhancement: enhancement,
                    rasterQuality: rasterQuality,
                    language: language,
                    minimumConfidence: minimumConfidence,
                    cropMarginsPercent: cropMarginsPercent,
                    splitDoublePages: splitDoublePages
                ) { [weak self] progress in
                    guard self?.localProcessingGeneration == generation else {
                        return
                    }
                    self?.localProcessingProgress = progress
                }
                try Task.checkCancellation()
                guard
                    let self,
                    self.localProcessingGeneration == generation,
                    let editor,
                    self.session?.editor === editor,
                    editor.currentRevision.pdfData == sourceRevisionData
                else {
                    throw PDFOCRError.documentChangedDuringProcessing
                }

                try editor.applyProcessedDocument(
                    result.document,
                    sourcePageIndexes: result.sourcePageIndexes
                )
                self.synchronizeAfterDocumentMutation()
                self.isLocalProcessing = false
                self.isLocalProcessingPresented = false
                self.localProcessingTask = nil
                let message = result.recognizedLineCount > 0
                    ? "Processed \(pageIndexes.count) \(pageIndexes.count == 1 ? "page" : "pages") locally and added \(result.recognizedLineCount) recognized text \(result.recognizedLineCount == 1 ? "line" : "lines")."
                    : "Processed \(pageIndexes.count) \(pageIndexes.count == 1 ? "page" : "pages") locally. No searchable text lines were added."
                self.presentedError = PresentedError(
                    title: "Local Processing Complete",
                    message: message
                )
            } catch is CancellationError {
                guard let self, self.localProcessingGeneration == generation else {
                    return
                }
                self.isLocalProcessing = false
                self.localProcessingTask = nil
            } catch {
                guard let self, self.localProcessingGeneration == generation else {
                    return
                }
                self.isLocalProcessing = false
                self.localProcessingTask = nil
                self.present(error, title: "Could Not Process Pages")
            }
        }
    }

    func cancelLocalProcessing() {
        localProcessingGeneration = UUID()
        localProcessingTask?.cancel()
        localProcessingTask = nil
        isLocalProcessing = false
        isLocalProcessingPresented = false
    }

    func presentConversion() {
        guard canConvertActiveDocument else {
            present(
                DocumentPermissionError.conversionDenied,
                title: "Conversion Not Permitted"
            )
            return
        }
        annotationState.end()
        redactionState.end()
        isPageOrganizerPresented = false
        isFormEditorPresented = false
        isLocalProcessingPresented = false
        isConversionPresented = true
    }

    func dismissConversion() {
        isConversionPresented = false
    }

    func chooseImagesForPDFCreation() {
        isConversionPresented = false
        presentOpenPanel(
            title: "Choose Images",
            message: "Choose up to 500 PNG, JPEG, HEIC, or TIFF images. Selection order becomes the PDF page order.",
            allowedContentTypes: [.image],
            allowsMultipleSelection: true,
            handle: handleImageImport
        )
    }

    func handleImageImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                return
            }
            do {
                guard urls.count <= PDFNativeConversionEngine.maximumImageCount else {
                    throw PDFNativeConversionError.tooManyImages
                }
                let inputs = try urls.map { url in
                    let didAccess = url.startAccessingSecurityScopedResource()
                    defer {
                        if didAccess {
                            url.stopAccessingSecurityScopedResource()
                        }
                    }
                    guard url.isFileURL else {
                        throw PDFNativeConversionError.invalidImage(url.lastPathComponent)
                    }
                    let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
                    guard
                        let fileSize,
                        fileSize <= PDFNativeConversionEngine.maximumInputImageBytes
                    else {
                        throw PDFNativeConversionError.imageTooLarge(url.lastPathComponent)
                    }
                    return PDFImageInput(
                        filename: url.lastPathComponent,
                        data: try Data(contentsOf: url, options: [.mappedIfSafe])
                    )
                }
                let document = try PDFNativeConversionEngine.document(from: inputs)
                let sourceURL = urls[0]
                let baseName = sourceURL.deletingPathExtension().lastPathComponent
                presentExportPanel(
                    document: document,
                    sourceURL: sourceURL,
                    suggestedFileName: "\(baseName.isEmpty ? "Images" : baseName) Converted.pdf",
                    title: "Create PDF From Images",
                    kind: .createdFromImages,
                    continuation: nil,
                    usesActiveSessionProtection: false
                )
            } catch {
                present(error, title: "Could Not Create PDF From Images")
            }
        case .failure(let error):
            let nsError = error as NSError
            let isUserCancellation = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSUserCancelledError
            if !isUserCancellation {
                present(error, title: "Could Not Choose Images")
            }
        }
    }

    func exportPagesAsImages(
        pageIndexes: IndexSet,
        format: PDFImageExportFormat,
        dpi: Int
    ) {
        guard canConvertActiveDocument, let session else {
            present(
                DocumentPermissionError.conversionDenied,
                title: "Conversion Not Permitted"
            )
            return
        }

        do {
            let files = try PDFNativeConversionEngine.imageFiles(
                from: session.editor.document,
                pageIndexes: pageIndexes,
                format: format,
                dpi: dpi,
                baseName: session.sourceURL.deletingPathExtension().lastPathComponent
            )
            let panel = NSOpenPanel()
            panel.title = "Export PDF Pages as \(format.title) Images"
            panel.message = "Choose an output folder. Existing files will not be overwritten."
            panel.prompt = "Export Images"
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.directoryURL = session.sourceURL.deletingLastPathComponent()
            panel.begin { [weak self] response in
                guard response == .OK, let destinationDirectory = panel.url else {
                    return
                }
                let didAccess = destinationDirectory.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        destinationDirectory.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    let outputURLs = try PDFNativeConversionEngine.writeImageFiles(
                        files,
                        to: destinationDirectory
                    )
                    self?.isConversionPresented = false
                    self?.exportReceipt = ExportReceipt(
                        url: destinationDirectory,
                        pageCount: outputURLs.count,
                        kind: .convertedImages,
                        fileSizeInBytes: files.reduce(0) { $0 + $1.data.count }
                    )
                } catch {
                    self?.present(error, title: "Could Not Export Images")
                }
            }
        } catch {
            present(error, title: "Could Not Convert PDF Pages")
        }
    }

    func exportPagesAsText(pageIndexes: IndexSet) {
        guard canConvertActiveDocument, let session else {
            present(
                DocumentPermissionError.conversionDenied,
                title: "Conversion Not Permitted"
            )
            return
        }

        do {
            let text = try PDFNativeConversionEngine.searchableText(
                from: session.editor.document,
                pageIndexes: pageIndexes
            )
            let panel = NSSavePanel()
            panel.title = "Export Searchable Text"
            panel.message = "Choose a new UTF-8 text output. The PDF will remain unchanged."
            panel.allowedContentTypes = [.plainText]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.directoryURL = session.sourceURL.deletingLastPathComponent()
            panel.nameFieldStringValue = "\(session.sourceURL.deletingPathExtension().lastPathComponent) Text.txt"
            panel.begin { [weak self] response in
                guard response == .OK, let destinationURL = panel.url else {
                    return
                }
                let didAccess = destinationURL.startAccessingSecurityScopedResource()
                defer {
                    if didAccess {
                        destinationURL.stopAccessingSecurityScopedResource()
                    }
                }
                do {
                    try PDFNativeConversionEngine.writeText(text, to: destinationURL)
                    self?.isConversionPresented = false
                    self?.exportReceipt = ExportReceipt(
                        url: destinationURL,
                        pageCount: pageIndexes.count,
                        kind: .convertedText,
                        fileSizeInBytes: text.lengthOfBytes(using: .utf8)
                    )
                } catch {
                    self?.present(error, title: "Could Not Export Text")
                }
            }
        } catch {
            present(error, title: "Could Not Convert PDF Text")
        }
    }

    func toggleAnnotationMode() {
        if annotationState.isActive {
            annotationState.end()
        } else {
            guard requireCommentingPermission() else {
                return
            }
            redactionState.end()
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

        if tool == .signature {
            isSignatureLibraryPresented = true
            return
        }

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
        if
            annotationState.isActive,
            annotationState.selectedTool == .eraser,
            let selection,
            selection.kind == .freehand,
            selection.isOwnedByPDFViewer
        {
            deleteAnnotation(selection)
            return
        }
        annotationState.selectAnnotation(selection)
        guard let selection, !selection.isOwnedByPDFViewer else {
            return
        }
        present(
            PDFDocumentEditorError.annotationIsReadOnly,
            title: "Read-Only Annotation"
        )
    }

    func navigateToOwnedAnnotation(_ item: OwnedAnnotationItem) {
        navigateToPage(number: item.pageNumber)
        if !annotationState.isActive { annotationState.begin() }
        annotationState.selectedTool = .select
        annotationState.selectAnnotation(
            SelectedAnnotation(
                pageIndex: item.pageIndex,
                identifier: item.identifier,
                kind: item.kind
            )
        )
    }

    func navigateToFormField(_ field: PDFFormField) {
        navigateToPage(number: field.pageIndex + 1)
    }

    func deleteOwnedAnnotation(_ item: OwnedAnnotationItem) {
        deleteAnnotation(
            SelectedAnnotation(
                pageIndex: item.pageIndex,
                identifier: item.identifier,
                kind: item.kind
            )
        )
    }

    private func deleteAnnotation(_ selection: SelectedAnnotation) {
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let identifier = selection.identifier
        else { return }
        do {
            try editor.deleteAnnotation(pageIndex: selection.pageIndex, identifier: identifier)
            synchronizeAfterDocumentMutation()
            annotationState.clearTransientSelection()
        } catch {
            present(error, title: "Could Not Delete Annotation")
        }
    }

    func addInkStroke(_ stroke: InkStroke) {
        guard requireCommentingPermission() else {
            return
        }
        performAnnotationOperation { editor in
            try editor.addInkStroke(
                stroke,
                customColor: annotationState.effectiveColor,
                lineWidth: annotationState.selectedLineWidth
            )
        }
    }

    func addShapeAnnotation(_ placement: ShapeAnnotationPlacement) {
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let kind = annotationState.selectedTool.shapeKind
        else {
            return
        }
        do {
            let identifier = try editor.addShapeAnnotation(
                kind: kind,
                placement: placement,
                customColor: annotationState.effectiveColor,
                lineWidth: annotationState.selectedLineWidth
            )
            synchronizeAfterDocumentMutation()
            annotationState.selectAnnotation(
                SelectedAnnotation(
                    pageIndex: placement.pageIndex,
                    identifier: identifier,
                    kind: annotationState.selectedTool
                )
            )
            annotationState.selectedTool = .select
        } catch {
            present(error, title: "Could Not Add Shape")
        }
    }

    func requestBuiltInStamp(at placement: AnnotationPlacement) {
        guard requireCommentingPermission(), let editor = session?.editor else {
            return
        }
        do {
            let identifier: AnnotationIdentifier
            if
                let stampID = annotationState.selectedCustomStampID,
                let stamp = stampLibrary.signatures.first(where: { $0.id == stampID })
            {
                identifier = try editor.addCustomStamp(
                    pageIndex: placement.pageIndex,
                    point: placement.point,
                    imageData: stampLibrary.imageData(for: stampID),
                    displayName: stamp.displayName
                )
            } else {
                identifier = try editor.addBuiltInStamp(
                    pageIndex: placement.pageIndex,
                    point: placement.point,
                    preset: annotationState.selectedStamp
                )
            }
            synchronizeAfterDocumentMutation()
            annotationState.selectAnnotation(
                SelectedAnnotation(
                    pageIndex: placement.pageIndex,
                    identifier: identifier,
                    kind: .stamp
                )
            )
            annotationState.selectedTool = .select
        } catch {
            present(error, title: "Could Not Add Stamp")
        }
    }

    func setStampPreset(_ preset: StampPreset) {
        annotationState.selectedStamp = preset
        annotationState.selectedCustomStampID = nil
    }

    func presentStampLibrary() { isStampLibraryPresented = true }

    func chooseCustomStamp(_ stamp: StoredSignature) {
        annotationState.selectedCustomStampID = stamp.id
        annotationState.selectedTool = .stamp
        isStampLibraryPresented = false
    }

    func importCustomStamp(at url: URL) {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let stamp = try stampLibrary.importImage(
                data: data,
                displayName: url.deletingPathExtension().lastPathComponent
            )
            chooseCustomStamp(stamp)
        } catch { present(error, title: "Could Not Import Stamp") }
    }

    func deleteCustomStamp(_ stamp: StoredSignature) {
        do {
            try stampLibrary.delete(stamp.id)
            if annotationState.selectedCustomStampID == stamp.id {
                annotationState.selectedCustomStampID = nil
            }
        } catch { present(error, title: "Could Not Delete Stamp") }
    }

    func moveAnnotation(_ selection: SelectedAnnotation, by translation: CGSize) {
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let identifier = selection.identifier
        else {
            return
        }
        do {
            try editor.moveAnnotation(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                by: translation
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Move Annotation")
        }
    }

    func resizeSelectedAnnotation(scale: CGFloat) {
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            let identifier = selection.identifier
        else {
            return
        }
        do {
            try editor.resizeAnnotation(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                scale: scale
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Resize Annotation")
        }
    }

    func rotateSelectedVisualSignature(clockwise: Bool) {
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            selection.kind == .signature,
            let identifier = selection.identifier
        else {
            return
        }
        do {
            try editor.rotateVisualSignature(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                clockwise: clockwise
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Rotate Visual Signature")
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

    func chooseVisualSignature(_ signature: StoredSignature) {
        guard annotationState.isActive, requireCommentingPermission() else {
            return
        }
        annotationState.selectedSignatureID = signature.id
        annotationState.selectedTool = .signature
        isSignatureLibraryPresented = false
    }

    func importVisualSignature(data: Data, displayName: String) {
        do {
            let stored = try signatureLibrary.importImage(
                data: data,
                displayName: displayName
            )
            chooseVisualSignature(stored)
        } catch {
            present(error, title: "Could Not Import Visual Signature")
        }
    }

    func handleVisualSignatureImport(_ result: Result<[URL], any Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }
            importVisualSignature(at: url)
        case .failure(let error):
            let nsError = error as NSError
            let isUserCancellation = nsError.domain == NSCocoaErrorDomain
                && nsError.code == NSUserCancelledError
            if !isUserCancellation {
                present(error, title: "Could Not Choose Visual Signature")
            }
        }
    }

    func importVisualSignature(at url: URL) {
        let hasScopedAccess = url.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        do {
            guard url.isFileURL else {
                throw SignatureLibraryError.invalidImage
            }
            let fileSize = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize
            guard
                let fileSize,
                fileSize <= SignatureLibrary.maximumImageBytes
            else {
                throw SignatureLibraryError.imageTooLarge
            }
            let data = try Data(contentsOf: url)
            importVisualSignature(
                data: data,
                displayName: url.deletingPathExtension().lastPathComponent
            )
        } catch {
            present(error, title: "Could Not Import Visual Signature")
        }
    }

    func createVisualSignature(
        strokes: [InkStroke],
        canvasSize: CGSize,
        displayName: String
    ) {
        do {
            let stored = try signatureLibrary.createFromDrawing(
                strokes: strokes,
                canvasSize: canvasSize,
                displayName: displayName
            )
            chooseVisualSignature(stored)
        } catch {
            present(error, title: "Could Not Save Visual Signature")
        }
    }

    func deleteVisualSignature(_ signature: StoredSignature) {
        do {
            try signatureLibrary.delete(signature.id)
            if annotationState.selectedSignatureID == signature.id {
                annotationState.selectedSignatureID = nil
            }
        } catch {
            present(error, title: "Could Not Delete Visual Signature")
        }
    }

    func dismissVisualSignatureLibrary() {
        isSignatureLibraryPresented = false
        if annotationState.selectedSignatureID == nil,
           annotationState.selectedTool == .signature {
            annotationState.selectedTool = .select
        }
    }

    func requestVisualSignature(at placement: AnnotationPlacement) {
        guard annotationState.isActive, requireCommentingPermission() else {
            return
        }
        guard let signatureID = annotationState.selectedSignatureID else {
            isSignatureLibraryPresented = true
            return
        }

        do {
            let imageData = try signatureLibrary.imageData(for: signatureID)
            guard let editor = session?.editor else {
                return
            }
            let identifier = try editor.addVisualSignature(
                pageIndex: placement.pageIndex,
                point: placement.point,
                imageData: imageData,
                size: annotationState.selectedSignatureSize
            )
            synchronizeAfterDocumentMutation()
            annotationState.selectAnnotation(
                SelectedAnnotation(
                    pageIndex: placement.pageIndex,
                    identifier: identifier,
                    kind: .signature
                )
            )
        } catch {
            present(error, title: "Could Not Place Visual Signature")
        }
    }

    func setVisualSignatureSize(_ size: SignatureSizePreset) {
        annotationState.selectedSignatureSize = size
        guard requireCommentingPermission() else {
            return
        }
        guard
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            selection.kind == .signature,
            let identifier = selection.identifier
        else {
            return
        }

        do {
            try editor.updateVisualSignatureSize(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                size: size
            )
            synchronizeAfterDocumentMutation()
        } catch {
            present(error, title: "Could Not Resize Visual Signature")
        }
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

        let trimmedContents = String(
            contents.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10_000)
        )
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
                    customColor: annotationState.effectiveColor
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
        annotationState.customColor = nil
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

    func setCustomAnnotationColor(_ color: NSColor) {
        annotationState.customColor = color.usingColorSpace(.deviceRGB) ?? color
        guard
            requireCommentingPermission(),
            let editor = session?.editor,
            let selection = annotationState.selectedAnnotation,
            let identifier = selection.identifier
        else { return }
        do {
            try editor.updateAnnotationColor(
                pageIndex: selection.pageIndex,
                identifier: identifier,
                customColor: annotationState.effectiveColor
            )
            synchronizeAfterDocumentMutation()
        } catch { present(error, title: "Could Not Restyle Annotation") }
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
        case .select, .freehand, .eraser, .textNote, .rectangle, .oval, .line, .arrow, .stamp, .signature:
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
                customColor: annotationState.effectiveColor
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

    func exportFlattenedForm() {
        guard requireFormFieldEntryPermission(), let session else {
            return
        }

        do {
            let flattened = try PDFFormEngine.flattenedDocument(from: session.editor.document)
            presentExportPanel(
                document: flattened,
                sourceURL: session.sourceURL,
                suggestedFileName: suggestedOutputFileName(
                    for: session.sourceURL,
                    suffix: "Flattened"
                ),
                title: "Export Flattened Form",
                kind: .flattenedForm,
                continuation: nil
            )
        } catch {
            present(error, title: "Could Not Flatten Form")
        }
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

    private func presentOpenPanel(
        title: String,
        message: String? = nil,
        allowedContentTypes: [UTType],
        allowsMultipleSelection: Bool,
        handle: @escaping @MainActor (Result<[URL], any Error>) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.title = title
        if let message {
            panel.message = message
        }
        panel.allowedContentTypes = allowedContentTypes
        panel.allowsMultipleSelection = allowsMultipleSelection
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK else {
                return
            }
            let urls = panel.urls
            Task { @MainActor in
                handle(.success(urls))
            }
        }
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
        encryptedExportConfirmed: Bool = false,
        usesActiveSessionProtection: Bool = true
    ) {
        if usesActiveSessionProtection,
           session?.securityContext.isEncrypted == true,
           !encryptedExportConfirmed {
            pendingEncryptedExport = PendingEncryptedExport(
                document: document,
                sourceURL: sourceURL,
                suggestedFileName: suggestedFileName,
                title: title,
                kind: kind,
                continuation: continuation,
                usesActiveSessionProtection: usesActiveSessionProtection
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

        let compressionAccessory = ExportCompressionAccessoryController()
        panel.accessoryView = compressionAccessory.view

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
                compression: compressionAccessory.selectedCompression,
                continuation: continuation,
                usesActiveSessionProtection: usesActiveSessionProtection
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
            encryptedExportConfirmed: true,
            usesActiveSessionProtection: pendingEncryptedExport.usesActiveSessionProtection
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
        compression: PDFExportCompression = .standard,
        continuation: PendingDocumentAction? = nil,
        usesActiveSessionProtection: Bool = true
    ) {
        do {
            let securityContext = usesActiveSessionProtection
                ? session?.securityContext
                : nil
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
                accessPermissions: securityContext?.accessPermissions ?? document.accessPermissions,
                compression: compression
            )

            if usesActiveSessionProtection, let editor = session?.editor {
                let exportedCurrentWorkingCopy = kind == .workingCopy && editor.document === document
                if exportedCurrentWorkingCopy || kind == .flattenedForm {
                    editor.markCurrentRevisionExported()
                }
            }

            exportReceipt = ExportReceipt(
                url: result.url,
                pageCount: result.pageCount,
                kind: kind,
                fileSizeInBytes: result.fileSizeInBytes
            )
            AppDiagnostics.record(.exportCompleted)

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
        AppDiagnostics.record(.recoverableOperationFailed)
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

    private func requireFormFieldEntryPermission() -> Bool {
        guard session?.securityContext.allowsFormFieldEntry == true else {
            present(
                DocumentPermissionError.formFieldEntryDenied,
                title: "Form Filling Not Permitted"
            )
            return false
        }
        return true
    }

    private func requireRedactionPermission() -> Bool {
        guard canRedactActiveDocument else {
            present(DocumentPermissionError.redactionDenied, title: "Redaction Not Permitted")
            return false
        }
        return true
    }

    private func requireDocumentProcessingPermission() -> Bool {
        guard canProcessActiveDocument else {
            present(
                DocumentPermissionError.documentProcessingDenied,
                title: "Local Processing Not Permitted"
            )
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
