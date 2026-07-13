import Foundation
import MANTACore

@MainActor
final class ReceiverStore: ObservableObject {
    @Published private(set) var bundle: MANTAValidatedBundle?
    @Published private(set) var importedArchiveURL: URL?
    @Published private(set) var isImporting = false
    @Published var errorMessage: String?

    func importArchive(from sourceURL: URL) async {
        isImporting = true
        errorMessage = nil

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            isImporting = false
        }

        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.persistAndValidate(sourceURL)
            }.value
            bundle = result.bundle
            importedArchiveURL = result.archiveURL
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private nonisolated static func persistAndValidate(
        _ sourceURL: URL
    ) throws -> (bundle: MANTAValidatedBundle, archiveURL: URL) {
        guard sourceURL.pathExtension.lowercased() == "manta" ||
                sourceURL.lastPathComponent.lowercased().hasSuffix(".manta.zip") else {
            throw ReceiverImportError.unsupportedExtension
        }

        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let imports = applicationSupport
            .appendingPathComponent("MANTA Receiver", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
        try fileManager.createDirectory(at: imports, withIntermediateDirectories: true)

        let receipt = imports.appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        try fileManager.createDirectory(at: receipt, withIntermediateDirectories: false)
        do {
            let archive = receipt.appendingPathComponent("capture.manta")
            try fileManager.copyItem(at: sourceURL, to: archive)
            let contents = receipt.appendingPathComponent("Contents", isDirectory: true)
            let bundle = try MANTAArchiveImporter().importBundle(at: archive, to: contents)
            return (bundle, archive)
        } catch {
            try? fileManager.removeItem(at: receipt)
            throw error
        }
    }
}

private enum ReceiverImportError: LocalizedError {
    case unsupportedExtension

    var errorDescription: String? {
        "Choose a .manta capture archive."
    }
}
