import Combine
import Foundation
@preconcurrency import PDFKit

enum PDFDocumentEditorError: LocalizedError, Equatable {
    case invalidPageSelection
    case cannotDeleteOnlyPage
    case invalidInsertionIndex
    case noPagesToInsert
    case couldNotCopyDocument
    case couldNotCopyPage
    case nothingToUndo
    case nothingToRedo
    case invalidAnnotation
    case annotationIsReadOnly
    case couldNotCreateAnnotation

    var errorDescription: String? {
        switch self {
        case .invalidPageSelection:
            "Choose one or more valid pages first."
        case .cannotDeleteOnlyPage:
            "A PDF must contain at least one page."
        case .invalidInsertionIndex:
            "The selected insertion position is no longer valid."
        case .noPagesToInsert:
            "The selected PDF has no pages to add."
        case .couldNotCopyDocument:
            "PDFViewer could not create a safe working copy of this PDF."
        case .couldNotCopyPage:
            "PDFViewer could not copy one of the selected pages."
        case .nothingToUndo:
            "There is no document operation to undo."
        case .nothingToRedo:
            "There is no document operation to redo."
        case .invalidAnnotation:
            "The selected annotation is no longer available."
        case .annotationIsReadOnly:
            "This annotation was not created by PDFViewer and is read-only."
        case .couldNotCreateAnnotation:
            "PDFViewer could not create that annotation safely."
        }
    }
}

@MainActor
final class PDFDocumentEditor: ObservableObject {
    @Published private(set) var document: PDFDocument
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isDirty = false
    @Published private(set) var hasUnexportedChanges = false
    @Published private(set) var pageIDs: [WorkingPageID]

    private var revisions: [DocumentRevision]
    private var snapshotIndex = 0
    private let sourceSnapshot: Data
    private var protectedSnapshots: Set<Data>

    init(
        document sourceDocument: PDFDocument,
        documentFingerprint suppliedFingerprint: String? = nil
    ) throws {
        let normalizedSource = try Self.document(
            from: Self.pages(in: sourceDocument),
            attributes: sourceDocument.documentAttributes
        )
        let sourceData = try Self.dataRepresentation(of: normalizedSource)
        let workingDocument = try Self.document(from: sourceData)
        let documentFingerprint = suppliedFingerprint ?? DocumentFingerprint.sha256(of: sourceData)
        let initialPageIDs = (0..<workingDocument.pageCount).map {
            WorkingPageID.original(
                documentFingerprint: documentFingerprint,
                pageIndex: $0
            )
        }
        self.document = workingDocument
        self.pageIDs = initialPageIDs
        self.revisions = [
            DocumentRevision(pdfData: sourceData, pageIDs: initialPageIDs),
        ]
        self.sourceSnapshot = sourceData
        self.protectedSnapshots = [sourceData]
    }

    var currentRevision: DocumentRevision {
        revisions[snapshotIndex]
    }

    func pageID(at index: Int) -> WorkingPageID? {
        guard pageIDs.indices.contains(index) else {
            return nil
        }
        return pageIDs[index]
    }

    func index(for pageID: WorkingPageID) -> Int? {
        pageIDs.firstIndex(of: pageID)
    }

    func deletePages(at indexes: IndexSet) throws {
        try validate(indexes: indexes, in: document)

        guard indexes.count < document.pageCount else {
            throw PDFDocumentEditorError.cannotDeleteOnlyPage
        }

        let remainingPageIDs = pageIDs.enumerated().compactMap { index, pageID in
            indexes.contains(index) ? nil : pageID
        }
        try mutate(pageIDs: remainingPageIDs) { candidate in
            for index in indexes.reversed() {
                candidate.removePage(at: index)
            }
        }
    }

    func rotatePages(at indexes: IndexSet, clockwise: Bool) throws {
        try validate(indexes: indexes, in: document)

        try mutate { candidate in
            for index in indexes {
                guard let page = candidate.page(at: index) else {
                    throw PDFDocumentEditorError.invalidPageSelection
                }
                page.rotation = normalizedRotation(
                    page.rotation + (clockwise ? 90 : -90)
                )
            }
        }
    }

