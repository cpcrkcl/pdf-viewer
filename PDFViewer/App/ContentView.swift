import AppKit
import CoreTransferable
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Catppuccin Mocha colors shared by the SwiftUI chrome and PDFKit canvas.
/// Keeping these values centralized prevents feature sheets from drifting into
/// a mixture of unrelated system colors as the app grows.
enum CatppuccinMocha {
    static let rosewater = Color(red: 245 / 255, green: 224 / 255, blue: 220 / 255)
    static let flamingo = Color(red: 242 / 255, green: 205 / 255, blue: 205 / 255)
    static let pink = Color(red: 245 / 255, green: 194 / 255, blue: 231 / 255)
    static let mauve = Color(red: 203 / 255, green: 166 / 255, blue: 247 / 255)
    static let red = Color(red: 243 / 255, green: 139 / 255, blue: 168 / 255)
    static let peach = Color(red: 250 / 255, green: 179 / 255, blue: 135 / 255)
    static let yellow = Color(red: 249 / 255, green: 226 / 255, blue: 175 / 255)
    static let green = Color(red: 166 / 255, green: 227 / 255, blue: 161 / 255)
    static let teal = Color(red: 148 / 255, green: 226 / 255, blue: 213 / 255)
    static let sky = Color(red: 137 / 255, green: 220 / 255, blue: 235 / 255)
    static let sapphire = Color(red: 116 / 255, green: 199 / 255, blue: 236 / 255)
    static let blue = Color(red: 137 / 255, green: 180 / 255, blue: 250 / 255)
    static let lavender = Color(red: 180 / 255, green: 190 / 255, blue: 254 / 255)
    static let text = Color(red: 205 / 255, green: 214 / 255, blue: 244 / 255)
    static let subtext = Color(red: 186 / 255, green: 194 / 255, blue: 222 / 255)
    static let overlay = Color(red: 127 / 255, green: 132 / 255, blue: 156 / 255)
    static let surface2 = Color(red: 88 / 255, green: 91 / 255, blue: 112 / 255)
    static let surface1 = Color(red: 69 / 255, green: 71 / 255, blue: 90 / 255)
    static let surface0 = Color(red: 49 / 255, green: 50 / 255, blue: 68 / 255)
    static let base = Color(red: 30 / 255, green: 30 / 255, blue: 46 / 255)
    static let mantle = Color(red: 24 / 255, green: 24 / 255, blue: 37 / 255)
    static let crust = Color(red: 17 / 255, green: 17 / 255, blue: 27 / 255)

    static let panelBorder = surface2.opacity(0.55)
    static let softShadow = Color.black.opacity(0.28)
}

/// A tinted, rounded-square symbol badge used to give sheets and the welcome
/// screen a consistent, friendlier visual identity.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.48, weight: .semibold))
            .foregroundStyle(CatppuccinMocha.crust)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [CatppuccinMocha.lavender, tint],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
                    .strokeBorder(.white.opacity(0.18))
            }
            .shadow(color: tint.opacity(0.28), radius: 6, y: 3)
            .accessibilityHidden(true)
    }
}

/// Standard sheet header: icon badge beside a title and optional subtitle.
struct SheetHeader: View {
    let title: String
    var subtitle: String? = nil
    let systemImage: String
    var tint: Color = .accentColor

    var body: some View {
        HStack(alignment: subtitle == nil ? .center : .top, spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint)
                .padding(.top, subtitle == nil ? 0 : 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

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

            if appState.isLoadingDocument {
                DocumentLoadingOverlay()
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.exportReceipt)
        .animation(.easeInOut(duration: 0.15), value: appState.isLoadingDocument)
        .frame(minWidth: 720, minHeight: 520)
        .tint(CatppuccinMocha.mauve)
        .preferredColorScheme(.dark)
        .background(
            WindowCloseGuard(
                appState: appState,
                closeRequestRevision: appState.windowCloseRequestRevision
            )
        )
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
        .sheet(isPresented: $appState.isSignatureLibraryPresented) {
            VisualSignatureLibrarySheet()
        }
        .sheet(isPresented: $appState.isStampLibraryPresented) {
            CustomStampLibrarySheet()
        }
        .sheet(isPresented: $appState.isFormEditorPresented) {
            if let editor = appState.session?.editor {
                PDFFormEditorSheet(editor: editor)
            }
        }
        .sheet(isPresented: $appState.isLocalProcessingPresented) {
            if let editor = appState.session?.editor {
                PDFOCRSheet(editor: editor)
            }
        }
        .sheet(isPresented: $appState.isConversionPresented) {
            if let editor = appState.session?.editor {
                PDFConversionSheet(editor: editor)
            }
        }
        .sheet(item: $appState.pendingBookmarkRename) { pendingBookmarkRename in
            BookmarkRenameSheet(pendingBookmarkRename: pendingBookmarkRename)
        }
        .sheet(item: $appState.pendingPDFComparison) { comparison in
            if let primary = appState.session?.editor.document {
                PDFComparisonSheet(
                    primaryDocument: primary,
                    primaryName: appState.session?.sourceURL.lastPathComponent ?? "Working Copy",
                    secondaryDocument: comparison.document,
                    secondaryName: comparison.displayName
                )
            }
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
        .alert(
            "Permanently Redact Selected Content?",
            isPresented: Binding(
                get: { appState.pendingPermanentRedaction != nil },
                set: { isPresented in
                    if !isPresented, appState.pendingPermanentRedaction != nil {
                        appState.cancelPermanentRedaction()
                    }
                }
            ),
            presenting: appState.pendingPermanentRedaction
        ) { pending in
            Button(
                "Apply \(pending.regionCount) Permanent \(pending.regionCount == 1 ? "Redaction" : "Redactions")",
                role: .destructive
            ) {
                appState.confirmPermanentRedaction()
            }
            Button("Cancel", role: .cancel) {
                appState.cancelPermanentRedaction()
            }
        } message: { pending in
            Text(
                "This will rasterize \(pending.pageCount) affected \(pending.pageCount == 1 ? "page" : "pages"), remove searchable text and interactive annotations from those pages, and clear document metadata. You can undo in this working session before export, but exported redactions cannot be reversed."
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

private struct DocumentLoadingOverlay: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 4) {
                Text("Preparing PDF…")
                    .font(.headline)
                Text("Creating a safe local working copy")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button("Cancel") {
                appState.cancelDocumentOpen()
            }
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 26)
        .background(CatppuccinMocha.mantle.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(CatppuccinMocha.panelBorder)
        }
        .shadow(color: CatppuccinMocha.softShadow, radius: 26, y: 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CatppuccinMocha.crust.opacity(0.72))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Preparing PDF")
    }
}

private struct PasswordUnlockSheet: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isPasswordFocused: Bool
    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                SheetHeader(
                    title: "Password Required",
                    subtitle: appState.pendingDocumentUnlock?.handle.displayName ?? "Protected PDF",
                    systemImage: "lock.fill",
                    tint: .gray
                )
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
            SheetHeader(
                title: pendingTextNote.isEditingExistingNote ? "Edit Text Note" : "Add Text Note",
                subtitle: "The note is stored in the working PDF and becomes permanent only in an exported copy.",
                systemImage: "note.text",
                tint: .yellow
            )

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
        .background(CatppuccinMocha.mantle.opacity(0.96), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(CatppuccinMocha.green.opacity(0.45))
        }
        .shadow(color: CatppuccinMocha.softShadow, radius: 18, y: 8)
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
        Image(systemName: "checkmark")
            .font(.system(size: 12, weight: .bold))
            .foregroundStyle(CatppuccinMocha.crust)
            .frame(width: 26, height: 26)
            .background(
                LinearGradient(
                    colors: [CatppuccinMocha.teal, CatppuccinMocha.green],
                    startPoint: .top,
                    endPoint: .bottom
                ),
                in: Circle()
            )
            .shadow(color: CatppuccinMocha.green.opacity(0.28), radius: 5, y: 2)
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
            Text(receiptDetail)
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
        case .flattenedForm:
            "Exported flattened form \(receipt.displayName)"
        case .createdFromImages:
            "Created \(receipt.displayName) from \(receipt.pageCount) \(receipt.pageCount == 1 ? "image" : "images")"
        case .convertedImages:
            "Exported \(receipt.pageCount) page \(receipt.pageCount == 1 ? "image" : "images")"
        case .convertedText:
            "Exported text from \(receipt.pageCount) \(receipt.pageCount == 1 ? "page" : "pages")"
        }
    }

