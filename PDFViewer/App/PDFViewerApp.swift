import AppKit
import SwiftUI

@MainActor
final class PDFViewerApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var windowRegistry: WindowStateRegistry?
    private var keyboardCommandMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        AppDiagnostics.record(.applicationLaunched)
    }

    func installKeyboardCommandMonitorIfNeeded() {
        guard keyboardCommandMonitor == nil else {
            return
        }

        keyboardCommandMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard
                !(NSApp.keyWindow is NSPanel),
                NSApp.keyWindow?.attachedSheet == nil,
                // A presented sheet becomes the key window itself, so also
                // ignore shortcuts while any sheet is frontmost.
                NSApp.keyWindow?.sheetParent == nil,
                let appState = self?.windowRegistry?.state(for: NSApp.keyWindow),
                appState.session != nil
            else {
                return event
            }

            let character = event.charactersIgnoringModifiers?.lowercased()
            // Escape and Delete must keep their normal behavior while the user
            // is editing text (search field, page-number field, etc.).
            let isEditingText = NSApp.keyWindow?.firstResponder is NSText
            if modifiers.isEmpty, event.keyCode == 53, !isEditingText, appState.annotationState.isActive {
                appState.cancelAnnotationInteraction()
                return nil
            }

            if
                modifiers.isEmpty,
                event.keyCode == 51 || event.keyCode == 117,
                !isEditingText,
                appState.annotationState.selectedAnnotation?.isOwnedByPDFViewer == true
            {
                appState.deleteSelectedAnnotation()
                return nil
            }

            if modifiers == .command, character == "w" {
                appState.requestCloseDocument()
                return nil
            }

            if modifiers == [.command, .shift], character == "+" || character == "=" {
                appState.readerState.requestZoom(.zoomIn)
                return nil
            }

            return event
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let keyboardCommandMonitor {
            NSEvent.removeMonitor(keyboardCommandMonitor)
            self.keyboardCommandMonitor = nil
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let windowRegistry else {
            return .terminateNow
        }
        let canTerminateImmediately = windowRegistry.requestApplicationTermination {
            NSApp.reply(toApplicationShouldTerminate: $0)
        }
        return canTerminateImmediately ? .terminateNow : .terminateLater
    }
}

@main
@MainActor
struct PDFViewerApp: App {
    @StateObject private var sharedServices: SharedServices
    @StateObject private var windowRegistry: WindowStateRegistry
    @NSApplicationDelegateAdaptor(PDFViewerApplicationDelegate.self) private var appDelegate
    private let windowLaunchConfiguration: WindowLaunchConfiguration

    init() {
        _sharedServices = StateObject(wrappedValue: SharedServices())
        _windowRegistry = StateObject(wrappedValue: WindowStateRegistry())
        windowLaunchConfiguration = WindowLaunchConfiguration.current

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup(for: WindowLaunchRequest.self) { request in
            PDFViewerWindowRoot(
                sharedServices: sharedServices,
                windowRegistry: windowRegistry,
                launchRequest: request.wrappedValue
            )
                .background(
                    WindowLaunchSizeController(
                        contentSize: windowLaunchConfiguration.initialSize,
                        shouldApply: windowLaunchConfiguration.hasUITestOverride
                    )
                )
                .onAppear {
                    appDelegate.windowRegistry = windowRegistry
                    appDelegate.installKeyboardCommandMonitorIfNeeded()
                }
        }
        .defaultSize(
            width: windowLaunchConfiguration.initialSize.width,
            height: windowLaunchConfiguration.initialSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            PDFViewerCommands()
        }
    }
}

@MainActor
private struct PDFViewerWindowRoot: View {
    @StateObject private var appState: AppState
    @State private var didHandleInitialURL = false
    @State private var windowID: UUID

    private let windowRegistry: WindowStateRegistry
    private let initialURL: URL?

    init(
        sharedServices: SharedServices,
        windowRegistry: WindowStateRegistry,
        launchRequest: WindowLaunchRequest?
    ) {
        _appState = StateObject(wrappedValue: sharedServices.makeAppState())
        _windowID = State(initialValue: launchRequest?.id ?? UUID())
        self.windowRegistry = windowRegistry
        self.initialURL = launchRequest?.url
    }

