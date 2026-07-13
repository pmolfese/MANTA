import Foundation
import MANTACore

@MainActor
final class ReceiverStore: ObservableObject {
    @Published private(set) var bundle: MANTAValidatedBundle?
    @Published private(set) var importedArchiveURL: URL?
    @Published private(set) var isImporting = false
    @Published private(set) var isReconstructing = false
    @Published private(set) var reconstructionCanCancel = false
    @Published private(set) var reconstructionProgress = 0.0
    @Published private(set) var reconstructionStage = ""
    @Published private(set) var reconstructionStartedAt: Date?
    @Published private(set) var processedPackageURL: URL?
    @Published private(set) var reconstructionAlignmentRMSMeters: Float?
    @Published private(set) var reconstructionAlignmentAccepted = false
    @Published private(set) var ephemeralReconstruction: ReceiverEphemeralReconstruction?
    @Published private(set) var isApplyingAlignment = false
    @Published private(set) var alignmentStage = ""
    @Published var errorMessage: String?

    private let reconstructionRunner = ReceiverPhotogrammetryRunner()
    private var reconstructionTask: Task<Void, Never>?
    private var ephemeralWorkspace: URL?

    deinit {
        if let ephemeralWorkspace {
            try? FileManager.default.removeItem(at: ephemeralWorkspace)
        }
    }

    var supportsPhotogrammetryReconstruction: Bool {
        reconstructionRunner.isSupported
    }

    func importArchive(from sourceURL: URL) async {
        guard !isReconstructing, !isApplyingAlignment else { return }
        let previousRoot = bundle?.rootDirectory
        isImporting = true
        errorMessage = nil

        let accessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessing { sourceURL.stopAccessingSecurityScopedResource() }
            isImporting = false
        }

        do {
            clearEphemeralReconstruction()
            let result = try await Task.detached(priority: .userInitiated) {
                try Self.persistAndValidate(sourceURL)
            }.value
            bundle = result.bundle
            importedArchiveURL = result.archiveURL
            processedPackageURL = ReceiverProcessedPackage.isPackage(result.bundle.rootDirectory)
                ? result.bundle.rootDirectory : nil
            reconstructionAlignmentRMSMeters = nil
            reconstructionAlignmentAccepted = false
            if let previousRoot {
                Self.removeImportedWorkspace(containing: previousRoot)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func reconstructionEstimate(
        for detail: ReceiverPhotogrammetryDetail
    ) -> ReceiverReconstructionEstimate? {
        guard let bundle else { return nil }
        return ReceiverReconstructionWorkflow.estimate(bundle: bundle, detail: detail)
    }

    func startReconstruction(
        detail: ReceiverPhotogrammetryDetail,
        outputMode: ReceiverReconstructionOutputMode
    ) {
        guard !isReconstructing, let sourceBundle = bundle else { return }
        clearEphemeralReconstruction()
        reconstructionTask = Task { [weak self] in
            await self?.performReconstruction(
                bundle: sourceBundle, detail: detail, outputMode: outputMode)
        }
    }

    func cancelReconstruction() {
        guard reconstructionCanCancel else { return }
        reconstructionStage = "Cancelling reconstruction…"
        reconstructionTask?.cancel()
        reconstructionRunner.cancel()
    }

    func discardReconstructionPreview() {
        guard !isReconstructing else { return }
        clearEphemeralReconstruction()
        reconstructionAlignmentRMSMeters = nil
        reconstructionAlignmentAccepted = false
    }

    func applyManualAlignment(
        _ outcome: ReceiverManualAlignmentOutcome,
        ephemeralReconstruction: ReceiverEphemeralReconstruction? = nil
    ) async {
        guard !isApplyingAlignment, !isReconstructing, let sourceBundle = bundle else { return }
        isApplyingAlignment = true
        alignmentStage = "Updating changed files in PROCESSED"
        errorMessage = nil
        defer { isApplyingAlignment = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateAlignment(
                    bundle: sourceBundle,
                    outcome: outcome,
                    ephemeralReconstruction: ephemeralReconstruction)
            }.value
            bundle = updated.bundle
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            reconstructionAlignmentRMSMeters = updated.alignmentRMSMeters
            reconstructionAlignmentAccepted = updated.alignmentAccepted
            if ephemeralReconstruction != nil {
                clearEphemeralReconstruction()
            }
            alignmentStage = "PROCESSED package updated"
        } catch {
            errorMessage = error.localizedDescription
            alignmentStage = "Alignment export failed"
        }
    }

    func applyFiducialCorrections(_ fiducials: [MANTAFiducialSolution]) async {
        guard !isApplyingAlignment, !isReconstructing, let sourceBundle = bundle else { return }
        isApplyingAlignment = true
        alignmentStage = "Writing reviewed fiducials"
        errorMessage = nil
        defer { isApplyingAlignment = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateFiducials(
                    bundle: sourceBundle, fiducials: fiducials)
            }.value
            bundle = updated.bundle
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            alignmentStage = "PROCESSED package updated"
        } catch {
            errorMessage = error.localizedDescription
            alignmentStage = "Fiducial correction export failed"
        }
    }

