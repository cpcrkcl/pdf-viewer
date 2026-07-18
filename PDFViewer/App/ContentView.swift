import AppKit
import CoreTransferable
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var appState: AppState
    @State private var isDropTargeted = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let session = appState.session {
                    ReaderWorkspace(
                        editor: session.editor,
                        sourceURL: session.sourceURL,
                        state: appState.readerState,
                        search: appState.searchController,
                        annotations: appState.annotationState
                    )
                } else {
                    WelcomeView(recentDocuments: appState.recentDocuments)
                }
            }

            if let receipt = appState.exportReceipt {
                ExportSuccessBanner(receipt: receipt)
                    .padding(16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.exportReceipt)
        .frame(minWidth: 720, minHeight: 520)
        .background(
            WindowCloseGuard(
                appState: appState,
                closeRequestRevision: appState.windowCloseRequestRevision
            )
        )
        .fileImporter(
            isPresented: $appState.isFileImporterPresented,
            allowedContentTypes: [.pdf],
            allowsMultipleSelection: false
        ) { result in
            appState.handleFileImport(result)
        }
        .onOpenURL { url in
            appState.requestOpenDocument(at: url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            appState.handleDroppedURLs(urls)
        } isTargeted: { isTargeted in
            isDropTargeted = isTargeted
        }
        .overlay {
            if isDropTargeted {
                DropTargetOverlay()
            }
        }
        .sheet(isPresented: $appState.isPageOrganizerPresented) {
            if let session = appState.session {
                PageOrganizerSheet(
                    editor: session.editor,
                    state: appState.readerState
                )
            }
        }
        .sheet(item: $appState.pendingTextNote) { pendingTextNote in
            TextNoteEditorSheet(pendingTextNote: pendingTextNote)
        }
        .sheet(item: $appState.pendingBookmarkRename) { pendingBookmarkRename in
            BookmarkRenameSheet(pendingBookmarkRename: pendingBookmarkRename)
        }
        .sheet(
            isPresented: Binding(
                get: { appState.pendingDocumentUnlock != nil },
                set: { isPresented in
                    if !isPresented, appState.pendingDocumentUnlock != nil {
                        appState.cancelDocumentUnlock()
                    }
                }
            )
        ) {
            PasswordUnlockSheet()
        }
        .alert(item: $appState.presentedError) { presentedError in
            Alert(
                title: Text(presentedError.title),
                message: Text(presentedError.message),
                dismissButton: .default(Text("OK"))
            )
        }
        .alert(
            "Export Changes Before Continuing?",
            isPresented: Binding(
                get: { appState.pendingUnsavedChanges != nil },
                set: { isPresented in
                    if !isPresented, appState.pendingUnsavedChanges != nil {
                        appState.resolveUnsavedChanges(.cancel)
                    }
                }
            ),
            presenting: appState.pendingUnsavedChanges
        ) { _ in
            Button("Export and Continue…") {
                appState.resolveUnsavedChanges(.exportAndContinue)
            }
            Button("Discard Changes", role: .destructive) {
                appState.resolveUnsavedChanges(.discard)
            }
            Button("Cancel", role: .cancel) {
                appState.resolveUnsavedChanges(.cancel)
            }
        } message: { _ in
            Text(
                "Your latest document changes exist only in this working session. Export them as a new PDF before continuing, discard them, or cancel. The original PDF will not be changed."
            )
        }
        .alert(
            "Export Encrypted Copy?",
            isPresented: Binding(
                get: { appState.pendingEncryptedExport != nil },
                set: { isPresented in
                    if !isPresented, appState.pendingEncryptedExport != nil {
                        appState.cancelEncryptedExport()
                    }
                }
            )
        ) {
            Button("Export Encrypted Copy") {
                appState.confirmEncryptedExport()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelEncryptedExport()
            }
        } message: {
            Text(
                "The output will remain password protected. The password used to unlock this session will grant both user and owner access to the exported PDF. PDFViewer cannot reproduce the original owner password or preserve separate owner and user credentials."
            )
        }
        .confirmationDialog(
            "Delete selected pages?",
            isPresented: $appState.isPageDeletionConfirmationPresented,
            titleVisibility: .visible
        ) {
            if let pendingDeletion = appState.pendingPageDeletion {
                Button(pendingDeletion.confirmationTitle, role: .destructive) {
                    appState.confirmPendingPageDeletion()
                }
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPendingPageDeletion()
            }
        } message: {
            if let pendingDeletion = appState.pendingPageDeletion {
                if pendingDeletion.selectedPageCount == 1, let pageIndex = pendingDeletion.pageIndexes.first {
                    Text(
                        "Page \(pageIndex + 1) will be removed from the working copy. The original PDF will not change."
                    )
                } else {
                    Text(
                        "\(pendingDeletion.selectedPageCount) selected pages will be removed from the working copy. The original PDF will not change."
                    )
                }
            }
        }
    }
}

private struct PasswordUnlockSheet: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isPasswordFocused: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Password Required", systemImage: "lock.fill")
                    .font(.title2.weight(.semibold))
                Text(appState.pendingDocumentUnlock?.handle.displayName ?? "Protected PDF")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(appState.pendingDocumentUnlock?.handle.displayName ?? "Protected PDF")
                Text("Enter the PDF password. PDFViewer keeps it only for this open document and never stores it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .focused($isPasswordFocused)
                .accessibilityLabel("PDF password")
                .onSubmit(unlock)

            if appState.pendingDocumentUnlock?.hasIncorrectPassword == true {
                Label("Incorrect password. Try again.", systemImage: "exclamationmark.circle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Incorrect password. Try again.")
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.cancelDocumentUnlock()
                }
                .keyboardShortcut(.cancelAction)
                Button("Unlock", action: unlock)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(minWidth: 420, idealWidth: 480)
        .interactiveDismissDisabled()
        .onAppear {
            isPasswordFocused = true
        }
    }

    private func unlock() {
        appState.submitDocumentPassword(password)
        if appState.pendingDocumentUnlock?.hasIncorrectPassword == true {
            password = ""
            isPasswordFocused = true
        }
    }
}