    var body: some View {
        ContentView()
            .environmentObject(appState)
            .focusedSceneObject(appState)
            .background(
                WindowStateAttachment(
                    registry: windowRegistry,
                    appState: appState,
                    windowID: windowID
                )
            )
            .onAppear {
                windowRegistry.register(appState, id: windowID)
                handleInitialURLIfNeeded()
            }
            .onChange(of: initialURL) {
                handleInitialURLIfNeeded()
            }
    }

    private func handleInitialURLIfNeeded() {
        guard !didHandleInitialURL, let initialURL else {
            return
        }
        didHandleInitialURL = true
        appState.requestOpenDocument(at: initialURL)
    }
}

private struct WindowStateAttachment: NSViewRepresentable {
    let registry: WindowStateRegistry
    let appState: AppState
    let windowID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(registry: registry, windowID: windowID)
    }

    func makeNSView(context: Context) -> WindowRegistryAttachmentView {
        let view = WindowRegistryAttachmentView()
        view.windowChanged = { window in
            registry.register(appState, id: windowID)
            registry.attach(window, to: windowID)
        }
        return view
    }

    func updateNSView(_ view: WindowRegistryAttachmentView, context: Context) {
        registry.register(appState, id: windowID)
        registry.attach(view.window, to: windowID)
    }

    static func dismantleNSView(
        _ view: WindowRegistryAttachmentView,
        coordinator: Coordinator
    ) {
        view.windowChanged = nil
        coordinator.registry.unregister(id: coordinator.windowID)
    }

    @MainActor
    final class Coordinator {
        let registry: WindowStateRegistry
        let windowID: UUID

        init(registry: WindowStateRegistry, windowID: UUID) {
            self.registry = registry
            self.windowID = windowID
        }
    }
}

private final class WindowRegistryAttachmentView: NSView {
    var windowChanged: ((NSWindow?) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(window)
    }
}

@MainActor
private struct PDFViewerCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @FocusedObject private var appState: AppState?

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Window") {
                openWindow(value: WindowLaunchRequest())
            }
            .keyboardShortcut("n")

            Button("Open PDF...") {
                appState?.isFileImporterPresented = true
            }
            .keyboardShortcut("o")
            .disabled(appState == nil)

            Button("Create PDF From Images…") {
                appState?.chooseImagesForPDFCreation()
            }
            .disabled(appState == nil)

            Button("Convert PDF…") {
                appState?.presentConversion()
            }
            .disabled(appState?.canConvertActiveDocument != true)

            Button("Close PDF") {
                appState?.requestCloseDocument()
            }
            .keyboardShortcut("w")
            .disabled(appState?.session == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                appState?.printWorkingDocument()
            }
            .keyboardShortcut("p")
            .disabled(appState?.canPrintActiveDocument != true)
        }

        CommandGroup(replacing: .undoRedo) {
            Button("Undo Document Operation") {
                appState?.undoPageOperation()
            }
            .keyboardShortcut("z")
            .disabled(appState?.session?.editor.canUndo != true)

            Button("Redo Document Operation") {
                appState?.redoPageOperation()
            }
            .keyboardShortcut("z", modifiers: [.command, .shift])
            .disabled(appState?.session?.editor.canRedo != true)
        }

        CommandGroup(replacing: .sidebar) {
            Button(
                appState?.readerState.isReaderSidebarVisible == true
                    ? "Hide Sidebar"
                    : "Show Sidebar"
            ) {
                appState?.readerState.toggleReaderSidebar()
            }
            .disabled(appState?.session == nil)
        }

        CommandMenu("Find") {
            Button("Find in PDF…") {
                appState?.requestSearchFocus()
            }
            .keyboardShortcut("f")
            .disabled(appState?.session == nil)

            Button("Find Next") {
                appState?.selectNextSearchResult()
            }
            .keyboardShortcut("g")
            .disabled(appState?.searchController.matchCount == 0)

            Button("Find Previous") {
                appState?.selectPreviousSearchResult()
            }
            .keyboardShortcut("g", modifiers: [.command, .shift])
            .disabled(appState?.searchController.matchCount == 0)
        }

        CommandMenu("Navigate") {
            Button("Back") {
                appState?.navigateBack()
            }
            .keyboardShortcut("[")
            .disabled(appState?.canNavigateBack != true)

            Button("Forward") {
                appState?.navigateForward()
            }
            .keyboardShortcut("]")
            .disabled(appState?.canNavigateForward != true)

            Divider()

            Button("Previous Page") {
                appState?.goToAdjacentPage(offset: -1)
            }
            .keyboardShortcut(.upArrow, modifiers: [.option])
            .disabled(
                appState?.session == nil ||
                    appState?.readerState.selectedPageIndex == 0
            )

            Button("Next Page") {
                appState?.goToAdjacentPage(offset: 1)
            }
            .keyboardShortcut(.downArrow, modifiers: [.option])
            .disabled(
                appState?.session == nil ||
                    (appState?.readerState.selectedPageIndex ?? 0) >=
                    (appState?.readerState.pageCount ?? 0) - 1
            )

            Divider()

            Button("Fit Page") {
                appState?.readerState.requestZoom(.fit)
            }
            .keyboardShortcut("0")
            .disabled(appState?.session == nil)

            Button("Zoom In") {
                appState?.readerState.requestZoom(.zoomIn)
            }
            .keyboardShortcut("=")
            .disabled(appState?.session == nil)

            Button("Zoom Out") {
                appState?.readerState.requestZoom(.zoomOut)
            }
            .keyboardShortcut("-")
            .disabled(appState?.session == nil)

            Divider()

            Button("Single Page") {
                appState?.setDisplayMode(.singlePage)
            }
            .keyboardShortcut("1")
            .disabled(appState?.session == nil)

            Button("Two Page") {
                appState?.setDisplayMode(.twoPage)
            }
            .keyboardShortcut("2")
            .disabled(appState?.session == nil)

            Button("Continuous") {
                appState?.setDisplayMode(.continuous)
            }
            .keyboardShortcut("3")
            .disabled(appState?.session == nil)
        }
    }
}

