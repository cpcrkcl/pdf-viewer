import AppKit
import CoreImage
import CoreText
import Foundation
import ImageIO
@preconcurrency import PDFKit
@preconcurrency import Vision

enum PDFScanEnhancementPreset: String, CaseIterable, Identifiable, Sendable {
    case none
    case grayscale
    case cleanScan

    var id: Self { self }

    var title: String {
        switch self {
        case .none:
            "No Enhancement"
        case .grayscale:
            "Grayscale"
        case .cleanScan:
            "Clean Scan"
        }
    }

    var summary: String {
        switch self {
        case .none:
            "Keeps the rendered page appearance unchanged."
        case .grayscale:
            "Removes color while preserving tonal detail."
        case .cleanScan:
            "Corrects perspective and deskew, reduces noise and shadows, whitens the background, increases contrast, and sharpens text."
        }
    }
}

enum PDFOCRRasterQuality: Int, CaseIterable, Identifiable, Sendable {
    case compact = 150
    case balanced = 200
    case archival = 300

    var id: Self { self }
    var dpi: CGFloat { CGFloat(rawValue) }

    var title: String {
        switch self {
        case .compact:
            "Compact (150 DPI)"
        case .balanced:
            "Balanced (200 DPI)"
        case .archival:
            "Archival (300 DPI)"
        }
    }
}

enum PDFOCRLanguage: String, CaseIterable, Identifiable, Sendable {
    case automatic
    case englishUS = "en-US"
    case spanish = "es-ES"
    case french = "fr-FR"
    case german = "de-DE"
    case italian = "it-IT"
    case portuguese = "pt-BR"
    case japanese = "ja-JP"
    case korean = "ko-KR"
    case chineseSimplified = "zh-Hans"

    var id: Self { self }
    var recognitionLanguage: String? { self == .automatic ? nil : rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .englishUS: "English (US)"
        case .spanish: "Spanish"
        case .french: "French"
        case .german: "German"
        case .italian: "Italian"
        case .portuguese: "Portuguese (Brazil)"
        case .japanese: "Japanese"
        case .korean: "Korean"
        case .chineseSimplified: "Chinese (Simplified)"
        }
    }
}

struct PDFOCRProgress: Equatable, Sendable {
    let completedPages: Int
    let totalPages: Int
}

struct PDFOCRResult {
    let document: PDFDocument
    let recognizedLineCount: Int
    let sourcePageIndexes: [Int]
}

struct PDFScanPreview: @unchecked Sendable {
    let original: CGImage
    let processed: CGImage
}

enum PDFOCRError: LocalizedError, Equatable {
    case noPagesSelected
    case invalidPageSelection
    case couldNotRenderPage
    case recognitionFailed
    case couldNotBuildSearchablePDF
    case invalidCropMargins
    case documentChangedDuringProcessing

    var errorDescription: String? {
        switch self {
        case .noPagesSelected:
            "Select one or more pages to process."
        case .invalidPageSelection:
            "One of the selected pages is no longer available."
        case .couldNotRenderPage:
            "PDFViewer could not render one of the selected pages for local processing."
        case .recognitionFailed:
            "Local text recognition could not process one of the selected pages."
        case .couldNotBuildSearchablePDF:
            "PDFViewer could not build a validated searchable PDF working copy."
        case .invalidCropMargins:
            "Choose a crop margin between 0 and 20 percent."
        case .documentChangedDuringProcessing:
            "The working PDF changed while local processing was running. Review the latest revision and try again."
        }
    }
}

struct PDFRecognizedTextLine: Equatable, Sendable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

