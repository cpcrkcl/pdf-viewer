import AppKit
import Combine
import CoreGraphics
import CoreText
import Foundation
@preconcurrency import PDFKit

struct PDFRedactionRegion: Identifiable, Equatable {
    let id: UUID
    let pageIndex: Int
    let bounds: CGRect

    init(id: UUID = UUID(), pageIndex: Int, bounds: CGRect) {
        self.id = id
        self.pageIndex = pageIndex
        self.bounds = bounds.standardized
    }
}

@MainActor
final class RedactionState: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var regions: [PDFRedactionRegion] = []
    @Published private(set) var reasonLabel = ""

    func begin() {
        isActive = true
    }

    func end(clearRegions: Bool = true) {
        isActive = false
        if clearRegions {
            regions = []
            reasonLabel = ""
        }
    }

    func add(_ region: PDFRedactionRegion) {
        guard isActive, regions.count < 500 else {
            return
        }
        regions.append(region)
    }

    func removeLast() {
        guard !regions.isEmpty else {
            return
        }
        regions.removeLast()
    }

    func clear() {
        regions = []
    }

    func updateReasonLabel(_ label: String) {
        reasonLabel = String(label.prefix(80))
    }
}

enum PDFRedactionError: LocalizedError, Equatable {
    case noRegions
    case invalidRegion
    case couldNotRasterize
    case couldNotBuildSanitizedDocument
    case sanitizationVerificationFailed

    var errorDescription: String? {
        switch self {
        case .noRegions:
            "Draw at least one redaction area first."
        case .invalidRegion:
            "One of the redaction areas is outside its page or too small to apply safely."
        case .couldNotRasterize:
            "PDFViewer could not securely rasterize one of the selected pages."
        case .couldNotBuildSanitizedDocument:
            "PDFViewer could not build a clean redacted working copy."
        case .sanitizationVerificationFailed:
            "PDFViewer refused the redaction because its security verification did not pass."
        }
    }
}

@MainActor
enum PDFRedactionEngine {
    private static let defaultDPI: CGFloat = 144
    private static let maximumPixelCount: CGFloat = 25_000_000

    static func redactedDocument(
        from document: PDFDocument,
        regions: [PDFRedactionRegion],
        reasonLabel: String? = nil
    ) throws -> PDFDocument {
        guard !regions.isEmpty else {
            throw PDFRedactionError.noRegions
        }

        let validatedRegions = try validate(regions, in: document)
        let pageIndexes = IndexSet(validatedRegions.keys)
        let burnedDocument = try annotationBurnedCopy(of: document)
        let sanitized = PDFDocument()
        sanitized.documentAttributes = [:]

        for pageIndex in 0..<document.pageCount {
            let outputPage: PDFPage
            if let pageRegions = validatedRegions[pageIndex] {
                guard let burnedPage = burnedDocument.page(at: pageIndex) else {
                    throw PDFRedactionError.couldNotRasterize
                }
                outputPage = try rasterizedPage(
                    from: burnedPage,
                    regions: pageRegions,
                    dpi: defaultDPI,
                    reasonLabel: sanitizedReasonLabel(reasonLabel)
                )
            } else {
                guard
                    let page = document.page(at: pageIndex),
                    let copiedPage = page.copy() as? PDFPage
                else {
                    throw PDFRedactionError.couldNotBuildSanitizedDocument
                }
                outputPage = copiedPage
            }
            sanitized.insert(outputPage, at: pageIndex)
        }

        guard
            sanitized.pageCount == document.pageCount,
            let serialized = sanitized.dataRepresentation(),
            !serialized.isEmpty,
            let reopened = PDFDocument(data: serialized),
            reopened.pageCount == document.pageCount
        else {
            throw PDFRedactionError.couldNotBuildSanitizedDocument
        }
        reopened.documentAttributes = [:]
        guard
            let scrubbedData = reopened.dataRepresentation(),
            !scrubbedData.isEmpty,
            let scrubbed = PDFDocument(data: scrubbedData),
            scrubbed.pageCount == document.pageCount
        else {
            throw PDFRedactionError.couldNotBuildSanitizedDocument
        }

        try verifySanitized(scrubbed, pageIndexes: pageIndexes)
        return scrubbed
    }

    static func verifySanitized(
        _ document: PDFDocument,
        pageIndexes: IndexSet
    ) throws {
        guard
            !pageIndexes.isEmpty,
            pageIndexes.allSatisfy({ (0..<document.pageCount).contains($0) })
        else {
            throw PDFRedactionError.sanitizationVerificationFailed
        }

        for pageIndex in pageIndexes {
            guard let page = document.page(at: pageIndex) else {
                throw PDFRedactionError.sanitizationVerificationFailed
            }
            let remainingText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard remainingText?.isEmpty != false, page.annotations.isEmpty else {
                throw PDFRedactionError.sanitizationVerificationFailed
            }
        }

        let sensitiveMetadataKeys: [PDFDocumentAttribute] = [
            .titleAttribute,
            .authorAttribute,
            .subjectAttribute,
            .keywordsAttribute,
            .creatorAttribute,
        ]
        let attributes = document.documentAttributes ?? [:]
        guard sensitiveMetadataKeys.allSatisfy({ attributes[$0] == nil }) else {
            throw PDFRedactionError.sanitizationVerificationFailed
        }
    }

