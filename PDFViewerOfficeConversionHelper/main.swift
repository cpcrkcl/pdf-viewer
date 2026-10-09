import Foundation

@objc protocol OfficeConversionXPCProtocol {
    func convert(
        executableBookmark: Data,
        inputBookmark: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    )
}

final class OfficeConversionService: NSObject, OfficeConversionXPCProtocol {
    private static let allowedExtensions: Set<String> = [
        "doc", "docx", "ppt", "pptx", "xls", "xlsx", "odt", "ods", "odp",
    ]
    private static let maximumInputBytes = 1_073_741_824
    // XPC returns the PDF as Data, so keep the response well below the input
    // ceiling to avoid a single conversion exhausting the app and service.
    private static let maximumOutputBytes = 268_435_456

    func convert(
        executableBookmark: Data,
        inputBookmark: Data,
        withReply reply: @escaping (Data?, String?) -> Void
    ) {
        do {
            let executable = try resolve(executableBookmark)
            let input = try resolve(inputBookmark)
            let executableAccess = executable.startAccessingSecurityScopedResource()
            let inputAccess = input.startAccessingSecurityScopedResource()
            defer {
                if executableAccess { executable.stopAccessingSecurityScopedResource() }
                if inputAccess { input.stopAccessingSecurityScopedResource() }
            }
            try validateExecutable(executable)
            try validateInput(input)

            let outputDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("PDFViewer-Office-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: outputDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            defer { try? FileManager.default.removeItem(at: outputDirectory) }

            let process = Process()
            process.executableURL = executable
            process.arguments = [
                "--headless", "--nologo", "--nodefault", "--nolockcheck",
                "--norestore", "--nofirststartwizard",
                "--convert-to", "pdf", "--outdir", outputDirectory.path, input.path,
            ]
            process.standardInput = FileHandle.nullDevice
            // LibreOffice can emit enough diagnostics to fill an unread pipe and
            // deadlock the helper. Diagnostics may also contain document paths, so
            // discard them and return only the bounded generic errors below.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let forceKill = DispatchWorkItem { [weak process] in
                guard let process, process.isRunning else { return }
                kill(process.processIdentifier, SIGKILL)
            }
            let timeout = DispatchWorkItem { [weak process] in
                if process?.isRunning == true {
                    process?.terminate()
                    DispatchQueue.global().asyncAfter(
                        deadline: .now() + 5,
                        execute: forceKill
                    )
                }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: timeout)
            process.waitUntilExit()
            timeout.cancel()
            forceKill.cancel()
            guard process.terminationStatus == 0 else {
                throw HelperError.conversionFailed
            }

            let outputs = try FileManager.default.contentsOfDirectory(
                at: outputDirectory,
                includingPropertiesForKeys: [
                    .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            ).filter { $0.pathExtension.lowercased() == "pdf" }
            guard outputs.count == 1 else { throw HelperError.invalidOutput }
            let output = outputs[0]
            let values = try output.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey,
            ])
            guard
                values.isRegularFile == true,
                values.isSymbolicLink != true,
                let size = values.fileSize,
                size > 4,
                size <= Self.maximumOutputBytes
            else { throw HelperError.invalidOutput }
            let data = try Data(contentsOf: output, options: .mappedIfSafe)
            guard data.starts(with: Data("%PDF".utf8)) else { throw HelperError.invalidOutput }
            reply(data, nil)
        } catch {
            reply(nil, (error as? LocalizedError)?.errorDescription ?? "Local Office conversion failed.")
        }
    }

    private func resolve(_ bookmark: Data) throws -> URL {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
        guard !stale, url.isFileURL else { throw HelperError.invalidSelection }
        return url
    }

    private func validateExecutable(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard
            url.lastPathComponent == "soffice",
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            FileManager.default.isExecutableFile(atPath: url.path)
        else { throw HelperError.invalidExecutable }
    }

    private func validateInput(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard
            Self.allowedExtensions.contains(url.pathExtension.lowercased()),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let size = values.fileSize,
            size > 0,
            size <= Self.maximumInputBytes
        else { throw HelperError.invalidSelection }
    }
}

private enum HelperError: LocalizedError {
    case invalidSelection
    case invalidExecutable
    case conversionFailed
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .invalidSelection: "Choose a supported local Office document."
        case .invalidExecutable: "The selected file is not a valid, non-symlink soffice executable."
        case .conversionFailed: "LibreOffice could not convert this document locally."
        case .invalidOutput: "LibreOffice did not produce one valid PDF."
        }
    }
}

final class ServiceDelegate: NSObject, NSXPCListenerDelegate {
    private let service = OfficeConversionService()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: OfficeConversionXPCProtocol.self)
        connection.exportedObject = service
        connection.resume()
        return true
    }
}

let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
