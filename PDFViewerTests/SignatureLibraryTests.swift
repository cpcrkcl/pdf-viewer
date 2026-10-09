import AppKit
import Foundation
import XCTest
@testable import PDFViewer

@MainActor
final class SignatureLibraryTests: XCTestCase {
    func testImportedSignaturePersistsLocallyAndCanBeDeleted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureLibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }

        let imageData = try makeImageData()
        let library = SignatureLibrary(storageDirectory: directory)
        let stored = try library.importImage(data: imageData, displayName: "My Signature")

        XCTAssertEqual(library.signatures, [stored])
        XCTAssertEqual(try library.imageData(for: stored.id), imageData)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("signatures.v1.json").path
            )
        )

        let reloaded = SignatureLibrary(storageDirectory: directory)
        XCTAssertEqual(reloaded.signatures, [stored])
        XCTAssertEqual(try reloaded.imageData(for: stored.id), imageData)

        try reloaded.delete(stored.id)
        XCTAssertTrue(reloaded.signatures.isEmpty)
        XCTAssertThrowsError(try reloaded.imageData(for: stored.id))
    }

    func testDrawingCreatesTransparentPNGAndPersistsIt() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureDrawingTests-\(UUID().uuidString)", isDirectory: true)
        defer {
            if FileManager.default.fileExists(atPath: directory.path) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
        let library = SignatureLibrary(storageDirectory: directory)
        let strokes = [
            InkStroke(
                pageIndex: 0,
                points: [
                    CGPoint(x: 10, y: 20),
                    CGPoint(x: 80, y: 60),
                    CGPoint(x: 180, y: 25),
                ]
            ),
        ]

        let stored = try library.createFromDrawing(
            strokes: strokes,
            canvasSize: CGSize(width: 200, height: 80),
            displayName: "Drawn Signature"
        )

        let data = try library.imageData(for: stored.id)
        XCTAssertNotNil(NSImage(data: data))
        XCTAssertEqual(stored.displayName, "Drawn Signature")
        XCTAssertEqual(stored.aspectRatio, 2.5, accuracy: 0.01)
    }

    func testImportRejectsUnsupportedImageFormatsInsteadOfMislabellingTheirBytes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureFormatTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let library = SignatureLibrary(storageDirectory: directory)

        let image = NSImage(size: NSSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.black.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        image.unlockFocus()
        let tiff = try XCTUnwrap(image.tiffRepresentation)

        XCTAssertThrowsError(
            try library.importImage(data: tiff, displayName: "TIFF")
        ) { error in
            XCTAssertEqual(error as? SignatureLibraryError, .invalidImage)
        }
        XCTAssertTrue(library.signatures.isEmpty)
    }

    func testReloadIgnoresTamperedIndexPathsAndDuplicateIDs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignatureIndexTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID()
        let unsafeID = UUID()
        try makeImageData().write(
            to: directory.appendingPathComponent("\(id.uuidString.lowercased()).png")
        )
        let records = [
            StoredSignature(
                id: unsafeID,
                displayName: "Unsafe",
                fileName: "../outside.png",
                aspectRatio: 2,
                createdAt: Date()
            ),
            StoredSignature(
                id: id,
                displayName: "First",
                fileName: "\(id.uuidString.lowercased()).png",
                aspectRatio: 2,
                createdAt: Date()
            ),
            StoredSignature(
                id: id,
                displayName: "Duplicate",
                fileName: "\(id.uuidString.lowercased()).png",
                aspectRatio: 2,
                createdAt: Date().addingTimeInterval(1)
            ),
        ]
        try JSONEncoder().encode(records).write(
            to: directory.appendingPathComponent("signatures.v1.json")
        )

        let signatures = SignatureLibrary(storageDirectory: directory).signatures
        XCTAssertEqual(signatures.count, 1)
        XCTAssertEqual(signatures.first?.displayName, "First")
    }

    private func makeImageData() throws -> Data {
        let image = NSImage(size: NSSize(width: 180, height: 60))
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: image.size).fill()
        NSColor.black.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 5
        path.move(to: NSPoint(x: 5, y: 10))
        path.line(to: NSPoint(x: 175, y: 50))
        path.stroke()
        image.unlockFocus()
        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw SignatureLibraryTestError.couldNotCreateImage
        }
        return data
    }
}

private enum SignatureLibraryTestError: Error {
    case couldNotCreateImage
}
