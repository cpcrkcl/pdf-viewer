import Foundation
@preconcurrency import PDFKit

enum PDFExportError: LocalizedError, Equatable {
    case emptyDocument
    case invalidDestination
    case sourceAndDestinationMatch
    case couldNotWriteTemporaryFile
    case couldNotValidateTemporaryFile
    case couldNotFinalizeExport
    case couldNotReopenExport
    case missingSessionPassword
    case encryptedOutputRequired

    var errorDescription: String? {
        switch self {
        case .emptyDocument:
            "The working copy has no pages to export."
        case .invalidDestination:
            "Choose a destination ending in .pdf."
        case .sourceAndDestinationMatch:
            "Choose a new output location. PDFViewer never replaces the original PDF."
        case .couldNotWriteTemporaryFile:
            "PDFViewer could not write a temporary export file."
        case .couldNotValidateTemporaryFile:
            "PDFViewer could not validate the temporary export file."
        case .couldNotFinalizeExport:
            "PDFViewer could not finish placing the exported PDF at the chosen location."
        case .couldNotReopenExport:
            "PDFViewer could not reopen the completed export for verification."
        case .missingSessionPassword:
            "The active encrypted document no longer has an in-memory session password. Reopen it and try again."
        case .encryptedOutputRequired:
            "PDFViewer refused to create an unencrypted copy of this protected PDF."
        }
    }
}

enum PDFOutputProtection: Equatable {
    case none
    case reuseSessionPassword
}

/// Output-size profiles applied while writing the export. Compression never
/// changes page count, order, rotations, searchable text, or annotations;
/// only embedded image encoding may change.
enum PDFExportCompression: String, CaseIterable, Identifiable {
    case standard
    case reducedSize
    case compact

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            "Standard"
        case .reducedSize:
            "Reduced Size"
        case .compact:
            "Compact"
        }
    }

    var summary: String {
        switch self {
        case .standard:
            "Keeps the original image quality."
        case .reducedSize:
            "Re-encodes embedded images as JPEG."
        case .compact:
            "Re-encodes images as JPEG and downsamples oversized images for screen reading."
        }
    }

    var writeOptions: [PDFDocumentWriteOption: Any] {
        switch self {
        case .standard:
            [:]
        case .reducedSize:
            [.saveImagesAsJPEGOption: true]
        case .compact:
            [
                .saveImagesAsJPEGOption: true,
                .optimizeImagesForScreenOption: true,
            ]
        }
    }
}

struct PDFExportResult: Equatable {
    let url: URL
    let pageCount: Int
    let fileSizeInBytes: Int

    init(url: URL, pageCount: Int, fileSizeInBytes: Int = 0) {
        self.url = url
        self.pageCount = pageCount
        self.fileSizeInBytes = fileSizeInBytes
    }
}

@MainActor
protocol PDFExporting {
    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL
    ) throws -> PDFExportResult

    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL,
        protection: PDFOutputProtection,
        sessionPassword: String?,
        accessPermissions: PDFAccessPermissions,
        compression: PDFExportCompression
    ) throws -> PDFExportResult
}

extension PDFExporting {
    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL,
        protection: PDFOutputProtection,
        sessionPassword: String?,
        accessPermissions: PDFAccessPermissions,
        compression: PDFExportCompression
    ) throws -> PDFExportResult {
        guard protection == .none else {
            throw PDFExportError.encryptedOutputRequired
        }
        return try export(document: document, sourceURL: sourceURL, to: destinationURL)
    }
}

@MainActor
struct PDFExporter: PDFExporting {
    private let fileManager: FileManager
    private let stagingDirectory: URL

    init(
        fileManager: FileManager = .default,
        stagingDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.stagingDirectory = stagingDirectory ?? fileManager.temporaryDirectory
    }

