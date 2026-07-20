import OSLog

/// A deliberately content-blind event vocabulary for release diagnostics.
///
/// Callers cannot attach filenames, URLs, recognized text, passwords, page
/// images, annotations, signature data, or arbitrary strings. This keeps the
/// unified log useful for coarse lifecycle troubleshooting without turning it
/// into a document-content side channel.
enum AppDiagnosticEvent: String, Sendable {
    case applicationLaunched = "application_launched"
    case documentOpened = "document_opened"
    case documentClosed = "document_closed"
    case exportCompleted = "export_completed"
    case recoverableOperationFailed = "recoverable_operation_failed"
}

enum AppDiagnostics {
    private static let logger = Logger(
        subsystem: "com.christopherrego.PDFViewer",
        category: "workflow"
    )

    static func record(_ event: AppDiagnosticEvent) {
        logger.notice("event=\(event.rawValue, privacy: .public)")
    }
}