enum PDFScanEnhancer {
    static func enhancedImage(
        _ image: CGImage,
        preset: PDFScanEnhancementPreset
    ) throws -> CGImage {
        guard preset != .none else {
            return image
        }

        var inputImage = CIImage(cgImage: image)
        if preset == .cleanScan, let deskewed = try? automaticallyDeskewed(inputImage) {
            inputImage = deskewed
        }

        let outputImage: CIImage
        switch preset {
        case .none:
            outputImage = inputImage
        case .grayscale:
            outputImage = inputImage.applyingFilter(
                "CIColorControls",
                parameters: [
                    kCIInputSaturationKey: 0,
                ]
            )
        case .cleanScan:
            outputImage = inputImage
                .applyingFilter(
                    "CIColorControls",
                    parameters: [
                        kCIInputSaturationKey: 0,
                        kCIInputBrightnessKey: 0.06,
                        kCIInputContrastKey: 1.28,
                    ]
                )
                .applyingFilter(
                    "CINoiseReduction",
                    parameters: [
                        "inputNoiseLevel": 0.025,
                        "inputSharpness": 0.35,
                    ]
                )
                .applyingFilter(
                    "CIHighlightShadowAdjust",
                    parameters: [
                        "inputShadowAmount": 0.35,
                        "inputHighlightAmount": 0.95,
                    ]
                )
                .applyingFilter(
                    "CIUnsharpMask",
                    parameters: [
                        kCIInputRadiusKey: 1.2,
                        kCIInputIntensityKey: 0.45,
                    ]
                )
        }

        let outputExtent = outputImage.extent.integral
        guard
            !outputExtent.isEmpty,
            !outputExtent.isInfinite,
            let output = CIContext(options: [.cacheIntermediates: false]).createCGImage(
                outputImage,
                from: outputExtent
            )
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        return output
    }

    private static func automaticallyDeskewed(_ image: CIImage) throws -> CIImage {
        let context = CIContext(options: [.cacheIntermediates: false])
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            throw PDFOCRError.couldNotRenderPage
        }

        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.75
        request.minimumSize = 0.5
        request.quadratureTolerance = 20
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up)
        try handler.perform([request])
        guard let rectangle = request.results?.first else {
            return image
        }

        let extent = image.extent
        func vector(_ point: CGPoint) -> CIVector {
            CIVector(
                x: extent.minX + point.x * extent.width,
                y: extent.minY + point.y * extent.height
            )
        }
        return image.applyingFilter(
            "CIPerspectiveCorrection",
            parameters: [
                "inputTopLeft": vector(rectangle.topLeft),
                "inputTopRight": vector(rectangle.topRight),
                "inputBottomLeft": vector(rectangle.bottomLeft),
                "inputBottomRight": vector(rectangle.bottomRight),
            ]
        )
    }
}

@MainActor
enum PDFOCREngine {
    private static let maximumPixelCount: CGFloat = 25_000_000

    static func process(
        document: PDFDocument,
        pageIndexes: IndexSet,
        addsSearchableText: Bool,
        enhancement: PDFScanEnhancementPreset,
        rasterQuality: PDFOCRRasterQuality = .balanced,
        language: PDFOCRLanguage = .automatic,
        minimumConfidence: Float = 0,
        cropMarginsPercent: Double = 0,
        splitDoublePages: Bool = false,
        progress: @escaping @MainActor (PDFOCRProgress) -> Void
    ) async throws -> PDFOCRResult {
        guard !pageIndexes.isEmpty else {
            throw PDFOCRError.noPagesSelected
        }
        guard pageIndexes.allSatisfy({ (0..<document.pageCount).contains($0) }) else {
            throw PDFOCRError.invalidPageSelection
        }
        guard cropMarginsPercent.isFinite,
              (0...20).contains(cropMarginsPercent) else {
            throw PDFOCRError.invalidCropMargins
        }
        guard minimumConfidence.isFinite, (0...1).contains(minimumConfidence) else {
            throw PDFOCRError.recognitionFailed
        }

        let burnedDocument = try annotationBurnedCopy(of: document)
        let output = PDFDocument()
        output.documentAttributes = document.documentAttributes
        var completedPages = 0
        var recognizedLineCount = 0
        var sourcePageIndexes: [Int] = []

        for pageIndex in 0..<document.pageCount {
            try Task.checkCancellation()
            let outputPages: [PDFPage]
            if pageIndexes.contains(pageIndex) {
                guard let page = burnedDocument.page(at: pageIndex) else {
                    throw PDFOCRError.couldNotRenderPage
                }
                let croppedPage = cropMarginsPercent > 0
                    ? try croppedCopy(of: page, marginsPercent: cropMarginsPercent)
                    : page
                let pagesToProcess = splitDoublePages
                    ? try splitIfDoublePage(croppedPage)
                    : [croppedPage]
                var processedPages: [PDFPage] = []
                for renderPage in pagesToProcess {
                    try Task.checkCancellation()
                    let rendered = try render(page: renderPage, rasterDPI: rasterQuality.dpi)
                    let processed = try await processPage(
                        rendered,
                        enhancement: enhancement,
                        recognizesText: addsSearchableText,
                        language: language,
                        minimumConfidence: minimumConfidence
                    )
                    recognizedLineCount += processed.lines.count
                    processedPages.append(
                        try searchablePage(
                            image: processed.image,
                            pageSize: rendered.pageSize,
                            lines: processed.lines
                        )
                    )
                }
                outputPages = processedPages
                completedPages += 1
                progress(
                    PDFOCRProgress(
                        completedPages: completedPages,
                        totalPages: pageIndexes.count
                    )
                )
                await Task.yield()
            } else {
                guard
                    let page = document.page(at: pageIndex),
                    let copiedPage = page.copy() as? PDFPage
                else {
                    throw PDFOCRError.couldNotBuildSearchablePDF
                }
                outputPages = [copiedPage]
            }
            for outputPage in outputPages {
                output.insert(outputPage, at: output.pageCount)
                sourcePageIndexes.append(pageIndex)
            }
        }

        guard
            output.pageCount >= document.pageCount,
            output.pageCount == sourcePageIndexes.count,
            let data = output.dataRepresentation(),
            !data.isEmpty,
            let reopened = PDFDocument(data: data),
            reopened.pageCount == output.pageCount
        else {
            throw PDFOCRError.couldNotBuildSearchablePDF
        }

        return PDFOCRResult(
            document: reopened,
            recognizedLineCount: recognizedLineCount,
            sourcePageIndexes: sourcePageIndexes
        )
    }

