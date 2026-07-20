import AppKit
import Foundation

/// Services whose storage is intentionally shared by every PDFViewer window.
/// All mutable document and presentation state stays in the per-window
/// `AppState` instances created by `makeAppState()`.
@MainActor
final class SharedServices: ObservableObject {
    let documentLoader: DocumentLoader
    let recentDocuments: RecentDocumentsStore
    let bookmarkStore: PageBookmarkStore
    let signatureLibrary: SignatureLibrary
    let pdfExporter: any PDFExporting
    let loadDocumentsAsynchronously: Bool

    init(
        documentLoader: DocumentLoader = DocumentLoader(),
        recentDocuments: RecentDocumentsStore = RecentDocumentsStore(),
        bookmarkStore: PageBookmarkStore = PageBookmarkStore(),
        signatureLibrary: SignatureLibrary = SignatureLibrary(),
        pdfExporter: any PDFExporting = PDFExporter(),
        loadDocumentsAsynchronously: Bool = true
    ) {
        self.documentLoader = documentLoader
        self.recentDocuments = recentDocuments
        self.bookmarkStore = bookmarkStore
        self.signatureLibrary = signatureLibrary
        self.pdfExporter = pdfExporter
        self.loadDocumentsAsynchronously = loadDocumentsAsynchronously
    }

    func makeAppState() -> AppState {
        AppState(
            documentLoader: documentLoader,
            recentDocuments: recentDocuments,
            bookmarkStore: bookmarkStore,
            signatureLibrary: signatureLibrary,
            pdfExporter: pdfExporter,
            loadDocumentsAsynchronously: loadDocumentsAsynchronously
        )
    }
}

/// A value uniquely identifying a newly requested window. Giving every request
/// a fresh identifier allows the same source URL to be opened in multiple
/// independent working sessions.
struct WindowLaunchRequest: Codable, Hashable {
    let id: UUID
    let url: URL?

    init(id: UUID = UUID(), url: URL? = nil) {
        self.id = id
        self.url = url
    }
}

/// Tracks the relationship between native windows and their per-window state.
/// Entries are weak so the registry never keeps a closed window or session
/// alive. It also coordinates delayed application termination across every
/// dirty window, one native warning at a time.
@MainActor
final class WindowStateRegistry: ObservableObject {
    private final class Entry {
        let id: UUID
        weak var state: AppState?
        weak var window: NSWindow?

        init(id: UUID, state: AppState) {
            self.id = id
            self.state = state
        }
    }

    private var entries: [Entry] = []
    private var terminationQueue: [AppState] = []
    private var terminationReply: ((Bool) -> Void)?

    var liveStates: [AppState] {
        compactEntries()
        return entries.compactMap(\.state)
    }

    func register(_ state: AppState, id: UUID) {
        compactEntries()
        if let entry = entries.first(where: { $0.id == id }) {
            entry.state = state
        } else {
            entries.append(Entry(id: id, state: state))
        }
    }

    func unregister(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }
        entries[index].state?.terminationReplyHandler = nil
        entries.remove(at: index)
    }

    func attach(_ window: NSWindow?, to id: UUID) {
        entries.first(where: { $0.id == id })?.window = window
    }

    func state(for window: NSWindow?) -> AppState? {
        guard let window else {
            return nil
        }
        compactEntries()
        return entries.first(where: { $0.window === window })?.state
    }

    /// Returns `true` only when termination can proceed immediately. A `false`
    /// result means the caller must use a delayed AppKit termination reply.
    func requestApplicationTermination(reply: @escaping (Bool) -> Void) -> Bool {
        guard terminationReply == nil else {
            return false
        }

        compactEntries()
        let keyWindowState = state(for: NSApp.keyWindow)
        let dirtyStates = entries.compactMap(\.state).filter {
            $0.session?.editor.hasUnexportedChanges == true
        }
        terminationQueue = dirtyStates
        if
            let keyWindowState,
            let keyIndex = terminationQueue.firstIndex(where: { $0 === keyWindowState }),
            keyIndex != terminationQueue.startIndex
        {
            let keyState = terminationQueue.remove(at: keyIndex)
            terminationQueue.insert(keyState, at: terminationQueue.startIndex)
        }

        guard !terminationQueue.isEmpty else {
            return true
        }

        terminationReply = reply
        reviewNextDirtyWindow()
        return false
    }

    private func reviewNextDirtyWindow() {
        while !terminationQueue.isEmpty {
            let state = terminationQueue.removeFirst()
            guard state.session?.editor.hasUnexportedChanges == true else {
                continue
            }

            if let window = entries.first(where: { $0.state === state })?.window {
                window.makeKeyAndOrderFront(nil)
            }

            state.terminationReplyHandler = { [weak self, weak state] shouldContinue in
                state?.terminationReplyHandler = nil
                guard let self else {
                    return
                }
                if shouldContinue {
                    self.reviewNextDirtyWindow()
                } else {
                    self.finishTerminationReview(shouldTerminate: false)
                }
            }

            if state.requestApplicationTermination() {
                state.terminationReplyHandler = nil
                continue
            }
            return
        }

        finishTerminationReview(shouldTerminate: true)
    }

    private func finishTerminationReview(shouldTerminate: Bool) {
        entries.compactMap(\.state).forEach { $0.terminationReplyHandler = nil }
        terminationQueue.removeAll()
        let reply = terminationReply
        terminationReply = nil
        reply?(shouldTerminate)
    }

    private func compactEntries() {
        entries.removeAll { $0.state == nil }
    }
}
