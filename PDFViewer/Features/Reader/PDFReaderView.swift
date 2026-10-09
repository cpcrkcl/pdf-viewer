import AppKit
@preconcurrency import PDFKit
import SwiftUI

struct PDFReaderView: NSViewRepresentable {
    let document: PDFDocument
    @Binding var selectedPageIndex: Int
    let displayMode: ReaderDisplayMode
    let theme: ReaderTheme
    let isReaderSidebarVisible: Bool
    let selectedSidebarTab: ReaderSidebarTab
    let outlineNodes: [DocumentOutlineNode]
    let resolvedBookmarks: [ResolvedPageBookmark]
    let availablePageIDs: Set<WorkingPageID>
    let zoomRequest: ReaderZoomRequest
    let printRequestSequence: Int
    let highlightedSelections: [PDFSelection]
    let activeSearchSelection: PDFSelection?
    let searchNavigationRevision: Int
    let annotationTool: AnnotationTool?
    let selectedAnnotation: SelectedAnnotation?
    let clearAnnotationSelectionRevision: Int
    let isRedactionModeActive: Bool
    let redactionRegions: [PDFRedactionRegion]
    let onTextMarkupRegionsChanged: ([TextMarkupRegion]) -> Void
    let onTextSelectionCommitted: () -> Void
    let onInkStroke: (InkStroke) -> Void
    let onTextNotePlacement: (AnnotationPlacement) -> Void
    let onShapeAnnotation: (ShapeAnnotationPlacement) -> Void
    let onBuiltInStampPlacement: (AnnotationPlacement) -> Void
    let onVisualSignaturePlacement: (AnnotationPlacement) -> Void
    let onAnnotationSelection: (SelectedAnnotation?) -> Void
    let onAnnotationMove: (SelectedAnnotation, CGSize) -> Void
    let onRedactionRegion: (PDFRedactionRegion) -> Void
    let onSidebarTabChange: (ReaderSidebarTab) -> Void
    let onThumbnailNavigation: (Int) -> Void
    let onOutlineNavigation: (WorkingPageID) -> Void
    let onBookmarkNavigation: (PageBookmark) -> Void
    let onAddBookmark: () -> Void
    let onRenameBookmark: (PageBookmark) -> Void
    let onDeleteBookmark: (PageBookmark) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> ReaderSplitView {
        let splitView = ReaderSplitView()
        splitView.pdfView.document = document
        splitView.thumbnailView.pdfView = splitView.pdfView
        splitView.thumbnailView.onExplicitPageSelection = onThumbnailNavigation
        context.coordinator.observe(splitView.pdfView)
        configure(splitView, coordinator: context.coordinator)
        return splitView
    }

    func updateNSView(_ splitView: ReaderSplitView, context: Context) {
        context.coordinator.parent = self

        if splitView.pdfView.document !== document {
            splitView.pdfView.document = document
            splitView.thumbnailView.pdfView = splitView.pdfView
        }

        configure(splitView, coordinator: context.coordinator)
    }

    private func configure(_ splitView: ReaderSplitView, coordinator: Coordinator) {
        let pdfView = splitView.pdfView
        applyDisplayMode(to: pdfView)
        applyTheme(to: splitView)
        splitView.setReaderSidebarVisible(isReaderSidebarVisible)
        splitView.thumbnailView.onExplicitPageSelection = onThumbnailNavigation
        splitView.configureSidebar(
            selectedTab: selectedSidebarTab,
            outlineNodes: outlineNodes,
            bookmarks: resolvedBookmarks,
            availablePageIDs: availablePageIDs,
            onTabChange: onSidebarTabChange,
            onOutlineNavigation: onOutlineNavigation,
            onBookmarkNavigation: onBookmarkNavigation,
            onAddBookmark: onAddBookmark,
            onRenameBookmark: onRenameBookmark,
            onDeleteBookmark: onDeleteBookmark
        )
        configureAnnotationInteraction(splitView.pdfView)

        if
            document.pageCount > 0,
            (0..<document.pageCount).contains(selectedPageIndex),
            let selectedPage = document.page(at: selectedPageIndex),
            pdfView.currentPage !== selectedPage
        {
            coordinator.pendingProgrammaticPageIndex = selectedPageIndex
            pdfView.go(to: selectedPage)
        }

        applySearch(to: pdfView, coordinator: coordinator)
        applyAnnotationSelection(to: pdfView, coordinator: coordinator)
        applyPrintRequest(to: pdfView, coordinator: coordinator)

        if coordinator.lastClearAnnotationSelectionRevision != clearAnnotationSelectionRevision {
            coordinator.lastClearAnnotationSelectionRevision = clearAnnotationSelectionRevision
            pdfView.setCurrentSelection(nil, animate: false)
        }

        guard coordinator.lastZoomSequence != zoomRequest.sequence else {
            return
        }

        coordinator.lastZoomSequence = zoomRequest.sequence
        switch zoomRequest.action {
        case .fit:
            pdfView.autoScales = true
        case .zoomIn:
            pdfView.autoScales = false
            pdfView.zoomIn(nil)
        case .zoomOut:
            pdfView.autoScales = false
            pdfView.zoomOut(nil)
        }
    }

    private func configureAnnotationInteraction(_ pdfView: InteractivePDFView) {
        pdfView.annotationTool = annotationTool
        pdfView.selectedAnnotation = selectedAnnotation
        pdfView.onTextSelectionCommitted = onTextSelectionCommitted
        pdfView.onInkStroke = onInkStroke
        pdfView.onTextNotePlacement = onTextNotePlacement
        pdfView.onShapeAnnotation = onShapeAnnotation
        pdfView.onBuiltInStampPlacement = onBuiltInStampPlacement
        pdfView.onVisualSignaturePlacement = onVisualSignaturePlacement
        pdfView.onAnnotationSelection = onAnnotationSelection
        pdfView.onAnnotationMove = onAnnotationMove
        pdfView.isRedactionModeActive = isRedactionModeActive
        pdfView.redactionRegions = redactionRegions
        pdfView.onRedactionRegion = onRedactionRegion
    }

