import Foundation
@preconcurrency import PDFKit

enum DocumentLoadingError: LocalizedError, Equatable {
    case unsupportedFileType
    case fileUnavailable
    case invalidPDF
    case lockedHandleUnavailable

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            "PDFViewer can open PDF files only."
        case .fileUnavailable:
            "This PDF is missing, unreadable, or no longer available."
        case .invalidPDF:
            "This file is not a valid PDF or could not be read safely."
        case .lockedHandleUnavailable:
            "This password prompt is no longer active. Open the PDF again to retry."
        }
    }
}

enum DocumentUnlockLevel: Equatable {
    case user
    case owner
}

struct DocumentSecurityContext: Equatable {
    let isEncrypted: Bool
    let unlockLevel: DocumentUnlockLevel
    let accessPermissions: PDFAccessPermissions

    var allowsCommenting: Bool {
        unlockLevel == .owner || hasPermission(.allowsCommenting)
    }

    var allowsDocumentAssembly: Bool {
        unlockLevel == .owner || hasPermission(.allowsDocumentAssembly)
    }

    var allowsContentCopying: Bool {
        unlockLevel == .owner || hasPermission(.allowsContentCopying)
    }

    var allowsPrinting: Bool {
        unlockLevel == .owner ||
            hasPermission(.allowsLowQualityPrinting) ||
            hasPermission(.allowsHighQualityPrinting)
    }

    var allowsFormFieldEntry: Bool {
        unlockLevel == .owner || hasPermission(.allowsFormFieldEntry)
    }

    var allowsDocumentChanges: Bool {
        unlockLevel == .owner || hasPermission(.allowsDocumentChanges)
    }

    private func hasPermission(_ permission: PDFAccessPermissions) -> Bool {
        accessPermissions.rawValue & permission.rawValue != 0
    }
}

enum DocumentOpenResult {
    case opened(DocumentSession)
    case passwordRequired(LockedDocumentHandle)
}

/// Immutable values produced by the background PDF preparation pass. PDFKit
/// reference types never cross the actor boundary; only independently owned
/// bytes and value metadata do.
private struct PreparedOpenDocument: Sendable {
    let sourceData: Data
    let workingCopyData: Data?
    let documentFingerprint: String
    let isEncrypted: Bool
    let hasUserPermissions: Bool
    let accessPermissionsRawValue: UInt
    let outlineNodes: [DocumentOutlineNode]
}

struct SecurityScopedResourceAccessProvider {
    let startAccessing: (URL) -> Bool
    let stopAccessing: (URL) -> Void

    @MainActor static let live = SecurityScopedResourceAccessProvider(
        startAccessing: { url in
            url.startAccessingSecurityScopedResource()
        },
        stopAccessing: { url in
            url.stopAccessingSecurityScopedResource()
        }
    )
}

private final class SecurityScopedResourceAccess {
    private let url: URL
    private let stopAccessing: (URL) -> Void
    private var isActive: Bool

    fileprivate init(
        url: URL,
        isActive: Bool,
        stopAccessing: @escaping (URL) -> Void
    ) {
        self.url = url
        self.isActive = isActive
        self.stopAccessing = stopAccessing
    }

    func close() {
        guard isActive else {
            return
        }

        stopAccessing(url)
        isActive = false
    }

    deinit {
        close()
    }
}

@MainActor
final class DocumentSession {
    let sourceURL: URL
    let editor: PDFDocumentEditor
    let securityContext: DocumentSecurityContext
    let documentFingerprint: String
    let outlineNodes: [DocumentOutlineNode]

    var document: PDFDocument {
        editor.document
    }

    private let securityScopedResourceAccess: SecurityScopedResourceAccess
    private(set) var sessionPassword: String?

    fileprivate init(
        sourceURL: URL,
        editor: PDFDocumentEditor,
        securityContext: DocumentSecurityContext,
        sessionPassword: String?,
        documentFingerprint: String,
        outlineNodes: [DocumentOutlineNode],
        securityScopedResourceAccess: SecurityScopedResourceAccess
    ) {
        self.sourceURL = sourceURL
        self.editor = editor
        self.securityContext = securityContext
        self.sessionPassword = sessionPassword
        self.documentFingerprint = documentFingerprint
        self.outlineNodes = outlineNodes
        self.securityScopedResourceAccess = securityScopedResourceAccess
    }

    func close() {
        sessionPassword = nil
        securityScopedResourceAccess.close()
    }
}

@MainActor
final class LockedDocumentHandle: Identifiable {
    let id = UUID()
    let sourceURL: URL

    var displayName: String {
        sourceURL.lastPathComponent
    }

    private var document: PDFDocument?
    private let documentFingerprint: String
    private let securityScopedResourceAccess: SecurityScopedResourceAccess
    private var didTransferAccess = false