    func movePages(at indexes: IndexSet, to destination: Int) throws {
        try validate(indexes: indexes, in: document)
        guard (0...document.pageCount).contains(destination) else {
            throw PDFDocumentEditorError.invalidInsertionIndex
        }

        let selectedIndexes = Array(indexes)
        let allPages = try Self.pages(in: document)
        let selectedPages = selectedIndexes.map { allPages[$0] }
        let selectedPageIDs = selectedIndexes.map { pageIDs[$0] }
        let remainingPages = allPages.enumerated().compactMap { index, page in
            indexes.contains(index) ? nil : page
        }
        let remainingPageIDs = pageIDs.enumerated().compactMap { index, pageID in
            indexes.contains(index) ? nil : pageID
        }
        let removedBeforeDestination = selectedIndexes.filter { $0 < destination }.count
        let adjustedDestination = destination - removedBeforeDestination

        guard (0...remainingPages.count).contains(adjustedDestination) else {
            throw PDFDocumentEditorError.invalidInsertionIndex
        }

        let reorderedPages =
            Array(remainingPages.prefix(adjustedDestination)) +
            selectedPages +
            Array(remainingPages.dropFirst(adjustedDestination))
        let reorderedPageIDs =
            Array(remainingPageIDs.prefix(adjustedDestination)) +
            selectedPageIDs +
            Array(remainingPageIDs.dropFirst(adjustedDestination))
        let reorderedDocument = try Self.document(
            from: reorderedPages,
            attributes: document.documentAttributes
        )
        try commit(reorderedDocument, pageIDs: reorderedPageIDs)
    }

    func insertPages(
        from sourceDocument: PDFDocument,
        sourceFingerprint: String? = nil,
        at index: Int
    ) throws {
        guard sourceDocument.pageCount > 0 else {
            throw PDFDocumentEditorError.noPagesToInsert
        }

        try insertPages(
            from: sourceDocument,
            selecting: IndexSet(integersIn: 0..<sourceDocument.pageCount),
            sourceFingerprint: sourceFingerprint,
            at: index
        )
    }

    func insertPages(
        from sourceDocument: PDFDocument,
        selecting indexes: IndexSet,
        sourceFingerprint suppliedSourceFingerprint: String? = nil,
        at index: Int
    ) throws {
        guard sourceDocument.pageCount > 0 else {
            throw PDFDocumentEditorError.noPagesToInsert
        }
        guard (0...document.pageCount).contains(index) else {
            throw PDFDocumentEditorError.invalidInsertionIndex
        }

        try validate(indexes: indexes, in: sourceDocument)
        let sourcePages = try indexes.map { sourceIndex -> PDFPage in
            guard let page = sourceDocument.page(at: sourceIndex) else {
                throw PDFDocumentEditorError.couldNotCopyPage
            }
            return page
        }

        let sourceFingerprint: String
        if let suppliedSourceFingerprint {
            sourceFingerprint = suppliedSourceFingerprint
        } else {
            sourceFingerprint = DocumentFingerprint.sha256(
                of: try Self.dataRepresentation(of: sourceDocument)
            )
        }
        let insertedPageIDs = indexes.map { sourceIndex in
            WorkingPageID(
                documentFingerprint: sourceFingerprint,
                originalPageIndex: sourceIndex,
                occurrenceID: UUID()
            )
        }
        var resultingPageIDs = pageIDs
        resultingPageIDs.insert(contentsOf: insertedPageIDs, at: index)

        try mutate(pageIDs: resultingPageIDs) { candidate in
            for (offset, page) in sourcePages.enumerated() {
                candidate.insert(try Self.copy(page: page), at: index + offset)
            }
        }
    }

    func extractPages(at indexes: IndexSet) throws -> PDFDocument {
        try validate(indexes: indexes, in: document)
        let selectedPages = try indexes.map { index -> PDFPage in
            guard let page = document.page(at: index) else {
                throw PDFDocumentEditorError.invalidPageSelection
            }
            return page
        }
        return try Self.document(
            from: selectedPages,
            attributes: document.documentAttributes
        )
    }