    private static func validate(
        _ regions: [PDFRedactionRegion],
        in document: PDFDocument
    ) throws -> [Int: [CGRect]] {
        var result: [Int: [CGRect]] = [:]

        for region in regions {
            guard
                (0..<document.pageCount).contains(region.pageIndex),
                let page = document.page(at: region.pageIndex)
            else {
                throw PDFRedactionError.invalidRegion
            }
            let pageBounds = page.bounds(for: .cropBox)
            let clipped = region.bounds.intersection(pageBounds)
            guard
                !clipped.isNull,
                !clipped.isInfinite,
                clipped.width >= 2,
                clipped.height >= 2
            else {
                throw PDFRedactionError.invalidRegion
            }
            result[region.pageIndex, default: []].append(clipped)
        }

        return result
    }

    private static func annotationBurnedCopy(of document: PDFDocument) throws -> PDFDocument {
        let options: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
        ]
        guard
            let data = document.dataRepresentation(options: options),
            !data.isEmpty,
            let copy = PDFDocument(data: data),
            copy.pageCount == document.pageCount
        else {
            throw PDFRedactionError.couldNotRasterize
        }
        return copy
    }

    private static func rasterizedPage(
        from page: PDFPage,
        regions: [CGRect],
        dpi: CGFloat,
        reasonLabel: String?
    ) throws -> PDFPage {
        guard let pageReference = page.pageRef else {
            throw PDFRedactionError.couldNotRasterize
        }

        let cropBounds = pageReference.getBoxRect(.cropBox)
        guard cropBounds.width > 0, cropBounds.height > 0 else {
            throw PDFRedactionError.couldNotRasterize
        }
        let normalizedRotation = ((page.rotation % 360) + 360) % 360
        let outputSize = normalizedRotation == 90 || normalizedRotation == 270
            ? CGSize(width: cropBounds.height, height: cropBounds.width)
            : cropBounds.size
        guard outputSize.width >= 2, outputSize.height >= 2 else {
            throw PDFRedactionError.couldNotRasterize
        }

        let requestedScale = max(1, dpi / 72)
        let safeScale = min(
            requestedScale,
            sqrt(maximumPixelCount / (outputSize.width * outputSize.height))
        )
        guard safeScale.isFinite, safeScale > 0 else {
            throw PDFRedactionError.couldNotRasterize
        }
        let pixelWidth = max(1, Int(ceil(outputSize.width * safeScale)))
        let pixelHeight = max(1, Int(ceil(outputSize.height * safeScale)))

        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw PDFRedactionError.couldNotRasterize
        }

        context.scaleBy(x: safeScale, y: safeScale)
        let outputBounds = CGRect(origin: .zero, size: outputSize)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(outputBounds)

        let drawingTransform = pageReference.getDrawingTransform(
            .cropBox,
            rect: outputBounds,
            rotate: 0,
            preserveAspectRatio: true
        )
        context.saveGState()
        context.concatenate(drawingTransform)
        context.drawPDFPage(pageReference)
        context.setFillColor(NSColor.black.cgColor)
        for region in regions {
            let coveredRegion = region.insetBy(dx: -0.5, dy: -0.5).intersection(cropBounds)
            context.fill(coveredRegion)
            if let reasonLabel {
                drawReasonLabel(reasonLabel, in: coveredRegion, context: context)
            }
        }
        context.restoreGState()

        guard let image = context.makeImage() else {
            throw PDFRedactionError.couldNotRasterize
        }
        let imageSize = NSSize(width: outputSize.width, height: outputSize.height)
        let rasterImage = NSImage(cgImage: image, size: imageSize)
        guard let outputPage = PDFPage(image: rasterImage) else {
            throw PDFRedactionError.couldNotRasterize
        }
        outputPage.rotation = 0
        return outputPage
    }

    private static func sanitizedReasonLabel(_ label: String?) -> String? {
        guard let label else {
            return nil
        }
        let normalized = String(label.prefix(80)).trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    private static func drawReasonLabel(
        _ label: String,
        in region: CGRect,
        context: CGContext
    ) {
        guard region.width >= 30, region.height >= 14 else {
            return
        }
        let fontSize = min(18, max(8, region.height * 0.22))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(
            string: label,
            attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.white,
            ]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        guard lineWidth > 0 else {
            return
        }
        let horizontalScale = min(1, max(0.1, (region.width - 12) / lineWidth))
        context.saveGState()
        context.setTextDrawingMode(.fill)
        context.setFillColor(NSColor.white.cgColor)
        context.translateBy(x: region.midX, y: region.midY)
        context.scaleBy(x: horizontalScale, y: 1)
        context.textPosition = CGPoint(x: -lineWidth / 2, y: -fontSize * 0.35)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}