private struct TextNoteEditorSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let pendingTextNote: PendingTextNote
    @State private var text: String

    init(pendingTextNote: PendingTextNote) {
        self.pendingTextNote = pendingTextNote
        _text = State(initialValue: pendingTextNote.initialText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(pendingTextNote.isEditingExistingNote ? "Edit Text Note" : "Add Text Note")
                    .font(.title2.weight(.semibold))
                Text("The note is stored in the working PDF and becomes permanent only in an exported copy.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextEditor(text: $text)
                .font(.body)
                .frame(minHeight: 180)
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(.quaternary)
                }
                .accessibilityLabel("Text note contents")
                .onChange(of: text) {
                    if text.count > 10_000 {
                        text = String(text.prefix(10_000))
                    }
                }

            HStack {
                Text("\(text.count) / 10,000")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Spacer()
                Button("Cancel") {
                    appState.cancelPendingTextNote()
                    dismiss()
                }
                Button(pendingTextNote.isEditingExistingNote ? "Update Note" : "Add Note") {
                    appState.submitPendingTextNote(contents: text)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 320, idealHeight: 380)
        .interactiveDismissDisabled()
    }
}

private struct ExportSuccessBanner: View {
    @EnvironmentObject private var appState: AppState
    let receipt: ExportReceipt

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalContent
                .fixedSize(horizontal: true, vertical: false)
            compactContent
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(.quaternary)
        }
        .shadow(radius: 10, y: 4)
        .frame(maxWidth: 520)
    }

    private var horizontalContent: some View {
        HStack(spacing: 12) {
            successIcon
            titleBlock
                .frame(minWidth: 120, idealWidth: 220, maxWidth: 280, alignment: .leading)
            showInFinderButton
            dismissButton
        }
    }

    private var compactContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                successIcon
                titleBlock
                Spacer(minLength: 8)
                dismissButton
            }

            HStack {
                Spacer()
                showInFinderButton
            }
        }
    }

    private var successIcon: some View {
        Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
            .font(.title2)
            .accessibilityHidden(true)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)
                .accessibilityLabel(title)
            Text("\(receipt.pageCount) \(receipt.pageCount == 1 ? "page" : "pages")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var showInFinderButton: some View {
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([receipt.url])
        }
        .fixedSize()
    }

    private var dismissButton: some View {
        Button {
            appState.dismissExportReceipt()
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.plain)
        .help("Dismiss Export Confirmation")
        .accessibilityLabel("Dismiss Export Confirmation")
    }

    private var title: String {
        switch receipt.kind {
        case .workingCopy:
            "Exported \(receipt.displayName)"
        case .extractedPages:
            "Extracted \(receipt.pageCount) \(receipt.pageCount == 1 ? "page" : "pages") to \(receipt.displayName)"
        }
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let shortestDimension = min(proxy.size.width, proxy.size.height)
            let inset = min(18, max(10, shortestDimension * 0.025))

            ZStack {
                Color.accentColor.opacity(0.12)
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(
                        Color.accentColor,
                        style: StrokeStyle(lineWidth: 3, dash: [9])
                    )
                    .padding(inset)

                Label("Drop PDF to Open", systemImage: "doc.badge.plus")
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
                    .padding(inset)
            }
        }
        .allowsHitTesting(false)
        .accessibilityLabel("Drop one PDF to open")
    }
}

private struct WindowCloseGuard: NSViewRepresentable {
    let appState: AppState
    let closeRequestRevision: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> WindowAttachmentView {
        let view = WindowAttachmentView()
        view.windowChanged = { window in
            context.coordinator.attach(to: window)
        }
        return view
    }

    func updateNSView(_ view: WindowAttachmentView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.attach(to: view.window)
        context.coordinator.handleCloseRequestIfNeeded()
    }

    static func dismantleNSView(_ view: WindowAttachmentView, coordinator: Coordinator) {
        coordinator.detach()
        view.windowChanged = nil
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: WindowCloseGuard

        private weak var window: NSWindow?
        private weak var closeButton: NSButton?
        private weak var originalTarget: AnyObject?
        private var originalAction: Selector?
        private var lastHandledCloseRequestRevision: Int

        init(parent: WindowCloseGuard) {
            self.parent = parent
            self.lastHandledCloseRequestRevision = parent.closeRequestRevision
        }

        func attach(to window: NSWindow?) {
            guard let window, self.window !== window else {
                return
            }

            detach()
            self.window = window
            guard let button = window.standardWindowButton(.closeButton) else {
                return
            }

            closeButton = button
            originalTarget = button.target
            originalAction = button.action
            button.target = self
            button.action = #selector(closeRequested(_:))
        }

        func handleCloseRequestIfNeeded() {
            guard parent.closeRequestRevision != lastHandledCloseRequestRevision else {
                return
            }

            lastHandledCloseRequestRevision = parent.closeRequestRevision
            performOriginalClose()
        }

        func detach() {
            if closeButton?.target === self {
                closeButton?.target = originalTarget
                closeButton?.action = originalAction
            }

            closeButton = nil
            originalTarget = nil
            originalAction = nil
            window = nil
        }

        @objc
        private func closeRequested(_ sender: NSButton) {
            if parent.appState.requestWindowClose() {
                performOriginalClose()
            }
        }

        private func performOriginalClose() {
            guard let window else {
                return
            }

            let button = closeButton
            let target = originalTarget
            let action = originalAction
            detach()

            if let action, NSApp.sendAction(action, to: target, from: button) {
                return
            }

            window.close()
        }
    }
}