    static func preview(
        document: PDFDocument,
        pageIndex: Int,
        enhancement: PDFScanEnhancementPreset,
        cropMarginsPercent: Double = 0
    ) async throws -> PDFScanPreview {
        guard
            (0..<document.pageCount).contains(pageIndex),
            let page = document.page(at: pageIndex)
        else {
            throw PDFOCRError.invalidPageSelection
        }
        guard cropMarginsPercent.isFinite,
              (0...20).contains(cropMarginsPercent) else {
            throw PDFOCRError.invalidCropMargins
        }

        let bounds = page.bounds(for: .cropBox)
        guard
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width > 0,
            bounds.height > 0
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        let maximumDimension: CGFloat = 520
        let scale = min(1, maximumDimension / max(bounds.width, bounds.height))
        let image = page.thumbnail(
            of: CGSize(
                width: max(1, bounds.width * scale),
                height: max(1, bounds.height * scale)
            ),
            for: .cropBox
        )
        var proposedRect = CGRect(origin: .zero, size: image.size)
        guard let original = image.cgImage(
            forProposedRect: &proposedRect,
            context: nil,
            hints: nil
        ) else {
            throw PDFOCRError.couldNotRenderPage
        }

        var processingInput = original
        if cropMarginsPercent > 0 {
            let fraction = CGFloat(cropMarginsPercent / 100)
            let pixelBounds = CGRect(
                x: CGFloat(processingInput.width) * fraction,
                y: CGFloat(processingInput.height) * fraction,
                width: CGFloat(processingInput.width) * (1 - 2 * fraction),
                height: CGFloat(processingInput.height) * (1 - 2 * fraction)
            ).integral
            guard let cropped = processingInput.cropping(to: pixelBounds) else {
                throw PDFOCRError.couldNotRenderPage
            }
            processingInput = cropped
        }

        let sendableOriginal = SendableCGImage(processingInput)
        let processed = try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            return try PDFScanEnhancer.enhancedImage(
                sendableOriginal.image,
                preset: enhancement
            )
        }.value
        return PDFScanPreview(original: original, processed: processed)
    }

    private static func annotationBurnedCopy(of document: PDFDocument) throws -> PDFDocument {
        let options: [PDFDocumentWriteOption: Any] = [
            .burnInAnnotationsOption: true,
        ]
        guard
            let data = document.dataRepresentation(options: options),
            let copy = PDFDocument(data: data),
            copy.pageCount == document.pageCount
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        return copy
    }

    private static func croppedCopy(
        of page: PDFPage,
        marginsPercent: Double
    ) throws -> PDFPage {
        guard let copiedPage = page.copy() as? PDFPage else {
            throw PDFOCRError.couldNotRenderPage
        }
        let cropBounds = copiedPage.bounds(for: .cropBox)
        let insetBounds = cropBounds.insetBy(
            dx: cropBounds.width * CGFloat(marginsPercent / 100),
            dy: cropBounds.height * CGFloat(marginsPercent / 100)
        )
        guard insetBounds.width >= 2, insetBounds.height >= 2 else {
            throw PDFOCRError.invalidCropMargins
        }
        copiedPage.setBounds(insetBounds, for: .cropBox)

        let container = PDFDocument()
        container.insert(copiedPage, at: 0)
        guard
            let data = container.dataRepresentation(),
            let reopened = PDFDocument(data: data),
            let croppedPage = reopened.page(at: 0),
            let independentPage = croppedPage.copy() as? PDFPage
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        return independentPage
    }

    private static func splitIfDoublePage(_ page: PDFPage) throws -> [PDFPage] {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width >= bounds.height * 1.3 else {
            return [page]
        }
        let halfWidth = bounds.width / 2
        return [
            try croppedCopy(
                of: page,
                cropBounds: CGRect(
                    x: bounds.minX,
                    y: bounds.minY,
                    width: halfWidth,
                    height: bounds.height
                )
            ),
            try croppedCopy(
                of: page,
                cropBounds: CGRect(
                    x: bounds.minX + halfWidth,
                    y: bounds.minY,
                    width: bounds.width - halfWidth,
                    height: bounds.height
                )
            ),
        ]
    }

    private static func croppedCopy(
        of page: PDFPage,
        cropBounds: CGRect
    ) throws -> PDFPage {
        guard let copiedPage = page.copy() as? PDFPage else {
            throw PDFOCRError.couldNotRenderPage
        }
        copiedPage.setBounds(cropBounds, for: .cropBox)
        let container = PDFDocument()
        container.insert(copiedPage, at: 0)
        guard
            let data = container.dataRepresentation(),
            let reopened = PDFDocument(data: data),
            let reopenedPage = reopened.page(at: 0),
            let independentPage = reopenedPage.copy() as? PDFPage
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        return independentPage
    }

    private static func render(page: PDFPage, rasterDPI: CGFloat) throws -> RenderedOCRPage {
        guard let pageReference = page.pageRef else {
            throw PDFOCRError.couldNotRenderPage
        }
        let cropBounds = pageReference.getBoxRect(.cropBox)
        let rotation = ((page.rotation % 360) + 360) % 360
        let pageSize = rotation == 90 || rotation == 270
            ? CGSize(width: cropBounds.height, height: cropBounds.width)
            : cropBounds.size
        guard
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 2,
            pageSize.height >= 2
        else {
            throw PDFOCRError.couldNotRenderPage
        }

        let dimensions = try rasterDimensions(pageSize: pageSize, rasterDPI: rasterDPI)
        let safeScale = dimensions.scale
        let width = dimensions.width
        let height = dimensions.height
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            throw PDFOCRError.couldNotRenderPage
        }

        context.scaleBy(x: safeScale, y: safeScale)
        let outputBounds = CGRect(origin: .zero, size: pageSize)
        context.setFillColor(NSColor.white.cgColor)
        context.fill(outputBounds)
        context.concatenate(
            pageReference.getDrawingTransform(
                .cropBox,
                rect: outputBounds,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(pageReference)
        guard let image = context.makeImage() else {
            throw PDFOCRError.couldNotRenderPage
        }
        return RenderedOCRPage(image: image, pageSize: pageSize)
    }

    static func rasterDimensions(
        pageSize: CGSize,
        rasterDPI: CGFloat
    ) throws -> (width: Int, height: Int, scale: CGFloat) {
        guard
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 2,
            pageSize.height >= 2,
            rasterDPI.isFinite,
            rasterDPI > 0
        else {
            throw PDFOCRError.couldNotRenderPage
        }

        let requestedScale = rasterDPI / 72
        let safeScale = min(
            requestedScale,
            sqrt(maximumPixelCount / (pageSize.width * pageSize.height))
        )
        let scaledWidth = ceil(pageSize.width * safeScale)
        let scaledHeight = ceil(pageSize.height * safeScale)
        guard
            safeScale.isFinite,
            safeScale > 0,
            scaledWidth.isFinite,
            scaledHeight.isFinite,
            scaledWidth >= 1,
            scaledHeight >= 1,
            scaledWidth <= CGFloat(Int.max),
            scaledHeight <= CGFloat(Int.max)
        else {
            throw PDFOCRError.couldNotRenderPage
        }
        return (Int(scaledWidth), Int(scaledHeight), safeScale)
    }

    private static func processPage(
        _ rendered: RenderedOCRPage,
        enhancement: PDFScanEnhancementPreset,
        recognizesText: Bool,
        language: PDFOCRLanguage,
        minimumConfidence: Float
    ) async throws -> ProcessedOCRPage {
        let input = SendableCGImage(rendered.image)
        return try await Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let enhanced = try PDFScanEnhancer.enhancedImage(input.image, preset: enhancement)
            let lines = recognizesText
                ? try recognizeText(
                    in: enhanced,
                    language: language,
                    minimumConfidence: minimumConfidence
                )
                : []
            return ProcessedOCRPage(image: enhanced, lines: lines)
        }.value
    }

    private nonisolated static func recognizeText(
        in image: CGImage,
        language: PDFOCRLanguage,
        minimumConfidence: Float
    ) throws -> [PDFRecognizedTextLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = language == .automatic
        if let recognitionLanguage = language.recognitionLanguage {
            request.recognitionLanguages = [recognitionLanguage]
        }
        let handler = VNImageRequestHandler(cgImage: image, orientation: .up)
        do {
            try handler.perform([request])
        } catch {
            throw PDFOCRError.recognitionFailed
        }

        return (request.results ?? [])
            .compactMap { observation -> PDFRecognizedTextLine? in
                guard let candidate = observation.topCandidates(1).first else {
                    return nil
                }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    return nil
                }
                guard candidate.confidence >= minimumConfidence else { return nil }
                return PDFRecognizedTextLine(
                    text: text,
                    boundingBox: observation.boundingBox,
                    confidence: candidate.confidence
                )
            }
            .sorted { left, right in
                if abs(left.boundingBox.maxY - right.boundingBox.maxY) > 0.01 {
                    return left.boundingBox.maxY > right.boundingBox.maxY
                }
                return left.boundingBox.minX < right.boundingBox.minX
            }
    }

    private static func searchablePage(
        image: CGImage,
        pageSize: CGSize,
        lines: [PDFRecognizedTextLine]
    ) throws -> PDFPage {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else {
            throw PDFOCRError.couldNotBuildSearchablePDF
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw PDFOCRError.couldNotBuildSearchablePDF
        }

        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.setTextDrawingMode(.invisible)
        context.setFillColor(NSColor.black.cgColor)

        for recognizedLine in lines {
            let box = CGRect(
                x: recognizedLine.boundingBox.minX * pageSize.width,
                y: recognizedLine.boundingBox.minY * pageSize.height,
                width: recognizedLine.boundingBox.width * pageSize.width,
                height: recognizedLine.boundingBox.height * pageSize.height
            )
            guard box.width > 0.5, box.height > 0.5 else {
                continue
            }
            let fontSize = max(4, box.height * 0.82)
            let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
            let attributed = NSAttributedString(
                string: recognizedLine.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): NSColor.black,
                ]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            let typographicWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            guard typographicWidth > 0 else {
                continue
            }
            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + box.height * 0.08)
            context.scaleBy(x: box.width / typographicWidth, y: 1)
            context.textPosition = .zero
            CTLineDraw(line, context)
            context.restoreGState()
        }

        context.endPDFPage()
        context.closePDF()
        guard
            let document = PDFDocument(data: data as Data),
            let page = document.page(at: 0),
            let copiedPage = page.copy() as? PDFPage
        else {
            throw PDFOCRError.couldNotBuildSearchablePDF
        }
        return copiedPage
    }
}

private struct RenderedOCRPage {
    let image: CGImage
    let pageSize: CGSize
}

private struct ProcessedOCRPage: @unchecked Sendable {
    let image: CGImage
    let lines: [PDFRecognizedTextLine]
}

private struct SendableCGImage: @unchecked Sendable {
    let image: CGImage

    init(_ image: CGImage) {
        self.image = image
    }
}
