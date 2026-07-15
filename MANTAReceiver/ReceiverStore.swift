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
    @Published private(set) var reconstructionLog = [ReceiverReconstructionLogEntry]()
    @Published private(set) var processedPackageURL: URL?
    @Published private(set) var reconstructionAlignmentRMSMeters: Float?
    @Published private(set) var reconstructionAlignmentAccepted = false
    @Published private(set) var ephemeralReconstruction: ReceiverEphemeralReconstruction?
    @Published private(set) var isApplyingAlignment = false
    @Published private(set) var alignmentStage = ""
    @Published private(set) var isDetectingElectrodes = false
    @Published private(set) var electrodeDetectionProgress = 0.0
    @Published private(set) var electrodeDetectionStage = ""
    @Published private(set) var electrodeDraft: ReceiverElectrodeDetectionResult?
    @Published private(set) var isUpdatingElectrodeGuesses = false
    @Published private(set) var isSavingElectrodes = false
    @Published var errorMessage: String?

    private let reconstructionRunner = ReceiverPhotogrammetryRunner()
    private var reconstructionTask: Task<Void, Never>?
    private var electrodeDetectionTask: Task<Void, Never>?
    private var electrodeGuessTask: Task<Void, Never>?
    private var electrodeGuessGeneration: UUID?
    private var electrodeModelMesh: ReceiverTriangleMesh?
    private var ephemeralWorkspace: URL?

    deinit {
        electrodeDetectionTask?.cancel()
        electrodeGuessTask?.cancel()
        if let ephemeralWorkspace {
            try? FileManager.default.removeItem(at: ephemeralWorkspace)
        }
    }

    var supportsPhotogrammetryReconstruction: Bool {
        reconstructionRunner.isSupported
    }

    func importArchive(from sourceURL: URL) async {
        guard !isReconstructing, !isApplyingAlignment, !isDetectingElectrodes,
              !isSavingElectrodes else { return }
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
            electrodeDraft = nil
            electrodeModelMesh = nil
            electrodeDetectionProgress = 0
            electrodeDetectionStage = ""
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
        guard !isReconstructing, !isDetectingElectrodes, !isSavingElectrodes,
              let sourceBundle = bundle else { return }
        clearEphemeralReconstruction()
        reconstructionLog.removeAll(keepingCapacity: true)
        appendReconstructionLog(
            .info,
            "Requested \(detail.title) reconstruction · \(outputMode.rawValue).")
        reconstructionTask = Task { [weak self] in
            await self?.performReconstruction(
                bundle: sourceBundle, detail: detail, outputMode: outputMode)
        }
    }

    func cancelReconstruction() {
        guard reconstructionCanCancel else { return }
        reconstructionStage = "Cancelling reconstruction…"
        appendReconstructionLog(.warning, "Cancellation requested by the user.")
        reconstructionTask?.cancel()
        reconstructionRunner.cancel()
    }

    func clearReconstructionLog() {
        reconstructionLog.removeAll(keepingCapacity: true)
    }

    private func appendReconstructionLog(
        _ level: ReceiverReconstructionLogLevel,
        _ message: String
    ) {
        guard reconstructionLog.last?.message != message else { return }
        reconstructionLog.append(ReceiverReconstructionLogEntry(
            level: level, message: message))
        if reconstructionLog.count > 1_000 {
            reconstructionLog.removeFirst(reconstructionLog.count - 1_000)
        }
    }

    private func updateReconstructionProgress(_ progress: Double, stage: String) {
        reconstructionProgress = progress
        guard reconstructionStage != stage else { return }
        reconstructionStage = stage
        appendReconstructionLog(.info, stage)
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
        guard !isApplyingAlignment, !isReconstructing, !isDetectingElectrodes,
              !isSavingElectrodes, let sourceBundle = bundle else { return }
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
            electrodeDraft = nil
            electrodeModelMesh = nil
            if ephemeralReconstruction != nil {
                clearEphemeralReconstruction()
            }
            alignmentStage = "PROCESSED package updated"
        } catch {
            errorMessage = error.localizedDescription
            alignmentStage = "Alignment export failed"
        }
    }

    /// Saves an edited head bounding box in place. Returns whether it succeeded
    /// so the sidebar can clear its "modified" state only on success.
    @discardableResult
    func updateHeadBoundingBox(_ boundingBox: HeadBoundingBox) async -> Bool {
        guard !isApplyingAlignment, !isReconstructing, !isDetectingElectrodes,
              !isSavingElectrodes, let sourceBundle = bundle else { return false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateHeadBoundingBox(
                    bundle: sourceBundle, boundingBox: boundingBox)
            }.value
            bundle = updated.bundle
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func applyFiducialCorrections(_ fiducials: [MANTAFiducialSolution]) async {
        guard !isApplyingAlignment, !isReconstructing, !isDetectingElectrodes,
              !isSavingElectrodes, let sourceBundle = bundle else { return }
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

    func detectElectrodes() {
        guard !isDetectingElectrodes, !isReconstructing, !isApplyingAlignment,
              !isSavingElectrodes, let sourceBundle = bundle else { return }
        isDetectingElectrodes = true
        electrodeDetectionProgress = 0
        electrodeDetectionStage = "Loading aligned photogrammetry surface"
        errorMessage = nil

        electrodeDetectionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                isDetectingElectrodes = false
                electrodeDetectionTask = nil
            }
            do {
                let mesh = try Self.loadElectrodeMesh(bundle: sourceBundle)
                let progressStore = self
                let result = try await Task.detached(priority: .userInitiated) {
                    try ReceiverElectrodeDetector.detect(
                        bundle: sourceBundle, modelMesh: mesh
                    ) { fraction, stage in
                        Task { @MainActor in
                            progressStore.electrodeDetectionProgress = fraction
                            progressStore.electrodeDetectionStage = stage
                        }
                    }
                }.value
                electrodeModelMesh = mesh
                electrodeDraft = result
                electrodeDetectionProgress = 1
                electrodeDetectionStage = "Electrode candidates ready for review"
            } catch is CancellationError {
                electrodeDetectionStage = "Electrode detection cancelled"
            } catch {
                errorMessage = error.localizedDescription
                electrodeDetectionStage = "Electrode detection failed"
            }
        }
    }

    func cancelElectrodeDetection() {
        guard isDetectingElectrodes else { return }
        electrodeDetectionStage = "Cancelling electrode detection"
        electrodeDetectionTask?.cancel()
    }

    func replaceElectrodeDraft(
        electrodes: [MANTAElectrodeSolution],
        evidence: ReceiverElectrodeEvidenceDocument
    ) {
        electrodeDraft = ReceiverElectrodeDetectionResult(
            electrodes: electrodes, evidence: evidence)
    }

    func recalculateElectrodeGuesses(
        electrodes: [MANTAElectrodeSolution],
        evidence: ReceiverElectrodeEvidenceDocument
    ) {
        guard !isDetectingElectrodes, !isSavingElectrodes,
              let sourceBundle = bundle else { return }
        electrodeGuessTask?.cancel()
        let generation = UUID()
        electrodeGuessGeneration = generation
        isUpdatingElectrodeGuesses = true
        electrodeDetectionStage = "Updating layout guesses"
        let cachedMesh = electrodeModelMesh

        electrodeGuessTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if electrodeGuessGeneration == generation {
                    isUpdatingElectrodeGuesses = false
                    electrodeGuessTask = nil
                }
            }
            do {
                let mesh = try cachedMesh ?? Self.loadElectrodeMesh(bundle: sourceBundle)
                try Task.checkCancellation()
                let result = await Task.detached(priority: .userInitiated) {
                    ReceiverElectrodeGuessSolver.recalculate(
                        bundle: sourceBundle, electrodes: electrodes,
                        evidence: evidence, modelMesh: mesh)
                }.value
                try Task.checkCancellation()
                guard electrodeGuessGeneration == generation else { return }
                electrodeModelMesh = mesh
                electrodeDraft = result
                electrodeDetectionStage = "Layout guesses updated"
            } catch is CancellationError {
                return
            } catch {
                guard electrodeGuessGeneration == generation else { return }
                errorMessage = error.localizedDescription
                electrodeDetectionStage = "Guess update failed"
            }
        }
    }

    func saveElectrodes(
        _ electrodes: [MANTAElectrodeSolution],
        evidence: ReceiverElectrodeEvidenceDocument
    ) async {
        guard !isSavingElectrodes, !isDetectingElectrodes,
              !isUpdatingElectrodeGuesses, !isReconstructing,
              !isApplyingAlignment, let sourceBundle = bundle else { return }
        isSavingElectrodes = true
        electrodeDetectionStage = "Writing reviewed electrodes"
        errorMessage = nil
        defer { isSavingElectrodes = false }
        do {
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateElectrodes(
                    bundle: sourceBundle, electrodes: electrodes, evidence: evidence)
            }.value
            bundle = updated.bundle
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            electrodeDraft = nil
            electrodeModelMesh = nil
            electrodeDetectionStage = "PROCESSED package updated"
        } catch {
            errorMessage = error.localizedDescription
            electrodeDetectionStage = "Electrode save failed"
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
        appendReconstructionLog(
            .info,
            "Preflight: \(sourceBundle.capture.observations.count) captured observations available.")

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
            updateReconstructionProgress(0.03, stage: "Prepared reconstruction inputs")
            appendReconstructionLog(
                .info,
                "Prepared \(prepared.imageCount) images (\(ByteCountFormatter.string(fromByteCount: prepared.sourceImageBytes, countStyle: .file))).")

            let run = try await reconstructionRunner.reconstruct(
                preparation: prepared
            ) { [weak self] fraction, stage in
                self?.updateReconstructionProgress(
                    0.03 + fraction * 0.72, stage: stage)
            } log: { [weak self] level, message in
                self?.appendReconstructionLog(level, message)
            }
            try Task.checkCancellation()

            if outputMode == .preview {
                reconstructionCanCancel = false
                updateReconstructionProgress(0.78, stage: "Preparing interactive preview")
                let progressStore = self
                let preview = try await Task.detached(priority: .userInitiated) {
                    try ReceiverReconstructionWorkflow.makePreview(
                        bundle: sourceBundle,
                        preparation: prepared,
                        run: run,
                        log: { level, message in
                            Task { @MainActor in
                                progressStore.appendReconstructionLog(level, message)
                            }
                        })
                }.value
                ephemeralReconstruction = preview
                ephemeralWorkspace = prepared.workspace
                // Keep the temporary USDZ alive for SceneKit; the Store now owns
                // cleanup instead of this reconstruction operation's defer block.
                preparation = nil
                reconstructionAlignmentRMSMeters = preview.alignmentRMSMeters
                reconstructionAlignmentAccepted = preview.alignmentAccepted
                updateReconstructionProgress(
                    1, stage: "Interactive preview ready · no MANTA archive written")
                appendReconstructionLog(
                    preview.alignmentAccepted ? .success : .warning,
                    preview.alignmentAccepted
                        ? "Preview alignment accepted."
                        : "Preview created, but automatic ARKit-world alignment was not accepted.")
                return
            }

            reconstructionCanCancel = false
            updateReconstructionProgress(0.75, stage: "Aligning and updating PROCESSED")
            let progressStore = self
            let updated = try await Task.detached(priority: .userInitiated) {
                try ReceiverProcessedPackage.updateReconstruction(
                    bundle: sourceBundle,
                    preparation: prepared,
                    run: run,
                    log: { level, message in
                        Task { @MainActor in
                            progressStore.appendReconstructionLog(level, message)
                        }
                    }
                ) { fraction, stage in
                    let mappedProgress = 0.75 + fraction * 0.22
                    Task { @MainActor in
                        guard mappedProgress > progressStore.reconstructionProgress else { return }
                        progressStore.updateReconstructionProgress(
                            mappedProgress, stage: stage)
                    }
                }
            }.value

            self.bundle = updated.bundle
            electrodeDraft = nil
            electrodeModelMesh = nil
            importedArchiveURL = updated.packageURL
            processedPackageURL = updated.packageURL
            reconstructionAlignmentRMSMeters = updated.alignmentRMSMeters
            reconstructionAlignmentAccepted = updated.alignmentAccepted
            updateReconstructionProgress(1, stage: "PROCESSED package updated")
            appendReconstructionLog(
                updated.alignmentAccepted ? .success : .warning,
                updated.alignmentAccepted
                    ? "Reconstruction saved and automatic alignment accepted."
                    : "Reconstruction saved, but automatic ARKit-world alignment was not accepted.")
        } catch let error as ReceiverReconstructionError {
            if case .cancelled = error {
                updateReconstructionProgress(
                    reconstructionProgress, stage: "Reconstruction cancelled")
                appendReconstructionLog(.warning, error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
                updateReconstructionProgress(
                    reconstructionProgress, stage: "Reconstruction failed")
                appendReconstructionLog(.error, error.localizedDescription)
            }
        } catch is CancellationError {
            updateReconstructionProgress(
                reconstructionProgress, stage: "Reconstruction cancelled")
            appendReconstructionLog(.warning, "Reconstruction task was cancelled.")
        } catch {
            errorMessage = error.localizedDescription
            updateReconstructionProgress(
                reconstructionProgress, stage: "Reconstruction failed")
            appendReconstructionLog(.error, error.localizedDescription)
        }
    }

    private func clearEphemeralReconstruction() {
        ephemeralReconstruction = nil
        if let ephemeralWorkspace {
            try? FileManager.default.removeItem(at: ephemeralWorkspace)
            self.ephemeralWorkspace = nil
        }
    }

    private static func loadElectrodeMesh(
        bundle: MANTAValidatedBundle
    ) throws -> ReceiverTriangleMesh? {
        guard let reconstruction = bundle.capture.reconstruction,
              let path = reconstruction.objectCaptureModelPath,
              let transform = ReceiverSurfaceExporter.modelToWorld(reconstruction) else {
            return nil
        }
        return try ReceiverSurfaceExporter.loadSceneMesh(
            bundle.rootDirectory.appendingPathComponent(path),
            modelToWorld: transform)
    }

    /// Everything about a capture lives in the one folder the user gave us.
    /// A folder is opened and edited directly, in place - nothing is copied into
    /// Application Support. Only a legacy `.manta`/`.manta.zip` archive or a
    /// pre-share iPad working-session folder needs a one-time conversion, and
    /// that conversion writes a sibling folder next to the source (not into any
    /// app-managed location) which then becomes the live package for every
    /// future edit.
    private nonisolated static func persistAndValidate(
        _ sourceURL: URL
    ) throws -> (bundle: MANTAValidatedBundle, archiveURL: URL) {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sourceURL.path, isDirectory: &isDirectory) else {
            throw ReceiverImportError.unsupportedExtension
        }

        if isDirectory.boolValue {
            if ReceiverProcessedPackage.isPackage(sourceURL) {
                return (try ReceiverProcessedPackage.load(at: sourceURL), sourceURL)
            }
            let manifestURL = sourceURL.appendingPathComponent(MANTABundleFormat.manifestFilename)
            let isRawSessionDirectory = fileManager.fileExists(
                atPath: sourceURL.appendingPathComponent("session.json").path)
                && !fileManager.fileExists(atPath: manifestURL.path)
            if isRawSessionDirectory {
                let destination = siblingDestination(for: sourceURL, tag: "recovered")
                let recovered = try MANTARawSessionRecovery().recoverDirectoryPackage(
                    from: sourceURL, to: destination, producer: recoveryProducer())
                return (recovered.bundle, recovered.packageURL)
            }
            guard fileManager.fileExists(atPath: manifestURL.path) else {
                throw ReceiverImportError.notALogicalBundle
            }
            let bundle = try MANTABundleValidator().validate(directory: sourceURL)
            return (bundle, sourceURL)
        }

        guard sourceURL.pathExtension.lowercased() == "manta" ||
                sourceURL.lastPathComponent.lowercased().hasSuffix(".manta.zip") else {
            throw ReceiverImportError.unsupportedExtension
        }
        let destination = siblingDestination(for: sourceURL, tag: nil)
        let bundle = try MANTAArchiveImporter().importBundle(at: sourceURL, to: destination)
        return (bundle, destination)
    }

    /// A not-yet-existing folder next to `source`, named after it. Used only for
    /// the one-time conversion of a legacy zip or a raw session folder into a
    /// live package; the source item itself is left untouched.
    private nonisolated static func siblingDestination(for source: URL, tag: String?) -> URL {
        let fileManager = FileManager.default
        let parent = source.deletingLastPathComponent()
        let base = source.deletingPathExtension().lastPathComponent
        let name = tag.map { "\(base)-\($0)" } ?? base
        var candidate = parent.appendingPathComponent("\(name).manta", isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(name)-\(suffix).manta", isDirectory: true)
            suffix += 1
        }
        return candidate
    }

    private nonisolated static func recoveryProducer() -> MANTAProducer {
        let info = Bundle.main.infoDictionary ?? [:]
        return MANTAProducer(
            application: info["CFBundleDisplayName"] as? String ?? "MANTAReceiver",
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            platform: "macOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: Host.current().localizedName ?? "Mac")
    }

}

private enum ReceiverImportError: LocalizedError {
    case unsupportedExtension
    case notALogicalBundle

    var errorDescription: String? {
        switch self {
        case .unsupportedExtension:
            return "Choose a .manta archive, a recovered .manta package, or a MANTA working-session folder."
        case .notALogicalBundle:
            return "This folder is missing manifest.json and session.json, so it is not a MANTA capture bundle or recoverable session."
        }
    }
}
