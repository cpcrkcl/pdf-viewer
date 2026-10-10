import AppKit
import Combine
import Foundation
import ImageIO
@preconcurrency import PDFKit
import UniformTypeIdentifiers

enum SignatureSizePreset: String, CaseIterable, Identifiable, Codable {
    case small
    case medium
    case large

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    var width: CGFloat {
        switch self {
        case .small:
            96
        case .medium:
            144
        case .large:
            216
        }
    }
}

struct StoredSignature: Codable, Identifiable, Equatable {
    let id: UUID
    var displayName: String
    let fileName: String
    let aspectRatio: Double
    let createdAt: Date
}

enum SignatureLibraryError: LocalizedError, Equatable {
    case invalidImage
    case emptyDrawing
    case missingSignature
    case couldNotCreateStorage
    case couldNotWriteImage
    case couldNotWriteIndex
    case imageTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidImage:
            "Choose a valid PNG or JPEG image."
        case .emptyDrawing:
            "Draw a signature before adding it."
        case .missingSignature:
            "That saved signature is no longer available."
        case .couldNotCreateStorage:
            "PDFViewer could not create its local signature library."
        case .couldNotWriteImage:
            "PDFViewer could not save that signature image locally."
        case .couldNotWriteIndex:
            "PDFViewer could not update its local signature library."
        case .imageTooLarge:
            "Choose a signature image smaller than 25 megapixels and 25 MB."
        }
    }
}

/// Local-only library for visual signature images. Files never leave
/// Application Support unless the user places a signature into an exported
/// PDF; no passwords, document data, or signature pixels are logged.
@MainActor
final class SignatureLibrary: ObservableObject {
    nonisolated static let maximumImageBytes = 25 * 1_024 * 1_024
    nonisolated static let maximumImagePixels = 25_000_000

    @Published private(set) var signatures: [StoredSignature] = []

    private let fileManager: FileManager
    private let storageDirectory: URL
    private let indexURL: URL

    init(
        storageDirectory: URL? = nil,
        libraryFolder: String = "Signatures",
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        let directory = storageDirectory ?? fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFViewer", isDirectory: true)
            .appendingPathComponent(libraryFolder, isDirectory: true)
        self.storageDirectory = directory
        self.indexURL = directory.appendingPathComponent("signatures.v1.json")
        loadIndex()
    }

    @discardableResult
    func importImage(
        data: Data,
        displayName: String
    ) throws -> StoredSignature {
        let imageProperties = Self.validatedImageProperties(for: data)
        if
            data.count > Self.maximumImageBytes ||
            (imageProperties?.pixelCount ?? 0) > Self.maximumImagePixels
        {
            throw SignatureLibraryError.imageTooLarge
        }
        guard
            let imageProperties,
            let image = NSImage(data: data),
            image.size.width > 0,
            image.size.height > 0
        else {
            throw SignatureLibraryError.invalidImage
        }

        try ensureStorageDirectory()
        let id = UUID()
        let fileExtension = imageProperties.fileExtension
        let fileName = "\(id.uuidString.lowercased()).\(fileExtension)"
        let imageURL = storageDirectory.appendingPathComponent(fileName)
        do {
            try data.write(to: imageURL, options: .atomic)
        } catch {
            throw SignatureLibraryError.couldNotWriteImage
        }

        let stored = StoredSignature(
            id: id,
            displayName: sanitizedName(displayName),
            fileName: fileName,
            aspectRatio: image.size.width / image.size.height,
            createdAt: Date()
        )
        signatures.append(stored)
        do {
            try persistIndex()
        } catch {
            signatures.removeAll { $0.id == id }
            try? fileManager.removeItem(at: imageURL)
            throw error
        }
        return stored
    }

    @discardableResult
    func createFromDrawing(
        strokes: [InkStroke],
        canvasSize: CGSize,
        displayName: String
    ) throws -> StoredSignature {
        let drawableStrokes = strokes.filter { $0.points.count >= 2 }
        guard
            !drawableStrokes.isEmpty,
            drawableStrokes.allSatisfy({ stroke in
                stroke.points.allSatisfy { $0.x.isFinite && $0.y.isFinite }
            }),
            canvasSize.width.isFinite,
            canvasSize.height.isFinite,
            canvasSize.width > 0,
            canvasSize.height > 0,
            canvasSize.width * canvasSize.height <= CGFloat(Self.maximumImagePixels)
        else {
            throw SignatureLibraryError.emptyDrawing
        }

        let image = NSImage(size: canvasSize)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: canvasSize).fill(using: .copy)
        NSColor.black.setStroke()
        for stroke in drawableStrokes {
            let path = NSBezierPath()
            path.lineWidth = 3
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            guard let first = stroke.points.first else {
                continue
            }
            path.move(to: first)
            for point in stroke.points.dropFirst() {
                path.line(to: point)
            }
            path.stroke()
        }
        image.unlockFocus()