    private func applyAnnotationSelection(
        to pdfView: PDFView,
        coordinator: Coordinator
    ) {
        guard coordinator.lastSelectedAnnotation != selectedAnnotation else {
            return
        }
        coordinator.lastSelectedAnnotation = selectedAnnotation

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }
            for annotation in page.annotations {
                guard let identifier = AnnotationIdentifier(annotation: annotation) else {
                    continue
                }
                annotation.isHighlighted = selectedAnnotation?.pageIndex == pageIndex &&
                    selectedAnnotation?.identifier == identifier
            }
        }
        pdfView.needsDisplay = true
    }

    private func applyPrintRequest(to pdfView: PDFView, coordinator: Coordinator) {
        guard coordinator.lastPrintRequestSequence != printRequestSequence else {
            return
        }
        coordinator.lastPrintRequestSequence = printRequestSequence

        guard pdfView.document != nil else {
            return
        }
        pdfView.print(with: .shared, autoRotate: true)
    }

    private func applyDisplayMode(to pdfView: PDFView) {
        if pdfView.displaysAsBook {
            pdfView.displaysAsBook = false
        }

        let desiredMode: PDFDisplayMode
        let desiredDirection: PDFDisplayDirection

        switch displayMode {
        case .singlePage:
            desiredMode = .singlePage
            desiredDirection = .horizontal
        case .twoPage:
            desiredMode = .twoUp
            desiredDirection = .horizontal
        case .continuous:
            desiredMode = .singlePageContinuous
            desiredDirection = .vertical
        }

        if pdfView.displayMode != desiredMode {
            pdfView.displayMode = desiredMode
        }
        if pdfView.displayDirection != desiredDirection {
            pdfView.displayDirection = desiredDirection
        }
    }

    private func applyTheme(to splitView: ReaderSplitView) {
        // PDFKit's dark Aqua rendering can paint opaque black regions over a
        // document page. Keep the AppKit reader in its stable Aqua appearance
        // and theme only the surrounding canvas colors.
        if splitView.appearance?.name != .aqua {
            splitView.appearance = NSAppearance(named: .aqua)
        }
        if splitView.pdfView.backgroundColor != theme.pdfBackgroundColor {
            splitView.pdfView.backgroundColor = theme.pdfBackgroundColor
        }
        if splitView.thumbnailView.backgroundColor != theme.thumbnailBackgroundColor {
            splitView.thumbnailView.backgroundColor = theme.thumbnailBackgroundColor
        }
        splitView.wantsLayer = true
        if splitView.layer?.backgroundColor != theme.pdfBackgroundColor.cgColor {
            splitView.layer?.backgroundColor = theme.pdfBackgroundColor.cgColor
        }
    }

    private func applySearch(to pdfView: PDFView, coordinator: Coordinator) {
        let highlightsAreUnchanged =
            coordinator.lastHighlightedSelections.count == highlightedSelections.count &&
            zip(coordinator.lastHighlightedSelections, highlightedSelections).allSatisfy { old, new in
                old === new
            }
        if !highlightsAreUnchanged {
            coordinator.lastHighlightedSelections = highlightedSelections
            pdfView.highlightedSelections = highlightedSelections
        }

        guard coordinator.lastSearchNavigationRevision != searchNavigationRevision else {
            return
        }

        coordinator.lastSearchNavigationRevision = searchNavigationRevision
        guard let activeSearchSelection else {
            pdfView.setCurrentSelection(nil, animate: false)
            return
        }

        pdfView.setCurrentSelection(activeSearchSelection, animate: true)
        pdfView.go(to: activeSearchSelection)
    }

    @MainActor
    final class Coordinator: NSObject {
        var parent: PDFReaderView
        var lastZoomSequence = -1
        var lastSearchNavigationRevision = -1
        var lastClearAnnotationSelectionRevision = -1
        var lastPrintRequestSequence: Int
        var lastSelectedAnnotation: SelectedAnnotation?
        var lastHighlightedSelections: [PDFSelection] = []
        var pendingProgrammaticPageIndex: Int?

        private weak var observedPDFView: PDFView?

        init(parent: PDFReaderView) {
            self.parent = parent
            // A print request made before this reader existed (or before a
            // document swap rebuilt it) must not open a print panel now.
            self.lastPrintRequestSequence = parent.printRequestSequence
        }

        func observe(_ pdfView: PDFView) {
            if let observedPDFView {
                NotificationCenter.default.removeObserver(
                    self,
                    name: .PDFViewPageChanged,
                    object: observedPDFView
                )
                NotificationCenter.default.removeObserver(
                    self,
                    name: .PDFViewSelectionChanged,
                    object: observedPDFView
                )
            }

            observedPDFView = pdfView
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(pageChanged(_:)),
                name: .PDFViewPageChanged,
                object: pdfView
            )
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(selectionChanged(_:)),
                name: .PDFViewSelectionChanged,
                object: pdfView
            )
        }

        @objc
        private func selectionChanged(_ notification: Notification) {
            guard
                let pdfView = notification.object as? PDFView,
                let document = pdfView.document,
                let selection = pdfView.currentSelection
            else {
                parent.onTextMarkupRegionsChanged([])
                return
            }

            let regions = selection.selectionsByLine().flatMap { lineSelection in
                lineSelection.pages.compactMap { page -> TextMarkupRegion? in
                    let pageIndex = document.index(for: page)
                    guard pageIndex != NSNotFound else {
                        return nil
                    }
                    let bounds = lineSelection.bounds(for: page)
                    guard !bounds.isEmpty, !bounds.isNull else {
                        return nil
                    }
                    return TextMarkupRegion(pageIndex: pageIndex, bounds: bounds)
                }
            }
            parent.onTextMarkupRegionsChanged(regions)
        }

        @objc
        private func pageChanged(_ notification: Notification) {
            guard
                let pdfView = notification.object as? PDFView,
                let document = pdfView.document,
                let currentPage = pdfView.currentPage
            else {
                return
            }

            let pageIndex = document.index(for: currentPage)
            guard pageIndex != NSNotFound else {
                return
            }

            // PDFKit may report a different visible page while recalculating a
            // continuous layout. ReaderSplitView restores the pre-resize page
            // when the resize or full-screen transition completes.
            if
                let splitView = pdfView.superview as? ReaderSplitView,
                splitView.isPreservingPageDuringResize
            {
                return
            }

            if let pendingProgrammaticPageIndex {
                if pageIndex == pendingProgrammaticPageIndex {
                    self.pendingProgrammaticPageIndex = nil
                }
                if
                    pageIndex != parent.selectedPageIndex,
                    document.pageCount > 0,
                    (0..<document.pageCount).contains(parent.selectedPageIndex),
                    let desiredPage = document.page(at: parent.selectedPageIndex)
                {
                    self.pendingProgrammaticPageIndex = parent.selectedPageIndex
                    DispatchQueue.main.async {
                        pdfView.go(to: desiredPage)
                    }
                }
                return
            }

            guard pageIndex != parent.selectedPageIndex else {
                return
            }

            parent.selectedPageIndex = pageIndex
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

final class ReaderSplitView: NSSplitView, NSSplitViewDelegate {
    let thumbnailView: TrackingPDFThumbnailView
    let pdfView: InteractivePDFView
    private let sidebarHostingView: NSHostingView<AnyView>
    private let sidebarPresentation: ReaderSidebarPresentation

    private(set) var isReaderSidebarVisible = true
    private(set) var lastVisibleSidebarWidth: CGFloat = 170
    private(set) var isPreservingPageDuringResize = false
    private var shouldRestoreAutoScalesAfterLiveResize = false
    private var preservedPageDuringResize: PDFPage?
    private var pagePreservationReasons: Set<PagePreservationReason> = []
    private var pageRestorationGeneration = 0
    private var isLiveResizeRenderingModeActive = false
    private var liveResizeInitialSize: NSSize?
    private var liveResizeSnapshotGeneration = 0
    private let liveResizeSnapshotLayer = CALayer()

    private enum PagePreservationReason: Hashable {
        case liveResize
        case fullScreenTransition
    }

    var isThumbnailSidebarVisible: Bool { isReaderSidebarVisible }
    var lastVisibleThumbnailWidth: CGFloat { lastVisibleSidebarWidth }

    override var preservesContentDuringLiveResize: Bool {
        true
    }

    override init(frame frameRect: NSRect) {
        let thumbnailView = TrackingPDFThumbnailView()
        let pdfView = InteractivePDFView()
        let sidebarPresentation = ReaderSidebarPresentation()
        self.thumbnailView = thumbnailView
        self.pdfView = pdfView
        self.sidebarPresentation = sidebarPresentation
        self.sidebarHostingView = NSHostingView(
            rootView: AnyView(
                ReaderSidebarContent(
                    model: sidebarPresentation,
                    thumbnailView: thumbnailView
                )
                .tint(CatppuccinMocha.mauve)
                .preferredColorScheme(.dark)
            )
        )
        super.init(frame: frameRect)

        wantsLayer = true
        pdfView.wantsLayer = true
        sidebarHostingView.wantsLayer = true
        // PDFView itself remains in Aqua to avoid PDFKit's dark-mode page
        // rendering artifacts, while the surrounding sidebar follows the
        // application's Mocha chrome with correctly contrasted controls.
        sidebarHostingView.appearance = NSAppearance(named: .darkAqua)
        thumbnailView.appearance = NSAppearance(named: .darkAqua)
        liveResizeSnapshotLayer.actions = [
            "bounds": NSNull(),
            "contents": NSNull(),
            "position": NSNull(),
        ]

        isVertical = true
        dividerStyle = .thin
        delegate = self

        thumbnailView.thumbnailSize = NSSize(width: 112, height: 145)
        thumbnailView.allowsDragging = false
        thumbnailView.allowsMultipleSelection = false
        sidebarHostingView.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        pdfView.autoScales = true
        pdfView.displayBox = .cropBox
        pdfView.displaysPageBreaks = true
        pdfView.pageBreakMargins = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        addArrangedSubview(sidebarHostingView)
        addArrangedSubview(pdfView)

        setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard !isLiveResizeRenderingModeActive else {
            return
        }
        ensureVisibleSidebarHasUsableWidth()
        rememberVisibleSidebarWidth()
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        guard !isLiveResizeRenderingModeActive else {
            updateLiveResizeSnapshotFrame()
            return
        }
        super.resizeSubviews(withOldSize: oldSize)
    }

    override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()

        guard !isLiveResizeRenderingModeActive else {
            return
        }

        beginPreservingPage(for: .liveResize)
        beginLiveResizeRenderingMode()

        shouldRestoreAutoScalesAfterLiveResize = pdfView.autoScales
        if shouldRestoreAutoScalesAfterLiveResize {
            // PDFKit's automatic fit mode lays out and rerenders the document
            // for every intermediate frame. Keep the current scale while the
            // user drags, then calculate the final fit once at the end.
            pdfView.autoScales = false
        }
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()

        guard isLiveResizeRenderingModeActive else {
            return
        }

        let initialSize = liveResizeInitialSize
        isLiveResizeRenderingModeActive = false
        liveResizeInitialSize = nil

        if let initialSize {
            super.resizeSubviews(withOldSize: initialSize)
        } else {
            adjustSubviews()
        }
        ensureVisibleSidebarHasUsableWidth()
        needsLayout = true
        layoutSubtreeIfNeeded()

        if shouldRestoreAutoScalesAfterLiveResize {
            shouldRestoreAutoScalesAfterLiveResize = false
            pdfView.autoScales = true
            // Install PDFKit's final fitted document layout synchronously
            // before restoring the active page. In two-page mode, allowing
            // this layout to arrive later can make PDFKit report the leading
            // page of the spread and overwrite the user's page selection.
            pdfView.layoutDocumentView()
        }

        rememberVisibleSidebarWidth()
        endPreservingPage(for: .liveResize)
        finishLiveResizeRenderingMode()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        let center = NotificationCenter.default
        center.removeObserver(
            self,
            name: NSWindow.willEnterFullScreenNotification,
            object: nil
        )
        center.removeObserver(
            self,
            name: NSWindow.didEnterFullScreenNotification,
            object: nil
        )
        center.removeObserver(
            self,
            name: NSWindow.willExitFullScreenNotification,
            object: nil
        )
        center.removeObserver(
            self,
            name: NSWindow.didExitFullScreenNotification,
            object: nil
        )

        guard let window else {
            return
        }
        center.addObserver(
            self,
            selector: #selector(windowWillChangeFullScreen(_:)),
            name: NSWindow.willEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChangeFullScreen(_:)),
            name: NSWindow.didEnterFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowWillChangeFullScreen(_:)),
            name: NSWindow.willExitFullScreenNotification,
            object: window
        )
        center.addObserver(
            self,
            selector: #selector(windowDidChangeFullScreen(_:)),
            name: NSWindow.didExitFullScreenNotification,
            object: window
        )
    }

    @objc
    private func windowWillChangeFullScreen(_ notification: Notification) {
        beginPreservingPage(for: .fullScreenTransition)
    }

    @objc
    private func windowDidChangeFullScreen(_ notification: Notification) {
        endPreservingPage(for: .fullScreenTransition)
    }

    private func beginPreservingPage(for reason: PagePreservationReason) {
        guard pagePreservationReasons.insert(reason).inserted else {
            return
        }

        pageRestorationGeneration += 1
        if !isPreservingPageDuringResize {
            preservedPageDuringResize = pdfView.currentPage
            isPreservingPageDuringResize = true
        }
    }

    private func endPreservingPage(for reason: PagePreservationReason) {
        guard pagePreservationReasons.remove(reason) != nil,
              pagePreservationReasons.isEmpty else {
            return
        }

        pageRestorationGeneration += 1
        let restorationGeneration = pageRestorationGeneration
        guard let page = preservedPageDuringResize else {
            isPreservingPageDuringResize = false
            return
        }

        pdfView.go(to: page)
        Task { @MainActor [weak self] in
            await Task.yield()
            guard
                let self,
                self.pagePreservationReasons.isEmpty,
                self.pageRestorationGeneration == restorationGeneration
            else {
                return
            }

            // Let PDFKit finish the final-size automatic layout before the
            // second page restoration. Two-page mode can otherwise publish
            // the spread's leading page on the following display commit.
            self.window?.displayIfNeeded()
            CATransaction.flush()
            try? await Task.sleep(for: .milliseconds(50))
            guard
                self.pagePreservationReasons.isEmpty,
                self.pageRestorationGeneration == restorationGeneration
            else {
                return
            }
            self.pdfView.go(to: page)
            await Task.yield()
            guard
                self.pagePreservationReasons.isEmpty,
                self.pageRestorationGeneration == restorationGeneration
            else {
                return
            }
            self.preservedPageDuringResize = nil
            self.isPreservingPageDuringResize = false
        }
    }

    private func beginLiveResizeRenderingMode() {
        guard !isLiveResizeRenderingModeActive else {
            return
        }

        liveResizeSnapshotGeneration += 1
        showLiveResizeSubviews()
        removeLiveResizeSnapshot()
        liveResizeInitialSize = bounds.size
        isLiveResizeRenderingModeActive = true

        let backingScale = window?.backingScaleFactor ?? 2
        if installLiveResizeSnapshot(backingScale: backingScale) {
            // NSSplitView continues to receive the window's intermediate
            // bounds, but its expensive arranged subviews keep their starting
            // frames until the drag ends. Only this cached frame is resized.
            pdfView.layer?.isHidden = true
            sidebarHostingView.layer?.isHidden = true
        }
    }

    private func finishLiveResizeRenderingMode() {
        showLiveResizeSubviews()
        for view in [pdfView, sidebarHostingView] {
            view.needsLayout = true
            view.needsDisplay = true
        }

        guard liveResizeSnapshotLayer.superlayer != nil else {
            removeLiveResizeSnapshot()
            return
        }

        let generation = liveResizeSnapshotGeneration
        guard window != nil else {
            removeLiveResizeSnapshot()
            return
        }

        // Keep the cached frame above the reader until AppKit has drawn and
        // committed the one final PDF/sidebar layout. A new resize increments
        // the generation and makes this pending cleanup harmless.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard
                let self,
                !self.isLiveResizeRenderingModeActive,
                self.liveResizeSnapshotGeneration == generation
            else {
                return
            }

            self.window?.displayIfNeeded()
            CATransaction.flush()

            guard
                !self.isLiveResizeRenderingModeActive,
                self.liveResizeSnapshotGeneration == generation
            else {
                return
            }
            self.removeLiveResizeSnapshot()
        }
    }

    /// PDFKit can spend most of an interactive resize repeatedly laying out
    /// and rasterizing the same visible pages. Present a single cached frame
    /// while the pointer is down, then let PDFKit render the final size once.
    /// The toolbar remains live and adaptive because only the reader split is
    /// cached.
    private func installLiveResizeSnapshot(backingScale: CGFloat) -> Bool {
        guard
            bounds.width > 0,
            bounds.height > 0,
            let representation = bitmapImageRepForCachingDisplay(in: bounds)
        else {
            return false
        }

        cacheDisplay(in: bounds, to: representation)
        guard let image = representation.cgImage else {
            return false
        }

        liveResizeSnapshotLayer.removeFromSuperlayer()
        liveResizeSnapshotLayer.contents = image
        liveResizeSnapshotLayer.contentsGravity = .resize
        liveResizeSnapshotLayer.contentsScale = backingScale
        liveResizeSnapshotLayer.frame = bounds
        liveResizeSnapshotLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(liveResizeSnapshotLayer)
        return liveResizeSnapshotLayer.superlayer != nil
    }

    private func updateLiveResizeSnapshotFrame() {
        guard liveResizeSnapshotLayer.superlayer != nil else {
            return
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        liveResizeSnapshotLayer.frame = bounds
        CATransaction.commit()
    }

    private func showLiveResizeSubviews() {
        pdfView.layer?.isHidden = false
        sidebarHostingView.layer?.isHidden = false
    }

    private func removeLiveResizeSnapshot() {
        liveResizeSnapshotLayer.removeFromSuperlayer()
        liveResizeSnapshotLayer.contents = nil
    }

    func configureSidebar(
        selectedTab: ReaderSidebarTab,
        outlineNodes: [DocumentOutlineNode],
        bookmarks: [ResolvedPageBookmark],
        availablePageIDs: Set<WorkingPageID>,
        onTabChange: @escaping (ReaderSidebarTab) -> Void,
        onOutlineNavigation: @escaping (WorkingPageID) -> Void,
        onBookmarkNavigation: @escaping (PageBookmark) -> Void,
        onAddBookmark: @escaping () -> Void,
        onRenameBookmark: @escaping (PageBookmark) -> Void,
        onDeleteBookmark: @escaping (PageBookmark) -> Void
    ) {
        sidebarPresentation.update(
            selectedTab: selectedTab,
            outlineNodes: outlineNodes,
            bookmarks: bookmarks,
            availablePageIDs: availablePageIDs,
            onTabChange: onTabChange,
            onOutlineNavigation: onOutlineNavigation,
            onBookmarkNavigation: onBookmarkNavigation,
            onAddBookmark: onAddBookmark,
            onRenameBookmark: onRenameBookmark,
            onDeleteBookmark: onDeleteBookmark
        )
    }

    func setReaderSidebarVisible(_ isVisible: Bool) {
        guard isVisible != isReaderSidebarVisible else {
            return
        }

        if isVisible {
            let rememberedWidth = lastVisibleSidebarWidth
            isReaderSidebarVisible = true
            sidebarHostingView.isHidden = false
            thumbnailView.isHidden = false
            adjustSubviews()

            let maximumAvailableWidth = max(136, bounds.width - 320 - dividerThickness)
            let restoredWidth = min(
                max(rememberedWidth, 136),
                min(260, maximumAvailableWidth)
            )
            setPosition(restoredWidth, ofDividerAt: 0)
            lastVisibleSidebarWidth = restoredWidth
        } else {
            rememberVisibleSidebarWidth()
            isReaderSidebarVisible = false
            sidebarHostingView.isHidden = true
            thumbnailView.isHidden = true
            adjustSubviews()
        }

        if pdfView.autoScales {
            pdfView.autoScales = false
            pdfView.autoScales = true
        }
    }

    func setThumbnailSidebarVisible(_ isVisible: Bool) {
        setReaderSidebarVisible(isVisible)
    }

    private func rememberVisibleSidebarWidth() {
        guard isReaderSidebarVisible, !sidebarHostingView.isHidden else {
            return
        }

        let width = sidebarHostingView.frame.width
        guard width >= 136 else {
            return
        }
        lastVisibleSidebarWidth = min(max(width, 136), 260)
    }

    private func ensureVisibleSidebarHasUsableWidth() {
        guard
            isReaderSidebarVisible,
            !sidebarHostingView.isHidden,
            sidebarHostingView.frame.width < 136,
            bounds.width >= 136 + 320 + dividerThickness
        else {
            return
        }

        let maximumAvailableWidth = bounds.width - 320 - dividerThickness
        let width = min(max(lastVisibleSidebarWidth, 136), min(260, maximumAvailableWidth))
        setPosition(width, ofDividerAt: 0)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, isReaderSidebarVisible else {
            return proposedMinimumPosition
        }
        return max(136, proposedMinimumPosition)
    }

    func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
    ) -> CGFloat {
        guard dividerIndex == 0, isReaderSidebarVisible else {
            return proposedMaximumPosition
        }

        let maximumForReader = bounds.width - 320 - dividerThickness
        return max(136, min(260, min(proposedMaximumPosition, maximumForReader)))
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool {
        view === pdfView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

@MainActor
final class ReaderSidebarPresentation: ObservableObject {
    @Published private(set) var selectedTab: ReaderSidebarTab = .thumbnails
    @Published private(set) var outlineNodes: [DocumentOutlineNode] = []
    @Published private(set) var bookmarks: [ResolvedPageBookmark] = []
    @Published private(set) var availablePageIDs: Set<WorkingPageID> = []

    private var onTabChange: (ReaderSidebarTab) -> Void = { _ in }
    private var updateGeneration = 0
    var onOutlineNavigation: (WorkingPageID) -> Void = { _ in }
    var onBookmarkNavigation: (PageBookmark) -> Void = { _ in }
    var onAddBookmark: () -> Void = {}
    var onRenameBookmark: (PageBookmark) -> Void = { _ in }
    var onDeleteBookmark: (PageBookmark) -> Void = { _ in }

    func update(
        selectedTab: ReaderSidebarTab,
        outlineNodes: [DocumentOutlineNode],
        bookmarks: [ResolvedPageBookmark],
        availablePageIDs: Set<WorkingPageID>,
        onTabChange: @escaping (ReaderSidebarTab) -> Void,
        onOutlineNavigation: @escaping (WorkingPageID) -> Void,
        onBookmarkNavigation: @escaping (PageBookmark) -> Void,
        onAddBookmark: @escaping () -> Void,
        onRenameBookmark: @escaping (PageBookmark) -> Void,
        onDeleteBookmark: @escaping (PageBookmark) -> Void
    ) {
        self.onTabChange = onTabChange
        self.onOutlineNavigation = onOutlineNavigation
        self.onBookmarkNavigation = onBookmarkNavigation
        self.onAddBookmark = onAddBookmark
        self.onRenameBookmark = onRenameBookmark
        self.onDeleteBookmark = onDeleteBookmark

        guard self.selectedTab != selectedTab ||
            self.outlineNodes != outlineNodes ||
            self.bookmarks != bookmarks ||
            self.availablePageIDs != availablePageIDs else {
            return
        }

        updateGeneration += 1
        let generation = updateGeneration

        // NSViewRepresentable updates run while SwiftUI is rendering. Defer
        // published presentation changes until that render transaction ends.
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, self.updateGeneration == generation else {
                return
            }
            if self.selectedTab != selectedTab {
                self.selectedTab = selectedTab
            }
            if self.outlineNodes != outlineNodes {
                self.outlineNodes = outlineNodes
            }
            if self.bookmarks != bookmarks {
                self.bookmarks = bookmarks
            }
            if self.availablePageIDs != availablePageIDs {
                self.availablePageIDs = availablePageIDs
            }
        }
    }

    func chooseTab(_ tab: ReaderSidebarTab) {
        guard tab != selectedTab else {
            return
        }
        selectedTab = tab
        onTabChange(tab)
    }
}

private struct ReaderSidebarContent: View {
    @ObservedObject var model: ReaderSidebarPresentation
    let thumbnailView: TrackingPDFThumbnailView

    var body: some View {
        VStack(spacing: 0) {
            Picker(
                "Reader Sidebar",
                selection: Binding(
                    get: { model.selectedTab },
                    set: { model.chooseTab($0) }
                )
            ) {
                Label("Thumbnails", systemImage: "rectangle.stack")
                    .tag(ReaderSidebarTab.thumbnails)
                    .accessibilityLabel("Thumbnails")
                Label("Contents", systemImage: "list.bullet.indent")
                    .tag(ReaderSidebarTab.contents)
                    .accessibilityLabel("Contents")
                Label("Bookmarks", systemImage: "bookmark")
                    .tag(ReaderSidebarTab.bookmarks)
                    .accessibilityLabel("Bookmarks")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .labelStyle(.iconOnly)
            .padding(8)

            Divider()

            switch model.selectedTab {
            case .thumbnails:
                ExistingThumbnailView(thumbnailView: thumbnailView)
                    .accessibilityLabel("Page Thumbnails")
            case .contents:
                contents
            case .bookmarks:
                bookmarks
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CatppuccinMocha.mantle)
    }

    @ViewBuilder
    private var contents: some View {
        if model.outlineNodes.isEmpty {
            ContentUnavailableView(
                "No Table of Contents",
                systemImage: "list.bullet.indent",
                description: Text("This PDF has no table of contents.")
            )
            .padding(8)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(model.outlineNodes) { node in
                        OutlineSidebarRow(node: node, model: model)
                    }
                }
                .padding(8)
            }
        }
    }

    private var bookmarks: some View {
        VStack(spacing: 0) {
            if model.bookmarks.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Add a bookmark for the current page.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(8)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.bookmarks) { resolvedBookmark in
                            BookmarkSidebarRow(
                                resolvedBookmark: resolvedBookmark,
                                model: model
                            )
                        }
                    }
                    .padding(8)
                }
            }

            Divider()
            Button {
                model.onAddBookmark()
            } label: {
                Label("Add Bookmark", systemImage: "bookmark.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .padding(8)
            .accessibilityIdentifier("Add Bookmark")
        }
    }
}