    func addTextMarkup(
        kind: TextMarkupKind,
        regions: [TextMarkupRegion],
        color: AnnotationPaletteColor
    ) throws {
        guard !regions.isEmpty else {
            throw PDFDocumentEditorError.invalidAnnotation
        }

        try mutateAnnotation { candidate in
            for region in regions {
                guard
                    (0..<candidate.pageCount).contains(region.pageIndex),
                    !region.bounds.isEmpty,
                    !region.bounds.isNull,
                    let page = candidate.page(at: region.pageIndex)
                else {
                    throw PDFDocumentEditorError.invalidAnnotation
                }

                let subtype: PDFAnnotationSubtype
                switch kind {
                case .highlight:
                    subtype = .highlight
                case .underline:
                    subtype = .underline
                case .strikethrough:
                    subtype = .strikeOut
                }

                let annotation = PDFAnnotation(
                    bounds: region.bounds,
                    forType: subtype,
                    withProperties: nil
                )
                Self.configureOwnedAnnotation(
                    annotation,
                    color: color.color.withAlphaComponent(kind == .highlight ? 0.35 : 0.9)
                )
                page.addAnnotation(annotation)
            }
        }
    }

    func addInkStroke(
        _ stroke: InkStroke,
        color: AnnotationPaletteColor,
        lineWidth: AnnotationLineWidth
    ) throws {
        guard
            stroke.points.count >= 2,
            (0..<document.pageCount).contains(stroke.pageIndex)
        else {
            throw PDFDocumentEditorError.invalidAnnotation
        }

        try mutateAnnotation { candidate in
            guard let page = candidate.page(at: stroke.pageIndex) else {
                throw PDFDocumentEditorError.invalidAnnotation
            }

            let inset = lineWidth.points / 2 + 1
            let pointBounds = stroke.points.dropFirst().reduce(
                CGRect(origin: stroke.points[0], size: .zero)
            ) { partialResult, point in
                partialResult.union(CGRect(origin: point, size: .zero))
            }
            let annotation = PDFAnnotation(
                bounds: pointBounds.insetBy(dx: -inset, dy: -inset),
                forType: .ink,
                withProperties: nil
            )
            let border = PDFBorder()
            border.lineWidth = lineWidth.points
            annotation.border = border
            Self.configureOwnedAnnotation(annotation, color: color.color)

            let path = NSBezierPath()
            if let firstPoint = stroke.points.first {
                path.move(
                    to: CGPoint(
                        x: firstPoint.x - annotation.bounds.minX,
                        y: firstPoint.y - annotation.bounds.minY
                    )
                )
                for point in stroke.points.dropFirst() {
                    path.line(
                        to: CGPoint(
                            x: point.x - annotation.bounds.minX,
                            y: point.y - annotation.bounds.minY
                        )
                    )
                }
            }
            annotation.add(path)
            page.addAnnotation(annotation)
        }
    }