    fileprivate init(
        sourceURL: URL,
        document: PDFDocument,
        documentFingerprint: String,
        securityScopedResourceAccess: SecurityScopedResourceAccess
    ) {
        self.sourceURL = sourceURL
        self.document = document
        self.documentFingerprint = documentFingerprint
        self.securityScopedResourceAccess = securityScopedResourceAccess
    }

    func unlock(with password: String) throws -> DocumentSession? {
        guard let document else {
            throw DocumentLoadingError.lockedHandleUnavailable
        }
        guard document.unlock(withPassword: password) else {
            return nil
        }
        guard document.pageCount > 0 else {
            cancel()
            throw DocumentLoadingError.invalidPDF
        }

        let editor: PDFDocumentEditor
        do {
            editor = try PDFDocumentEditor(
                document: document,
                documentFingerprint: documentFingerprint
            )
        } catch {
            cancel()
            throw DocumentLoadingError.invalidPDF
        }

        let securityContext = DocumentSecurityContext(
            isEncrypted: true,
            unlockLevel: document.permissionsStatus == .owner ? .owner : .user,
            accessPermissions: document.accessPermissions
        )
        didTransferAccess = true
        self.document = nil
        return DocumentSession(
            sourceURL: sourceURL,
            editor: editor,
            securityContext: securityContext,
            sessionPassword: password,
            documentFingerprint: documentFingerprint,
            outlineNodes: DocumentOutlineBuilder.build(
                from: document,
                pageIDs: editor.pageIDs
            ),
            securityScopedResourceAccess: securityScopedResourceAccess
        )
    }

    func cancel() {
        document = nil
        if !didTransferAccess {
            securityScopedResourceAccess.close()
        }
    }

}

@MainActor
struct DocumentLoader {
    private let fileManager: FileManager
    private let securityScopedResources: SecurityScopedResourceAccessProvider

    init(
        fileManager: FileManager = .default,
        securityScopedResources: SecurityScopedResourceAccessProvider = .live
    ) {
        self.fileManager = fileManager
        self.securityScopedResources = securityScopedResources
    }

    func open(_ url: URL) throws -> DocumentOpenResult {
        guard url.isFileURL, url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else {
            throw DocumentLoadingError.unsupportedFileType
        }

        let standardizedURL = url.standardizedFileURL
        let hasScopedAccess = securityScopedResources.startAccessing(standardizedURL)

        let scopedAccess = SecurityScopedResourceAccess(
            url: standardizedURL,
            isActive: hasScopedAccess,
            stopAccessing: securityScopedResources.stopAccessing
        )

        guard
            fileManager.fileExists(atPath: standardizedURL.path),
            fileManager.isReadableFile(atPath: standardizedURL.path)
        else {
            scopedAccess.close()
            throw DocumentLoadingError.fileUnavailable
        }

        guard
            let sourceData = try? Data(contentsOf: standardizedURL),
            !sourceData.isEmpty,
            let document = PDFDocument(data: sourceData)
        else {
            scopedAccess.close()
            throw DocumentLoadingError.invalidPDF
        }
        let documentFingerprint = DocumentFingerprint.sha256(of: sourceData)

        if document.isLocked {
            return .passwordRequired(
                LockedDocumentHandle(
                    sourceURL: standardizedURL,
                    document: document,
                    documentFingerprint: documentFingerprint,
                    securityScopedResourceAccess: scopedAccess
                )
            )
        }

        guard document.pageCount > 0 else {
            scopedAccess.close()
            throw DocumentLoadingError.invalidPDF
        }

        let editor: PDFDocumentEditor
        do {
            editor = try PDFDocumentEditor(
                document: document,
                documentFingerprint: documentFingerprint
            )
        } catch {
            scopedAccess.close()
            throw DocumentLoadingError.invalidPDF
        }

        return .opened(
            DocumentSession(
                sourceURL: standardizedURL,
                editor: editor,
                securityContext: DocumentSecurityContext(
                    isEncrypted: document.isEncrypted,
                    unlockLevel: document.permissionsStatus == .user ? .user : .owner,
                    accessPermissions: document.accessPermissions
                ),
                sessionPassword: document.isEncrypted ? "" : nil,
                documentFingerprint: documentFingerprint,
                outlineNodes: DocumentOutlineBuilder.build(
                    from: document,
                    pageIDs: editor.pageIDs
                ),
                securityScopedResourceAccess: scopedAccess
            )
        )
    }