private struct OutlineSidebarRow: View {
    let node: DocumentOutlineNode
    @ObservedObject var model: ReaderSidebarPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            outlineButton
            if !node.children.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(node.children) { child in
                        OutlineSidebarRow(node: child, model: model)
                    }
                }
                .padding(.leading, 12)
            }
        }
    }

    private var outlineButton: some View {
        Button {
            if let pageID = node.pageID {
                model.onOutlineNavigation(pageID)
            }
        } label: {
            Text(node.title)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(node.title)
        .disabled(!isDestinationAvailable)
        .help(
            !isDestinationAvailable
                ? "This outline destination is unavailable in the current revision."
                : node.title
        )
    }

    private var isDestinationAvailable: Bool {
        guard let pageID = node.pageID else {
            return false
        }
        return model.availablePageIDs.contains(pageID)
    }
}

private struct BookmarkSidebarRow: View {
    let resolvedBookmark: ResolvedPageBookmark
    @ObservedObject var model: ReaderSidebarPresentation

    var body: some View {
        HStack(spacing: 4) {
            Button {
                model.onBookmarkNavigation(resolvedBookmark.bookmark)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(resolvedBookmark.bookmark.label)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(pageDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            .contentShape(Rectangle())
            .accessibilityLabel(
                "\(resolvedBookmark.bookmark.label), \(pageDescription)"
            )
            .accessibilityAction {
                model.onBookmarkNavigation(resolvedBookmark.bookmark)
            }
            .disabled(resolvedBookmark.pageIndex == nil)
            .help(
                resolvedBookmark.pageIndex == nil
                    ? "This page is unavailable. Undoing its deletion may restore it."
                    : resolvedBookmark.bookmark.label
            )

            Menu {
                Button("Rename Bookmark") {
                    model.onRenameBookmark(resolvedBookmark.bookmark)
                }
                Button("Delete Bookmark", role: .destructive) {
                    model.onDeleteBookmark(resolvedBookmark.bookmark)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Bookmark Actions")
        }
        .padding(.vertical, 3)
    }

    private var pageDescription: String {
        if let pageIndex = resolvedBookmark.pageIndex {
            return "Page \(pageIndex + 1)"
        }
        return "Page unavailable"
    }
}

private struct ExistingThumbnailView: NSViewRepresentable {
    let thumbnailView: TrackingPDFThumbnailView

    func makeNSView(context: Context) -> TrackingPDFThumbnailView {
        thumbnailView
    }

    func updateNSView(_ nsView: TrackingPDFThumbnailView, context: Context) {}
}

final class TrackingPDFThumbnailView: PDFThumbnailView {
    var onExplicitPageSelection: ((Int) -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        guard
            let document = pdfView?.document,
            let page = pdfView?.currentPage
        else {
            return
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else {
            return
        }
        onExplicitPageSelection?(pageIndex)
    }
}

private final class PDFInteractionPolicyDelegate: NSObject, @MainActor PDFViewDelegate {
    weak var owner: InteractivePDFView?

    init(owner: InteractivePDFView) {
        self.owner = owner
    }

    @MainActor
    func pdfViewWillClick(onLink sender: PDFView, with url: URL) {
        owner?.confirmOpeningExternalLink(url)
    }

    @MainActor
    func pdfViewPerformPrint(_ sender: PDFView) {
        owner?.blockEmbeddedPrintRequest()
    }
}

final class InteractivePDFView: PDFView {
    override var preservesContentDuringLiveResize: Bool {
        true
    }

    var annotationTool: AnnotationTool? {
        didSet {
            if annotationTool != oldValue {
                cancelInkPreview()
                cancelShapePreview()
                resetSelectGesture()
                window?.invalidateCursorRects(for: self)
            }
        }
    }
    var selectedAnnotation: SelectedAnnotation?
    var isRedactionModeActive = false {
        didSet {
            guard isRedactionModeActive != oldValue else {
                return
            }
            cancelRedactionPreview()
            redactionOverlayView.isHidden = !isRedactionModeActive
            window?.invalidateCursorRects(for: self)
        }
    }
    var redactionRegions: [PDFRedactionRegion] = [] {
        didSet {
            redactionOverlayView.regions = redactionRegions
            redactionOverlayView.needsDisplay = true
        }
    }
    var onInkStroke: ((InkStroke) -> Void)?
    var onTextSelectionCommitted: (() -> Void)?
    var onTextNotePlacement: ((AnnotationPlacement) -> Void)?
    var onShapeAnnotation: ((ShapeAnnotationPlacement) -> Void)?
    var onBuiltInStampPlacement: ((AnnotationPlacement) -> Void)?
    var onVisualSignaturePlacement: ((AnnotationPlacement) -> Void)?
    var onAnnotationSelection: ((SelectedAnnotation?) -> Void)?
    var onAnnotationMove: ((SelectedAnnotation, CGSize) -> Void)?
    var onRedactionRegion: ((PDFRedactionRegion) -> Void)?

    private var inkPageIndex: Int?
    private var inkPagePoints: [CGPoint] = []
    private var inkViewPoints: [CGPoint] = []
    private var inkPreviewPath = CGMutablePath()
    private let inkPreviewLayer = CAShapeLayer()
    private var shapeStart: AnnotationPlacement?
    private var shapeStartViewPoint: CGPoint?
    private let shapePreviewLayer = CAShapeLayer()
    private var selectMouseDownPoint: CGPoint?
    private var selectPageStartPoint: AnnotationPlacement?
    private var pendingClickedAnnotation: SelectedAnnotation?
    private var selectGestureDidDrag = false
    private var redactionStart: AnnotationPlacement?
    private lazy var redactionOverlayView = RedactionOverlayView(pdfView: self)
    private lazy var interactionPolicyDelegate = PDFInteractionPolicyDelegate(owner: self)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inkPreviewLayer.fillColor = NSColor.clear.cgColor
        inkPreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
        inkPreviewLayer.lineCap = .round
        inkPreviewLayer.lineJoin = .round
        inkPreviewLayer.actions = [
            "path": NSNull(),
            "frame": NSNull(),
            "bounds": NSNull(),
            "position": NSNull(),
        ]
        shapePreviewLayer.fillColor = NSColor.clear.cgColor
        shapePreviewLayer.strokeColor = NSColor.controlAccentColor.cgColor
        shapePreviewLayer.lineWidth = 2
        shapePreviewLayer.lineDashPattern = [6, 4]
        shapePreviewLayer.actions = inkPreviewLayer.actions
        redactionOverlayView.frame = bounds
        redactionOverlayView.autoresizingMask = [.width, .height]
        redactionOverlayView.isHidden = true
        addSubview(redactionOverlayView, positioned: .above, relativeTo: nil)
        delegate = interactionPolicyDelegate
    }

    override func layout() {
        super.layout()
        redactionOverlayView.frame = bounds
        redactionOverlayView.needsDisplay = true
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        redactionOverlayView.needsDisplay = true
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isRedactionModeActive {
            addCursorRect(bounds, cursor: .crosshair)
            return
        }
        switch annotationTool {
        case .freehand, .textNote, .rectangle, .oval, .line, .arrow, .stamp, .signature:
            addCursorRect(bounds, cursor: .crosshair)
        case .eraser:
            addCursorRect(bounds, cursor: .pointingHand)
        default:
            break
        }
    }

    override func mouseDown(with event: NSEvent) {
        if isRedactionModeActive {
            beginRedaction(at: convert(event.locationInWindow, from: nil))
            return
        }
        guard let annotationTool else {
            super.mouseDown(with: event)
            return
        }

        let viewPoint = convert(event.locationInWindow, from: nil)
        switch annotationTool {
        case .freehand:
            beginInk(at: viewPoint)
        case .eraser:
            let selection = annotationSelection(at: viewPoint)
            onAnnotationSelection?(selection?.kind == .freehand && selection?.isOwnedByPDFViewer == true ? selection : nil)
        case .textNote:
            guard let placement = annotationPlacement(at: viewPoint) else {
                return
            }
            onTextNotePlacement?(placement)
        case .rectangle, .oval, .line, .arrow:
            beginShape(at: viewPoint)
        case .stamp:
            guard let placement = annotationPlacement(at: viewPoint) else {
                return
            }
            onBuiltInStampPlacement?(placement)
        case .signature:
            guard let placement = annotationPlacement(at: viewPoint) else {
                return
            }
            onVisualSignaturePlacement?(placement)
        case .select:
            window?.makeFirstResponder(self)
            selectMouseDownPoint = viewPoint
            pendingClickedAnnotation = annotationSelection(at: viewPoint)
            selectPageStartPoint = annotationPlacement(at: viewPoint)
            selectGestureDidDrag = false
            if pendingClickedAnnotation?.isOwnedByPDFViewer != true {
                super.mouseDown(with: event)
            }
        case .highlight, .underline, .strikethrough:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if isRedactionModeActive, redactionStart != nil {
            updateRedactionPreview(at: convert(event.locationInWindow, from: nil))
            return
        }
        if annotationTool == .select {
            let viewPoint = convert(event.locationInWindow, from: nil)
            if
                let selectMouseDownPoint,
                hypot(
                    viewPoint.x - selectMouseDownPoint.x,
                    viewPoint.y - selectMouseDownPoint.y
                ) >= 3
            {
                selectGestureDidDrag = true
            }
            if pendingClickedAnnotation?.isOwnedByPDFViewer != true {
                super.mouseDragged(with: event)
            }
            return
        }

        if annotationTool?.shapeKind != nil, shapeStart != nil {
            updateShapePreview(at: convert(event.locationInWindow, from: nil))
            return
        }

        guard annotationTool == .freehand, inkPageIndex != nil else {
            super.mouseDragged(with: event)
            return
        }
        appendInkPoint(convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        if isRedactionModeActive, redactionStart != nil {
            finishRedaction(at: convert(event.locationInWindow, from: nil))
            return
        }
        if annotationTool == .select {
            if pendingClickedAnnotation?.isOwnedByPDFViewer != true {
                super.mouseUp(with: event)
            }
            let viewPoint = convert(event.locationInWindow, from: nil)
            let movedDistance = selectMouseDownPoint.map {
                hypot(viewPoint.x - $0.x, viewPoint.y - $0.y)
            } ?? .greatestFiniteMagnitude
            let clickedAnnotation = pendingClickedAnnotation
            if
                selectGestureDidDrag,
                let clickedAnnotation,
                clickedAnnotation.isOwnedByPDFViewer,
                let start = selectPageStartPoint,
                let end = annotationPlacement(at: viewPoint),
                end.pageIndex == start.pageIndex
            {
                onAnnotationMove?(
                    clickedAnnotation,
                    CGSize(
                        width: end.point.x - start.point.x,
                        height: end.point.y - start.point.y
                    )
                )
                onAnnotationSelection?(clickedAnnotation)
            } else {
                onAnnotationSelection?(!selectGestureDidDrag && movedDistance < 3 ? clickedAnnotation : nil)
            }
            resetSelectGesture()
            return
        }

        if annotationTool?.shapeKind != nil, shapeStart != nil {
            finishShape(at: convert(event.locationInWindow, from: nil))
            return
        }

        if annotationTool?.requiresTextSelection == true {
            super.mouseUp(with: event)
            Task { @MainActor [weak self] in
                await Task.yield()
                guard self?.annotationTool?.requiresTextSelection == true else {
                    return
                }
                self?.onTextSelectionCommitted?()
            }
            return
        }
        if
            annotationTool == .eraser ||
            annotationTool == .textNote ||
            annotationTool == .stamp ||
            annotationTool == .signature
        {
            return
        }

        guard annotationTool == .freehand, let pageIndex = inkPageIndex else {
            super.mouseUp(with: event)
            return
        }

        appendInkPoint(convert(event.locationInWindow, from: nil))
        let stroke = InkStroke(pageIndex: pageIndex, points: inkPagePoints)
        if stroke.points.count >= 2 {
            onInkStroke?(stroke)
        }
        // Keep the preview visible until the live PDF annotation has been
        // installed so lifting the pointer never produces a blank flash.
        cancelInkPreview()
    }

    override func cancelOperation(_ sender: Any?) {
        if shapeStart != nil {
            cancelShapePreview()
            return
        }
        if redactionStart != nil {
            cancelRedactionPreview()
            return
        }
        super.cancelOperation(sender)
    }

    override func keyDown(with event: NSEvent) {
        guard
            annotationTool == .select,
            let selectedAnnotation,
            selectedAnnotation.isOwnedByPDFViewer
        else {
            super.keyDown(with: event)
            return
        }
        let distance: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
        let translation: CGSize
        switch event.keyCode {
        case 123:
            translation = CGSize(width: -distance, height: 0)
        case 124:
            translation = CGSize(width: distance, height: 0)
        case 125:
            translation = CGSize(width: 0, height: -distance)
        case 126:
            translation = CGSize(width: 0, height: distance)
        default:
            super.keyDown(with: event)
            return
        }
        onAnnotationMove?(selectedAnnotation, translation)
    }

    fileprivate func confirmOpeningExternalLink(_ url: URL) {
        let allowedSchemes = Set(["https", "http", "mailto"])
        guard
            let scheme = url.scheme?.lowercased(),
            allowedSchemes.contains(scheme),
            let window
        else {
            NSSound.beep()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Open External Link?"
        alert.informativeText = "This PDF wants to open:\n\n\(url.absoluteString)\n\nOnly continue if you trust the document and destination."
        alert.addButton(withTitle: "Open Link")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                return
            }
            NSWorkspace.shared.open(url)
        }
    }

    fileprivate func blockEmbeddedPrintRequest() {
        NSSound.beep()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Embedded Print Request Blocked"
        alert.informativeText = "For safety, PDFViewer does not let a document start printing. Use File > Print when you want to print."
        alert.addButton(withTitle: "OK")
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }

    private func beginRedaction(at viewPoint: CGPoint) {
        guard let placement = annotationPlacement(at: viewPoint) else {
            return
        }
        redactionStart = placement
        redactionOverlayView.liveRegion = PDFRedactionRegion(
            pageIndex: placement.pageIndex,
            bounds: CGRect(origin: placement.point, size: .zero)
        )
        redactionOverlayView.needsDisplay = true
    }

    private func updateRedactionPreview(at viewPoint: CGPoint) {
        guard
            let redactionStart,
            let current = annotationPlacement(at: viewPoint),
            current.pageIndex == redactionStart.pageIndex
        else {
            return
        }
        redactionOverlayView.liveRegion = PDFRedactionRegion(
            pageIndex: redactionStart.pageIndex,
            bounds: CGRect(
                x: redactionStart.point.x,
                y: redactionStart.point.y,
                width: current.point.x - redactionStart.point.x,
                height: current.point.y - redactionStart.point.y
            )
        )
        redactionOverlayView.needsDisplay = true
    }

    private func finishRedaction(at viewPoint: CGPoint) {
        updateRedactionPreview(at: viewPoint)
        let region = redactionOverlayView.liveRegion
        cancelRedactionPreview()
        guard let region, region.bounds.width >= 2, region.bounds.height >= 2 else {
            NSSound.beep()
            return
        }
        onRedactionRegion?(region)
    }

    private func cancelRedactionPreview() {
        redactionStart = nil
        redactionOverlayView.liveRegion = nil
        redactionOverlayView.needsDisplay = true
    }

    private func beginInk(at viewPoint: CGPoint) {
        guard let placement = annotationPlacement(at: viewPoint) else {
            return
        }

        wantsLayer = true
        if inkPreviewLayer.superlayer == nil {
            layer?.addSublayer(inkPreviewLayer)
        }
        inkPageIndex = placement.pageIndex
        inkPagePoints = [placement.point]
        inkViewPoints = [viewPoint]
        inkPreviewPath = CGMutablePath()
        inkPreviewPath.move(to: viewPoint)
        inkPreviewLayer.frame = bounds
        inkPreviewLayer.contentsScale = window?.backingScaleFactor ?? 2
        inkPreviewLayer.lineWidth = 3
        inkPreviewLayer.path = inkPreviewPath
    }

    private func appendInkPoint(_ viewPoint: CGPoint) {
        guard
            let pageIndex = inkPageIndex,
            let document,
            let page = document.page(at: pageIndex),
            self.page(for: viewPoint, nearest: false) === page,
            let lastViewPoint = inkViewPoints.last,
            hypot(viewPoint.x - lastViewPoint.x, viewPoint.y - lastViewPoint.y) >= 2
        else {
            return
        }
        inkViewPoints.append(viewPoint)
        inkPagePoints.append(convert(viewPoint, to: page))
        inkPreviewPath.addLine(to: viewPoint)
        inkPreviewLayer.path = inkPreviewPath
    }

    private func cancelInkPreview() {
        inkPageIndex = nil
        inkPagePoints = []
        inkViewPoints = []
        inkPreviewPath = CGMutablePath()
        inkPreviewLayer.path = nil
        inkPreviewLayer.removeFromSuperlayer()
    }

    private func beginShape(at viewPoint: CGPoint) {
        guard annotationTool?.shapeKind != nil,
              let placement = annotationPlacement(at: viewPoint) else {
            return
        }
        wantsLayer = true
        if shapePreviewLayer.superlayer == nil {
            layer?.addSublayer(shapePreviewLayer)
        }
        shapeStart = placement
        shapeStartViewPoint = viewPoint
        shapePreviewLayer.frame = bounds
        shapePreviewLayer.contentsScale = window?.backingScaleFactor ?? 2
        shapePreviewLayer.path = nil
    }

    private func updateShapePreview(at viewPoint: CGPoint) {
        guard
            let shapeStart,
            let shapeStartViewPoint,
            let current = annotationPlacement(at: viewPoint),
            current.pageIndex == shapeStart.pageIndex,
            let kind = annotationTool?.shapeKind
        else {
            return
        }
        let rect = CGRect(
            x: min(shapeStartViewPoint.x, viewPoint.x),
            y: min(shapeStartViewPoint.y, viewPoint.y),
            width: abs(viewPoint.x - shapeStartViewPoint.x),
            height: abs(viewPoint.y - shapeStartViewPoint.y)
        )
        let path = CGMutablePath()
        switch kind {
        case .rectangle:
            path.addRect(rect)
        case .oval:
            path.addEllipse(in: rect)
        case .line, .arrow:
            path.move(to: shapeStartViewPoint)
            path.addLine(to: viewPoint)
        }
        shapePreviewLayer.path = path
    }

    private func finishShape(at viewPoint: CGPoint) {
        updateShapePreview(at: viewPoint)
        guard
            let start = shapeStart,
            let end = annotationPlacement(at: viewPoint),
            end.pageIndex == start.pageIndex
        else {
            cancelShapePreview()
            return
        }
        let placement = ShapeAnnotationPlacement(
            pageIndex: start.pageIndex,
            startPoint: start.point,
            endPoint: end.point
        )
        cancelShapePreview()
        onShapeAnnotation?(placement)
    }

    private func cancelShapePreview() {
        shapeStart = nil
        shapeStartViewPoint = nil
        shapePreviewLayer.path = nil
        shapePreviewLayer.removeFromSuperlayer()
    }

    private func resetSelectGesture() {
        selectMouseDownPoint = nil
        selectPageStartPoint = nil
        pendingClickedAnnotation = nil
        selectGestureDidDrag = false
    }

    func annotationPlacement(at viewPoint: CGPoint) -> AnnotationPlacement? {
        guard
            let document,
            let page = page(for: viewPoint, nearest: false)
        else {
            return nil
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else {
            return nil
        }
        return AnnotationPlacement(
            pageIndex: pageIndex,
            point: convert(viewPoint, to: page)
        )
    }

    func annotationSelection(at viewPoint: CGPoint) -> SelectedAnnotation? {
        guard
            let document,
            let page = page(for: viewPoint, nearest: false)
        else {
            return nil
        }
        let pageIndex = document.index(for: page)
        guard pageIndex != NSNotFound else {
            return nil
        }
        let pagePoint = convert(viewPoint, to: page)
        guard let annotation = page.annotations.reversed().first(where: { candidate in
            annotation(candidate, contains: pagePoint)
        }) else {
            return nil
        }

        let identifier = AnnotationIdentifier(annotation: annotation)
        return SelectedAnnotation(
            pageIndex: pageIndex,
            identifier: identifier,
            kind: annotationTool(for: annotation)
        )
    }

    private func annotation(
        _ annotation: PDFAnnotation,
        contains pagePoint: CGPoint
    ) -> Bool {
        let expandedBounds = annotation.bounds.insetBy(dx: -4, dy: -4)
        guard expandedBounds.contains(pagePoint) else {
            return false
        }
        guard annotation.type == PDFAnnotationSubtype.ink.pdfTypeName else {
            return true
        }

        let annotationPoint = CGPoint(
            x: pagePoint.x - annotation.bounds.minX,
            y: pagePoint.y - annotation.bounds.minY
        )
        let tolerance = max(5, (annotation.border?.lineWidth ?? 1) / 2 + 3)
        return annotation.paths?.contains { path in
            path.isWithinStrokeDistance(tolerance, of: annotationPoint)
        } == true
    }

    private func annotationTool(for annotation: PDFAnnotation) -> AnnotationTool? {
        if annotation.type == PDFAnnotationSubtype.highlight.pdfTypeName {
            return .highlight
        }
        if annotation.type == PDFAnnotationSubtype.underline.pdfTypeName {
            return .underline
        }
        if annotation.type == PDFAnnotationSubtype.strikeOut.pdfTypeName {
            return .strikethrough
        }
        if annotation.type == PDFAnnotationSubtype.ink.pdfTypeName {
            return .freehand
        }
        if annotation.type == PDFAnnotationSubtype.text.pdfTypeName {
            return .textNote
        }
        if annotation.type == PDFAnnotationSubtype.square.pdfTypeName {
            return .rectangle
        }
        if annotation.type == PDFAnnotationSubtype.circle.pdfTypeName {
            return .oval
        }
        if annotation.type == PDFAnnotationSubtype.line.pdfTypeName {
            return annotation.endLineStyle == .closedArrow ? .arrow : .line
        }
        if annotation.type == PDFAnnotationSubtype.stamp.pdfTypeName {
            return VisualSignatureAnnotation.imageData(from: annotation) == nil ||
                VisualSignatureAnnotation.isCustomStamp(annotation) ? .stamp : .signature
        }
        return nil
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private final class RedactionOverlayView: NSView {
    weak var pdfView: PDFView?
    var regions: [PDFRedactionRegion] = []
    var liveRegion: PDFRedactionRegion?

    init(pdfView: PDFView) {
        self.pdfView = pdfView
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override var isOpaque: Bool { false }
    override var isFlipped: Bool { pdfView?.isFlipped ?? false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let pdfView, let document = pdfView.document else {
            return
        }

        for region in regions + [liveRegion].compactMap({ $0 }) {
            guard
                (0..<document.pageCount).contains(region.pageIndex),
                let page = document.page(at: region.pageIndex)
            else {
                continue
            }
            let viewBounds = pdfView.convert(region.bounds, from: page).standardized
            guard viewBounds.intersects(bounds) else {
                continue
            }
            let path = NSBezierPath(rect: viewBounds)
            NSColor.black.withAlphaComponent(0.62).setFill()
            path.fill()
            NSColor.systemRed.setStroke()
            path.lineWidth = 2
            path.setLineDash([6, 4], count: 2, phase: 0)
            path.stroke()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}

private extension NSBezierPath {
    func isWithinStrokeDistance(_ tolerance: CGFloat, of point: CGPoint) -> Bool {
        guard elementCount > 0 else {
            return false
        }

        var currentPoint: CGPoint?
        var subpathStart: CGPoint?
        var associatedPoints = [NSPoint](repeating: .zero, count: 3)

        for elementIndex in 0..<elementCount {
            let element = associatedPoints.withUnsafeMutableBufferPointer { buffer in
                self.element(at: elementIndex, associatedPoints: buffer.baseAddress)
            }
            switch element {
            case .moveTo:
                currentPoint = associatedPoints[0]
                subpathStart = associatedPoints[0]
            case .lineTo:
                if
                    let currentPoint,
                    point.distance(toSegmentFrom: currentPoint, to: associatedPoints[0]) <= tolerance
                {
                    return true
                }
                currentPoint = associatedPoints[0]
            case .curveTo, .cubicCurveTo:
                // PDFViewer ink paths are line-based. Treat a third-party
                // curve's control polygon as selectable without making its
                // entire annotation bounding box intercept text drags.
                var curveStart = currentPoint
                for curvePoint in associatedPoints.prefix(3) {
                    if
                        let curveStart,
                        point.distance(toSegmentFrom: curveStart, to: curvePoint) <= tolerance
                    {
                        return true
                    }
                    curveStart = curvePoint
                }
                currentPoint = associatedPoints[2]
            case .quadraticCurveTo:
                var curveStart = currentPoint
                for curvePoint in associatedPoints.prefix(2) {
                    if
                        let curveStart,
                        point.distance(toSegmentFrom: curveStart, to: curvePoint) <= tolerance
                    {
                        return true
                    }
                    curveStart = curvePoint
                }
                currentPoint = associatedPoints[1]
            case .closePath:
                if
                    let currentPoint,
                    let subpathStart,
                    point.distance(toSegmentFrom: currentPoint, to: subpathStart) <= tolerance
                {
                    return true
                }
                currentPoint = subpathStart
            @unknown default:
                continue
            }
        }
        return false
    }
}

private extension CGPoint {
    func distance(toSegmentFrom start: CGPoint, to end: CGPoint) -> CGFloat {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        let lengthSquared = deltaX * deltaX + deltaY * deltaY
        guard lengthSquared > 0 else {
            return hypot(x - start.x, y - start.y)
        }
        let projection = min(
            1,
            max(0, ((x - start.x) * deltaX + (y - start.y) * deltaY) / lengthSquared)
        )
        let closest = CGPoint(
            x: start.x + projection * deltaX,
            y: start.y + projection * deltaY
        )
        return hypot(x - closest.x, y - closest.y)
    }
}

private extension ReaderTheme {
    var pdfBackgroundColor: NSColor {
        switch self {
        case .day:
            NSColor(calibratedWhite: 0.82, alpha: 1)
        case .night:
            NSColor(calibratedRed: 30 / 255, green: 30 / 255, blue: 46 / 255, alpha: 1)
        case .sepia:
            NSColor(calibratedRed: 0.70, green: 0.63, blue: 0.49, alpha: 1)
        }
    }

    var thumbnailBackgroundColor: NSColor {
        switch self {
        case .day:
            NSColor(calibratedWhite: 0.92, alpha: 1)
        case .night:
            NSColor(calibratedRed: 24 / 255, green: 24 / 255, blue: 37 / 255, alpha: 1)
        case .sepia:
            NSColor(calibratedRed: 0.86, green: 0.80, blue: 0.68, alpha: 1)
        }
    }
}
