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

    /// Writes a PDF whose single page embeds one large bitmap using lossless
    /// (flate) encoding, like a typical scan. The gradient-plus-noise pixels
    /// compress badly losslessly but well as JPEG, so JPEG-based export
    /// profiles produce a measurably smaller output.
    static func writeLargeImagePDF(
        to url: URL,
        pixelWidth: Int = 1400,
        pixelHeight: Int = 1800
    ) throws {
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelWidth,
                pixelsHigh: pixelHeight,
                bitsPerSample: 8,
                samplesPerPixel: 3,
                hasAlpha: false,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ),
            let bitmapData = bitmap.bitmapData
        else {
            throw FixtureError.couldNotCreatePage
        }

        var seed: UInt64 = 0x9E3779B97F4A7C15
        for y in 0..<pixelHeight {
            for x in 0..<pixelWidth {
                let index = y * bitmap.bytesPerRow + x * 3
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let noise = Int(seed >> 60)
                bitmapData[index] = UInt8((x * 255 / pixelWidth + noise) % 256)
                bitmapData[index + 1] = UInt8((y * 255 / pixelHeight + noise) % 256)
                bitmapData[index + 2] = UInt8(
                    ((x + y) * 255 / (pixelWidth + pixelHeight) + noise) % 256
                )
            }
        }

        guard
            let cgImage = bitmap.cgImage,
            let consumer = CGDataConsumer(url: url as CFURL)
        else {
            throw FixtureError.couldNotCreatePage
        }

        var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw FixtureError.couldNotWritePDF
        }
        context.beginPDFPage(nil)
        context.draw(cgImage, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
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
