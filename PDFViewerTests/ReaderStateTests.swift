import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class ReaderStateTests: XCTestCase {
    func testReaderOffersEveryCommittedTheme() {
        XCTAssertEqual(
            ReaderTheme.allCases.map(\.title),
            ["Day", "Night", "Sepia"]
        )
    }

    func testNavigationAcceptsValidPagesAndRejectsInvalidPages() {
        let state = ReaderState(pageCount: 5)

        XCTAssertTrue(state.goToPage(number: 5))
        XCTAssertEqual(state.selectedPageIndex, 4)
        XCTAssertFalse(state.goToPage(number: 0))
        XCTAssertFalse(state.goToPage(number: 6))
        XCTAssertEqual(state.selectedPageIndex, 4)
    }

    func testPageCountResetClampsSelection() {
        let state = ReaderState(pageCount: 5)
        XCTAssertTrue(state.selectPage(at: 4))

        state.reset(pageCount: 2)

        XCTAssertEqual(state.pageCount, 2)
        XCTAssertEqual(state.selectedPageIndex, 1)
    }

    func testDisplayPreferencesDoNotMarkDocumentDirty() {
        let state = ReaderState(pageCount: 3)

        state.displayMode = .twoPage
        state.theme = .night
        state.displayMode = .continuous
        state.theme = .sepia
        state.theme = .day

        XCTAssertFalse(state.isDocumentDirty)
    }

    func testThumbnailSidebarVisibilityIsTemporaryPresentationState() {
        let state = ReaderState(pageCount: 3)

        XCTAssertTrue(state.isThumbnailSidebarVisible)
        state.toggleThumbnailSidebar()
        XCTAssertFalse(state.isThumbnailSidebarVisible)
        XCTAssertFalse(state.isDocumentDirty)

        state.markDocumentDirty()
        state.toggleThumbnailSidebar()
        XCTAssertTrue(state.isThumbnailSidebarVisible)
        XCTAssertTrue(state.isDocumentDirty)

        state.toggleThumbnailSidebar()
        state.reset(pageCount: 2)
        XCTAssertTrue(state.isThumbnailSidebarVisible)
        XCTAssertFalse(state.isDocumentDirty)
    }

    func testReaderSidebarTabAndVisibilityArePresentationOnly() {
        let state = ReaderState(pageCount: 3)

        state.selectedSidebarTab = .contents
        state.toggleReaderSidebar()
        state.selectedSidebarTab = .bookmarks

        XCTAssertFalse(state.isReaderSidebarVisible)
        XCTAssertEqual(state.selectedSidebarTab, .bookmarks)
        XCTAssertFalse(state.isDocumentDirty)

        state.reset(pageCount: 2)
        XCTAssertTrue(state.isReaderSidebarVisible)
        XCTAssertEqual(state.selectedSidebarTab, .thumbnails)
        XCTAssertFalse(state.isDocumentDirty)
    }

    func testMultiPageSelectionTracksAPrimaryPageAndRejectsInvalidIndexes() {
        let state = ReaderState(pageCount: 5)

        XCTAssertTrue(state.selectPages(at: [1, 3], preferredPageIndex: 3))
        XCTAssertEqual(state.selectedPageIndexes, [1, 3])
        XCTAssertEqual(state.selectedPageIndex, 3)
        XCTAssertEqual(state.selectedPageIndexSet, IndexSet([1, 3]))

        XCTAssertFalse(state.selectPages(at: [2, 6]))
        XCTAssertEqual(state.selectedPageIndexes, [1, 3])

        XCTAssertTrue(state.selectPage(at: 2))
        XCTAssertEqual(state.selectedPageIndexes, [2])
    }
}

@MainActor
final class ReaderSplitViewTests: XCTestCase {
    func testCompactLayoutPreservesUsableReaderWidth() {
        let splitView = makeSplitView(width: 720)

        XCTAssertTrue(splitView.isThumbnailSidebarVisible)
        XCTAssertGreaterThanOrEqual(splitView.thumbnailView.frame.width, 136)
        XCTAssertLessThanOrEqual(splitView.thumbnailView.frame.width, 260)
        XCTAssertGreaterThanOrEqual(splitView.pdfView.frame.width, 320)
    }