    private var receiptDetail: String {
        let pages = "\(receipt.pageCount) \(receipt.pageCount == 1 ? "page" : "pages")"
        guard let formattedFileSize = receipt.formattedFileSize else {
            return pages
        }
        return "\(pages) · \(formattedFileSize)"
    }
}

private struct DropTargetOverlay: View {
    var body: some View {
        GeometryReader { proxy in
            let shortestDimension = min(proxy.size.width, proxy.size.height)
            let inset = min(18, max(10, shortestDimension * 0.025))

            ZStack {
                CatppuccinMocha.mauve.opacity(0.14)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        CatppuccinMocha.mauve.opacity(0.9),
                        style: StrokeStyle(lineWidth: 2.5, dash: [9])
                    )
                    .padding(inset)

                Label("Drop PDF to Open", systemImage: "doc.badge.plus")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(CatppuccinMocha.lavender)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 14)
                    .background(.regularMaterial, in: Capsule())
                    .overlay {
                        Capsule().strokeBorder(CatppuccinMocha.mauve.opacity(0.5))
                    }
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
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
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var recentDocuments: RecentDocumentsStore
    @State private var hoveredDocumentID: RecentDocument.ID?

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                hero
                featureHighlights
                if !recentDocuments.documents.isEmpty {
                    recentDocumentsCard
                }
                Label("You can also drop a PDF anywhere in this window", systemImage: "arrow.down.doc")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.top, 38)
            .padding(.bottom, 32)
        }
        .background {
            ZStack {
                CatppuccinMocha.base
                RadialGradient(
                    colors: [CatppuccinMocha.mauve.opacity(0.20), .clear],
                    center: UnitPoint(x: 0.22, y: 0.05),
                    startRadius: 10,
                    endRadius: 470
                )
                RadialGradient(
                    colors: [CatppuccinMocha.blue.opacity(0.10), .clear],
                    center: UnitPoint(x: 0.84, y: 0.48),
                    startRadius: 20,
                    endRadius: 420
                )
            }
            .ignoresSafeArea()
        }
    }

    private var hero: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.richtext.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(CatppuccinMocha.crust)
                .frame(width: 82, height: 82)
                .background(
                    LinearGradient(
                        colors: [CatppuccinMocha.lavender, CatppuccinMocha.mauve],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 22, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.2))
                }
                .shadow(color: CatppuccinMocha.mauve.opacity(0.34), radius: 22, y: 10)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text("PDFViewer")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(CatppuccinMocha.text)
                Text("A focused workspace for reading, annotating, and organizing PDFs—entirely on your Mac.")
                    .font(.callout)
                    .foregroundStyle(CatppuccinMocha.subtext)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
            }

            HStack(spacing: 12) {
                Button {
                    appState.presentOpenPDFPanel()
                } label: {
                    Label("Choose PDF...", systemImage: "folder.badge.plus")
                        .fontWeight(.semibold)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button {
                    appState.chooseImagesForPDFCreation()
                } label: {
                    Label("From Images…", systemImage: "photo.on.rectangle.angled")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Create PDF From Images")
            }
        }
        .padding(.horizontal, 34)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
        .background(CatppuccinMocha.mantle.opacity(0.86), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(CatppuccinMocha.panelBorder)
        }
        .shadow(color: CatppuccinMocha.softShadow, radius: 30, y: 14)
    }

    private var featureHighlights: some View {
        HStack(spacing: 0) {
            featureHighlight("Annotate", systemImage: "pencil.and.outline", tint: CatppuccinMocha.peach)
            featureHighlight("Organize", systemImage: "square.grid.2x2", tint: CatppuccinMocha.blue)
            featureHighlight("Fill Forms", systemImage: "list.bullet.rectangle", tint: CatppuccinMocha.green)
            featureHighlight("OCR", systemImage: "doc.text.viewfinder", tint: CatppuccinMocha.teal)
            featureHighlight("Redact", systemImage: "eye.slash", tint: CatppuccinMocha.pink)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(CatppuccinMocha.surface0.opacity(0.66), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CatppuccinMocha.panelBorder)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Features: annotate, organize, fill forms, OCR, and redact")
    }

    private func featureHighlight(_ title: String, systemImage: String, tint: Color) -> some View {
        VStack(spacing: 7) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(CatppuccinMocha.subtext)
        }
        .frame(maxWidth: .infinity)
    }

    private var recentDocumentsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Recent Documents")
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 12)
                .padding(.bottom, 6)

            ForEach(recentDocuments.documents) { document in
                recentDocumentRow(document)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CatppuccinMocha.mantle.opacity(0.84), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(CatppuccinMocha.panelBorder)
        }
    }

    private func recentDocumentRow(_ document: RecentDocument) -> some View {
        HStack(spacing: 10) {
            Button {
                appState.openRecentDocument(document)
            } label: {
                HStack(spacing: 11) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(CatppuccinMocha.lavender)
                        .frame(width: 28, height: 28)
                        .background(
                            CatppuccinMocha.mauve.opacity(0.14),
                            in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(document.displayName)
                            .fontWeight(.medium)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(document.displayName)
                        Text(document.lastOpenedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open recent document \(document.displayName)")

            Button {
                guard let url = appState.resolveRecentDocumentURL(document) else {
                    return
                }
                openWindow(value: WindowLaunchRequest(url: url))
            } label: {
                Image(systemName: "macwindow.badge.plus")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Open in New Window")
            .accessibilityLabel(
                "Open \(document.displayName) in a new window"
            )
            .opacity(hoveredDocumentID == document.id ? 1 : 0.35)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            hoveredDocumentID == document.id
                ? AnyShapeStyle(CatppuccinMocha.surface0.opacity(0.9))
                : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .onHover { isHovered in
            hoveredDocumentID = isHovered ? document.id : nil
        }
        .animation(.easeOut(duration: 0.12), value: hoveredDocumentID == document.id)
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
            SheetHeader(
                title: "Rename Bookmark",
                systemImage: "bookmark.fill",
                tint: .orange
            )

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

private struct VisualSignatureLibrarySheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var isImageImporterPresented = false
    @State private var isDrawingPresented = false

    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 12),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                title: "Visual Signatures",
                subtitle: "Choose a locally stored signature image to place on the PDF. This is a visual mark only—not a cryptographic or identity-verified signature.",
                systemImage: "signature",
                tint: .indigo
            )

            if appState.signatureLibrary.signatures.isEmpty {
                ContentUnavailableView(
                    "No Visual Signatures",
                    systemImage: "signature",
                    description: Text("Draw one or import a PNG or JPEG. Signatures stay in Application Support on this Mac.")
                )
                .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(appState.signatureLibrary.signatures) { signature in
                            signatureCard(signature)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .frame(minHeight: 220)
            }

            Divider()

            ViewThatFits(in: .horizontal) {
                HStack {
                    creationButtons
                    Spacer()
                    cancelButton
                }
                VStack(alignment: .leading, spacing: 10) {
                    creationButtons
                    HStack {
                        Spacer()
                        cancelButton
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 720, minHeight: 440, idealHeight: 560)
        .interactiveDismissDisabled()
        .fileImporter(
            isPresented: $isImageImporterPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false
        ) { result in
            appState.handleVisualSignatureImport(result)
        }
        .sheet(isPresented: $isDrawingPresented) {
            SignatureDrawingSheet()
        }
    }

    @ViewBuilder
    private func signatureCard(_ signature: StoredSignature) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if
                    let data = try? appState.signatureLibrary.imageData(for: signature.id),
                    let image = NSImage(data: data)
                {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                } else {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 86, maxHeight: 110)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            .accessibilityLabel("Preview of \(signature.displayName)")

            Text(signature.displayName)
                .font(.headline)
                .lineLimit(2)

            HStack {
                Button("Use") {
                    appState.chooseVisualSignature(signature)
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                Button("Delete", role: .destructive) {
                    appState.deleteVisualSignature(signature)
                }
            }
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
        }
    }

    private var creationButtons: some View {
        HStack {
            Button("Draw Signature…") {
                isDrawingPresented = true
            }
            Button("Import Image…") {
                isImageImporterPresented = true
            }
        }
    }

    private var cancelButton: some View {
        Button("Cancel") {
            appState.dismissVisualSignatureLibrary()
        }
        .keyboardShortcut(.cancelAction)
    }
}

private struct CustomStampLibrarySheet: View {
    @EnvironmentObject private var appState: AppState
    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SheetHeader(
                title: "Custom Stamps",
                subtitle: "Import PNG or JPEG artwork into a local-only stamp library.",
                systemImage: "seal.fill",
                tint: .teal
            )

            if appState.stampLibrary.signatures.isEmpty {
                ContentUnavailableView("No Custom Stamps", systemImage: "seal")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List(appState.stampLibrary.signatures) { stamp in
                    HStack(spacing: 12) {
                        if
                            let data = try? appState.stampLibrary.imageData(for: stamp.id),
                            let image = NSImage(data: data)
                        {
                            Image(nsImage: image)
                                .resizable().scaledToFit()
                                .frame(width: 90, height: 56)
                        }
                        Text(stamp.displayName)
                        Spacer()
                        Button("Use") { appState.chooseCustomStamp(stamp) }
                            .buttonStyle(.borderedProminent)
                        Button("Delete", role: .destructive) {
                            appState.deleteCustomStamp(stamp)
                        }
                    }
                }
            }

            Divider()
            HStack {
                Button("Import Artwork…") { isImporterPresented = true }
                Spacer()
                Button("Close") { appState.isStampLibraryPresented = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 420)
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.png, .jpeg],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                appState.importCustomStamp(at: url)
            }
        }
    }
}

private struct SignatureDrawingSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Visual Signature"
    @State private var strokes: [[CGPoint]] = []
    @State private var currentStroke: [CGPoint] = []

    private let canvasSize = CGSize(width: 480, height: 180)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SheetHeader(
                title: "Draw Visual Signature",
                subtitle: "Draw with the mouse or trackpad. The result is stored only on this Mac and is not a cryptographic signature.",
                systemImage: "pencil.tip",
                tint: .indigo
            )

            TextField("Signature name", text: $name)
                .textFieldStyle(.roundedBorder)

            Canvas { context, _ in
                for points in strokes + [currentStroke] where points.count >= 2 {
                    var path = Path()
                    path.move(to: points[0])
                    for point in points.dropFirst() {
                        path.addLine(to: point)
                    }
                    context.stroke(
                        path,
                        with: .color(.primary),
                        style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
                    )
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
            .gesture(signatureDragGesture)
            .accessibilityLabel("Signature drawing area")

            HStack {
                Button("Clear") {
                    strokes = []
                    currentStroke = []
                }
                .disabled(strokes.isEmpty && currentStroke.isEmpty)

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                Button("Add Signature") {
                    let inkStrokes = strokes.map {
                        InkStroke(
                            pageIndex: 0,
                            points: $0.map { point in
                                CGPoint(
                                    x: point.x,
                                    y: canvasSize.height - point.y
                                )
                            }
                        )
                    }
                    appState.createVisualSignature(
                        strokes: inkStrokes,
                        canvasSize: canvasSize,
                        displayName: name
                    )
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(strokes.allSatisfy { $0.count < 2 })
            }
        }
        .padding(20)
        .frame(minWidth: 540)
    }

    private var signatureDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let point = CGPoint(
                    x: min(max(0, value.location.x), canvasSize.width),
                    y: min(max(0, value.location.y), canvasSize.height)
                )
                if let last = currentStroke.last,
                   hypot(point.x - last.x, point.y - last.y) < 2 {
                    return
                }
                currentStroke.append(point)
            }
            .onEnded { _ in
                if currentStroke.count >= 2 {
                    strokes.append(currentStroke)
                }
                currentStroke = []
            }
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

/// Chooses between a regular and a compact layout based on the width the
/// container offers, like `ViewThatFits`, but without re-measuring every
/// candidate subtree on each layout pass. During a live window resize AppKit
/// asks the SwiftUI hosting view for a fresh layout *and* fresh min/max size
/// constraints on every frame, and `ViewThatFits` rebuilds and measures all of
/// its candidates for each of those passes, which made resizing the window
/// visibly lag. This container instead measures the regular tier's natural
/// width in a hidden, inert probe whose layout proposal never changes (so the
/// measurement is cached until the tier's content changes) and builds only the
/// selected tier.
private struct WidthAdaptiveRow<Regular: View, Compact: View>: View {
    @State private var showsRegular = true
    @State private var regularNaturalWidth: CGFloat?
    @State private var latestRowWidth = MutableBox<CGFloat>()

    @ViewBuilder let regular: () -> Regular
    @ViewBuilder let compact: () -> Compact

    var body: some View {
        Group {
            if showsRegular {
                regular()
            } else {
                compact()
            }
        }
        // Reporting exactly the proposed width keeps the hosting view's
        // min-size pass from descending into a fixed-width regular tier and
        // locking the window's minimum width to that tier's natural width.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .background(alignment: .leading) {
            measurementProbe
        }
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { width in
            latestRowWidth.value = width
            showsRegular = regularFits(in: width)
        }
        .onChange(of: regularNaturalWidth) {
            // The probe can deliver its first measurement after the row's
            // geometry callback already ran, so re-evaluate the choice.
            guard let rowWidth = latestRowWidth.value else {
                return
            }
            showsRegular = regularFits(in: rowWidth)
        }
    }

    private var measurementProbe: some View {
        regular()
            .fixedSize()
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { width in
                regularNaturalWidth = width
            }
            .hidden()
            .disabled(true)
            .accessibilityHidden(true)
            .frame(width: 0, height: 0)
    }

    private func regularFits(in rowWidth: CGFloat) -> Bool {
        guard let regularNaturalWidth else {
            return true
        }
        return regularNaturalWidth <= rowWidth + 0.5
    }
}