    /// Stages and validates the PDF in app-owned storage, then coordinates one
    /// atomic write to the exact destination approved by the save panel.
    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL
    ) throws -> PDFExportResult {
        try export(
            document: document,
            sourceURL: sourceURL,
            to: destinationURL,
            protection: .none,
            sessionPassword: nil,
            accessPermissions: document.accessPermissions,
            compression: .standard
        )
    }

    func export(
        document: PDFDocument,
        sourceURL: URL,
        to destinationURL: URL,
        protection: PDFOutputProtection,
        sessionPassword: String?,
        accessPermissions: PDFAccessPermissions,
        compression: PDFExportCompression
    ) throws -> PDFExportResult {
        guard document.pageCount > 0 else {
            throw PDFExportError.emptyDocument
        }

        let destinationURL = destinationURL.standardizedFileURL
        guard
            destinationURL.isFileURL,
            destinationURL.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        else {
            throw PDFExportError.invalidDestination
        }

        let resolvedSourceURL = sourceURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let resolvedDestinationURL = destinationURL
            .resolvingSymlinksInPath()
            .standardizedFileURL
        guard resolvedSourceURL.path != resolvedDestinationURL.path else {
            throw PDFExportError.sourceAndDestinationMatch
        }
        let hasScopedAccess = destinationURL.startAccessingSecurityScopedResource()
        defer {
            if hasScopedAccess {
                destinationURL.stopAccessingSecurityScopedResource()
            }
        }
        if resourcesReferToSameFile(resolvedSourceURL, resolvedDestinationURL) {
            throw PDFExportError.sourceAndDestinationMatch
        }

        var isStagingDirectory: ObjCBool = false
        guard
            fileManager.fileExists(
                atPath: stagingDirectory.path,
                isDirectory: &isStagingDirectory
            ),
            isStagingDirectory.boolValue
        else {
            throw PDFExportError.couldNotWriteTemporaryFile
        }

        let temporaryURL = stagingDirectory.appendingPathComponent(
            ".pdfviewer-export-\(UUID().uuidString).pdf"
        )
        defer {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let expectedSnapshot = validationSnapshot(of: document)
        var writeOptions = compression.writeOptions
        switch protection {
        case .none:
            break
        case .reuseSessionPassword:
            guard let sessionPassword else {
                throw PDFExportError.missingSessionPassword
            }
            writeOptions[.ownerPasswordOption] = sessionPassword
            writeOptions[.userPasswordOption] = sessionPassword
            writeOptions[.accessPermissionsOption] = NSNumber(value: accessPermissions.rawValue)
        }
        let didWrite = document.write(to: temporaryURL, withOptions: writeOptions)

        guard didWrite else {
            throw PDFExportError.couldNotWriteTemporaryFile
        }

        guard isValid(
            documentAt: temporaryURL,
            expectedSnapshot: expectedSnapshot,
            protection: protection,
            sessionPassword: sessionPassword
        ) else {
            throw PDFExportError.couldNotValidateTemporaryFile
        }

        let stagedData: Data
        do {
            stagedData = try Data(contentsOf: temporaryURL)
        } catch {
            throw PDFExportError.couldNotValidateTemporaryFile
        }

        guard writeAtomically(stagedData, to: destinationURL) else {
            throw PDFExportError.couldNotFinalizeExport
        }

        guard isValid(
            documentAt: destinationURL,
            expectedSnapshot: expectedSnapshot,
            protection: protection,
            sessionPassword: sessionPassword
        ) else {
            throw PDFExportError.couldNotReopenExport
        }

        return PDFExportResult(
            url: destinationURL,
            pageCount: document.pageCount,
            fileSizeInBytes: stagedData.count
        )
    }

    private func writeAtomically(_ data: Data, to destinationURL: URL) -> Bool {
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: (any Error)?

        coordinator.coordinate(
            writingItemAt: destinationURL,
            options: .forReplacing,
            error: &coordinationError
        ) { coordinatedURL in
            do {
                try data.write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        return coordinationError == nil && writeError == nil
    }

    private func isValid(
        documentAt url: URL,
        expectedSnapshot: ValidationSnapshot,
        protection: PDFOutputProtection,
        sessionPassword: String?
    ) -> Bool {
        guard let outputDocument = PDFDocument(url: url) else {
            return false
        }

        switch protection {
        case .none:
            guard !outputDocument.isEncrypted, !outputDocument.isLocked else {
                return false
            }
        case .reuseSessionPassword:
            guard outputDocument.isEncrypted, let sessionPassword else {
                return false
            }

            if !sessionPassword.isEmpty {
                guard outputDocument.isLocked else {
                    return false
                }
                let incorrectPassword = sessionPassword == "pdfviewer-incorrect-password"
                    ? "pdfviewer-other-incorrect-password"
                    : "pdfviewer-incorrect-password"
                guard
                    let incorrectAttempt = PDFDocument(url: url),
                    !incorrectAttempt.unlock(withPassword: incorrectPassword)
                else {
                    return false
                }
            }

            guard outputDocument.unlock(withPassword: sessionPassword) else {
                return false
            }
        }

        guard
            expectedSnapshot.pages.count == expectedSnapshot.pageCount,
            validationSnapshot(of: outputDocument) == expectedSnapshot,
            let data = outputDocument.dataRepresentation(),
            !data.isEmpty
        else {
            return false
        }
        return true
    }

    private func validationSnapshot(of document: PDFDocument) -> ValidationSnapshot {
        ValidationSnapshot(
            pageCount: document.pageCount,
            pages: (0..<document.pageCount).compactMap { pageIndex in
                guard let page = document.page(at: pageIndex) else {
                    return nil
                }
                return ValidationPage(
                    rotation: page.rotation,
                    cropBounds: page.bounds(for: .cropBox),
                    text: page.string,
                    annotations: page.annotations
                        .filter { $0.type != PDFAnnotationSubtype.popup.pdfTypeName }
                        .map { annotation in
                            ValidationAnnotation(
                                type: annotation.type,
                                bounds: annotation.bounds,
                                contents: annotation.contents,
                                identifier: AnnotationIdentifier(annotation: annotation)?.pdfName,
                                visualSignatureData: VisualSignatureAnnotation.imageData(
                                    from: annotation
                                ),
                                formFieldName: annotation.fieldName,
                                formFieldType: annotation.value(
                                    forAnnotationKey: .widgetFieldType
                                ) as? String,
                                formValue: annotation.widgetStringValue,
                                formDefaultValue: annotation.widgetDefaultStringValue,
                                formButtonState: annotation.type == PDFAnnotationSubtype.widget.pdfTypeName
                                    ? annotation.buttonWidgetState.rawValue
                                    : nil,
                                formChoices: annotation.choices,
                                formExportValues: annotation.values,
                                formFlags: (
                                    annotation.value(forAnnotationKey: .widgetFieldFlags) as? NSNumber
                                )?.intValue,
                                formMaximumLength: annotation.maximumLength,
                                formIsReadOnly: annotation.isReadOnly
                            )
                        }
                )
            }
        )
    }

    private func resourcesReferToSameFile(_ firstURL: URL, _ secondURL: URL) -> Bool {
        guard
            fileManager.fileExists(atPath: secondURL.path),
            let firstIdentifier = try? firstURL.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier as? NSObject,
            let secondIdentifier = try? secondURL.resourceValues(
                forKeys: [.fileResourceIdentifierKey]
            ).fileResourceIdentifier as? NSObject
        else {
            return false
        }
        return firstIdentifier.isEqual(secondIdentifier)
    }
}

private struct ValidationSnapshot: Equatable {
    let pageCount: Int
    let pages: [ValidationPage]
}

private struct ValidationPage: Equatable {
    let rotation: Int
    let cropBounds: CGRect
    let text: String?
    let annotations: [ValidationAnnotation]
}

private struct ValidationAnnotation: Equatable {
    let type: String?
    let bounds: CGRect
    let contents: String?
    let identifier: String?
    let visualSignatureData: Data?
    let formFieldName: String?
    let formFieldType: String?
    let formValue: String?
    let formDefaultValue: String?
    let formButtonState: Int?
    let formChoices: [String]?
    let formExportValues: [String]?
    let formFlags: Int?
    let formMaximumLength: Int
    let formIsReadOnly: Bool
}