    func testSidebarVisibilityIsIdempotentAndPreservesReaderState() {
        let splitView = makeSplitView(width: 720)
        splitView.setPosition(190, ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        let document = splitView.pdfView.document
        let currentPage = splitView.pdfView.currentPage
        let visiblePDFWidth = splitView.pdfView.frame.width

        splitView.setThumbnailSidebarVisible(false)
        splitView.setThumbnailSidebarVisible(false)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertFalse(splitView.isThumbnailSidebarVisible)
        XCTAssertTrue(splitView.thumbnailView.isHidden)
        XCTAssertGreaterThan(splitView.pdfView.frame.width, visiblePDFWidth)
        XCTAssertTrue(splitView.pdfView.document === document)
        XCTAssertTrue(splitView.pdfView.currentPage === currentPage)

        splitView.setThumbnailSidebarVisible(true)
        splitView.setThumbnailSidebarVisible(true)
        splitView.layoutSubtreeIfNeeded()

        XCTAssertTrue(splitView.isThumbnailSidebarVisible)
        XCTAssertFalse(splitView.thumbnailView.isHidden)
        XCTAssertEqual(splitView.thumbnailView.frame.width, 190, accuracy: 2)
        XCTAssertTrue(splitView.pdfView.document === document)
        XCTAssertTrue(splitView.pdfView.currentPage === currentPage)
    }

    func testLiveResizeDefersAutomaticFitUntilResizeEnds() {
        let splitView = makeSplitView(width: 720)
        splitView.pdfView.autoScales = true

        let document = splitView.pdfView.document
        let currentPage = splitView.pdfView.currentPage

        splitView.viewWillStartLiveResize()

        XCTAssertFalse(splitView.pdfView.autoScales)
        XCTAssertEqual(splitView.pdfView.layer?.shouldRasterize, false)
        XCTAssertEqual(splitView.pdfView.layer?.isHidden, true)
        XCTAssertTrue(splitView.pdfView.document === document)
        XCTAssertTrue(splitView.pdfView.currentPage === currentPage)

        splitView.viewDidEndLiveResize()

        XCTAssertTrue(splitView.pdfView.autoScales)
        XCTAssertEqual(splitView.pdfView.layer?.shouldRasterize, false)
        XCTAssertEqual(splitView.pdfView.layer?.isHidden, false)
        XCTAssertTrue(splitView.pdfView.document === document)
        XCTAssertTrue(splitView.pdfView.currentPage === currentPage)
    }

    func testLiveResizePreservesManualZoomMode() {
        let splitView = makeSplitView(width: 720)
        splitView.pdfView.autoScales = false

        splitView.viewWillStartLiveResize()
        splitView.viewDidEndLiveResize()

        XCTAssertFalse(splitView.pdfView.autoScales)
    }

    func testLiveResizeFreezesExpensiveSubviewFramesUntilResizeEnds() throws {
        let splitView = makeSplitView(width: 720, pageCount: 2)
        splitView.setPosition(190, ofDividerAt: 0)
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        splitView.pdfView.autoScales = true

        let activePage = try XCTUnwrap(splitView.pdfView.document?.page(at: 1))
        splitView.pdfView.go(to: activePage)
        let initialSidebarFrame = splitView.subviews[0].frame
        let initialPDFFrame = splitView.pdfView.frame

        splitView.viewWillStartLiveResize()

        for size in [
            NSSize(width: 920, height: 640),
            NSSize(width: 760, height: 560),
            NSSize(width: 1080, height: 700),
        ] {
            splitView.setFrameSize(size)
            splitView.layoutSubtreeIfNeeded()

            XCTAssertEqual(splitView.subviews[0].frame, initialSidebarFrame)
            XCTAssertEqual(splitView.pdfView.frame, initialPDFFrame)
            XCTAssertTrue(splitView.pdfView.currentPage === activePage)
        }

        splitView.viewDidEndLiveResize()
        splitView.layoutSubtreeIfNeeded()

        XCTAssertEqual(splitView.subviews[0].frame.width, initialSidebarFrame.width, accuracy: 2)
        XCTAssertEqual(splitView.subviews[0].frame.height, 700, accuracy: 0.5)
        XCTAssertEqual(splitView.pdfView.frame.height, 700, accuracy: 0.5)
        XCTAssertGreaterThan(splitView.pdfView.frame.width, initialPDFFrame.width)
        XCTAssertTrue(splitView.pdfView.autoScales)
        XCTAssertTrue(splitView.pdfView.currentPage === activePage)
    }

    func testRepeatedLiveResizeCyclesPreserveManualZoomAndLayerVisibility() throws {
        let splitView = makeSplitView(width: 820, pageCount: 2)
        let activePage = try XCTUnwrap(splitView.pdfView.document?.page(at: 1))
        splitView.pdfView.go(to: activePage)
        splitView.pdfView.autoScales = false
        splitView.pdfView.scaleFactor = 1.35
        let expectedScale = splitView.pdfView.scaleFactor

        for size in [
            NSSize(width: 1040, height: 680),
            NSSize(width: 740, height: 540),
            NSSize(width: 1120, height: 720),
        ] {
            let initialSidebarFrame = splitView.subviews[0].frame
            let initialPDFFrame = splitView.pdfView.frame

            splitView.viewWillStartLiveResize()
            splitView.setFrameSize(size)
            splitView.layoutSubtreeIfNeeded()

            XCTAssertEqual(splitView.subviews[0].frame, initialSidebarFrame)
            XCTAssertEqual(splitView.pdfView.frame, initialPDFFrame)

            splitView.viewDidEndLiveResize()
            splitView.layoutSubtreeIfNeeded()

            XCTAssertFalse(splitView.pdfView.autoScales)
            XCTAssertEqual(splitView.pdfView.scaleFactor, expectedScale, accuracy: 0.001)
            XCTAssertEqual(splitView.pdfView.layer?.isHidden, false)
            XCTAssertEqual(splitView.subviews[0].layer?.isHidden, false)
            XCTAssertTrue(splitView.pdfView.currentPage === activePage)
            XCTAssertEqual(splitView.pdfView.frame.height, size.height, accuracy: 0.5)
        }
    }

    func testLiveResizeRestoresTheActivePageAfterPDFKitRelayout() throws {
        let splitView = makeSplitView(width: 720, pageCount: 2)
        let firstPage = try XCTUnwrap(splitView.pdfView.document?.page(at: 0))
        let secondPage = try XCTUnwrap(splitView.pdfView.document?.page(at: 1))
        splitView.pdfView.go(to: secondPage)

        splitView.viewWillStartLiveResize()
        XCTAssertTrue(splitView.isPreservingPageDuringResize)

        // Simulate PDFKit selecting a different visible page during layout.
        splitView.pdfView.go(to: firstPage)
        splitView.viewDidEndLiveResize()

        XCTAssertTrue(splitView.pdfView.currentPage === secondPage)
    }

    func testLiveResizeRestoresTwoPageSelectionAfterFinalAutomaticLayout() async throws {
        let splitView = makeSplitView(width: 1_100, pageCount: 4)
        splitView.pdfView.displayMode = .twoUp
        splitView.pdfView.autoScales = true
        splitView.pdfView.layoutDocumentView()
        let fourthPage = try XCTUnwrap(splitView.pdfView.document?.page(at: 3))
        splitView.pdfView.go(to: fourthPage)

        splitView.viewWillStartLiveResize()
        splitView.setFrameSize(NSSize(width: 720, height: 548))
        splitView.layoutSubtreeIfNeeded()
        splitView.viewDidEndLiveResize()

        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(splitView.pdfView.autoScales)
        XCTAssertTrue(splitView.pdfView.currentPage === fourthPage)
        XCTAssertFalse(splitView.isPreservingPageDuringResize)
    }

    func testAnnotationCoordinateConversionRespectsZoomAndPageRotation() throws {
        let splitView = makeSplitView(width: 720)
        let page = try XCTUnwrap(splitView.pdfView.document?.page(at: 0))
        page.rotation = 90
        splitView.pdfView.autoScales = false
        splitView.pdfView.scaleFactor = 2
        splitView.pdfView.layoutDocumentView()

        let expectedPagePoint = CGPoint(x: 120, y: 180)
        let viewPoint = splitView.pdfView.convert(expectedPagePoint, from: page)
        let placement = try XCTUnwrap(splitView.pdfView.annotationPlacement(at: viewPoint))

        XCTAssertEqual(placement.pageIndex, 0)
        XCTAssertEqual(placement.point.x, expectedPagePoint.x, accuracy: 0.5)
        XCTAssertEqual(placement.point.y, expectedPagePoint.y, accuracy: 0.5)
    }

    func testInkSelectionUsesTheStrokeInsteadOfItsWholeBoundingBox() throws {
        let splitView = makeSplitView(width: 720)
        let page = try XCTUnwrap(splitView.pdfView.document?.page(at: 0))
        let annotation = PDFAnnotation(
            bounds: CGRect(x: 100, y: 100, width: 120, height: 100),
            forType: .ink,
            withProperties: nil
        )
        let identifier = AnnotationIdentifier()
        _ = annotation.setValue(identifier.pdfName, forAnnotationKey: .name)
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: 10))
        path.line(to: CGPoint(x: 120, y: 10))
        annotation.add(path)
        page.addAnnotation(annotation)
        splitView.pdfView.layoutDocumentView()