private final class MutableBox<Value> {
    var value: Value?
}

private struct ReaderWorkspace: View {
    @EnvironmentObject private var appState: AppState
    @FocusState private var isSearchFieldFocused: Bool
    @State private var isSearchResultsPresented = false
    @State private var isDocumentNavigatorPresented = false

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
        .sheet(isPresented: $isSearchResultsPresented) {
            SearchResultsSheet(editor: editor, search: search)
        }
        .sheet(isPresented: $isDocumentNavigatorPresented) {
            AnnotationFormNavigatorSheet(editor: editor)
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
            printRequestSequence: state.printRequestSequence,
            highlightedSelections: search.matches,
            activeSearchSelection: search.activeSelection,
            searchNavigationRevision: search.navigationRevision,
            annotationTool: annotations.isActive ? annotations.selectedTool : nil,
            selectedAnnotation: annotations.selectedAnnotation,
            clearAnnotationSelectionRevision: annotations.clearSelectionRevision,
            isRedactionModeActive: appState.redactionState.isActive,
            redactionRegions: appState.redactionState.regions,
            onTextMarkupRegionsChanged: appState.updateTextMarkupRegions,
            onTextSelectionCommitted: appState.commitSelectedTextMarkup,
            onInkStroke: appState.addInkStroke,
            onTextNotePlacement: appState.requestTextNote,
            onShapeAnnotation: appState.addShapeAnnotation,
            onBuiltInStampPlacement: appState.requestBuiltInStamp,
            onVisualSignaturePlacement: appState.requestVisualSignature,
            onAnnotationSelection: appState.selectAnnotation,
            onAnnotationMove: appState.moveAnnotation,
            onRedactionRegion: appState.addRedactionRegion,
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
            Rectangle()
                .fill(CatppuccinMocha.surface1.opacity(0.65))
                .frame(height: 1)
            adaptiveReaderControls
            if annotations.isActive {
                adaptiveAnnotationControls
            }
            if appState.redactionState.isActive {
                redactionControls
                    .padding(8)
                    .background(
                        CatppuccinMocha.red.opacity(0.08),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(CatppuccinMocha.red.opacity(0.25))
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .controlSize(.regular)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            LinearGradient(
                colors: [CatppuccinMocha.mantle, CatppuccinMocha.crust.opacity(0.96)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CatppuccinMocha.surface1.opacity(0.75))
                .frame(height: 1)
        }
    }

    private var adaptiveReaderControls: some View {
        WidthAdaptiveRow {
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
        } compact: {
            WidthAdaptiveRow {
                HStack(spacing: 12) {
                    compactReaderControls
                    searchControls(compact: true)
                }
                .fixedSize(horizontal: true, vertical: false)
            } compact: {
                VStack(alignment: .leading, spacing: 8) {
                    compactReaderControls
                    searchControls(compact: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var documentHeaderControls: some View {
        WidthAdaptiveRow {
            HStack(spacing: 8) {
                thumbnailSidebarButton
                navigationHistoryControls
                openDocumentButton
                organizeButton
                annotateButton
                documentToolsMenu
                exportButton
                documentFilename
                closeDocumentButton
            }
            .fixedSize(horizontal: true, vertical: false)
        } compact: {
            compactDocumentHeaderControls
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var compactDocumentHeaderControls: some View {
        HStack(spacing: 8) {
            thumbnailSidebarButton
            navigationHistoryControls

            Button {
                appState.presentOpenPDFPanel()
            } label: {
                Image(systemName: "folder")
            }
            .help("Open")
            .accessibilityLabel("Open")

            Button {
                appState.presentPageOrganizer()
            } label: {
                Image(systemName: "square.grid.2x2")
            }
            .help("Select and organize pages")
            .accessibilityLabel("Organize")

            Button {
                appState.toggleAnnotationMode()
            } label: {
                Image(
                    systemName: annotations.isActive
                        ? "pencil.circle.fill"
                        : "pencil.and.outline"
                )
            }
            .accessibilityLabel(annotations.isActive ? "Done Annotating" : "Annotate")
            .disabled(!annotations.isActive && !appState.canCommentOnActiveDocument)
            .help(
                !appState.canCommentOnActiveDocument
                    ? "The PDF's permissions do not allow commenting."
                    : (annotations.isActive ? "Finish annotating" : "Add annotations")
            )

            documentToolsMenu

            Button {
                appState.exportWorkingCopy()
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export a new PDF without changing the original")
            .accessibilityLabel("Export")

            Spacer(minLength: 0)

            Button {
                appState.requestCloseDocument()
            } label: {
                Image(systemName: "xmark")
            }
            .help("Close Document")
            .accessibilityLabel("Close Document")
            .accessibilityIdentifier("Close Document")
        }
        .fixedSize(horizontal: false, vertical: true)
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
            appState.presentOpenPDFPanel()
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

    private var formButton: some View {
        Button {
            appState.presentFormEditor()
        } label: {
            Label("Fill Form", systemImage: "list.bullet.rectangle")
        }
        .fixedSize()
        .disabled(!appState.canFillFormsInActiveDocument)
        .help(
            appState.canFillFormsInActiveDocument
                ? "Fill and validate interactive PDF form fields"
                : "This PDF has no writable form fields."
        )
        .accessibilityLabel("Fill PDF Form")
    }

    private var documentToolsMenu: some View {
        Menu {
            Button {
                appState.presentFormEditor()
            } label: {
                Label("Fill Form", systemImage: "list.bullet.rectangle")
            }
            .disabled(!appState.canFillFormsInActiveDocument)

            Button {
                isDocumentNavigatorPresented = true
            } label: {
                Label("Annotations & Form Navigator…", systemImage: "list.bullet.rectangle.portrait")
            }

            Button {
                appState.toggleRedactionMode()
            } label: {
                Label(
                    appState.redactionState.isActive ? "Done Selecting Redactions" : "Permanent Redaction…",
                    systemImage: "eye.slash"
                )
            }
            .disabled(!appState.redactionState.isActive && !appState.canRedactActiveDocument)

            Button {
                appState.presentLocalProcessing()
            } label: {
                Label("OCR & Scan Enhancement…", systemImage: "doc.text.viewfinder")
            }
            .disabled(!appState.canProcessActiveDocument)

            Button {
                appState.presentConversion()
            } label: {
                Label("Local Conversion…", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
            }
            .disabled(!appState.canConvertActiveDocument)

            Button {
                appState.presentComparePDFPanel()
            } label: {
                Label("Compare Side by Side…", systemImage: "rectangle.split.2x1")
            }
        } label: {
            Label("Tools", systemImage: "wrench.and.screwdriver")
        }
        .fixedSize()
        .help("Forms, permanent redaction, local OCR, scan enhancement, and conversion")
        .accessibilityLabel("Document Tools")
    }

    private var redactionButton: some View {
        Button {
            appState.toggleRedactionMode()
        } label: {
            Label(
                appState.redactionState.isActive ? "Done Redacting" : "Redact",
                systemImage: appState.redactionState.isActive
                    ? "eye.slash.circle.fill"
                    : "eye.slash"
            )
        }
        .fixedSize()
        .disabled(!appState.redactionState.isActive && !appState.canRedactActiveDocument)
        .help(
            appState.canRedactActiveDocument
                ? "Draw areas to remove permanently after confirmation"
                : "The PDF's permissions do not allow content changes."
        )
        .accessibilityLabel(
            appState.redactionState.isActive ? "Done Selecting Redactions" : "Redact PDF"
        )
    }

    private var localProcessingButton: some View {
        Button {
            appState.presentLocalProcessing()
        } label: {
            Label("OCR", systemImage: "doc.text.viewfinder")
        }
        .fixedSize()
        .disabled(!appState.canProcessActiveDocument)
        .help(
            appState.canProcessActiveDocument
                ? "Run local OCR or enhance selected scanned pages"
                : "The PDF's permissions do not allow replacing processed pages."
        )
        .accessibilityLabel("OCR and Scan Enhancement")
    }

    private var conversionButton: some View {
        Button {
            appState.presentConversion()
        } label: {
            Label("Convert", systemImage: "arrow.triangle.2.circlepath.doc.on.clipboard")
        }
        .fixedSize()
        .disabled(!appState.canConvertActiveDocument)
        .help(
            appState.canConvertActiveDocument
                ? "Convert PDF pages to images or text, or create a PDF from images"
                : "The PDF's permissions do not allow copying content for conversion."
        )
        .accessibilityLabel("Local PDF Conversion")
    }

    private var redactionControls: some View {
        WidthAdaptiveRow {
            HStack(spacing: 10) {
                Label("Draw rectangles over content to remove", systemImage: "viewfinder.rectangular")
                    .font(.callout.weight(.semibold))
                Text(redactionCountDescription)
                    .foregroundStyle(.secondary)
                redactionReasonField
                redactionActionButtons
            }
            .fixedSize(horizontal: true, vertical: false)
        } compact: {
            VStack(alignment: .leading, spacing: 6) {
                Label("Draw rectangles over content to remove", systemImage: "viewfinder.rectangular")
                    .font(.callout.weight(.semibold))
                redactionReasonField
                redactionActionButtons
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var redactionActionButtons: some View {
        HStack(spacing: 8) {
            Button("Undo Area") {
                appState.removeLastRedactionRegion()
            }
            .disabled(appState.redactionState.regions.isEmpty)

            Button("Clear Areas") {
                appState.clearRedactionRegions()
            }
            .disabled(appState.redactionState.regions.isEmpty)

            Button("Apply Permanently…", role: .destructive) {
                appState.requestApplyPermanentRedactions()
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(appState.redactionState.regions.isEmpty)

            Button("Cancel") {
                appState.toggleRedactionMode()
            }
        }
        .fixedSize()
    }

    private var redactionCountDescription: String {
        let count = appState.redactionState.regions.count
        return "\(count) \(count == 1 ? "area" : "areas") selected"
    }

    private var redactionReasonField: some View {
        TextField("Reason label (optional)", text: redactionReasonBinding)
            .textFieldStyle(.roundedBorder)
            .frame(width: 190)
            .help("Burn this label visibly into every redaction area")
            .accessibilityLabel("Optional redaction reason label")
    }

    private var redactionReasonBinding: Binding<String> {
        Binding(
            get: { appState.redactionState.reasonLabel },
            set: { appState.redactionState.updateReasonLabel($0) }
        )
    }

    private var adaptiveAnnotationControls: some View {
        WidthAdaptiveRow {
            regularAnnotationControls
                .fixedSize(horizontal: true, vertical: false)
        } compact: {
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
            if annotations.selectedTool != .signature &&
                annotations.selectedAnnotation?.kind != .signature {
                annotationColorMenu
            }
            if annotations.selectedTool == .freehand ||
                annotations.selectedTool.shapeKind != nil ||
                annotations.selectedAnnotation?.kind == .freehand ||
                annotations.selectedAnnotation?.kind?.shapeKind != nil {
                annotationLineWidthPicker
            }
            if annotations.selectedTool == .stamp {
                annotationStampPicker
            }
            if annotations.selectedTool == .signature ||
                annotations.selectedAnnotation?.kind == .signature {
                annotationSignatureSizePicker
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
            Divider()
            ColorPicker("Custom Color", selection: customAnnotationColorBinding, supportsOpacity: true)
        } label: {
            Label("Color: \(annotations.colorTitle)", systemImage: "paintpalette")
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
            if annotations.selectedTool != .signature &&
                annotations.selectedAnnotation?.kind != .signature {
                Menu("Color") {
                    ForEach(AnnotationPaletteColor.allCases) { color in
                        Button(color.title) {
                            appState.setAnnotationColor(color)
                        }
                    }
                    Divider()
                    ColorPicker("Custom Color", selection: customAnnotationColorBinding, supportsOpacity: true)
                }
            }

            if annotations.selectedTool == .freehand ||
                annotations.selectedTool.shapeKind != nil ||
                annotations.selectedAnnotation?.kind == .freehand ||
                annotations.selectedAnnotation?.kind?.shapeKind != nil {
                Menu("Ink Width") {
                    ForEach(AnnotationLineWidth.allCases) { lineWidth in
                        Button(lineWidth.title) {
                            appState.setAnnotationLineWidth(lineWidth)
                        }
                    }
                }
            }

            if annotations.selectedTool == .stamp {
                Menu("Stamp") {
                    ForEach(StampPreset.allCases) { preset in
                        Button(preset.title) {
                            appState.setStampPreset(preset)
                        }
                    }
                }
            }

            if annotations.selectedTool == .signature ||
                annotations.selectedAnnotation?.kind == .signature {
                Menu("Visual Signature Size") {
                    ForEach(SignatureSizePreset.allCases) { size in
                        Button(size.title) {
                            appState.setVisualSignatureSize(size)
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

            if selection.supportsControlledResize {
                Button("Smaller") {
                    appState.resizeSelectedAnnotation(scale: 0.8)
                }
                .help("Make the selected annotation smaller")
                .fixedSize()

                Button("Larger") {
                    appState.resizeSelectedAnnotation(scale: 1.25)
                }
                .help("Make the selected annotation larger")
                .fixedSize()
            }

            if selection.kind == .signature, selection.isOwnedByPDFViewer {
                Button("Rotate Left") {
                    appState.rotateSelectedVisualSignature(clockwise: false)
                }
                .fixedSize()

                Button("Rotate Right") {
                    appState.rotateSelectedVisualSignature(clockwise: true)
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
        .tint(CatppuccinMocha.mauve)
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

    private var customAnnotationColorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: annotations.effectiveColor) },
            set: { appState.setCustomAnnotationColor(NSColor($0)) }
        )
    }

    private var annotationSignatureSizePicker: some View {
        Picker("Visual Signature Size", selection: annotationSignatureSizeBinding) {
            ForEach(SignatureSizePreset.allCases) { size in
                Text(size.title).tag(size)
            }
        }
        .pickerStyle(.segmented)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var annotationStampPicker: some View {
        Menu {
            ForEach(StampPreset.allCases) { preset in
                Button(preset.title) { appState.setStampPreset(preset) }
            }
            Divider()
            Button("Custom Stamp Library…") { appState.presentStampLibrary() }
        } label: {
            Label(
                annotations.selectedCustomStampID == nil
                    ? annotations.selectedStamp.title
                    : "Custom Stamp",
                systemImage: "seal"
            )
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var annotationStampBinding: Binding<StampPreset> {
        Binding(
            get: { annotations.selectedStamp },
            set: { appState.setStampPreset($0) }
        )
    }

    private var annotationSignatureSizeBinding: Binding<SignatureSizePreset> {
        Binding(
            get: { annotations.selectedSignatureSize },
            set: { appState.setVisualSignatureSize($0) }
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
        HStack(spacing: 7) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(CatppuccinMocha.lavender)
                .accessibilityHidden(true)
            Text(sourceURL.lastPathComponent)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            if state.isDocumentDirty {
                Circle()
                    .fill(CatppuccinMocha.peach)
                    .frame(width: 7, height: 7)
                    .help("Working copy has unexported changes")
                    .accessibilityLabel("Unexported changes")
            }
        }
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

            Text("(\(state.pageLabel(for: state.selectedPageIndex, in: editor.document)))")
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .help("Displayed page label")

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

            Picker("Page Labels", selection: $state.pageLabelStyle) {
                ForEach(PageLabelStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            if state.pageLabelStyle != .document {
                Stepper("First label: \(state.pageLabelStart)", value: $state.pageLabelStart, in: 1...9999)
                TextField("Label prefix", text: $state.pageLabelPrefix)
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

            TextField(
                "Search text",
                text: Binding(
                    get: { search.query },
                    set: { search.updateQuery($0) }
                )
            )
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

            Menu {
                Toggle(
                    "Case Sensitive",
                    isOn: Binding(
                        get: { search.options.isCaseSensitive },
                        set: {
                            appState.updateSearchOptions(
                                caseSensitive: $0,
                                wholeWords: search.options.matchesWholeWords
                            )
                        }
                    )
                )
                Toggle(
                    "Whole Words",
                    isOn: Binding(
                        get: { search.options.matchesWholeWords },
                        set: {
                            appState.updateSearchOptions(
                                caseSensitive: search.options.isCaseSensitive,
                                wholeWords: $0
                            )
                        }
                    )
                )
                Divider()
                Button("Show Match List…") {
                    isSearchResultsPresented = true
                }
                .disabled(search.matchCount == 0)
            } label: {
                Image(systemName: "line.3.horizontal.decrease.circle")
            }
            .help("Search Options and Match List")

            Button {
                appState.clearSearch()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .disabled(search.query.isEmpty && search.matchCount == 0)
            .help("Clear Search")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            CatppuccinMocha.surface0.opacity(0.72),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(CatppuccinMocha.panelBorder)
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

private struct SearchResultsSheet: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var editor: PDFDocumentEditor
    @ObservedObject var search: PDFSearchController
    @State private var selectedMatchIndexes: Set<Int> = []

    private var summaries: [PDFSearchMatchSummary] {
        search.summaries(in: editor.document)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                SheetHeader(
                    title: "Search Matches",
                    subtitle: "Select matches to navigate or turn into permanent-redaction candidates.",
                    systemImage: "text.magnifyingglass",
                    tint: .blue
                )
                Spacer()
                Text("\(summaries.count) matches")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(18)

            Divider()

            List(summaries, selection: $selectedMatchIndexes) { summary in
                Button {
                    selectedMatchIndexes = [summary.id]
                    appState.selectSearchResult(at: summary.id)
                } label: {
                    HStack {
                        Text("Page \(summary.pageNumber)")
                            .fontWeight(.semibold)
                            .frame(width: 76, alignment: .leading)
                        Text(summary.text)
                            .lineLimit(2)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .tag(summary.id)
            }

            Divider()

            HStack {
                Button("Select All") {
                    selectedMatchIndexes = Set(summaries.map(\.id))
                }
                Button("Clear Selection") {
                    selectedMatchIndexes.removeAll()
                }
                Spacer()
                Button("Close") { dismiss() }
                Button("Mark for Redaction…") {
                    appState.markSearchMatchesForRedaction(selectedMatchIndexes)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(selectedMatchIndexes.isEmpty || !appState.canRedactActiveDocument)
            }
            .padding(14)
        }
        .frame(minWidth: 560, minHeight: 420)
        .onAppear {
            if let active = search.activeMatchIndex { selectedMatchIndexes = [active] }
        }
    }
}

private struct AnnotationFormNavigatorSheet: View {
    private enum Tab: String, CaseIterable, Identifiable {
        case annotations = "Annotations"
        case forms = "Form Fields"
        var id: Self { self }
    }

    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var editor: PDFDocumentEditor
    @State private var tab: Tab = .annotations

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SheetHeader(
                    title: "Document Navigator",
                    subtitle: "Jump to annotations and interactive form fields by page.",
                    systemImage: "list.bullet.rectangle.portrait",
                    tint: .purple
                )
                Spacer()
            }
            .padding(18)

            Picker("Navigator", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 18)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch tab {
                case .annotations: annotationList
                case .forms: formList
                }
            }

            Divider()
            HStack {
                Text(tab == .annotations
                     ? "Only annotations created by PDFViewer can be deleted."
                     : "Use Fill Form to edit writable field values.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(minWidth: 580, minHeight: 440)
    }

    private var annotationList: some View {
        List(editor.ownedAnnotations) { item in
            HStack(spacing: 10) {
                Button {
                    appState.navigateToOwnedAnnotation(item)
                } label: {
                    HStack {
                        Label(item.kind.title, systemImage: item.kind.systemImage)
                            .frame(width: 150, alignment: .leading)
                        Text(item.label).lineLimit(1)
                        Spacer()
                        Text("Page \(item.pageNumber)")
                            .foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if item.isInk {
                    Button(role: .destructive) {
                        appState.deleteOwnedAnnotation(item)
                    } label: {
                        Image(systemName: "eraser")
                    }
                    .help("Delete this owned ink stroke")
                }
            }
        }
        .overlay {
            if editor.ownedAnnotations.isEmpty {
                ContentUnavailableView("No Owned Annotations", systemImage: "pencil.slash")
            }
        }
    }

    private var formList: some View {
        List(editor.formFields) { field in
            Button {
                appState.navigateToFormField(field)
            } label: {
                HStack {
                    Text(field.displayName)
                    Spacer()
                    Text(field.kind.rawValue.capitalized)
                        .foregroundStyle(.secondary)
                    Text("Page \(field.pageIndex + 1)")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .overlay {
            if editor.formFields.isEmpty {
                ContentUnavailableView("No Form Fields", systemImage: "list.bullet.rectangle")
            }
        }
    }
}

private struct PDFComparisonSheet: View {
    @EnvironmentObject private var appState: AppState
    let primaryDocument: PDFDocument
    let primaryName: String
    let secondaryDocument: PDFDocument
    let secondaryName: String
    @State private var synchronizedPageIndex = 0
    @State private var synchronizesPages = true
    @State private var primaryPageIndex = 0
    @State private var secondaryPageIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                SheetHeader(
                    title: "Side-by-Side Comparison",
                    systemImage: "rectangle.split.2x1",
                    tint: .cyan
                )
                Spacer()
                Toggle("Sync pages", isOn: $synchronizesPages)
                    .toggleStyle(.switch)
                Button("Close") { appState.pendingPDFComparison = nil }
            }
            .padding(14)
            Divider()
            HStack(spacing: 1) {
                comparePane(document: primaryDocument, name: primaryName, isPrimary: true)
                Divider()
                comparePane(document: secondaryDocument, name: secondaryName, isPrimary: false)
            }
        }
        .frame(minWidth: 900, minHeight: 650)
        .onChange(of: synchronizedPageIndex) {
            guard synchronizesPages else { return }
            primaryPageIndex = min(synchronizedPageIndex, max(0, primaryDocument.pageCount - 1))
            secondaryPageIndex = min(synchronizedPageIndex, max(0, secondaryDocument.pageCount - 1))
        }
    }

    private func comparePane(document: PDFDocument, name: String, isPrimary: Bool) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(name).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Text("Page \((isPrimary ? primaryPageIndex : secondaryPageIndex) + 1) of \(document.pageCount)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(10)
            Divider()
            ComparePDFPane(
                document: document,
                pageIndex: isPrimary ? $primaryPageIndex : $secondaryPageIndex,
                onVisiblePageChange: { index in
                    if synchronizesPages {
                        synchronizedPageIndex = index
                    }
                }
            )
        }
    }
}

private struct ComparePDFPane: NSViewRepresentable {
    let document: PDFDocument
    @Binding var pageIndex: Int
    let onVisiblePageChange: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.autoScales = true
        context.coordinator.observe(view)
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        context.coordinator.parent = self
        if view.document !== document { view.document = document }
        guard
            (0..<document.pageCount).contains(pageIndex),
            let page = document.page(at: pageIndex),
            view.currentPage !== page
        else { return }
        context.coordinator.isNavigatingProgrammatically = true
        view.go(to: page)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ComparePDFPane
        var isNavigatingProgrammatically = false
        weak var view: PDFView?

        init(parent: ComparePDFPane) { self.parent = parent }
        func observe(_ view: PDFView) {
            self.view = view
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: view
            )
        }
        @objc private func pageChanged(_ note: Notification) {
            guard
                let view = note.object as? PDFView,
                let document = view.document,
                let page = view.currentPage
            else { return }
            let index = document.index(for: page)
            guard index != NSNotFound else { return }
            isNavigatingProgrammatically = false
            parent.pageIndex = index
            parent.onVisiblePageChange(index)
        }
        deinit { NotificationCenter.default.removeObserver(self) }
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
                    OrganizerPageRow(
                        document: editor.document,
                        pageIndex: pageIndex,
                        displayLabel: state.pageLabel(for: pageIndex, in: editor.document)
                    )
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
        HStack(spacing: 10) {
            IconBadge(systemImage: "square.grid.2x2", tint: .blue, size: 30)
            Text("Organize Pages")
                .font(.title3.weight(.semibold))
        }
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
        Menu {
            Button("Selected Pages as PDF…") {
                appState.extractSelectedPages()
            }
            Menu("Selected Pages as Images") {
                ForEach(PDFImageExportFormat.allCases) { format in
                    Button("\(format.title), 144 DPI…") {
                        appState.exportPagesAsImages(
                            pageIndexes: state.selectedPageIndexSet,
                            format: format,
                            dpi: 144
                        )
                    }
                }
            }
        } label: {
            organizerControlLabel(
                "Export Selected Pages…",
                systemImage: "square.and.arrow.up",
                compact: compact
            )
        }
        .disabled(!appState.canExtractFromActiveDocument || state.selectedPageIndexes.isEmpty)
        .help(
            appState.canExtractFromActiveDocument
                ? "Export the selected pages as a new PDF or a numbered image set."
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
        exportedAs: "com.christopherrego.PDFViewer.organizer-page-selection"
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
        HStack(spacing: 10) {
            IconBadge(systemImage: "doc.badge.plus", tint: .green, size: 30)
            Text("Choose Pages to Add")
                .font(.title3.weight(.semibold))
        }
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
    var displayLabel: String? = nil

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

            Text(displayLabel.map { "Page \(pageIndex + 1) · \($0)" } ?? "Page \(pageIndex + 1)")
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
            CatppuccinMocha.base
        case .sepia:
            Color(red: 0.70, green: 0.63, blue: 0.49)
        }
    }
}
