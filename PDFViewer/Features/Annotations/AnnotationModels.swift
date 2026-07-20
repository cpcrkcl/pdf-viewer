import AppKit
import Combine
import Foundation
@preconcurrency import PDFKit

extension PDFAnnotationSubtype {
    var pdfTypeName: String {
        rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case select
    case highlight
    case underline
    case strikethrough
    case freehand
    case textNote
    case rectangle
    case oval
    case line
    case arrow
    case stamp
    case signature

    var id: Self { self }

    var title: String {
        switch self {
        case .select:
            "Select"
        case .highlight:
            "Highlight"
        case .underline:
            "Underline"
        case .strikethrough:
            "Strikethrough"
        case .freehand:
            "Freehand"
        case .textNote:
            "Text Note"
        case .rectangle:
            "Rectangle"
        case .oval:
            "Oval"
        case .line:
            "Line"
        case .arrow:
            "Arrow"
        case .stamp:
            "Stamp"
        case .signature:
            "Visual Signature"
        }
    }

    var systemImage: String {
        switch self {
        case .select:
            "cursorarrow"
        case .highlight:
            "highlighter"
        case .underline:
            "underline"
        case .strikethrough:
            "strikethrough"
        case .freehand:
            "pencil.tip"
        case .textNote:
            "note.text.badge.plus"
        case .rectangle:
            "rectangle"
        case .oval:
            "circle"
        case .line:
            "line.diagonal"
        case .arrow:
            "arrow.up.right"
        case .stamp:
            "seal"
        case .signature:
            "signature"
        }
    }

    var requiresTextSelection: Bool {
        switch self {
        case .highlight, .underline, .strikethrough:
            true
        case .select, .freehand, .textNote, .rectangle, .oval, .line, .arrow, .stamp, .signature:
            false
        }
    }

    var shapeKind: ShapeAnnotationKind? {
        switch self {
        case .rectangle:
            .rectangle
        case .oval:
            .oval
        case .line:
            .line
        case .arrow:
            .arrow
        default:
            nil
        }
    }
}

enum ShapeAnnotationKind: String, CaseIterable, Identifiable {
    case rectangle
    case oval
    case line
    case arrow

    var id: Self { self }
}

enum StampPreset: String, CaseIterable, Identifiable {
    case approved
    case draft
    case confidential
    case final
    case topSecret

    var id: Self { self }

    var title: String {
        switch self {
        case .approved:
            "Approved"
        case .draft:
            "Draft"
        case .confidential:
            "Confidential"
        case .final:
            "Final"
        case .topSecret:
            "Top Secret"
        }
    }

    var pdfName: String {
        switch self {
        case .topSecret:
            "TopSecret"
        default:
            title
        }
    }
}

enum AnnotationPaletteColor: String, CaseIterable, Identifiable {
    case yellow
    case green
    case blue
    case pink
    case red
    case black

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    var color: NSColor {
        switch self {
        case .yellow:
            .systemYellow
        case .green:
            .systemGreen
        case .blue:
            .systemBlue
        case .pink:
            .systemPink
        case .red:
            .systemRed
        case .black:
            .black
        }
    }
}

enum AnnotationLineWidth: String, CaseIterable, Identifiable {
    case fine
    case standard
    case bold

    var id: Self { self }

    var title: String {
        rawValue.capitalized
    }

    var points: CGFloat {
        switch self {
        case .fine:
            1.5
        case .standard:
            3
        case .bold:
            5
        }
    }
}

enum TextMarkupKind: Equatable {
    case highlight
    case underline
    case strikethrough
}

struct AnnotationIdentifier: Hashable, Codable {
    static let prefix = "pdfviewer:"
    static let storageKey = PDFAnnotationKey(rawValue: "/PDFViewerID")

    let rawValue: UUID

    var pdfName: String {
        Self.prefix + rawValue.uuidString.lowercased()
    }

    init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    init?(pdfName: String) {
        guard
            pdfName.hasPrefix(Self.prefix),
            let identifier = UUID(uuidString: String(pdfName.dropFirst(Self.prefix.count)))
        else {
            return nil
        }
        self.rawValue = identifier
    }

    init?(annotation: PDFAnnotation) {
        let storedName = (annotation.value(forAnnotationKey: .name) as? String) ??
            (annotation.value(forAnnotationKey: Self.storageKey) as? String)
        guard let storedName, let identifier = AnnotationIdentifier(pdfName: storedName) else {
            return nil
        }
        self = identifier
    }
}

struct SelectedAnnotation: Equatable {
    let pageIndex: Int
    let identifier: AnnotationIdentifier?
    let kind: AnnotationTool?

    var isOwnedByPDFViewer: Bool {
        identifier != nil
    }

    var supportsControlledResize: Bool {
        guard isOwnedByPDFViewer else {
            return false
        }
        return switch kind {
        case .rectangle, .oval, .line, .arrow, .stamp:
            true
        default:
            false
        }
    }
}

struct TextMarkupRegion: Equatable {
    let pageIndex: Int
    let bounds: CGRect
}

struct InkStroke: Equatable {
    let pageIndex: Int
    let points: [CGPoint]
}

struct AnnotationPlacement: Equatable {
    let pageIndex: Int
    let point: CGPoint
}

struct ShapeAnnotationPlacement: Equatable {
    let pageIndex: Int
    let startPoint: CGPoint
    let endPoint: CGPoint

    var bounds: CGRect {
        CGRect(
            x: min(startPoint.x, endPoint.x),
            y: min(startPoint.y, endPoint.y),
            width: abs(endPoint.x - startPoint.x),
            height: abs(endPoint.y - startPoint.y)
        )
    }
}

struct PendingTextNote: Identifiable, Equatable {
    let id = UUID()
    let pageIndex: Int
    let point: CGPoint?
    let annotationIdentifier: AnnotationIdentifier?
    let initialText: String

    var isEditingExistingNote: Bool {
        annotationIdentifier != nil
    }
}

@MainActor
final class AnnotationState: ObservableObject {
    @Published var isActive = false
    @Published var selectedTool: AnnotationTool = .select
    @Published var selectedColor: AnnotationPaletteColor = .black
    @Published var selectedLineWidth: AnnotationLineWidth = .standard
    @Published var selectedStamp: StampPreset = .approved
    @Published var selectedSignatureSize: SignatureSizePreset = .medium
    @Published var selectedSignatureID: UUID?
    @Published private(set) var textMarkupRegions: [TextMarkupRegion] = []
    @Published private(set) var selectedAnnotation: SelectedAnnotation?
    @Published private(set) var clearSelectionRevision = 0

    var hasTextSelection: Bool {
        !textMarkupRegions.isEmpty
    }

    func begin() {
        isActive = true
        selectedTool = .select
    }

    func end() {
        isActive = false
        selectedTool = .select
        clearTransientSelection()
    }

    func reset() {
        isActive = false
        selectedTool = .select
        selectedColor = .black
        selectedLineWidth = .standard
        selectedStamp = .approved
        selectedSignatureSize = .medium
        selectedSignatureID = nil
        clearTransientSelection()
    }

    func updateTextMarkupRegions(_ regions: [TextMarkupRegion]) {
        textMarkupRegions = regions
    }

    func selectAnnotation(_ selection: SelectedAnnotation?) {
        selectedAnnotation = selection
    }

    func clearTransientSelection() {
        textMarkupRegions = []
        selectedAnnotation = nil
        clearSelectionRevision += 1
    }
}