private final class WindowAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

private struct WelcomeView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var recentDocuments: RecentDocumentsStore

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                ContentUnavailableView {
                    Label("Open a PDF", systemImage: "doc.richtext")
                } description: {
                    Text("Read and organize a local document without changing the original file.")
                } actions: {
                    Button("Choose PDF...") {
                        appState.isFileImporterPresented = true
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }

                if !recentDocuments.documents.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Recent Documents")
                            .font(.headline)

                        ForEach(recentDocuments.documents) { document in
                            Button {
                                appState.openRecentDocument(document)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: "doc")
                                        .foregroundStyle(.secondary)
                                    Text(document.displayName)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .help(document.displayName)
                                    Spacer(minLength: 20)
                                    Text(document.lastOpenedAt, style: .relative)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 5)
                            .accessibilityLabel("Open recent document \(document.displayName)")
                        }
                    }
                    .padding(16)
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
            .padding(20)
        }
    }
}

private struct BookmarkRenameSheet: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isLabelFocused: Bool
    @State private var label: String

    let pendingBookmarkRename: PendingBookmarkRename

    init(pendingBookmarkRename: PendingBookmarkRename) {
        self.pendingBookmarkRename = pendingBookmarkRename
        _label = State(initialValue: pendingBookmarkRename.bookmark.label)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Bookmark")
                .font(.title2.weight(.semibold))

            TextField("Bookmark name", text: $label)
                .focused($isLabelFocused)
                .onSubmit(submit)
                .accessibilityIdentifier("Bookmark Name")

            Text("Bookmark names can contain up to 120 characters.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel") {
                    appState.cancelBookmarkRename()
                }
                .keyboardShortcut(.cancelAction)
                Button("Rename") {
                    submit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedLabel.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            isLabelFocused = true
        }
    }

    private var trimmedLabel: String {
        label.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func submit() {
        guard !trimmedLabel.isEmpty else {
            return
        }
        appState.renamePendingBookmark(to: String(trimmedLabel.prefix(120)))
    }
}

private struct AnnotationToolSymbol: View {
    let tool: AnnotationTool