    /// Opens and normalizes a PDF without performing file reads, PDF parsing,
    /// page copying, or serialization on the main actor.
    func openAsync(_ url: URL) async throws -> DocumentOpenResult {
        let (standardizedURL, scopedAccess) = try beginAccess(to: url)
        var didTransferAccess = false
        defer {
            if !didTransferAccess {
                scopedAccess.close()
            }
        }

        let prepared = try await Task.detached(priority: .userInitiated) {
            try Self.prepareDocument(at: standardizedURL)
        }.value
        try Task.checkCancellation()

        let result: DocumentOpenResult
        if prepared.workingCopyData == nil {
            guard let lockedDocument = PDFDocument(data: prepared.sourceData) else {
                throw DocumentLoadingError.invalidPDF
            }
            result = .passwordRequired(
                LockedDocumentHandle(
                    sourceURL: standardizedURL,
                    document: lockedDocument,
                    documentFingerprint: prepared.documentFingerprint,
                    securityScopedResourceAccess: scopedAccess
                )
            )
        } else {
            guard let workingCopyData = prepared.workingCopyData else {
                throw DocumentLoadingError.invalidPDF
            }
            let editor: PDFDocumentEditor
            do {
                editor = try PDFDocumentEditor(
                    preparedPDFData: workingCopyData,
                    documentFingerprint: prepared.documentFingerprint
                )
            } catch {
                throw DocumentLoadingError.invalidPDF
            }
            guard let accessPermissions = PDFAccessPermissions(
                rawValue: prepared.accessPermissionsRawValue
            ) else {
                throw DocumentLoadingError.invalidPDF
            }
            result = .opened(
                DocumentSession(
                    sourceURL: standardizedURL,
                    editor: editor,
                    securityContext: DocumentSecurityContext(
                        isEncrypted: prepared.isEncrypted,
                        unlockLevel: prepared.hasUserPermissions ? .user : .owner,
                        accessPermissions: accessPermissions
                    ),
                    sessionPassword: prepared.isEncrypted ? "" : nil,
                    documentFingerprint: prepared.documentFingerprint,
                    outlineNodes: prepared.outlineNodes,
                    securityScopedResourceAccess: scopedAccess
                )
            )
        }

        didTransferAccess = true
        return result
    }

    private func beginAccess(
        to url: URL
    ) throws -> (URL, SecurityScopedResourceAccess) {
        guard url.isFileURL, url.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame else {
            throw DocumentLoadingError.unsupportedFileType
        }

        let standardizedURL = url.standardizedFileURL
        let hasScopedAccess = securityScopedResources.startAccessing(standardizedURL)
        let scopedAccess = SecurityScopedResourceAccess(
            url: standardizedURL,
            isActive: hasScopedAccess,
            stopAccessing: securityScopedResources.stopAccessing
        )
        guard
            fileManager.fileExists(atPath: standardizedURL.path),
            fileManager.isReadableFile(atPath: standardizedURL.path)
        else {
            scopedAccess.close()
            throw DocumentLoadingError.fileUnavailable
        }
        return (standardizedURL, scopedAccess)
    }

    private nonisolated static func prepareDocument(
        at url: URL
    ) throws -> PreparedOpenDocument {
        guard
            let sourceData = try? Data(contentsOf: url),
            !sourceData.isEmpty,
            let sourceDocument = PDFDocument(data: sourceData)
        else {
            throw DocumentLoadingError.invalidPDF
        }

        let fingerprint = DocumentFingerprint.sha256(of: sourceData)
        if sourceDocument.isLocked {
            return PreparedOpenDocument(
                sourceData: sourceData,
                workingCopyData: nil,
                documentFingerprint: fingerprint,
                isEncrypted: true,
                hasUserPermissions: true,
                accessPermissionsRawValue: 0,
                outlineNodes: []
            )
        }
        guard sourceDocument.pageCount > 0 else {
            throw DocumentLoadingError.invalidPDF
        }

        let pageIDs = (0..<sourceDocument.pageCount).map {
            WorkingPageID.original(documentFingerprint: fingerprint, pageIndex: $0)
        }
        let outlineNodes = DocumentOutlineBuilder.build(
            from: sourceDocument,
            pageIDs: pageIDs
        )
        let workingDocument = PDFDocument()
        workingDocument.documentAttributes = sourceDocument.documentAttributes
        for index in 0..<sourceDocument.pageCount {
            guard
                let page = sourceDocument.page(at: index),
                let copiedPage = page.copy() as? PDFPage
            else {
                throw DocumentLoadingError.invalidPDF
            }
            workingDocument.insert(copiedPage, at: index)
        }
        guard
            let workingCopyData = workingDocument.dataRepresentation(),
            !workingCopyData.isEmpty
        else {
            throw DocumentLoadingError.invalidPDF
        }

        return PreparedOpenDocument(
            sourceData: sourceData,
            workingCopyData: workingCopyData,
            documentFingerprint: fingerprint,
            isEncrypted: sourceDocument.isEncrypted,
            hasUserPermissions: sourceDocument.permissionsStatus == .user,
            accessPermissionsRawValue: sourceDocument.accessPermissions.rawValue,
            outlineNodes: outlineNodes
        )
    }
}