private struct WindowLaunchConfiguration {
    let initialSize: CGSize
    let hasUITestOverride: Bool

    static var current: WindowLaunchConfiguration {
        let arguments = ProcessInfo.processInfo.arguments
        let width = value(after: "-PDFViewerUITestWindowWidth", in: arguments)
        let height = value(after: "-PDFViewerUITestWindowHeight", in: arguments)

        guard let width, let height, width >= 720, height >= 520 else {
            return WindowLaunchConfiguration(
                initialSize: CGSize(width: 1100, height: 720),
                hasUITestOverride: false
            )
        }

        return WindowLaunchConfiguration(
            initialSize: CGSize(width: width, height: height),
            hasUITestOverride: true
        )
    }

    private static func value(after flag: String, in arguments: [String]) -> CGFloat? {
        guard
            let flagIndex = arguments.firstIndex(of: flag),
            arguments.indices.contains(flagIndex + 1),
            let value = Double(arguments[flagIndex + 1]),
            value.isFinite
        else {
            return nil
        }
        return CGFloat(value)
    }
}

private struct WindowLaunchSizeController: NSViewRepresentable {
    let contentSize: CGSize
    let shouldApply: Bool

    func makeNSView(context: Context) -> WindowLaunchSizeAttachmentView {
        let view = WindowLaunchSizeAttachmentView()
        view.contentSize = contentSize
        view.shouldApply = shouldApply
        return view
    }

    func updateNSView(_ view: WindowLaunchSizeAttachmentView, context: Context) {
        view.contentSize = contentSize
        view.shouldApply = shouldApply
        view.applyIfNeeded()
    }
}

private final class WindowLaunchSizeAttachmentView: NSView {
    var contentSize = CGSize(width: 1100, height: 720)
    var shouldApply = false
    private weak var configuredWindow: NSWindow?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyIfNeeded()
    }

    func applyIfNeeded() {
        guard shouldApply, let window, configuredWindow !== window else {
            return
        }

        configuredWindow = window
        window.setContentSize(contentSize)
    }
}
