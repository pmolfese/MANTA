import Foundation
import MANTACore
import simd

/// Lightweight metadata that distinguishes a mutable PROCESSED package from an
/// extracted, immutable RAW bundle. PROCESSED deliberately does not promise
/// archive-wide checksums: its files are edited incrementally in place.
nonisolated private struct ReceiverProcessedPackageMetadata: Codable, Sendable {
    var format = "org.nih.manta.processed-package"
    var version = 1
    var processedBundleID: UUID
    var rawBundleID: UUID
    var sessionID: UUID
    var createdAt: Date
    var updatedAt: Date
}

struct ReceiverProcessedUpdate: Sendable {
    var bundle: MANTAValidatedBundle
    var packageURL: URL
    var alignmentRMSMeters: Float?
    var alignmentAccepted: Bool
}

/// Original acquisition files stay in place. Receiver edits and their effective
/// manifest live under derivatives/receiver; legacy processed packages still open.
nonisolated enum ReceiverProcessedPackage {
    static let metadataFilename = "derivatives/receiver/processed.json"
    private static let logFilename = "derivatives/receiver/log_manta.json"
    private static let electrodeEvidencePath = "derivatives/receiver/analysis/electrode_evidence.json"

    static func isPackage(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(metadataFilename).path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("processed.json").path)
    }

    static func load(at root: URL, verifyIntegrity: Bool = false,
                     progress: ((MANTACaptureReadProgress) -> Void)? = nil) throws -> MANTAValidatedBundle {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(metadataFilename).path) {
            let bundle = try MANTABundleValidator().validateProcessingIndex(directory: root,
                verifyIntegrity: verifyIntegrity, progress: progress)
            let metadata = try MANTAJSON.makeDecoder().decode(ReceiverProcessedPackageMetadata.self,
                from: Data(contentsOf: root.appendingPathComponent(metadataFilename)))
            guard metadata.sessionID == bundle.manifest.sessionID,
                  metadata.processedBundleID == bundle.manifest.bundleID,
                  metadata.rawBundleID == bundle.manifest.parentBundleID else {
                throw ReceiverProcessedPackageError.inconsistentMetadata
            }
            return ReceiverAlignmentPolicy.applying(to: bundle)
        }
        let decoder = MANTAJSON.makeDecoder()
        let metadata = try decoder.decode(
            ReceiverProcessedPackageMetadata.self,
            from: Data(contentsOf: root.appendingPathComponent("processed.json")))
        var manifest = try decoder.decode(
            MANTABundleManifest.self,
            from: Data(contentsOf: root.appendingPathComponent(MANTABundleFormat.manifestFilename)))
        let capture = try decoder.decode(
            MANTACaptureDocument.self,
            from: Data(contentsOf: root.appendingPathComponent(manifest.content.capture)))
        let changeLog = try manifest.content.changeLog.map {
            try decoder.decode(
                MANTAChangeLogDocument.self,
                from: Data(contentsOf: root.appendingPathComponent($0)))
        }
        guard metadata.sessionID == manifest.sessionID,
              capture.sessionID == manifest.sessionID else {
            throw ReceiverProcessedPackageError.inconsistentMetadata
        }
        // If the app stopped between atomic per-file writes, the marker is the
        // stable package identity. Normalize the in-memory manifest and let the
        // next edit finish writing it instead of making the working package
        // unrecoverable.
        manifest.bundleID = metadata.processedBundleID
        manifest.parentBundleID = metadata.rawBundleID
        return ReceiverAlignmentPolicy.applying(to: MANTAValidatedBundle(
            rootDirectory: root,
            manifest: manifest,
            capture: capture,
            changeLog: changeLog,
            integrityWarnings: verifyIntegrity
                ? MANTABundleIntegrity.warnings(directory: root, files: manifest.files, progress: progress) : []))
    }

    static func loadElectrodeEvidence(
        from bundle: MANTAValidatedBundle
    ) -> ReceiverElectrodeEvidenceDocument? {
        let preferred = bundle.rootDirectory.appendingPathComponent(electrodeEvidencePath)
        let usesDerivatives = bundle.manifest.content.capture.hasPrefix("derivatives/receiver/")
        let url = usesDerivatives || FileManager.default.fileExists(atPath: preferred.path) ? preferred
            : bundle.rootDirectory.appendingPathComponent("analysis/electrode_evidence.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? MANTAJSON.makeDecoder().decode(
            ReceiverElectrodeEvidenceDocument.self, from: data)
    }

    static func updateReconstruction(
        bundle source: MANTAValidatedBundle,
        preparation: ReceiverReconstructionPreparation,
        run: ReceiverPhotogrammetryRun,
        log: (@Sendable (ReceiverReconstructionLogLevel, String) -> Void)? = nil,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> ReceiverProcessedUpdate {
        let preview = try ReceiverReconstructionWorkflow.makePreview(
            bundle: source, preparation: preparation, run: run,
            progress: progress, log: log)
        var state = try ensurePackage(for: source)
        let modelPath = "derivatives/receiver/reconstruction/macos_\(preparation.detail.rawValue).usdz"
        let diagnosticsPath = "derivatives/receiver/reconstruction/macos_\(preparation.detail.rawValue)_diagnostics.json"
        let posesPath = "derivatives/receiver/reconstruction/macos_poses.json"
        try replaceFile(preparation.modelURL, at: modelPath, in: state.root)
        try replaceFile(preparation.diagnosticsURL, at: diagnosticsPath, in: state.root)
        try replaceFile(preparation.posesURL, at: posesPath, in: state.root)

        var capture = state.bundle.capture
        let invalidatedElectrodes = invalidateElectrodes(in: &state, capture: &capture)
        var reconstruction = capture.reconstruction ?? MANTAReconstructionReference()
        reconstruction.objectCaptureModelPath = modelPath
        reconstruction.modelToWorld = preview.modelToWorld.map(flattened)
        reconstruction.worldCoordinateSystem = "arkit-world"
        capture.reconstruction = reconstruction
        let change = MANTAChangeRecord(
            changedAt: Date(),
            category: "photogrammetry-reconstruction",
            summary: "Generated a macOS \(preparation.detail.rawValue.capitalized) Object Capture model and attempted ARKit-world alignment."
                + (invalidatedElectrodes ? " Invalidated the previous electrode solution." : ""),
            targets: [modelPath, diagnosticsPath, posesPath, "capture.json"])
        let changed = [
            FileDescription(path: modelPath, mediaType: "model/vnd.usdz+zip", role: "photogrammetry-model-macos"),
            FileDescription(path: diagnosticsPath, mediaType: "application/json", role: "reconstruction-diagnostics"),
            FileDescription(path: posesPath, mediaType: "application/json", role: "reconstruction-camera-poses")
        ]
        state.bundle = try commit(state: state, capture: capture, change: change, changedFiles: changed)
        return ReceiverProcessedUpdate(
            bundle: state.bundle,
            packageURL: state.root,
            alignmentRMSMeters: preview.alignmentRMSMeters,
            alignmentAccepted: preview.alignmentAccepted)
    }

    static func updateAlignment(
        bundle source: MANTAValidatedBundle,
        outcome: ReceiverManualAlignmentOutcome,
        ephemeralReconstruction: ReceiverEphemeralReconstruction?
    ) throws -> ReceiverProcessedUpdate {
        var state = try ensurePackage(for: source)
        let diagnosticsPath = "derivatives/receiver/reconstruction/manual_alignment_diagnostics.json"
        try writeJSON(outcome.diagnostics, to: state.root.appendingPathComponent(diagnosticsPath))

        var capture = state.bundle.capture
        let invalidatedElectrodes = invalidateElectrodes(in: &state, capture: &capture)
        var reconstruction = capture.reconstruction ?? MANTAReconstructionReference()
        reconstruction.modelToWorld = flattened(outcome.result.transform)
        reconstruction.worldCoordinateSystem = "arkit-world"
        var changed = [
            FileDescription(path: diagnosticsPath, mediaType: "application/json", role: "manual-alignment-diagnostics")
        ]
        var targets = ["capture.json", diagnosticsPath]
        if let ephemeralReconstruction {
            let modelPath = "derivatives/receiver/reconstruction/macos_\(ephemeralReconstruction.detail.rawValue).usdz"
            let reconstructionDiagnosticsPath = "derivatives/receiver/reconstruction/macos_\(ephemeralReconstruction.detail.rawValue)_diagnostics.json"
            let posesPath = "derivatives/receiver/reconstruction/macos_poses.json"
            try replaceFile(ephemeralReconstruction.modelURL, at: modelPath, in: state.root)
            try replaceFile(ephemeralReconstruction.diagnosticsURL, at: reconstructionDiagnosticsPath, in: state.root)
            try replaceFile(ephemeralReconstruction.posesURL, at: posesPath, in: state.root)
            reconstruction.objectCaptureModelPath = modelPath
            changed += [
                FileDescription(path: modelPath, mediaType: "model/vnd.usdz+zip", role: "photogrammetry-model-macos"),
                FileDescription(path: reconstructionDiagnosticsPath, mediaType: "application/json", role: "reconstruction-diagnostics"),
                FileDescription(path: posesPath, mediaType: "application/json", role: "reconstruction-camera-poses")
            ]
            targets += [modelPath, reconstructionDiagnosticsPath, posesPath]
        }
        capture.reconstruction = reconstruction
        let change = MANTAChangeRecord(
            changedAt: Date(),
            category: "manual-world-alignment",
            summary: outcome.diagnostics.userOverrideAccepted
                ? "Accepted a macOS model-to-world alignment with an explicit plausibility-warning override."
                    + (invalidatedElectrodes ? " Invalidated the previous electrode solution." : "")
                : "Accepted a macOS landmark-guided model-to-world alignment."
                    + (invalidatedElectrodes ? " Invalidated the previous electrode solution." : ""),
            targets: targets)
        state.bundle = try commit(state: state, capture: capture, change: change, changedFiles: changed)
        return ReceiverProcessedUpdate(
            bundle: state.bundle,
            packageURL: state.root,
            alignmentRMSMeters: outcome.result.rmsError.isFinite ? outcome.result.rmsError : nil,
            alignmentAccepted: outcome.diagnostics.accepted || outcome.diagnostics.userOverrideAccepted)
    }

    static func updateFiducials(
        bundle source: MANTAValidatedBundle,
        fiducials: [MANTAFiducialSolution]
    ) throws -> ReceiverProcessedUpdate {
        var state = try ensurePackage(for: source)
        var capture = state.bundle.capture
        capture.fiducials = fiducials
        let change = MANTAChangeRecord(
            changedAt: Date(),
            category: "manual-fiducial-correction",
            summary: "Reviewed and repositioned fiducials on macOS against metric 3D evidence.",
            targets: ["capture.json"])
        state.bundle = try commit(state: state, capture: capture, change: change, changedFiles: [])
        return ReceiverProcessedUpdate(
            bundle: state.bundle, packageURL: state.root,
            alignmentRMSMeters: nil, alignmentAccepted: false)
    }

    /// Saves an edited head bounding box. This only changes what future Fused
    /// Depth builds and LiDAR-crop alignment fallbacks treat as "the head" - it
    /// never touches electrode search, which depends solely on camera poses and
    /// the photogrammetry mesh.
    static func updateHeadBoundingBox(
        bundle source: MANTAValidatedBundle,
        boundingBox: HeadBoundingBox
    ) throws -> ReceiverProcessedUpdate {
        var state = try ensurePackage(for: source)
        var capture = state.bundle.capture
        var reconstruction = capture.reconstruction ?? MANTAReconstructionReference()
        reconstruction.headBoundingBox = boundingBox

        // Regenerate the head-cropped LiDAR mesh from the full-environment mesh
        // using the new box. The crop was previously a fixed file baked once at
        // capture time; widening the box here had no effect on it, only on
        // Fused Depth. Best-effort: if the full mesh is missing or unreadable,
        // leave the existing crop (if any) untouched rather than failing the
        // whole save.
        var changedFiles = [FileDescription]()
        var targets = ["capture.json"]
        if let fullPath = reconstruction.lidarMeshPath {
            let fullURL = state.root.appendingPathComponent(fullPath)
            if let cropped = try? croppedLiDARMesh(fullMeshURL: fullURL, boundingBox: boundingBox),
               !cropped.vertices.isEmpty {
                let croppedPath = "derivatives/receiver/reconstruction/lidar_mesh_head.ply"
                let temporary = FileManager.default.temporaryDirectory
                    .appendingPathComponent("manta-lidar-crop-\(UUID().uuidString).ply")
                do {
                    try ReceiverSurfaceExporter.writeMeshPLY(cropped, to: temporary)
                    try replaceFile(temporary, at: croppedPath, in: state.root)
                    reconstruction.headCroppedLidarMeshPath = croppedPath
                    changedFiles.append(FileDescription(
                        path: croppedPath, mediaType: "application/octet-stream",
                        role: "lidar-head-crop"))
                    targets.append(croppedPath)
                } catch {
                    // Leave the prior crop (if any) in place.
                }
                try? FileManager.default.removeItem(at: temporary)
            }
        }

        capture.reconstruction = reconstruction
        let change = MANTAChangeRecord(
            changedAt: Date(),
            category: "head-bounding-box-edit",
            summary: changedFiles.isEmpty
                ? "Adjusted the head bounding box used for Fused Depth and LiDAR-crop alignment on macOS."
                : "Adjusted the head bounding box and regenerated the LiDAR head crop on macOS.",
            targets: targets)
        state.bundle = try commit(state: state, capture: capture, change: change, changedFiles: changedFiles)
        return ReceiverProcessedUpdate(
            bundle: state.bundle, packageURL: state.root,
            alignmentRMSMeters: nil, alignmentAccepted: false)
    }

    /// Filters the full LiDAR mesh's triangles down to the ones entirely inside
    /// `boundingBox`, remapping vertex indices to stay contiguous. A triangle
    /// with any vertex outside the box is dropped rather than clipped, which
    /// can leave a slightly jagged boundary edge - acceptable for a
    /// visualization/ICP target, not a precision surface.
    private static func croppedLiDARMesh(
        fullMeshURL: URL, boundingBox: HeadBoundingBox
    ) throws -> ReceiverTriangleMesh {
        guard let mesh = try ReceiverPLYMesh(contentsOf: fullMeshURL) else {
            throw ReceiverProcessedPackageError.inconsistentMetadata
        }
        let center = SIMD3<Float>(
            Float(boundingBox.center.x), Float(boundingBox.center.y), Float(boundingBox.center.z))
        let half = SIMD3<Float>(
            Float(boundingBox.widthMeters / 2), Float(boundingBox.heightMeters / 2),
            Float(boundingBox.depthMeters / 2))
        func isInside(_ p: SIMD3<Float>) -> Bool {
            let delta = abs(p - center)
            return delta.x <= half.x && delta.y <= half.y && delta.z <= half.z
        }
        var remap = [Int: UInt32]()
        var vertices = [SIMD3<Float>]()
        var indices = [UInt32]()
        func remappedIndex(_ index: Int) -> UInt32? {
            guard isInside(mesh.points[index]) else { return nil }
            if let existing = remap[index] { return existing }
            let newIndex = UInt32(vertices.count)
            vertices.append(mesh.points[index])
            remap[index] = newIndex
            return newIndex
        }
        for face in stride(from: 0, to: mesh.indices.count, by: 3) {
            guard let a = remappedIndex(Int(mesh.indices[face])),
                  let b = remappedIndex(Int(mesh.indices[face + 1])),
                  let c = remappedIndex(Int(mesh.indices[face + 2])) else { continue }
            indices.append(contentsOf: [a, b, c])
        }
        return ReceiverTriangleMesh(vertices: vertices, indices: indices)
    }

    static func updateElectrodes(
        bundle source: MANTAValidatedBundle,
        electrodes: [MANTAElectrodeSolution],
        evidence: ReceiverElectrodeEvidenceDocument
    ) throws -> ReceiverProcessedUpdate {
        var state = try ensurePackage(for: source)
        let evidenceURL = state.root.appendingPathComponent(electrodeEvidencePath)
        try writeJSON(evidence, to: evidenceURL)
        var capture = state.bundle.capture
        capture.electrodes = electrodes
        let reviewedCount = electrodes.filter { $0.state == "Reviewed" }.count
        let change = MANTAChangeRecord(
            changedAt: Date(),
            category: "electrode-identification",
            summary: "Saved \(electrodes.count) electrode coordinates from macOS OCR, multi-view geometry, and manual review (\(reviewedCount) reviewed).",
            targets: ["capture.json", electrodeEvidencePath])
        state.bundle = try commit(
            state: state, capture: capture, change: change,
            changedFiles: [
                FileDescription(
                    path: electrodeEvidencePath, mediaType: "application/json",
                    role: "electrode-detection-evidence")
            ])
        return ReceiverProcessedUpdate(
            bundle: state.bundle, packageURL: state.root,
            alignmentRMSMeters: nil, alignmentAccepted: false)
    }

    private struct State {
        var root: URL
        var bundle: MANTAValidatedBundle
        var metadata: ReceiverProcessedPackageMetadata
    }

    private struct FileDescription {
        var path: String
        var mediaType: String
        var role: String
    }

    /// Original capture files stay in place. All Receiver writes are scoped to
    /// derivatives/receiver, including migrated legacy PROCESSED edits.
    private static func ensurePackage(for source: MANTAValidatedBundle) throws -> State {
        let root = source.rootDirectory
        for path in ["derivatives", "derivatives/receiver", "derivatives/receiver/reconstruction", "derivatives/receiver/analysis"] {
            let url = root.appendingPathComponent(path)
            if FileManager.default.fileExists(atPath: url.path) {
                let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ReceiverProcessedPackageError.inconsistentMetadata
                }
            }
        }
        if isPackage(root) {
            let loaded = try load(at: root)
            let path = FileManager.default.fileExists(atPath: root.appendingPathComponent(metadataFilename).path)
                ? metadataFilename : "processed.json"
            let metadata = try MANTAJSON.makeDecoder().decode(ReceiverProcessedPackageMetadata.self,
                from: Data(contentsOf: root.appendingPathComponent(path)))
            return State(root: root, bundle: loaded, metadata: metadata)
        }
        let now = Date()
        let metadata = ReceiverProcessedPackageMetadata(processedBundleID: UUID(), rawBundleID: source.manifest.bundleID,
            sessionID: source.manifest.sessionID, createdAt: now, updatedAt: now)
        return State(root: root, bundle: source, metadata: metadata)
    }

    private static func invalidateElectrodes(
        in state: inout State,
        capture: inout MANTACaptureDocument
    ) -> Bool {
        guard !(capture.electrodes ?? []).isEmpty else { return false }
        capture.electrodes = nil
        try? FileManager.default.removeItem(
            at: state.root.appendingPathComponent(electrodeEvidencePath))
        var manifest = state.bundle.manifest
        manifest.files.removeAll { $0.path == electrodeEvidencePath }
        state.bundle = MANTAValidatedBundle(
            rootDirectory: state.bundle.rootDirectory,
            manifest: manifest,
            capture: state.bundle.capture,
            changeLog: state.bundle.changeLog)
        return true
    }

    private static func commit(
        state: State,
        capture: MANTACaptureDocument,
        change: MANTAChangeRecord,
        changedFiles: [FileDescription]
    ) throws -> MANTAValidatedBundle {
        var metadata = state.metadata
        metadata.updatedAt = change.changedAt
        let changes = (state.bundle.changeLog?.changes ?? []) + [change]
        let log = MANTAChangeLogDocument(
            schema: MANTABundleFormat.changeLogSchema,
            bundleID: metadata.processedBundleID,
            parentBundleID: metadata.rawBundleID,
            createdAt: metadata.createdAt,
            producer: producer(),
            changes: changes)

        let capturePath = "derivatives/receiver/capture.json"
        try writeJSON(capture, to: state.root.appendingPathComponent(capturePath))
        try writeJSON(log, to: state.root.appendingPathComponent(logFilename))

        var manifest = state.bundle.manifest
        manifest.bundleID = metadata.processedBundleID
        manifest.parentBundleID = metadata.rawBundleID
        manifest.finalizedAt = change.changedAt
        manifest.producer = producer()
        manifest.content.changeLog = logFilename
        manifest.content.capture = capturePath
        let descriptions = changedFiles + [
            FileDescription(path: capturePath, mediaType: "application/json", role: "capture-metadata"),
            FileDescription(path: logFilename, mediaType: "application/json", role: "change-log")
        ]
        for description in descriptions {
            let entry = lightweightEntry(description, root: state.root)
            manifest.files.removeAll { $0.path == description.path }
            manifest.files.append(entry)
        }
        manifest.files.sort { $0.path < $1.path }
        // Publish the manifest after output files. Each write is atomic, but a
        // multi-file edit is not a transaction; original acquisition is preserved.
        try writeJSON(
            manifest,
            to: state.root.appendingPathComponent("derivatives/receiver/manifest.json"))
        try writeJSON(metadata, to: state.root.appendingPathComponent(metadataFilename))
        return MANTAValidatedBundle(
            rootDirectory: state.root, manifest: manifest,
            capture: capture, changeLog: log)
    }

    private static func replaceFile(_ source: URL, at path: String, in root: URL) throws {
        let fileManager = FileManager.default
        let destination = root.appendingPathComponent(path)
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        try fileManager.copyItem(at: source, to: temporary)
        do {
            if fileManager.fileExists(atPath: destination.path) {
                try? fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw error
        }
    }

    private static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try MANTAJSON.makeEncoder().encode(value).write(to: url, options: .atomic)
    }

    private static func lightweightEntry(
        _ description: FileDescription, root: URL
    ) -> MANTAFileEntry {
        let url = root.appendingPathComponent(description.path)
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return MANTAFileEntry(
            path: description.path, mediaType: description.mediaType,
            role: description.role, size: size, sha256: "")
    }

    private static func flattened(_ matrix: simd_float4x4) -> [Double] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
    }

    private static func producer() -> MANTAProducer {
        let info = Bundle.main.infoDictionary ?? [:]
        return MANTAProducer(
            application: info["CFBundleDisplayName"] as? String ?? "MANTA Receiver",
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            platform: "macOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: "Mac")
    }
}

private enum ReceiverProcessedPackageError: LocalizedError {
    case inconsistentMetadata
    case destinationExists(String)

    var errorDescription: String? {
        switch self {
        case .inconsistentMetadata:
            "The PROCESSED package metadata does not match its capture files."
        case .destinationExists(let path):
            "A non-package item already exists at the PROCESSED path: \(path)"
        }
    }
}