    @discardableResult
    func addTextNote(
        pageIndex: Int,
        point: CGPoint,
        contents: String,
        color: AnnotationPaletteColor
    ) throws -> AnnotationIdentifier {
        let trimmedContents = String(contents.prefix(10_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !trimmedContents.isEmpty,
            (0..<document.pageCount).contains(pageIndex)
        else {
            throw PDFDocumentEditorError.invalidAnnotation
        }

        let identifier = AnnotationIdentifier()
        try mutateAnnotation { candidate in
            guard let page = candidate.page(at: pageIndex) else {
                throw PDFDocumentEditorError.invalidAnnotation
            }

            let pageBounds = page.bounds(for: .cropBox)
            let size = CGSize(width: 24, height: 24)
            let origin = CGPoint(
                x: min(max(pageBounds.minX, point.x - size.width / 2), pageBounds.maxX - size.width),
                y: min(max(pageBounds.minY, point.y - size.height / 2), pageBounds.maxY - size.height)
            )
            let annotation = PDFAnnotation(
                bounds: CGRect(origin: origin, size: size),
                forType: .text,
                withProperties: nil
            )
            annotation.contents = trimmedContents
            Self.configureOwnedAnnotation(annotation, identifier: identifier, color: color.color)
            page.addAnnotation(annotation)
        }
        return identifier
    }

    func updateAnnotationColor(
        pageIndex: Int,
        identifier: AnnotationIdentifier,
        color: AnnotationPaletteColor
    ) throws {
        try mutateOwnedAnnotation(pageIndex: pageIndex, identifier: identifier) { annotation in
            let alpha: CGFloat = annotation.type == PDFAnnotationSubtype.highlight.pdfTypeName ? 0.35 : 0.9
            annotation.color = color.color.withAlphaComponent(alpha)
            annotation.modificationDate = Date()
        }
    }

    func updateInkLineWidth(
        pageIndex: Int,
        identifier: AnnotationIdentifier,
        lineWidth: AnnotationLineWidth
    ) throws {
        try mutateOwnedAnnotation(pageIndex: pageIndex, identifier: identifier) { annotation in
            guard annotation.type == PDFAnnotationSubtype.ink.pdfTypeName else {
                throw PDFDocumentEditorError.invalidAnnotation
            }
            let border = annotation.border ?? PDFBorder()
            border.lineWidth = lineWidth.points
            annotation.border = border
            annotation.modificationDate = Date()
        }
    }

    func updateTextNote(
        pageIndex: Int,
        identifier: AnnotationIdentifier,
        contents: String
    ) throws {
        let trimmedContents = String(contents.prefix(10_000)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedContents.isEmpty else {
            throw PDFDocumentEditorError.invalidAnnotation
        }

        try mutateOwnedAnnotation(pageIndex: pageIndex, identifier: identifier) { annotation in
            guard annotation.type == PDFAnnotationSubtype.text.pdfTypeName else {
                throw PDFDocumentEditorError.invalidAnnotation
            }
            annotation.contents = trimmedContents
            annotation.modificationDate = Date()
        }
    }

    func deleteAnnotation(
        pageIndex: Int,
        identifier: AnnotationIdentifier
    ) throws {
        try mutateAnnotation { candidate in
            guard
                let page = candidate.page(at: pageIndex),
                let annotation = Self.ownedAnnotation(
                    on: page,
                    identifier: identifier
                )
            else {
                throw PDFDocumentEditorError.invalidAnnotation
            }
            page.removeAnnotation(annotation)
        }
    }

    func textNoteContents(
        pageIndex: Int,
        identifier: AnnotationIdentifier
    ) -> String? {
        guard
            let page = document.page(at: pageIndex),
            let annotation = Self.ownedAnnotation(on: page, identifier: identifier),
            annotation.type == PDFAnnotationSubtype.text.pdfTypeName
        else {
            return nil
        }
        return annotation.contents
    }

    func undo() throws {
        guard canUndo else {
            throw PDFDocumentEditorError.nothingToUndo
        }

        snapshotIndex -= 1
        let revision = revisions[snapshotIndex]
        document = try Self.document(from: revision.pdfData)
        pageIDs = revision.pageIDs
        refreshHistoryState()
    }

    func redo() throws {
        guard canRedo else {
            throw PDFDocumentEditorError.nothingToRedo
        }

        snapshotIndex += 1
        let revision = revisions[snapshotIndex]
        document = try Self.document(from: revision.pdfData)
        pageIDs = revision.pageIDs
        refreshHistoryState()
    }

    func markCurrentRevisionExported() {
        protectedSnapshots.insert(revisions[snapshotIndex].pdfData)
        refreshHistoryState()
    }

    private func mutate(
        pageIDs updatedPageIDs: [WorkingPageID]? = nil,
        _ body: (PDFDocument) throws -> Void
    ) throws {
        let candidate = try Self.document(from: Self.dataRepresentation(of: document))
        try body(candidate)
        try commit(candidate, pageIDs: updatedPageIDs ?? pageIDs)
    }

    private func mutateOwnedAnnotation(
        pageIndex: Int,
        identifier: AnnotationIdentifier,
        _ body: (PDFAnnotation) throws -> Void
    ) throws {
        try mutateAnnotation { candidate in
            guard
                let page = candidate.page(at: pageIndex),
                let annotation = Self.ownedAnnotation(on: page, identifier: identifier)
            else {
                throw PDFDocumentEditorError.invalidAnnotation
            }
            try body(annotation)
        }
    }

    /// Annotation changes can be applied directly to the PDFKit document that
    /// is already attached to PDFView. We still serialize the completed state
    /// for the protected-revision and undo model, but avoiding a document clone
    /// and object swap prevents PDFKit from rebuilding every visible page.
    private func mutateAnnotation(
        _ body: (PDFDocument) throws -> Void
    ) throws {
        let previousRevision = revisions[snapshotIndex]
        do {
            try body(document)
            try commitAnnotationMutation()
        } catch {
            // A mutation body can fail after touching more than one annotation.
            // Restore the last valid revision so partial work never leaks into
            // the reader or export state.
            document = try Self.document(from: previousRevision.pdfData)
            pageIDs = previousRevision.pageIDs
            refreshHistoryState()
            throw error
        }
    }

    private func commitAnnotationMutation() throws {
        let snapshot = try Self.dataRepresentation(of: document)
        revisions = Array(revisions.prefix(snapshotIndex + 1))
        revisions.append(
            DocumentRevision(pdfData: snapshot, pageIDs: pageIDs)
        )
        snapshotIndex += 1
        refreshHistoryState()
    }

    private static func configureOwnedAnnotation(
        _ annotation: PDFAnnotation,
        identifier: AnnotationIdentifier = AnnotationIdentifier(),
        color: NSColor
    ) {
        annotation.color = color
        annotation.userName = "PDFViewer"
        annotation.modificationDate = Date()
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        _ = annotation.setValue(identifier.pdfName, forAnnotationKey: .name)
        _ = annotation.setValue(
            identifier.pdfName,
            forAnnotationKey: AnnotationIdentifier.storageKey
        )
    }

    private static func ownedAnnotation(
        on page: PDFPage,
        identifier: AnnotationIdentifier
    ) -> PDFAnnotation? {
        page.annotations.first { annotation in
            guard let annotationIdentifier = AnnotationIdentifier(annotation: annotation) else {
                return false
            }
            return annotationIdentifier == identifier
        }
    }

    private func commit(
        _ candidate: PDFDocument,
        pageIDs candidatePageIDs: [WorkingPageID]
    ) throws {
        guard candidate.pageCount == candidatePageIDs.count else {
            throw PDFDocumentEditorError.couldNotCopyDocument
        }
        let snapshot = try Self.dataRepresentation(of: candidate)
        revisions = Array(revisions.prefix(snapshotIndex + 1))
        revisions.append(
            DocumentRevision(pdfData: snapshot, pageIDs: candidatePageIDs)
        )
        snapshotIndex += 1
        document = candidate
        pageIDs = candidatePageIDs
        refreshHistoryState()
    }

    private func validate(indexes: IndexSet, in document: PDFDocument) throws {
        guard
            !indexes.isEmpty,
            indexes.allSatisfy({ (0..<document.pageCount).contains($0) })
        else {
            throw PDFDocumentEditorError.invalidPageSelection
        }
    }

    private func refreshHistoryState() {
        let nextCanUndo = snapshotIndex > 0
        let nextCanRedo = snapshotIndex < revisions.count - 1
        let currentSnapshot = revisions[snapshotIndex].pdfData
        let nextIsDirty = currentSnapshot != sourceSnapshot
        let nextHasUnexportedChanges = !protectedSnapshots.contains(currentSnapshot)

        if canUndo != nextCanUndo {
            canUndo = nextCanUndo
        }
        if canRedo != nextCanRedo {
            canRedo = nextCanRedo
        }
        if isDirty != nextIsDirty {
            isDirty = nextIsDirty
        }
        if hasUnexportedChanges != nextHasUnexportedChanges {
            hasUnexportedChanges = nextHasUnexportedChanges
        }
    }

    private static func pages(in document: PDFDocument) throws -> [PDFPage] {
        try (0..<document.pageCount).map { index in
            guard let page = document.page(at: index) else {
                throw PDFDocumentEditorError.couldNotCopyPage
            }
            return page
        }
    }

    private static func document(
        from pages: [PDFPage],
        attributes: [AnyHashable: Any]? = nil
    ) throws -> PDFDocument {
        let document = PDFDocument()
        document.documentAttributes = attributes

        for (index, page) in pages.enumerated() {
            document.insert(try copy(page: page), at: index)
        }
        return document
    }

    private static func copy(page: PDFPage) throws -> PDFPage {
        guard let copiedPage = page.copy() as? PDFPage else {
            throw PDFDocumentEditorError.couldNotCopyPage
        }
        return copiedPage
    }

    private static func dataRepresentation(of document: PDFDocument) throws -> Data {
        guard let data = document.dataRepresentation(), !data.isEmpty else {
            throw PDFDocumentEditorError.couldNotCopyDocument
        }
        return data
    }

    private static func document(from data: Data) throws -> PDFDocument {
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw PDFDocumentEditorError.couldNotCopyDocument
        }
        return document
    }

    private func normalizedRotation(_ rotation: Int) -> Int {
        let normalized = rotation % 360
        return normalized >= 0 ? normalized : normalized + 360
    }
}