        let pointOnStroke = splitView.pdfView.convert(
            CGPoint(x: 160, y: 110),
            from: page
        )
        let pointOnlyInsideBounds = splitView.pdfView.convert(
            CGPoint(x: 160, y: 180),
            from: page
        )

        XCTAssertEqual(
            splitView.pdfView.annotationSelection(at: pointOnStroke)?.identifier,
            identifier
        )
        XCTAssertNil(splitView.pdfView.annotationSelection(at: pointOnlyInsideBounds))
    }

    func testAnnotationStateDefaultsAndResetArePresentationOnly() {
        let annotations = AnnotationState()

        XCTAssertFalse(annotations.isActive)
        XCTAssertEqual(annotations.selectedTool, .select)
        XCTAssertEqual(annotations.selectedColor, .black)
        XCTAssertEqual(annotations.selectedLineWidth, .standard)

        annotations.begin()
        annotations.selectedTool = .freehand
        annotations.selectedColor = .black
        annotations.selectedLineWidth = .bold
        annotations.updateTextMarkupRegions([
            TextMarkupRegion(pageIndex: 0, bounds: CGRect(x: 1, y: 2, width: 3, height: 4)),
        ])
        annotations.reset()

        XCTAssertFalse(annotations.isActive)
        XCTAssertEqual(annotations.selectedTool, .select)
        XCTAssertEqual(annotations.selectedColor, .black)
        XCTAssertEqual(annotations.selectedLineWidth, .standard)
        XCTAssertFalse(annotations.hasTextSelection)
    }

    func testCustomPageLabelsSupportRomanLettersPrefixAndStart() {
        let document = PDFDocument()
        for index in 0..<3 { document.insert(PDFPage(), at: index) }
        let state = ReaderState(pageCount: 3)

        state.pageLabelStyle = .romanUpper
        state.pageLabelStart = 4
        state.pageLabelPrefix = "A-"
        XCTAssertEqual(state.pageLabel(for: 0, in: document), "A-IV")
        XCTAssertEqual(state.pageLabel(for: 2, in: document), "A-VI")

        state.pageLabelStyle = .letters
        state.pageLabelStart = 26
        state.pageLabelPrefix = ""
        XCTAssertEqual(state.pageLabel(for: 0, in: document), "Z")
        XCTAssertEqual(state.pageLabel(for: 1, in: document), "AA")
    }

    private func makeSplitView(width: CGFloat, pageCount: Int = 1) -> ReaderSplitView {
        let document = PDFDocument()
        for pageIndex in 0..<pageCount {
            document.insert(PDFPage(), at: pageIndex)
        }

        let splitView = ReaderSplitView(
            frame: NSRect(x: 0, y: 0, width: width, height: 520)
        )
        splitView.pdfView.document = document
        splitView.thumbnailView.pdfView = splitView.pdfView
        splitView.setPosition(170, ofDividerAt: 0)
        splitView.adjustSubviews()
        splitView.layoutSubtreeIfNeeded()
        return splitView
    }
}
