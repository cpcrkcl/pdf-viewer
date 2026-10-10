import Combine
import Foundation
import PDFKit
import XCTest
@testable import PDFViewer

@MainActor
final class PDFSearchControllerTests: XCTestCase {
    func testEditingACompletedQueryClearsStaleResultsUntilResubmission() async throws {
        let controller = PDFSearchController()
        let document = try makeTextDocument(pages: ["Alpha alpha beta"])
        let finished = expectation(description: "search finished")
        let observation = controller.$isSearching
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in finished.fulfill() }
        controller.startSearch(for: "alpha", in: document)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(controller.matchCount, 2)

        controller.updateQuery("beta")

        XCTAssertEqual(controller.query, "beta")
        XCTAssertEqual(controller.matchCount, 0)
        XCTAssertNil(controller.activeMatchIndex)
        XCTAssertEqual(controller.feedback, .idle)
    }

    func testReplacementSearchIgnoresMatchesFromCancelledQuery() async throws {
        let controller = PDFSearchController()
        let document = try makeTextDocument(
            pages: Array(repeating: "Alpha appears on this page.", count: 40)
                + ["Beta is the replacement result."]
        )
        let finished = expectation(description: "replacement search finished")
        let observation = controller.$isSearching
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in finished.fulfill() }

        controller.startSearch(for: "alpha", in: document)
        controller.startSearch(for: "beta", in: document)

        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(controller.query, "beta")
        XCTAssertEqual(controller.matchCount, 1)
        XCTAssertTrue(
            controller.matches.allSatisfy {
                $0.string?.localizedCaseInsensitiveContains("beta") == true
            }
        )
    }

    func testCaseInsensitiveSearchHighlightsAndNavigatesMatches() async throws {
        let document = try makeTextDocument(pages: [
            "The Needle appears on page one.",
            "A second needle appears on page two.",
        ])
        let controller = PDFSearchController()
        let finished = expectation(description: "search finished")
        let observation = controller.$isSearching
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in finished.fulfill() }

        controller.startSearch(for: "NEEDLE", in: document)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}

        XCTAssertEqual(controller.matchCount, 2)
        XCTAssertEqual(controller.feedback, .matches)
        XCTAssertEqual(controller.activeMatchIndex, 0)
        XCTAssertNotNil(controller.activeSelection)

        controller.selectNextMatch()
        XCTAssertEqual(controller.activeMatchIndex, 1)
        controller.selectNextMatch()
        XCTAssertEqual(controller.activeMatchIndex, 0)
        controller.selectPreviousMatch()
        XCTAssertEqual(controller.activeMatchIndex, 1)
    }

    func testTextlessPDFReportsSearchUnavailableWithoutCreatingMatches() {
        let document = PDFDocument()
        let image = NSImage(size: NSSize(width: 100, height: 100))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        document.insert(PDFPage(image: image)!, at: 0)
        let controller = PDFSearchController()

        controller.startSearch(for: "needle", in: document)

        XCTAssertFalse(controller.isSearching)
        XCTAssertEqual(controller.matchCount, 0)
        XCTAssertEqual(controller.feedback, .textUnavailable)
    }

    func testClearingSearchRemovesMatchesAndFeedback() async throws {
        let document = try makeTextDocument(pages: ["A needle is here."])
        let controller = PDFSearchController()
        let finished = expectation(description: "search finished")
        let observation = controller.$isSearching
            .dropFirst()
            .filter { !$0 }
            .prefix(1)
            .sink { _ in finished.fulfill() }

        controller.startSearch(for: "needle", in: document)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}
        controller.clear()

        XCTAssertEqual(controller.query, "")
        XCTAssertEqual(controller.matchCount, 0)
        XCTAssertNil(controller.activeMatchIndex)
        XCTAssertEqual(controller.feedback, .idle)
    }

    func testCaseSensitiveAndWholeWordOptionsFilterResults() async throws {
        let document = try makeTextDocument(pages: ["Cat cat concatenate cat."])
        let controller = PDFSearchController()
        controller.options = PDFSearchOptions(isCaseSensitive: true, matchesWholeWords: true)
        let finished = expectation(description: "search finished")
        let observation = controller.$isSearching.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            finished.fulfill()
        }
        controller.startSearch(for: "cat", in: document)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}
        XCTAssertEqual(controller.matchCount, 2)
        XCTAssertTrue(controller.matches.allSatisfy { $0.string == "cat" })
    }

    func testSelectedMatchesMapToRedactionRegionsAndCanNavigateDirectly() async throws {
        let document = try makeTextDocument(pages: ["secret one", "secret two"])
        let controller = PDFSearchController()
        let finished = expectation(description: "search finished")
        let observation = controller.$isSearching.dropFirst().filter { !$0 }.prefix(1).sink { _ in
            finished.fulfill()
        }
        controller.startSearch(for: "secret", in: document)
        await fulfillment(of: [finished], timeout: 2)
        withExtendedLifetime(observation) {}

        let regions = controller.redactionRegions(forMatchIndexes: [1], in: document)
        XCTAssertEqual(regions.count, 1)
        XCTAssertEqual(regions.first?.pageIndex, 1)
        XCTAssertFalse(regions[0].bounds.isEmpty)
        controller.selectMatch(at: 1)
        XCTAssertEqual(controller.activeMatchIndex, 1)
    }

    private func makeTextDocument(pages: [String]) throws -> PDFDocument {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let url = temporaryDirectory.appendingPathComponent("searchable.pdf")
        try FixturePDFBuilder.writeTextPDF(pages: pages, to: url)
        let data = try Data(contentsOf: url)

        guard let document = PDFDocument(data: data) else {
            throw TestError.couldNotOpenFixture
        }
        return document
    }

    private enum TestError: Error {
        case couldNotOpenFixture
    }
}
