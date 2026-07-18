import PDFKit
import XCTest

@MainActor
final class PDFViewerUITests: XCTestCase {
    private var app: XCUIApplication!
    private var exportDirectory: URL?
    private var protectedFixtureDirectory: URL?
    private var navigationFixtureDirectory: URL?

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = [
            "-ApplePersistenceIgnoreState", "YES",
            "-PDFViewerUITestWindowWidth", "1100",
            "-PDFViewerUITestWindowHeight", "720",
        ]
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Choose PDF..."].waitForExistence(timeout: 5))
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let exportDirectory {
            try? FileManager.default.removeItem(at: exportDirectory)
        }
        exportDirectory = nil
        if let protectedFixtureDirectory {
            try? FileManager.default.removeItem(at: protectedFixtureDirectory)
        }
        protectedFixtureDirectory = nil
        if let navigationFixtureDirectory {
            try? FileManager.default.removeItem(at: navigationFixtureDirectory)
        }
        navigationFixtureDirectory = nil
        app = nil
    }

    func testNativeOpenPanelDirtyCloseGuardShortcutsAndOrganizerLabels() throws {
        try openFixtureThroughNativePanel()

        app.typeKey("f", modifierFlags: .command)
        let searchField = app.textFields["Search document text"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 2))
        searchField.typeText("PDF")
        searchField.typeKey(.return, modifierFlags: [])

        app.buttons["Organize"].click()
        let organizer = app.sheets.firstMatch
        XCTAssertTrue(organizer.waitForExistence(timeout: 3))
        XCTAssertTrue(organizer.buttons["Move Up"].exists)
        XCTAssertTrue(organizer.buttons["Move Down"].exists)
        XCTAssertTrue(organizer.buttons["Rotate Left"].exists)
        XCTAssertTrue(organizer.buttons["Rotate Right"].exists)
        XCTAssertTrue(organizer.buttons["Extract Selected Pages…"].exists)
        XCTAssertTrue(organizer.buttons["Export New PDF…"].exists)

        organizer.buttons["Rotate Right"].click()
        organizer.buttons["Done"].click()

        app.typeKey("z", modifierFlags: .command)
        app.typeKey("z", modifierFlags: [.command, .shift])
        app.typeKey("w", modifierFlags: .command)

        let exportAndContinueButton = app.buttons["Export and Continue…"]
        XCTAssertTrue(exportAndContinueButton.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Discard Changes"].exists)
        let cancelButton = app.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(cancelButton.exists)
        cancelButton.click()

        XCTAssertTrue(app.buttons["Organize"].waitForExistence(timeout: 2))
    }

    func testValidatedExportShowsReceiptAndAllowsQuietClose() throws {
        try openFixtureThroughNativePanel()
        app.buttons["Organize"].click()
        let organizer = app.sheets.firstMatch
        XCTAssertTrue(organizer.waitForExistence(timeout: 3))
        organizer.buttons["Rotate Right"].click()
        organizer.buttons["Done"].click()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerUITests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        exportDirectory = directory

        let window = app.windows.firstMatch
        resizeWindow(window, width: 720, height: 548)
        XCTAssertLessThanOrEqual(window.frame.width, 760)

        let exportFileName =
            "A Deliberately Long Responsive Export Filename That Preserves Actions.pdf"
        app.buttons["Export"].click()
        try chooseSaveDestination(
            directory: directory,
            fileName: exportFileName
        )

        let showInFinder = app.buttons["Show in Finder"]
        XCTAssertTrue(showInFinder.waitForExistence(timeout: 5))
        assertElement(showInFinder, isContainedIn: window)
        assertElement(app.buttons["Dismiss Export Confirmation"], isContainedIn: window)
        XCTAssertTrue(app.staticTexts["Exported \(exportFileName)"].exists)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(exportFileName).path
        ))

        app.typeKey("w", modifierFlags: .command)
        XCTAssertFalse(app.buttons["Export and Continue…"].waitForExistence(timeout: 1))
        XCTAssertTrue(app.buttons["Choose PDF..."].waitForExistence(timeout: 3))
    }

    func testReaderAndOrganizerReflowAcrossCompactAndRegularWindowSizes() throws {
        try openFixtureThroughNativePanel()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)
        XCTAssertTrue(
            app.radioButtons["Continuous"].exists,
            "Regular controls missing at initial window frame \(window.frame)"
        )
        XCTAssertTrue(app.radioButtons["Day"].exists)
        XCTAssertTrue(app.buttons["Rotate Left"].exists)

        let pageField = app.textFields["Page number"]
        XCTAssertTrue(pageField.exists)
        let originalPageNumber = pageField.value as? String

        resizeWindow(window, width: 720, height: 548)
        XCTAssertLessThanOrEqual(window.frame.width, 760)

        let compactElements = [
            app.buttons["Open"],
            app.buttons["Organize"],
            app.buttons["Export"],
            app.buttons["Close Document"],
            app.buttons["Hide Sidebar"],
            app.textFields["Page number"],
            app.textFields["Search document text"],
            app.menuButtons["View"],
            app.menuButtons["Page Actions"],
        ]
        for element in compactElements {
            assertElement(element, isContainedIn: window)
        }

        app.menuButtons["Page Actions"].click()
        for title in [
            "Undo Document Operation",
            "Redo Document Operation",
            "Move Page Up",
            "Move Page Down",
            "Rotate Left",
            "Rotate Right",
            "Delete Page",
        ] {
            XCTAssertTrue(
                app.menuItems[title].waitForExistence(timeout: 2),
                "Missing Page Actions item: \(title)"
            )
        }
        app.typeKey(.escape, modifierFlags: [])

        app.menuButtons["View"].click()
        for title in [
            "Single Page",
            "Two Page",
            "Continuous",
            "Day",
            "Night",
            "Hide Sidebar",
        ] {
            XCTAssertTrue(
                app.menuItems[title].waitForExistence(timeout: 2),
                "Missing View item: \(title)"
            )
        }
        app.typeKey(.escape, modifierFlags: [])

        app.buttons["Hide Sidebar"].click()
        XCTAssertTrue(app.buttons["Show Sidebar"].waitForExistence(timeout: 2))
        XCTAssertEqual(pageField.value as? String, originalPageNumber)
        app.buttons["Show Sidebar"].click()
        XCTAssertTrue(app.buttons["Hide Sidebar"].waitForExistence(timeout: 2))
        XCTAssertEqual(pageField.value as? String, originalPageNumber)

        let repeatedResizeTargets: [(width: CGFloat, height: CGFloat, isCompact: Bool)] = [
            (1100, 748, false),
            (720, 548, true),
            (1100, 748, false),
            (720, 548, true),
        ]
        for target in repeatedResizeTargets {
            resizeWindow(window, width: target.width, height: target.height)

            if target.isCompact {
                XCTAssertLessThanOrEqual(window.frame.width, 760)
                XCTAssertTrue(app.menuButtons["View"].waitForExistence(timeout: 2))
                XCTAssertTrue(app.menuButtons["Page Actions"].exists)
            } else {
                XCTAssertGreaterThanOrEqual(window.frame.width, 1050)
                XCTAssertTrue(app.radioButtons["Continuous"].waitForExistence(timeout: 2))
                XCTAssertTrue(app.radioButtons["Day"].exists)
            }

            assertElement(app.buttons["Hide Sidebar"], isContainedIn: window)
            assertElement(pageField, isContainedIn: window)
            XCTAssertTrue(app.splitGroups.firstMatch.exists)
            XCTAssertEqual(pageField.value as? String, originalPageNumber)
        }

        app.buttons["Organize"].click()
        let organizer = app.sheets.firstMatch
        XCTAssertTrue(organizer.waitForExistence(timeout: 3))

        let organizerButtons = [
            organizer.buttons["Move Up"],
            organizer.buttons["Move Down"],
            organizer.buttons["Rotate Left"],
            organizer.buttons["Rotate Right"],
            organizer.buttons["Delete Page"],
            organizer.buttons["Extract Selected Pages…"],
            organizer.buttons["Export New PDF…"],
            organizer.buttons["Done"],
        ]
        for element in organizerButtons {
            assertElement(element, isContainedIn: organizer)
        }
        assertElement(organizer.menuButtons["Move To…"], isContainedIn: organizer)
        assertElement(
            organizer.menuButtons["Add Pages / Merge PDF…"],
            isContainedIn: organizer
        )
        XCTAssertGreaterThanOrEqual(
            organizer.buttons["Extract Selected Pages…"].frame.width,
            150
        )
        organizer.buttons["Done"].click()

        resizeWindow(window, width: 1100, height: 748)
        XCTAssertGreaterThanOrEqual(window.frame.width, 1050)
        XCTAssertTrue(app.radioButtons["Continuous"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.radioButtons["Day"].exists)
        XCTAssertTrue(app.buttons["Rotate Left"].exists)
        XCTAssertEqual(pageField.value as? String, originalPageNumber)
    }

    func testAnnotationControlsRemainCompleteAtMinimumWindowSize() throws {
        try openFixtureThroughNativePanel()
        let window = app.windows.firstMatch
        resizeWindow(window, width: 720, height: 548)

        app.buttons["Annotate"].click()
        XCTAssertTrue(app.buttons["Done Annotating"].waitForExistence(timeout: 2))

        let toolMenu = app.menuButtons["Tool: Select"]
        let styleMenu = app.menuButtons["Style"]
        assertElement(app.buttons["Done"], isContainedIn: window)

        if toolMenu.exists {
            assertElement(toolMenu, isContainedIn: window)
            assertElement(styleMenu, isContainedIn: window)
            toolMenu.click()
            for title in ["Select", "Highlight", "Underline", "Strikethrough", "Freehand", "Text Note"] {
                XCTAssertTrue(app.menuItems[title].exists, "Missing annotation tool: \(title)")
            }
            app.menuItems["Freehand"].click()
            XCTAssertTrue(app.menuButtons["Tool: Freehand"].waitForExistence(timeout: 2))
            assertElement(app.menuButtons["Style"], isContainedIn: window)
        } else {
            for title in ["Select", "Highlight", "Underline", "Strikethrough", "Freehand", "Text Note"] {
                assertElement(app.radioButtons[title], isContainedIn: window)
            }
            assertElement(app.menuButtons["Color: Black"], isContainedIn: window)
            app.radioButtons["Freehand"].click()
        }

        resizeWindow(window, width: 1300, height: 748)
        XCTAssertTrue(app.radioButtons["Freehand"].waitForExistence(timeout: 2))
        assertElement(app.menuButtons["Color: Black"], isContainedIn: window)
        for title in ["Fine", "Standard", "Bold"] {
            assertElement(app.radioButtons[title], isContainedIn: window)
        }

        app.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Annotate"].waitForExistence(timeout: 2))
    }

    func testPasswordPromptRetryUnlockAndEncryptedExportWarning() throws {
        let protectedURL = try makeProtectedFixture()
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        try enterPathInNativePanel(protectedURL.path)
        app.typeKey(.return, modifierFlags: [])

        let passwordField = app.secureTextFields["PDF password"]
        XCTAssertTrue(passwordField.waitForExistence(timeout: 4))
        XCTAssertTrue(app.staticTexts[protectedURL.lastPathComponent].exists)
        passwordField.typeText("incorrect")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Incorrect password. Try again."].waitForExistence(timeout: 2))

        passwordField.typeText("fixture-user")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Organize"].waitForExistence(timeout: 5))

        app.buttons["Export"].click()
        XCTAssertTrue(app.buttons["Export Encrypted Copy"].waitForExistence(timeout: 3))
        let warningCancel = app.sheets.firstMatch.buttons["Cancel"]
        XCTAssertTrue(warningCancel.exists)
        warningCancel.click()
        XCTAssertTrue(app.buttons["Export"].waitForExistence(timeout: 2))
    }

    func testReaderSidebarBookmarksOutlinesAndNavigationHistory() throws {
        let navigationURL = try makeNavigationFixture()
        try openDocumentThroughNativePanel(navigationURL)

        let window = app.windows.firstMatch
        resizeWindow(window, width: 720, height: 548)
        XCTAssertLessThanOrEqual(window.frame.width, 760)

        sidebarTab(named: "Contents").click()
        XCTAssertTrue(app.buttons["Chapter Two"].waitForExistence(timeout: 3))
        app.buttons["Chapter Two"].click()
        XCTAssertEqual(app.textFields["Page number"].value as? String, "2")

        sidebarTab(named: "Bookmarks").click()
        XCTAssertTrue(app.buttons["Add Bookmark"].waitForExistence(timeout: 2))
        app.buttons["Add Bookmark"].click()
        XCTAssertTrue(app.buttons["Chapter Two, Page 2"].waitForExistence(timeout: 2))

        let bookmarkActions = app.menuButtons["Bookmark Actions"]
        XCTAssertTrue(bookmarkActions.exists)
        bookmarkActions.click()
        app.menuItems["Rename Bookmark"].click()
        let nameField = app.textFields["Bookmark Name"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText("Important Section")
        app.sheets.firstMatch.buttons["Rename"].click()
        XCTAssertTrue(app.buttons["Important Section, Page 2"].waitForExistence(timeout: 2))

        app.buttons["Organize"].click()
        let organizer = app.sheets.firstMatch
        XCTAssertTrue(organizer.waitForExistence(timeout: 2))
        organizer.buttons["Move Down"].click()
        organizer.buttons["Done"].click()
        XCTAssertTrue(app.buttons["Important Section, Page 3"].waitForExistence(timeout: 2))

        let pageField = app.textFields["Page number"]
        pageField.click()
        pageField.typeKey("a", modifierFlags: .command)
        pageField.typeText("1")
        pageField.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(pageField.value as? String, "1")
        app.buttons["Important Section, Page 3"].click()
        XCTAssertEqual(pageField.value as? String, "3")

        app.typeKey("z", modifierFlags: .command)
        XCTAssertTrue(app.buttons["Important Section, Page 2"].waitForExistence(timeout: 2))
        pageField.click()
        pageField.typeKey("a", modifierFlags: .command)
        pageField.typeText("1")
        pageField.typeKey(.return, modifierFlags: [])
        app.buttons["Important Section, Page 2"].click()
        XCTAssertEqual(pageField.value as? String, "2")

        XCTAssertTrue(app.buttons["Back"].isEnabled)
        app.buttons["Back"].click()
        XCTAssertEqual(pageField.value as? String, "1")
        XCTAssertTrue(app.buttons["Forward"].isEnabled)
        app.buttons["Forward"].click()
        XCTAssertEqual(pageField.value as? String, "2")

        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(app.buttons["Choose PDF..."].waitForExistence(timeout: 5))
        try openDocumentThroughNativePanel(navigationURL)
        sidebarTab(named: "Bookmarks").click()
        XCTAssertTrue(app.buttons["Important Section, Page 2"].waitForExistence(timeout: 3))

        app.menuButtons["Bookmark Actions"].click()
        app.menuItems["Delete Bookmark"].click()
        XCTAssertTrue(
            app.buttons["Important Section, Page 2"].waitForNonExistence(timeout: 3)
        )
    }

    private func openFixtureThroughNativePanel() throws {
        try openDocumentThroughNativePanel(fixtureURL)
    }

    private func openDocumentThroughNativePanel(_ url: URL) throws {
        app.typeKey("o", modifierFlags: .command)
        XCTAssertTrue(app.sheets.firstMatch.waitForExistence(timeout: 3))
        try enterPathInNativePanel(url.path)
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["Organize"].waitForExistence(timeout: 5))
    }

    private func sidebarTab(named name: String) -> XCUIElement {
        let radioButton = app.radioButtons[name]
        return radioButton.exists ? radioButton : app.buttons[name]
    }

    private func chooseSaveDestination(directory: URL, fileName: String) throws {
        let savePanel = app.windows["Export PDF"]
        XCTAssertTrue(savePanel.waitForExistence(timeout: 3))
        try enterPathInNativePanel(directory.path)

        let nameField = savePanel.textFields.firstMatch
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        nameField.typeKey("a", modifierFlags: .command)
        nameField.typeText(fileName)
        savePanel.buttons["Save"].click()
    }

    private func enterPathInNativePanel(_ path: String) throws {
        app.typeKey("g", modifierFlags: [.command, .shift])
        let pathField = app.textFields["PathTextField"]
        XCTAssertTrue(pathField.waitForExistence(timeout: 2))
        pathField.typeText(path)
        app.typeKey(.return, modifierFlags: [])
    }

    private func resizeWindow(_ window: XCUIElement, width: CGFloat, height: CGFloat) {
        let currentFrame = window.frame
        let lowerRight = window.coordinate(
            withNormalizedOffset: CGVector(dx: 0.995, dy: 0.995)
        )
        let destination = window.coordinate(
            withNormalizedOffset: CGVector(
                dx: width / currentFrame.width,
                dy: height / currentFrame.height
            )
        )
        lowerRight.press(forDuration: 0.2, thenDragTo: destination)
    }

    private func assertElement(
        _ element: XCUIElement,
        isContainedIn container: XCUIElement,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(element.exists, file: file, line: line)
        XCTAssertTrue(element.isHittable, file: file, line: line)
        XCTAssertTrue(
            container.frame.insetBy(dx: -2, dy: -2).contains(element.frame),
            "\(element) frame \(element.frame) lies outside \(container) frame \(container.frame)",
            file: file,
            line: line
        )
    }

    private var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("pdf-mac-app-gameplan.pdf")
    }

    private func makeProtectedFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerProtectedUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        protectedFixtureDirectory = directory
        let url = directory.appendingPathComponent("Protected Fixture.pdf")
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let wrote = document.write(
            to: url,
            withOptions: [
                .ownerPasswordOption: "fixture-owner",
                .userPasswordOption: "fixture-user",
            ]
        )
        guard wrote else {
            throw UITestFixtureError.couldNotWriteProtectedPDF
        }
        return url
    }

    private func makeNavigationFixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFViewerNavigationUITest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        navigationFixtureDirectory = directory
        let url = directory.appendingPathComponent("Navigation Fixture.pdf")

        let document = PDFDocument()
        for _ in 0..<3 {
            document.insert(PDFPage(), at: document.pageCount)
        }
        document.documentAttributes = [
            PDFDocumentAttribute.titleAttribute: "Navigation \(UUID().uuidString)",
        ]
        let root = PDFOutline()
        let chapterOne = PDFOutline()
        chapterOne.label = "Chapter One"
        chapterOne.destination = PDFDestination(page: document.page(at: 0)!, at: .zero)
        root.insertChild(chapterOne, at: 0)

        let chapterTwo = PDFOutline()
        chapterTwo.label = "Chapter Two"
        chapterTwo.destination = PDFDestination(page: document.page(at: 1)!, at: .zero)
        let section = PDFOutline()
        section.label = "Section 2.1"
        section.destination = PDFDestination(page: document.page(at: 2)!, at: .zero)
        chapterTwo.insertChild(section, at: 0)
        root.insertChild(chapterTwo, at: 1)
        document.outlineRoot = root

        guard document.write(to: url) else {
            throw UITestFixtureError.couldNotWriteNavigationPDF
        }
        return url
    }

    private enum UITestFixtureError: Error {
        case couldNotWriteProtectedPDF
        case couldNotWriteNavigationPDF
    }
}
