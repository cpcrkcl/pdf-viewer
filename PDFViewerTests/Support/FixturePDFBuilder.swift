import AppKit
import CoreGraphics
import CoreText
import Foundation
import PDFKit

enum FixturePDFBuilder {
    static func writePDF(pageCount: Int, to url: URL) throws {
        let document = try makeDocument(pageCount: pageCount)

        guard document.write(to: url) else {
            throw FixtureError.couldNotWritePDF
        }
    }

    static func writePasswordProtectedPDF(
        to url: URL,
        userPassword: String = "fixture-user",
        ownerPassword: String = "fixture-owner",
        permissions: [PDFAccessPermissions] = [
            .allowsLowQualityPrinting,
            .allowsHighQualityPrinting,
            .allowsDocumentChanges,
            .allowsDocumentAssembly,
            .allowsContentCopying,
            .allowsContentAccessibility,
            .allowsCommenting,
            .allowsFormFieldEntry,
        ]
    ) throws {
        let document = try makeDocument(pageCount: 1)
        let permissionBits = permissions.reduce(UInt(0)) { partialResult, permission in
            partialResult | permission.rawValue
        }
        let options: [PDFDocumentWriteOption: Any] = [
            .ownerPasswordOption: ownerPassword,
            .userPasswordOption: userPassword,
            .accessPermissionsOption: NSNumber(value: permissionBits),
        ]

        guard document.write(to: url, withOptions: options) else {
            throw FixtureError.couldNotWritePDF
        }
    }

    static func writeTextPDF(pages: [String], to url: URL) throws {
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw FixtureError.couldNotWritePDF
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotWritePDF
        }

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
        ]

        for pageText in pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(
                NSAttributedString(string: pageText, attributes: attributes)
            )
            context.textPosition = CGPoint(x: 72, y: 680)
            CTLineDraw(line, context)
            context.endPDFPage()
        }

        context.closePDF()
    }

    private static func makeDocument(pageCount: Int) throws -> PDFDocument {
        let document = PDFDocument()

        for index in 0..<pageCount {
            let image = NSImage(size: NSSize(width: 612, height: 792))
            image.lockFocus()
            NSColor.white.setFill()
            NSRect(origin: .zero, size: image.size).fill()

            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 32, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
            NSString(string: "Fixture page \(index + 1)").draw(
                at: NSPoint(x: 72, y: 680),
                withAttributes: attributes
            )
            image.unlockFocus()

            guard let page = PDFPage(image: image) else {
                throw FixtureError.couldNotCreatePage
            }
            document.insert(page, at: index)
        }

        return document
    }

    enum FixtureError: Error {
        case couldNotCreatePage
        case couldNotWritePDF
    }
}
