import AppKit
import SwiftUI

@MainActor
final class PDFViewerApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var appState: AppState?
    private var keyboardCommandMonitor: Any?

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
                let appState = self?.appState,
                appState.session != nil
            else {
                return event
            }

            let character = event.charactersIgnoringModifiers?.lowercased()
            if modifiers.isEmpty, event.keyCode == 53, appState.annotationState.isActive {
                appState.cancelAnnotationInteraction()
                return nil
            }

            if
                modifiers.isEmpty,
                event.keyCode == 51 || event.keyCode == 117,
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
        guard let appState else {
            return .terminateNow
        }
        return appState.requestApplicationTermination() ? .terminateNow : .terminateLater
    }
}

@main
@MainActor
struct PDFViewerApp: App {
    @StateObject private var appState = AppState()
    @NSApplicationDelegateAdaptor(PDFViewerApplicationDelegate.self) private var appDelegate
    private let windowLaunchConfiguration: WindowLaunchConfiguration

    init() {
        windowLaunchConfiguration = WindowLaunchConfiguration.current

        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .background(
                    WindowLaunchSizeController(
                        contentSize: windowLaunchConfiguration.initialSize,
                        shouldApply: windowLaunchConfiguration.hasUITestOverride
                    )
                )
                .onAppear {
                    appDelegate.appState = appState
                    appDelegate.installKeyboardCommandMonitorIfNeeded()
                    appState.terminationReplyHandler = { shouldTerminate in
                        NSApp.reply(toApplicationShouldTerminate: shouldTerminate)
                    }
                }
        }
        .defaultSize(
            width: windowLaunchConfiguration.initialSize.width,
            height: windowLaunchConfiguration.initialSize.height
        )
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open PDF...") {
                    appState.isFileImporterPresented = true
                }
                .keyboardShortcut("o")

                if appState.session != nil {
                    Button("Close PDF") {
                        appState.requestCloseDocument()
                    }
                    .keyboardShortcut("w")
                }
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo Document Operation") {
                    appState.undoPageOperation()
                }
                .keyboardShortcut("z")
                .disabled(appState.session?.editor.canUndo != true)

                Button("Redo Document Operation") {
                    appState.redoPageOperation()
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(appState.session?.editor.canRedo != true)
            }

            CommandGroup(replacing: .sidebar) {
                Button(
                    appState.readerState.isReaderSidebarVisible
                        ? "Hide Sidebar"
                        : "Show Sidebar"
                ) {
                    appState.readerState.toggleReaderSidebar()
                }
                .disabled(appState.session == nil)
            }

            CommandMenu("Find") {
                Button("Find in PDF…") {
                    appState.requestSearchFocus()
                }
                .keyboardShortcut("f")
                .disabled(appState.session == nil)

                Button("Find Next") {
                    appState.selectNextSearchResult()
                }
                .keyboardShortcut("g")
                .disabled(appState.searchController.matchCount == 0)

                Button("Find Previous") {
                    appState.selectPreviousSearchResult()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(appState.searchController.matchCount == 0)
            }

            CommandMenu("Navigate") {
                Button("Back") {
                    appState.navigateBack()
                }
                .keyboardShortcut("[")
                .disabled(!appState.canNavigateBack)

                Button("Forward") {
                    appState.navigateForward()
                }
                .keyboardShortcut("]")
                .disabled(!appState.canNavigateForward)

                Divider()

                Button("Previous Page") {
                    appState.goToAdjacentPage(offset: -1)
                }
                .keyboardShortcut(.upArrow, modifiers: [.option])
                .disabled(
                    appState.session == nil ||
                        appState.readerState.selectedPageIndex == 0
                )

                Button("Next Page") {
                    appState.goToAdjacentPage(offset: 1)
                }
                .keyboardShortcut(.downArrow, modifiers: [.option])
                .disabled(
                    appState.session == nil ||
                        appState.readerState.selectedPageIndex >= appState.readerState.pageCount - 1
                )

                Divider()

                Button("Fit Page") {
                    appState.readerState.requestZoom(.fit)
                }
                .keyboardShortcut("0")
                .disabled(appState.session == nil)

                Button("Zoom In") {
                    appState.readerState.requestZoom(.zoomIn)
                }
                .keyboardShortcut("=")
                .disabled(appState.session == nil)

                Button("Zoom Out") {
                    appState.readerState.requestZoom(.zoomOut)
                }
                .keyboardShortcut("-")
                .disabled(appState.session == nil)

                Divider()

                Button("Single Page") {
                    appState.setDisplayMode(.singlePage)
                }
                .keyboardShortcut("1")
                .disabled(appState.session == nil)

                Button("Two Page") {
                    appState.setDisplayMode(.twoPage)
                }
                .keyboardShortcut("2")
                .disabled(appState.session == nil)

                Button("Continuous") {
                    appState.setDisplayMode(.continuous)
                }
                .keyboardShortcut("3")
                .disabled(appState.session == nil)
            }
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