    private func performReconstruction(
        bundle sourceBundle: MANTAValidatedBundle,
        detail: ReceiverPhotogrammetryDetail,
        outputMode: ReceiverReconstructionOutputMode
    ) async {
        isReconstructing = true
        reconstructionCanCancel = true
        reconstructionProgress = 0
        reconstructionStage = "Preparing source images"
        reconstructionStartedAt = Date()
        reconstructionAlignmentRMSMeters = nil
        reconstructionAlignmentAccepted = false
        errorMessage = nil

        var preparation: ReceiverReconstructionPreparation?
        defer {
            if let preparation {
                ReceiverReconstructionWorkflow.removeWorkspace(preparation)
            }
            isReconstructing = false
            reconstructionCanCancel = false
            reconstructionTask = nil
        }

        do {
            let prepared = try await Task.detached(priority: .userInitiated) {
                try ReceiverReconstructionWorkflow.prepare(
                    bundle: sourceBundle, detail: detail)
            }.value
            preparation = prepared
            try Task.checkCancellation()
            reconstructionProgress = 0.03

            let run = try await reconstructionRunner.reconstruct(
                preparation: prepared
            ) { [weak self] fraction, stage in
                self?.reconstructionProgress = 0.03 + fraction * 0.72
                self?.reconstructionStage = stage
            }
            try Task.checkCancellation()

            if outputMode == .preview {
                reconstructionCanCancel = false
                reconstructionProgress = 0.78
                reconstructionStage = "Preparing interactive preview"
                let preview = try await Task.detached(priority: .userInitiated) {
                    try ReceiverReconstructionWorkflow.makePreview(
                        bundle: sourceBundle,
                        preparation: prepared,
                        run: run)
                }.value
                ephemeralReconstruction = preview
                ephemeralWorkspace = prepared.workspace
                // Keep the temporary USDZ alive for SceneKit; the Store now owns
                // cleanup instead of this reconstruction operation's defer block.
                preparation = nil
                reconstructionAlignmentRMSMeters = preview.alignmentRMSMeters
                reconstructionAlignmentAccepted = preview.alignmentAccepted
                reconstructionProgress = 1
                reconstructionStage = "Interactive preview ready · no MANTA archive written"
                return
            }

            reconstructionCanCancel = false
            reconstructionProgress = 0.75
            reconstructionStage = "Aligning and updating PROCESSED"
            let progressStore = self
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateReconstruction(
                    bundle: sourceBundle,
                    preparation: prepared,
                    run: run
                ) { fraction, stage in
                    let mappedProgress = 0.75 + fraction * 0.22
                    Task { @MainActor in
                        guard mappedProgress > progressStore.reconstructionProgress else { return }
                        progressStore.reconstructionProgress = mappedProgress
                        progressStore.reconstructionStage = stage
                    }
                }
            }.value

            self.bundle = updated.bundle
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            reconstructionAlignmentRMSMeters = updated.alignmentRMSMeters
            reconstructionAlignmentAccepted = updated.alignmentAccepted
            reconstructionProgress = 1
            reconstructionStage = "PROCESSED package updated"
        } catch let error as ReceiverReconstructionError {
            if case .cancelled = error {
                reconstructionStage = "Reconstruction cancelled"
            } else {
                errorMessage = error.localizedDescription
                reconstructionStage = "Reconstruction failed"
            }
        } catch is CancellationError {
            reconstructionStage = "Reconstruction cancelled"
        } catch {
            errorMessage = error.localizedDescription
            reconstructionStage = "Reconstruction failed"
        }
    }

    private func clearEphemeralReconstruction() {
        ephemeralReconstruction = nil
        if let ephemeralWorkspace {
            try? FileManager.default.removeItem(at: ephemeralWorkspace)
            self.ephemeralWorkspace = nil
        }
    }

    private nonisolated static func persistAndValidate(
        _ sourceURL: URL,
        copyArchive: Bool = true
    ) throws -> (bundle: MANTAValidatedBundle, archiveURL: URL) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ReceiverImportError.unsupportedExtension
        }

        // A directory is accepted only when it is an already-extracted logical
        // bundle (contains manifest.json). A raw working-session folder copied off
        // a device is not a bundle and is rejected with a specific explanation.
        if isDirectory.boolValue {
            if ReceiverProcessedPackage.isPackage(sourceURL) {
                return (try ReceiverProcessedPackage.load(at: sourceURL), sourceURL)
            }
            let manifestURL = sourceURL.appendingPathComponent(MANTABundleFormat.manifestFilename)
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                let sessionURL = sourceURL.appendingPathComponent("session.json")
                throw fileManager.fileExists(atPath: sessionURL.path)
                    ? ReceiverImportError.rawSessionFolder
                    : ReceiverImportError.notALogicalBundle
            }
        } else {
            guard sourceURL.pathExtension.lowercased() == "manta" ||
                    sourceURL.lastPathComponent.lowercased().hasSuffix(".manta.zip") else {
                throw ReceiverImportError.unsupportedExtension
            }
        }

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
            let contents = receipt.appendingPathComponent("Contents", isDirectory: true)
            if isDirectory.boolValue {
                // Copy the extracted bundle in, then validate the copy in place so
                // the imported record survives if the source folder is later moved.
                try fileManager.copyItem(at: sourceURL, to: contents)
                let bundle = try MANTABundleValidator().validate(directory: contents)
                return (bundle, contents)
            }
            let archive: URL
            if copyArchive {
                archive = receipt.appendingPathComponent("capture.manta")
                try fileManager.copyItem(at: sourceURL, to: archive)
            } else {
                archive = sourceURL
            }
            let bundle = try MANTAArchiveImporter().importBundle(at: archive, to: contents)
            return (bundle, archive)
        } catch {
            try? fileManager.removeItem(at: receipt)
            throw error
        }
    }

    private nonisolated static func removeImportedWorkspace(containing root: URL) {
        let fileManager = FileManager.default
        guard let applicationSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false) else { return }
        let imports = applicationSupport
            .appendingPathComponent("MANTA Receiver", isDirectory: true)
            .appendingPathComponent("Imports", isDirectory: true)
            .standardizedFileURL
        let receipt = root.standardizedFileURL.deletingLastPathComponent()
        guard receipt.deletingLastPathComponent() == imports else { return }
        try? fileManager.removeItem(at: receipt)
    }

}

private enum ReceiverImportError: LocalizedError {
    case unsupportedExtension
    case rawSessionFolder
    case notALogicalBundle

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension:
            return "Choose a .manta archive, or a folder containing an extracted .manta bundle."
        case .rawSessionFolder:
            return """
            This is a raw working-session folder, not a .manta bundle (it has \
            session.json but no manifest.json). On the capturing iPad, tap Export \
            to produce a .manta archive, then import that file or its extracted folder.
            """
        case .notALogicalBundle:
            return "This folder is missing manifest.json, so it is not a MANTA capture bundle."
        }
    }
}