        guard
            let tiff = image.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiff),
            let data = bitmap.representation(using: .png, properties: [:])
        else {
            throw SignatureLibraryError.couldNotWriteImage
        }
        return try importImage(data: data, displayName: displayName)
    }

    func imageData(for id: UUID) throws -> Data {
        guard let signature = signatures.first(where: { $0.id == id }) else {
            throw SignatureLibraryError.missingSignature
        }
        do {
            let data = try Data(contentsOf: storageDirectory.appendingPathComponent(signature.fileName))
            guard
                data.count <= Self.maximumImageBytes,
                let properties = Self.validatedImageProperties(for: data),
                properties.pixelCount <= Self.maximumImagePixels
            else {
                throw SignatureLibraryError.missingSignature
            }
            return data
        } catch {
            throw SignatureLibraryError.missingSignature
        }
    }

    func delete(_ id: UUID) throws {
        guard let index = signatures.firstIndex(where: { $0.id == id }) else {
            throw SignatureLibraryError.missingSignature
        }
        let removed = signatures.remove(at: index)
        do {
            try persistIndex()
        } catch {
            signatures.insert(removed, at: index)
            throw error
        }
        try? fileManager.removeItem(
            at: storageDirectory.appendingPathComponent(removed.fileName)
        )
    }

    private func loadIndex() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([StoredSignature].self, from: data)
        else {
            signatures = []
            return
        }
        var seenIDs: Set<UUID> = []
        signatures = decoded
            .filter { signature in
                guard
                    isSafeStoredFilename(signature.fileName, for: signature.id),
                    signature.aspectRatio.isFinite,
                    signature.aspectRatio > 0
                else {
                    return false
                }
                let imageURL = storageDirectory.appendingPathComponent(signature.fileName)
                guard
                    let data = try? Data(contentsOf: imageURL),
                    data.count <= Self.maximumImageBytes,
                    let properties = Self.validatedImageProperties(for: data),
                    properties.pixelCount <= Self.maximumImagePixels
                else {
                    return false
                }
                return seenIDs.insert(signature.id).inserted
            }
            .map { signature in
                StoredSignature(
                    id: signature.id,
                    displayName: sanitizedName(signature.displayName),
                    fileName: signature.fileName,
                    aspectRatio: signature.aspectRatio,
                    createdAt: signature.createdAt
                )
            }
            .sorted { $0.createdAt < $1.createdAt }
    }

    private func ensureStorageDirectory() throws {
        do {
            try fileManager.createDirectory(
                at: storageDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            throw SignatureLibraryError.couldNotCreateStorage
        }
    }

    private func persistIndex() throws {
        try ensureStorageDirectory()
        do {
            let data = try JSONEncoder().encode(signatures)
            try data.write(to: indexURL, options: .atomic)
        } catch let error as SignatureLibraryError {
            throw error
        } catch {
            throw SignatureLibraryError.couldNotWriteIndex
        }
    }

    private func sanitizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Visual Signature" : trimmed).prefix(80))
    }

    nonisolated fileprivate static func validatedImageProperties(
        for data: Data
    ) -> (fileExtension: String, pixelCount: Int)? {
        guard
            let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let typeIdentifier = CGImageSourceGetType(source) as String?,
            typeIdentifier == UTType.png.identifier || typeIdentifier == UTType.jpeg.identifier,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
            let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
            width.doubleValue.isFinite,
            height.doubleValue.isFinite,
            width.doubleValue > 0,
            height.doubleValue > 0
        else {
            return nil
        }
        let pixelCount = width.doubleValue * height.doubleValue
        guard pixelCount.isFinite, pixelCount <= Double(Int.max) else {
            return nil
        }
        return (
            typeIdentifier == UTType.jpeg.identifier ? "jpg" : "png",
            Int(pixelCount)
        )
    }

    private func isSafeStoredFilename(_ fileName: String, for id: UUID) -> Bool {
        guard
            (fileName as NSString).lastPathComponent == fileName,
            !fileName.contains("/"),
            !fileName.contains("\\"),
            !fileName.contains(":"),
            let fileID = UUID(
                uuidString: (fileName as NSString).deletingPathExtension
            ),
            fileID == id
        else {
            return false
        }
        let fileExtension = (fileName as NSString).pathExtension.lowercased()
        return fileExtension == "png" || fileExtension == "jpg" || fileExtension == "jpeg"
    }
}