    var body: some View {
        Group {
            if tool == .strikethrough {
                // A compact U with a centered strike is intentionally distinct
                // from the underlined U shown by the native underline symbol.
                ZStack {
                    Text("U")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                    Rectangle()
                        .frame(width: 12, height: 1.25)
                }
                .frame(width: 16, height: 16)
            } else {
                Image(systemName: tool.systemImage)
                    .frame(width: 16, height: 16)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ReaderWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isSearchFieldFocused: Bool

    @ObservedObject var editor: PDFDocumentEditor
    let sourceURL: URL
    @ObservedObject var state: ReaderState
    @ObservedObject var search: PDFSearchController
    @ObservedObject var annotations: AnnotationState

    var body: some View {
        VStack(spacing: 0) {
            readerToolbar
            Divider()
            readerSurface
        }
        .background(state.theme.workspaceColor)
        .onChange(of: appState.searchFocusRevision) {
            isSearchFieldFocused = true
            Task { @MainActor in
                await Task.yield()
                NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil)
            }
        }
    }

    private var readerSurface: some View {
        PDFReaderView(
            document: editor.document,
            selectedPageIndex: Binding(
                get: { state.selectedPageIndex },
                set: { newIndex in
                    _ = state.selectPage(at: newIndex)
                }
            ),
            displayMode: state.displayMode,
            theme: state.theme,
            isReaderSidebarVisible: state.isReaderSidebarVisible,
            selectedSidebarTab: state.selectedSidebarTab,
            outlineNodes: appState.session?.outlineNodes ?? [],
            resolvedBookmarks: appState.resolvedBookmarks,
            availablePageIDs: Set(editor.pageIDs),
            zoomRequest: state.zoomRequest,
            highlightedSelections: search.matches,
            activeSearchSelection: search.activeSelection,
            searchNavigationRevision: search.navigationRevision,
            annotationTool: annotations.isActive ? annotations.selectedTool : nil,
            selectedAnnotation: annotations.selectedAnnotation,
            clearAnnotationSelectionRevision: annotations.clearSelectionRevision,
            onTextMarkupRegionsChanged: appState.updateTextMarkupRegions,
            onTextSelectionCommitted: appState.commitSelectedTextMarkup,
            onInkStroke: appState.addInkStroke,
            onTextNotePlacement: appState.requestTextNote,
            onAnnotationSelection: appState.selectAnnotation,
            onSidebarTabChange: { state.selectedSidebarTab = $0 },
            onThumbnailNavigation: appState.navigateFromThumbnail,
            onOutlineNavigation: appState.navigateToOutlinePage,
            onBookmarkNavigation: appState.navigateToBookmark,
            onAddBookmark: appState.addBookmarkForCurrentPage,
            onRenameBookmark: appState.requestRenameBookmark,
            onDeleteBookmark: appState.deleteBookmark
        )
    }

    private var readerToolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            documentHeaderControls
            adaptiveReaderControls
            if annotations.isActive {
                adaptiveAnnotationControls
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private var adaptiveReaderControls: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 14) {
                    displayModePicker
                    pageNavigationControls
                    themePicker
                }

                HStack(spacing: 12) {
                    pageOperationControls
                    searchControls(compact: false)
                }
            }
            .fixedSize(horizontal: true, vertical: false)

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    compactReaderControls
                    searchControls(compact: true)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: 8) {
                    compactReaderControls
                    searchControls(compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var documentHeaderControls: some View {
        HStack(spacing: 8) {
            thumbnailSidebarButton
            navigationHistoryControls
            openDocumentButton
            organizeButton
            annotateButton
            exportButton
            documentFilename
            closeDocumentButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactReaderControls: some View {
        HStack(spacing: 8) {
            pageNavigationControls

            Divider()
                .frame(height: 20)

            viewMenu
            pageActionsMenu
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var thumbnailSidebarButton: some View {
        Button {
            state.toggleReaderSidebar()
        } label: {
            Image(systemName: "sidebar.left")
        }
        .help(state.isReaderSidebarVisible ? "Hide Sidebar" : "Show Sidebar")
        .accessibilityLabel(
            state.isReaderSidebarVisible ? "Hide Sidebar" : "Show Sidebar"
        )
    }

    private var navigationHistoryControls: some View {
        HStack(spacing: 2) {
            Button {
                appState.navigateBack()
            } label: {
                Image(systemName: "chevron.backward")
            }
            .disabled(!appState.canNavigateBack)
            .help("Back")
            .accessibilityLabel("Back")

            Button {
                appState.navigateForward()
            } label: {
                Image(systemName: "chevron.forward")
            }
            .disabled(!appState.canNavigateForward)
            .help("Forward")
            .accessibilityLabel("Forward")
        }
        .fixedSize()
    }

    private var openDocumentButton: some View {
        Button {
            appState.isFileImporterPresented = true
        } label: {
            Label("Open", systemImage: "folder")
        }
        .fixedSize()
    }

    private var organizeButton: some View {
        Button {
            appState.presentPageOrganizer()
        } label: {
            Label("Organize", systemImage: "square.grid.2x2")
        }
        .fixedSize()
        .help("Select and organize pages")
    }

    private var annotateButton: some View {
        Button {
            appState.toggleAnnotationMode()
        } label: {
            Label(
                "Annotate",
                systemImage: annotations.isActive ? "pencil.circle.fill" : "pencil.and.outline"
            )
        }
        .fixedSize()
        .accessibilityLabel(annotations.isActive ? "Done Annotating" : "Annotate")
        .disabled(!annotations.isActive && !appState.canCommentOnActiveDocument)
        .help(
            !appState.canCommentOnActiveDocument
                ? "The PDF's permissions do not allow commenting."
                : (annotations.isActive ? "Finish annotating" : "Add annotations")
        )
    }

    private var adaptiveAnnotationControls: some View {
        ViewThatFits(in: .horizontal) {
            regularAnnotationControls
                .fixedSize(horizontal: true, vertical: false)
            compactAnnotationControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var regularAnnotationControls: some View {
        HStack(spacing: 8) {
            Text("Annotate")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            annotationToolPicker
            annotationColorMenu
            if annotations.selectedTool == .freehand ||
                annotations.selectedAnnotation?.kind == .freehand {
                annotationLineWidthPicker
            }
            selectedAnnotationActions
            finishAnnotatingButton
        }
    }

    private var compactAnnotationControls: some View {
        HStack(spacing: 8) {
            annotationToolMenu
            annotationStyleMenu
            selectedAnnotationActions
            finishAnnotatingButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var annotationToolPicker: some View {
        Picker("Annotation Tool", selection: annotationToolBinding) {
            ForEach(AnnotationTool.allCases) { tool in
                AnnotationToolSymbol(tool: tool)
                    .tag(tool)
                    .help(tool.title)
                    .accessibilityLabel(tool.title)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Annotation Tool")
    }

    private var annotationToolMenu: some View {
        Menu {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    appState.selectAnnotationTool(tool)
                } label: {
                    HStack(spacing: 7) {
                        AnnotationToolSymbol(tool: tool)
                        Text(tool.title)
                    }
                }
            }
        } label: {
            HStack(spacing: 7) {
                AnnotationToolSymbol(tool: annotations.selectedTool)
                Text("Tool: \(annotations.selectedTool.title)")
            }
        }
        .accessibilityLabel("Tool: \(annotations.selectedTool.title)")
        .fixedSize()
    }

    private var annotationColorMenu: some View {
        Menu {
            ForEach(AnnotationPaletteColor.allCases) { color in
                Button(color.title) {
                    appState.setAnnotationColor(color)
                }
            }
        } label: {
            Label("Color: \(annotations.selectedColor.title)", systemImage: "paintpalette")
        }
        .fixedSize()
    }

    private var annotationLineWidthPicker: some View {
        Picker("Ink Width", selection: annotationLineWidthBinding) {
            ForEach(AnnotationLineWidth.allCases) { lineWidth in
                Text(lineWidth.title).tag(lineWidth)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var annotationStyleMenu: some View {
        Menu {
            Menu("Color") {
                ForEach(AnnotationPaletteColor.allCases) { color in
                    Button(color.title) {
                        appState.setAnnotationColor(color)
                    }
                }
            }

            if annotations.selectedTool == .freehand ||
                annotations.selectedAnnotation?.kind == .freehand {
                Menu("Ink Width") {
                    ForEach(AnnotationLineWidth.allCases) { lineWidth in
                        Button(lineWidth.title) {
                            appState.setAnnotationLineWidth(lineWidth)
                        }
                    }
                }
            }
        } label: {
            Label("Style", systemImage: "paintpalette")
        }
        .fixedSize()
    }

    @ViewBuilder
    private var selectedAnnotationActions: some View {
        if let selection = annotations.selectedAnnotation {
            if selection.kind == .textNote, selection.isOwnedByPDFViewer {
                Button("Edit Note") {
                    appState.requestEditSelectedTextNote()
                }
                .fixedSize()
            }

            Button("Delete Annotation", role: .destructive) {
                appState.deleteSelectedAnnotation()
            }
            .disabled(!selection.isOwnedByPDFViewer)
            .fixedSize()
        }
    }

    private var finishAnnotatingButton: some View {
        Button("Done") {
            appState.endAnnotationMode()
        }
        .buttonStyle(.borderedProminent)
        .fixedSize()
    }

    private var annotationToolBinding: Binding<AnnotationTool> {
        Binding(
            get: { annotations.selectedTool },
            set: { appState.selectAnnotationTool($0) }
        )
    }

    private var annotationLineWidthBinding: Binding<AnnotationLineWidth> {
        Binding(
            get: { annotations.selectedLineWidth },
            set: { appState.setAnnotationLineWidth($0) }
        )
    }

    private var exportButton: some View {
        Button {
            appState.exportWorkingCopy()
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .fixedSize()
        .help("Export a new PDF without changing the original")
    }

    private var documentFilename: some View {
        Text(sourceURL.lastPathComponent)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(minWidth: 100, maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .help(sourceURL.lastPathComponent)
            .accessibilityLabel("Document \(sourceURL.lastPathComponent)")
    }

    private var displayModePicker: some View {
        Picker("Display", selection: $state.displayMode) {
            ForEach(ReaderDisplayMode.allCases) { mode in
                Text(mode.title).tag(mode)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Display mode")
    }

    private var themePicker: some View {
        Picker("Theme", selection: $state.theme) {
            ForEach(ReaderTheme.allCases) { theme in
                Text(theme.title).tag(theme)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel("Reading theme")
    }

    private var pageNavigationControls: some View {
        HStack(spacing: 6) {
            TextField("Page", value: pageNumberBinding, format: .number)
                .multilineTextAlignment(.trailing)
                .frame(width: 44)
                .onSubmit {
                    NSApp.keyWindow?.makeFirstResponder(nil)
                }
                .accessibilityLabel("Page number")

            Text("of \(state.pageCount)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .fixedSize()

            Button {
                state.requestZoom(.zoomOut)
            } label: {
                Image(systemName: "minus.magnifyingglass")
            }
            .help("Zoom Out")

            Button {
                state.requestZoom(.fit)
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .help("Fit Page")

            Button {
                state.requestZoom(.zoomIn)
            } label: {
                Image(systemName: "plus.magnifyingglass")
            }
            .help("Zoom In")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var closeDocumentButton: some View {
        Button {
            appState.requestCloseDocument()
        } label: {
            Label("Close", systemImage: "xmark")
        }
        .fixedSize()
        .accessibilityIdentifier("Close Document")
    }

    private var viewMenu: some View {
        Menu {
            Picker("Display Mode", selection: $state.displayMode) {
                ForEach(ReaderDisplayMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }

            Divider()

            Picker("Reading Theme", selection: $state.theme) {
                ForEach(ReaderTheme.allCases) { theme in
                    Text(theme.title).tag(theme)
                }
            }

            Divider()

            Button(
                state.isReaderSidebarVisible
                    ? "Hide Sidebar"
                    : "Show Sidebar"
            ) {
                state.toggleReaderSidebar()
            }
        } label: {
            Label("View", systemImage: "eye")
        }
        .fixedSize()
    }

    private var pageActionsMenu: some View {
        Menu {
            Button("Undo Document Operation") {
                appState.undoPageOperation()
            }
            .disabled(!editor.canUndo)

            Button("Redo Document Operation") {
                appState.redoPageOperation()
            }
            .disabled(!editor.canRedo)

            Divider()

            Button("Move Page Up") {
                appState.moveSelectedPage(up: true)
            }
            .disabled(
                !appState.canAssembleActiveDocument ||
                    state.selectedPageIndexes.count != 1 || state.selectedPageIndex == 0
            )

            Button("Move Page Down") {
                appState.moveSelectedPage(up: false)
            }
            .disabled(
                !appState.canAssembleActiveDocument ||
                    state.selectedPageIndexes.count != 1 ||
                    state.selectedPageIndex >= state.pageCount - 1
            )

            Divider()

            Button("Rotate Left") {
                appState.rotateSelectedPages(clockwise: false)
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)

            Button("Rotate Right") {
                appState.rotateSelectedPages(clockwise: true)
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)

            Button(deleteButtonTitle, role: .destructive) {
                appState.requestDeleteSelectedPages()
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
        } label: {
            Label("Page Actions", systemImage: "doc.badge.gearshape")
        }
        .fixedSize()
    }

    private var pageOperationControls: some View {
        HStack(spacing: 6) {
            Button {
                appState.undoPageOperation()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(!editor.canUndo)
            .help("Undo Document Operation")

            Button {
                appState.redoPageOperation()
            } label: {
                Image(systemName: "arrow.uturn.forward")
            }
            .disabled(!editor.canRedo)
            .help("Redo Document Operation")

            Divider()
                .frame(height: 18)

            Button {
                appState.moveSelectedPage(up: true)
            } label: {
                Image(systemName: "arrow.up")
            }
            .disabled(
                !appState.canAssembleActiveDocument ||
                    state.selectedPageIndexes.count != 1 || state.selectedPageIndex == 0
            )
            .help(pageAssemblyHelp("Move Page Up"))

            Button {
                appState.moveSelectedPage(up: false)
            } label: {
                Image(systemName: "arrow.down")
            }
            .disabled(
                !appState.canAssembleActiveDocument ||
                    state.selectedPageIndexes.count != 1 ||
                    state.selectedPageIndex >= state.pageCount - 1
            )
            .help(pageAssemblyHelp("Move Page Down"))

            Divider()
                .frame(height: 18)

            Button {
                appState.rotateSelectedPages(clockwise: false)
            } label: {
                Image(systemName: "rotate.left")
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
            .help(pageAssemblyHelp("Rotate Selected Pages Counterclockwise"))

            Button {
                appState.rotateSelectedPages(clockwise: true)
            } label: {
                Image(systemName: "rotate.right")
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
            .help(pageAssemblyHelp("Rotate Selected Pages Clockwise"))

            Button(role: .destructive) {
                appState.requestDeleteSelectedPages()
            } label: {
                Label(deleteButtonTitle, systemImage: "trash")
            }
            .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
            .help(pageAssemblyHelp("Delete Selected Pages"))
        }
    }

    private var deleteButtonTitle: String {
        switch state.selectedPageIndexes.count {
        case 0:
            "Delete Pages"
        case 1:
            "Delete Page"
        default:
            "Delete \(state.selectedPageIndexes.count) Pages"
        }
    }

    private func pageAssemblyHelp(_ allowedDescription: String) -> String {
        appState.canAssembleActiveDocument
            ? allowedDescription
            : "The PDF's permissions do not allow page assembly changes."
    }

    private func searchControls(compact: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search text", text: $search.query)
                .frame(
                    minWidth: compact ? 120 : 180,
                    idealWidth: compact ? 150 : 180,
                    maxWidth: compact ? 240 : 180
                )
                .focused($isSearchFieldFocused)
                .onSubmit {
                    appState.startSearch(for: search.query)
                }
                .accessibilityLabel("Search document text")

            if search.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if !search.resultDescription.isEmpty {
                Text(compact ? search.compactResultDescription : search.resultDescription)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: compact ? 44 : 64, alignment: .leading)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel(search.resultDescription)
            }

            Button {
                appState.selectPreviousSearchResult()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(search.matchCount == 0)
            .help("Previous Search Result")

            Button {
                appState.selectNextSearchResult()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(search.matchCount == 0)
            .help("Next Search Result")

            Button {
                appState.clearSearch()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .disabled(search.query.isEmpty && search.matchCount == 0)
            .help("Clear Search")
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var pageNumberBinding: Binding<Int> {
        Binding(
            get: { state.pageCount == 0 ? 0 : state.selectedPageIndex + 1 },
            set: { pageNumber in
                appState.navigateToPage(number: pageNumber)
            }
        )
    }
}

private struct PageOrganizerSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @ObservedObject var editor: PDFDocumentEditor
    @ObservedObject var state: ReaderState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            List(selection: selectionBinding) {
                ForEach(0..<editor.document.pageCount, id: \.self) { pageIndex in
                    OrganizerPageRow(document: editor.document, pageIndex: pageIndex)
                        .tag(pageIndex)
                        .draggable(dragPayload(for: pageIndex))
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4)
                                .onChanged { _ in
                                    if !state.selectedPageIndexes.contains(pageIndex) {
                                        appState.selectPageIndexes([pageIndex])
                                    }
                                }
                        )
                        .overlay(alignment: .top) {
                            OrganizerPageDropZone(
                                destination: pageIndex,
                                edge: .top
                            )
                        }
                        .overlay(alignment: .bottom) {
                            OrganizerPageDropZone(
                                destination: pageIndex + 1,
                                edge: .bottom
                            )
                        }
                }
            }
            .listStyle(.inset)

            Divider()
            controls
        }
        .frame(
            minWidth: 600,
            idealWidth: 720,
            minHeight: 460,
            idealHeight: 600
        )
        .sheet(item: $appState.pendingPDFImport) { pendingPDFImport in
            ImportedPageSelectionSheet(pendingPDFImport: pendingPDFImport)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            regularHeader
                .fixedSize(horizontal: true, vertical: false)
            compactHeader
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    private var regularHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                organizerTitle
                organizerInstructions
            }
            .frame(width: 460, alignment: .leading)

            selectionStatus
        }
    }

    private var compactHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            organizerTitle
            selectionStatus
            organizerInstructions
        }
    }

    private var organizerTitle: some View {
        Text("Organize Pages")
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var organizerInstructions: some View {
        Text("⌘-click rows to select multiple pages, then drag to reorder. Changes affect only the working copy until you export.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var selectionStatus: some View {
        Text(selectionDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .fixedSize(horizontal: true, vertical: false)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            ViewThatFits(in: .horizontal) {
                regularControlGrid
                    .fixedSize(horizontal: true, vertical: false)
                compactControlSections
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            organizerFooter
        }
        .controlSize(.regular)
        .padding(16)
        .background(.bar)
    }

    private var regularControlGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 10) {
            GridRow {
                controlSectionTitle("Reorder")

                HStack(spacing: 8) {
                    moveUpButton(compact: false)
                    moveDownButton(compact: false)
                    moveToMenu(compact: false)
                }
            }

            GridRow {
                controlSectionTitle("Edit")

                HStack(spacing: 8) {
                    rotateLeftButton(compact: false)
                    rotateRightButton(compact: false)
                    deletePagesButton(compact: false)
                }
            }

            GridRow {
                controlSectionTitle("Add or Extract")

                HStack(spacing: 8) {
                    addOrMergeMenu(compact: false)
                    extractPagesButton(compact: false)
                }
            }
        }
    }

    private var compactControlSections: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                compactControlSectionTitle("Reorder")
                LazyVGrid(columns: compactControlColumns, alignment: .leading, spacing: 8) {
                    moveUpButton(compact: true)
                    moveDownButton(compact: true)
                    moveToMenu(compact: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                compactControlSectionTitle("Edit")
                LazyVGrid(columns: compactControlColumns, alignment: .leading, spacing: 8) {
                    rotateLeftButton(compact: true)
                    rotateRightButton(compact: true)
                    deletePagesButton(compact: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                compactControlSectionTitle("Add or Extract")
                LazyVGrid(columns: compactControlColumns, alignment: .leading, spacing: 8) {
                    addOrMergeMenu(compact: true)
                    extractPagesButton(compact: true)
                }
            }
        }
        .buttonStyle(.bordered)
    }

    private var compactControlColumns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: 150, maximum: 240),
                spacing: 8,
                alignment: .leading
            ),
        ]
    }

    private var organizerFooter: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                exportExplanation
                exportNewPDFButton
                doneButton
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 10) {
                exportExplanation
                HStack(spacing: 10) {
                    Spacer()
                    exportNewPDFButton
                    doneButton
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var exportExplanation: some View {
        Text("Export creates a new PDF and leaves the original unchanged.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var exportNewPDFButton: some View {
        Button("Export New PDF…") {
            appState.exportWorkingCopy()
        }
        .fixedSize()
    }

    private var doneButton: some View {
        Button("Done") {
            dismiss()
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
        .fixedSize()
    }

    private func controlSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 88, alignment: .leading)
    }

    private func compactControlSectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func moveUpButton(compact: Bool) -> some View {
        Button {
            appState.moveSelectedPage(up: true)
        } label: {
            organizerControlLabel("Move Up", systemImage: "arrow.up", compact: compact)
        }
        .disabled(!canMoveSelectedPage(up: true))
    }

    private func moveDownButton(compact: Bool) -> some View {
        Button {
            appState.moveSelectedPage(up: false)
        } label: {
            organizerControlLabel("Move Down", systemImage: "arrow.down", compact: compact)
        }
        .disabled(!canMoveSelectedPage(up: false))
    }

    private func moveToMenu(compact: Bool) -> some View {
        Menu {
            Button("Beginning of Document") {
                appState.moveSelectedPagesToBeginning()
            }
            Button("End of Document") {
                appState.moveSelectedPagesToEnd()
            }
        } label: {
            organizerControlLabel("Move To…", systemImage: "arrow.up.arrow.down", compact: compact)
        }
        .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(pageAssemblyPermissionHelp)
    }

    private func rotateLeftButton(compact: Bool) -> some View {
        Button {
            appState.rotateSelectedPages(clockwise: false)
        } label: {
            organizerControlLabel("Rotate Left", systemImage: "rotate.left", compact: compact)
        }
        .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(pageAssemblyPermissionHelp)
    }

    private func rotateRightButton(compact: Bool) -> some View {
        Button {
            appState.rotateSelectedPages(clockwise: true)
        } label: {
            organizerControlLabel("Rotate Right", systemImage: "rotate.right", compact: compact)
        }
        .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(pageAssemblyPermissionHelp)
    }

    private func deletePagesButton(compact: Bool) -> some View {
        Button(role: .destructive) {
            appState.requestDeleteSelectedPages()
        } label: {
            organizerControlLabel(deleteButtonTitle, systemImage: "trash", compact: compact)
        }
        .disabled(!appState.canAssembleActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(pageAssemblyPermissionHelp)
    }

    private func addOrMergeMenu(compact: Bool) -> some View {
        Menu {
            Button("Add Selected Pages From PDF…") {
                appState.requestAddPages()
            }
            Button("Merge Entire PDF…") {
                appState.requestMergePDF()
            }
        } label: {
            organizerControlLabel(
                "Add Pages / Merge PDF…",
                systemImage: "doc.badge.plus",
                compact: compact
            )
        }
        .disabled(!appState.canAssembleActiveDocument)
        .help(pageAssemblyPermissionHelp)
    }

    private func extractPagesButton(compact: Bool) -> some View {
        Button {
            appState.extractSelectedPages()
        } label: {
            organizerControlLabel(
                "Extract Selected Pages…",
                systemImage: "square.and.arrow.up",
                compact: compact
            )
        }
        .disabled(!appState.canExtractFromActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(
            appState.canExtractFromActiveDocument
                ? "Extract the selected pages into a new PDF."
                : "The PDF's permissions do not allow both page assembly and content copying."
        )
    }

    @ViewBuilder
    private func organizerControlLabel(
        _ title: String,
        systemImage: String,
        compact: Bool
    ) -> some View {
        if compact {
            Label {
                Text(title)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: systemImage)
            }
            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
        } else {
            Label(title, systemImage: systemImage)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var deleteButtonTitle: String {
        state.selectedPageIndexes.count == 1 ? "Delete Page" : "Delete Pages"
    }

    private var selectionBinding: Binding<Set<Int>> {
        Binding(
            get: { state.selectedPageIndexes },
            set: { appState.selectPageIndexes($0) }
        )
    }

    private var selectionDescription: String {
        switch state.selectedPageIndexes.count {
        case 0:
            "No pages selected"
        case 1:
            "1 page selected"
        default:
            "\(state.selectedPageIndexes.count) pages selected"
        }
    }

    private func canMoveSelectedPage(up: Bool) -> Bool {
        guard appState.canAssembleActiveDocument, state.selectedPageIndexes.count == 1 else {
            return false
        }

        if up {
            return state.selectedPageIndex > 0
        }
        return state.selectedPageIndex < state.pageCount - 1
    }

    private var pageAssemblyPermissionHelp: String {
        appState.canAssembleActiveDocument
            ? "Change pages in the working copy."
            : "The PDF's permissions do not allow page assembly changes."
    }

    private func dragPayload(for pageIndex: Int) -> OrganizerPageDragPayload {
        let pageIndexes = state.selectedPageIndexes.contains(pageIndex)
            ? state.selectedPageIndexes.sorted()
            : [pageIndex]
        return OrganizerPageDragPayload(pageIndexes: pageIndexes)
    }
}

private struct OrganizerPageDragPayload: Codable, Transferable {
    let pageIndexes: [Int]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .pdfViewerOrganizerPageSelection)
    }
}

private extension UTType {
    static let pdfViewerOrganizerPageSelection = UTType(
        exportedAs: "com.example.PDFViewer.organizer-page-selection"
    )
}

private struct OrganizerPageDropZone: View {
    @EnvironmentObject private var appState: AppState

    let destination: Int
    let edge: VerticalEdge
    @State private var isTargeted = false

    var body: some View {
        Rectangle()
            .fill(isTargeted ? Color.accentColor : Color.clear)
            .frame(height: isTargeted ? 3 : 14)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .dropDestination(for: OrganizerPageDragPayload.self) { payloads, _ in
                guard
                    appState.canAssembleActiveDocument,
                    let payload = payloads.first,
                    !payload.pageIndexes.isEmpty
                else {
                    return false
                }

                appState.selectPageIndexes(Set(payload.pageIndexes))
                appState.moveSelectedPages(to: destination)
                return true
            } isTargeted: { isTargeted in
                self.isTargeted = isTargeted
            }
            .accessibilityHidden(true)
            .frame(
                maxHeight: .infinity,
                alignment: edge == .top ? .top : .bottom
            )
    }
}

private struct ImportedPageSelectionSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    let pendingPDFImport: PendingPDFImport
    @State private var selectedPageIndexes: Set<Int>

    init(pendingPDFImport: PendingPDFImport) {
        self.pendingPDFImport = pendingPDFImport
        _selectedPageIndexes = State(
            initialValue: Set(0..<pendingPDFImport.document.pageCount)
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            importedPageHeader
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Divider()

            List(selection: $selectedPageIndexes) {
                ForEach(0..<pendingPDFImport.document.pageCount, id: \.self) { pageIndex in
                    OrganizerPageRow(document: pendingPDFImport.document, pageIndex: pageIndex)
                        .tag(pageIndex)
                }
            }
            .listStyle(.inset)

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    cancelButton
                    Spacer()
                    addPagesButton
                }

                VStack(alignment: .trailing, spacing: 8) {
                    addPagesButton
                    cancelButton
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(12)
            .background(.bar)
        }
        .frame(
            minWidth: 520,
            idealWidth: 640,
            minHeight: 420,
            idealHeight: 560
        )
    }

    private var importedPageHeader: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                importedPageTitle
                importedPageInstructions
                    .frame(width: 360, alignment: .leading)
            }
            .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: 6) {
                importedPageTitle
                importedPageInstructions
            }
        }
    }

    private var importedPageTitle: some View {
        Text("Choose Pages to Add")
            .font(.title2.weight(.semibold))
            .fixedSize(horizontal: true, vertical: false)
    }

    private var importedPageInstructions: some View {
        Text("Select pages from \(pendingPDFImport.sourceName). They will be inserted after the current page in the working copy.")
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var cancelButton: some View {
        Button("Cancel") {
            appState.cancelPendingPDFImport()
            dismiss()
        }
        .fixedSize()
    }

    private var addPagesButton: some View {
        Button(addButtonTitle) {
            appState.addPendingImportedPages(
                selectedPageIndexes: selectedPageIndexes
            )
            dismiss()
        }
        .buttonStyle(.borderedProminent)
        .disabled(!appState.canAssembleActiveDocument || selectedPageIndexes.isEmpty)
        .fixedSize()
    }

    private var addButtonTitle: String {
        selectedPageIndexes.count == 1
            ? "Add 1 Page"
            : "Add \(selectedPageIndexes.count) Pages"
    }
}

private struct OrganizerPageRow: View {
    let document: PDFDocument
    let pageIndex: Int

    var body: some View {
        HStack(spacing: 12) {
            if let page = document.page(at: pageIndex) {
                Image(nsImage: page.thumbnail(of: NSSize(width: 48, height: 64), for: .cropBox))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 64)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 3))
            } else {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                    .frame(width: 48, height: 64)
            }

            Text("Page \(pageIndex + 1)")
                .fontWeight(.medium)

            Spacer()

            if let rotation = document.page(at: pageIndex)?.rotation, rotation != 0 {
                Label("\(rotation)°", systemImage: "rotate.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

private extension PDFSearchController {
    var compactResultDescription: String {
        switch feedback {
        case .idle:
            ""
        case .matches:
            "\((activeMatchIndex ?? 0) + 1) / \(matchCount)"
        case .noMatches:
            "No results"
        case .textUnavailable:
            "No text"
        }
    }

    var resultDescription: String {
        switch feedback {
        case .idle:
            ""
        case .matches:
            "\((activeMatchIndex ?? 0) + 1) of \(matchCount)"
        case .noMatches:
            "No matches"
        case .textUnavailable:
            "No searchable text"
        }
    }
}

private extension ReaderTheme {
    var workspaceColor: Color {
        switch self {
        case .day:
            Color(red: 0.82, green: 0.82, blue: 0.82)
        case .night:
            Color(red: 0.055, green: 0.055, blue: 0.06)
        }
    }
}