/// Custom stamp annotation whose generated PDF appearance stream contains the
/// visual signature. The original image is also stored under a private key so
/// PDFViewer can resize the annotation after export and reopen.
final class VisualSignatureAnnotation: PDFAnnotation {
    static let imageDataKey = PDFAnnotationKey(rawValue: "/PDFViewerSignatureData")
    static let aspectRatioKey = PDFAnnotationKey(rawValue: "/PDFViewerSignatureAspectRatio")
    static let rotationKey = PDFAnnotationKey(rawValue: "/PDFViewerSignatureRotation")
    static let customStampKey = PDFAnnotationKey(rawValue: "/PDFViewerCustomStamp")

    private let signatureImage: NSImage
    private let rotationQuarterTurns: Int

    init(
        bounds: CGRect,
        imageData: Data,
        rotationQuarterTurns: Int = 0,
        isCustomStamp: Bool = false
    ) throws {
        guard
            bounds.origin.x.isFinite,
            bounds.origin.y.isFinite,
            bounds.width.isFinite,
            bounds.height.isFinite,
            bounds.width > 0,
            bounds.height > 0,
            imageData.count <= SignatureLibrary.maximumImageBytes,
            let properties = SignatureLibrary.validatedImageProperties(for: imageData),
            properties.pixelCount <= SignatureLibrary.maximumImagePixels,
            let image = NSImage(data: imageData)
        else {
            throw SignatureLibraryError.invalidImage
        }
        self.signatureImage = image
        self.rotationQuarterTurns = Self.normalizedRotation(rotationQuarterTurns)
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
        _ = setValue(imageData.base64EncodedString(), forAnnotationKey: Self.imageDataKey)
        _ = setValue(
            NSNumber(value: image.size.width / image.size.height),
            forAnnotationKey: Self.aspectRatioKey
        )
        _ = setValue(NSNumber(value: self.rotationQuarterTurns), forAnnotationKey: Self.rotationKey)
        if isCustomStamp {
            _ = setValue(NSNumber(value: true), forAnnotationKey: Self.customStampKey)
        }
    }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let image = signatureImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return
        }
        context.saveGState()
        context.interpolationQuality = .high
        context.translateBy(x: bounds.midX, y: bounds.midY)
        context.rotate(by: CGFloat(rotationQuarterTurns) * .pi / 2)
        let imageBounds: CGRect
        if rotationQuarterTurns.isMultiple(of: 2) {
            imageBounds = CGRect(
                x: -bounds.width / 2,
                y: -bounds.height / 2,
                width: bounds.width,
                height: bounds.height
            )
        } else {
            imageBounds = CGRect(
                x: -bounds.height / 2,
                y: -bounds.width / 2,
                width: bounds.height,
                height: bounds.width
            )
        }
        context.draw(image, in: imageBounds)
        context.restoreGState()
    }

    static func imageData(from annotation: PDFAnnotation) -> Data? {
        guard
            let encoded = annotation.value(forAnnotationKey: imageDataKey) as? String,
            encoded.utf8.count <= ((SignatureLibrary.maximumImageBytes + 2) / 3) * 4,
            let data = Data(base64Encoded: encoded),
            data.count <= SignatureLibrary.maximumImageBytes,
            let properties = SignatureLibrary.validatedImageProperties(for: data),
            properties.pixelCount <= SignatureLibrary.maximumImagePixels,
            NSImage(data: data) != nil
        else {
            return nil
        }
        return data
    }

    static func isCustomStamp(_ annotation: PDFAnnotation) -> Bool {
        (annotation.value(forAnnotationKey: customStampKey) as? NSNumber)?.boolValue == true
    }

    static func aspectRatio(from annotation: PDFAnnotation) -> CGFloat? {
        if let value = annotation.value(forAnnotationKey: aspectRatioKey) as? NSNumber,
           value.doubleValue.isFinite,
           value.doubleValue > 0 {
            return value.doubleValue
        }
        guard
            let data = imageData(from: annotation),
            let image = NSImage(data: data),
            image.size.height > 0
        else {
            return nil
        }
        return image.size.width / image.size.height
    }

    static func rotationQuarterTurns(from annotation: PDFAnnotation) -> Int {
        let stored = (annotation.value(forAnnotationKey: rotationKey) as? NSNumber)?.intValue ?? 0
        return normalizedRotation(stored)
    }

    private static func normalizedRotation(_ quarterTurns: Int) -> Int {
        ((quarterTurns % 4) + 4) % 4
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }
}
