import Foundation
import MANTACore
import simd

nonisolated struct ReceiverManualImageEvidence: Codable, Sendable {
    var kind: String
    var observationID: UUID
    var rawImagePoint: [Double]
    var worldPoint: [Double]
    var depthMeters: Double
    var confidence: UInt8
    var contributingDepthPixels: Int
}

nonisolated struct ReceiverManualAlignmentRequest: Sendable {
    var strategy: WorldAlignmentStrategy
    var seed: AlignmentSeed
    var sourceLandmarks: [FiducialKind: SIMD3<Float>]
    var targetLandmarks: [FiducialKind: SIMD3<Float>]
    var targetEvidenceCounts: [FiducialKind: Int]
    var targetUsedEvidenceCounts: [FiducialKind: Int]
    var targetMaximumSpreads: [FiducialKind: Float]
    var targetRawMaximumSpreads: [FiducialKind: Float]
    var targetCenterMethods: [FiducialKind: String]
    var imageEvidence: [ReceiverManualImageEvidence]
}

nonisolated struct ReceiverManualAlignmentDiagnostics: Codable, Sendable {
    var strategy: String
    var seed: String
    var solvedAt: Date
    var sourceLandmarks: [String: [Double]]
    var targetLandmarks: [String: [Double]]
    var targetEvidenceCounts: [String: Int]
    var targetUsedEvidenceCounts: [String: Int]
    var targetMaximumSpreadsMeters: [String: Double]
    var targetRawMaximumSpreadsMeters: [String: Double]
    var targetCenterMethods: [String: String]
    var imageEvidence: [ReceiverManualImageEvidence]
    var sourceCloudPoints: Int
    var targetCloudPoints: Int
    var transform: [Double]
    var solverRMSMeters: Double?
    var landmarkRMSMeters: Double?
    var scale: Double
    var iterations: Int
    var accepted: Bool
    var userOverrideAccepted: Bool
    var warnings: [String]
}

nonisolated struct ReceiverManualAlignmentOutcome: Sendable {
    var result: WorldAlignmentResult
    var diagnostics: ReceiverManualAlignmentDiagnostics
}

enum ReceiverManualAlignmentError: LocalizedError {
    case noPhotogrammetry
    case missingLandmarks(String)
    case noSourceCloud
    case noTargetCloud
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .noPhotogrammetry:
            "This bundle has no photogrammetry model to align."
        case .missingLandmarks(let description):
            "Place \(description) before solving this configuration."
        case .noSourceCloud:
            "The photogrammetry model did not yield enough vertices for ICP."
        case .noTargetCloud:
            "No usable LiDAR head surface was found for ICP."
        case .invalidResult:
            "The alignment solver returned a non-finite or implausible transform."
        }
    }
}

nonisolated enum ReceiverManualAlignmentWorkflow {
    static let diagnosticsPath = "reconstruction/manual_alignment_diagnostics.json"

    static func solve(
        bundle: MANTAValidatedBundle,
        request: ReceiverManualAlignmentRequest,
        modelURLOverride: URL? = nil
    ) throws -> ReceiverManualAlignmentOutcome {
        let modelURL: URL
        if let modelURLOverride {
            modelURL = modelURLOverride
        } else if let modelPath = bundle.capture.reconstruction?.objectCaptureModelPath {
            modelURL = bundle.rootDirectory.appendingPathComponent(modelPath)
        } else {
            throw ReceiverManualAlignmentError.noPhotogrammetry
        }
        let orderedKinds = FiducialKind.allCases
        let sourceLandmarks = orderedKinds.compactMap { request.sourceLandmarks[$0] }
        let targetLandmarks = orderedKinds.compactMap { request.targetLandmarks[$0] }
        let hasAllPairs = sourceLandmarks.count == orderedKinds.count
            && targetLandmarks.count == orderedKinds.count

        if request.strategy != .icp || request.seed == .landmarks, !hasAllPairs {
            throw ReceiverManualAlignmentError.missingLandmarks(
                "Nasion, LPA, and RPA on both the images and model")
        }

        var input = WorldAlignmentInput()
        input.seed = request.seed
        if hasAllPairs {
            input.sourceLandmarks = orderedKinds.map { request.sourceLandmarks[$0]! }
            input.targetLandmarks = orderedKinds.map { request.targetLandmarks[$0]! }
        }

        var sourceCloud = [SIMD3<Float>]()
        var targetCloud = [SIMD3<Float>]()
        if request.strategy == .icp {
            sourceCloud = ModelPointCloudLoader.load(
                url: modelURL, maxPoints: 2_500)
            targetCloud = alignmentTarget(bundle: bundle, maxPoints: 2_500)
            guard sourceCloud.count >= 100 else { throw ReceiverManualAlignmentError.noSourceCloud }
            guard targetCloud.count >= 100 else { throw ReceiverManualAlignmentError.noTargetCloud }
            input.sourceCloud = sourceCloud
            input.targetCloud = targetCloud
            input.icpMaxIterations = 25
            input.icpTolerance = 2e-5
        } else if request.strategy == .depthAssisted {
            input.metricScaleHint = scaleHint(
                source: input.sourceLandmarks, target: input.targetLandmarks)
        }

        let result = WorldAlignmentSolver.solve(strategy: request.strategy, input: input)
        let matrixValues = flattened(result.transform)
        guard matrixValues.allSatisfy(\.isFinite) else {
            throw ReceiverManualAlignmentError.invalidResult
        }

        let axisScales = [
            simd_length(SIMD3(result.transform.columns.0.x, result.transform.columns.0.y, result.transform.columns.0.z)),
            simd_length(SIMD3(result.transform.columns.1.x, result.transform.columns.1.y, result.transform.columns.1.z)),
            simd_length(SIMD3(result.transform.columns.2.x, result.transform.columns.2.y, result.transform.columns.2.z))
        ]
        let scale = axisScales.reduce(0, +) / 3
        guard scale.isFinite, scale > 0.001, scale < 1_000 else {
            throw ReceiverManualAlignmentError.invalidResult
        }

        let landmarkRMS = hasAllPairs
            ? rms(transform: result.transform, source: input.sourceLandmarks, target: input.targetLandmarks)
            : nil
        var warnings = [String]()
        if let landmarkRMS, landmarkRMS > 0.015 {
            warnings.append(String(format: "Landmark residual is %.1f mm.", landmarkRMS * 1_000))
        }
        let largestSpread = request.targetMaximumSpreads.values.max() ?? 0
        if largestSpread > 0.015 {
            warnings.append(String(format: "Retained image placements differ from their fitted centers by up to %.1f mm.", largestSpread * 1_000))
        }
        var hasUnresolvedRepeatDisagreement = false
        for kind in orderedKinds {
            let total = request.targetEvidenceCounts[kind] ?? 0
            let used = request.targetUsedEvidenceCounts[kind] ?? total
            let rawSpread = request.targetRawMaximumSpreads[kind] ?? 0
            if total > used {
                warnings.append(String(
                    format: "%@: fitted %@ using %d of %d clicks; %d outlier(s) were ignored (raw spread %.1f mm).",
                    kind.rawValue,
                    request.targetCenterMethods[kind] ?? "robust center",
                    used, total, total - used, rawSpread * 1_000))
            }
            if total > 1, used < 2 {
                hasUnresolvedRepeatDisagreement = true
                warnings.append(
                    "\(kind.rawValue): no two repeated image clicks agree within 25 mm.")
            }
        }
        if request.strategy == .icp, request.seed != .landmarks {
            warnings.append("Unseeded surface alignment can converge to the wrong side of a roughly symmetric head.")
        }
        if request.strategy == .icp, result.rmsError.isFinite, result.rmsError > 0.04 {
            warnings.append(String(format: "Surface residual is %.1f mm.", result.rmsError * 1_000))
        }

        let accepted: Bool
        if let landmarkRMS {
            accepted = landmarkRMS <= 0.025 && largestSpread <= 0.025
                && !hasUnresolvedRepeatDisagreement
                && (!result.rmsError.isFinite || request.strategy != .icp || result.rmsError <= 0.06)
        } else {
            accepted = result.rmsError.isFinite && result.rmsError <= 0.04
        }
        let diagnostics = ReceiverManualAlignmentDiagnostics(
            strategy: request.strategy.rawValue,
            seed: request.seed.rawValue,
            solvedAt: Date(),
            sourceLandmarks: encoded(request.sourceLandmarks),
            targetLandmarks: encoded(request.targetLandmarks),
            targetEvidenceCounts: Dictionary(uniqueKeysWithValues: request.targetEvidenceCounts.map {
                ($0.key.rawValue, $0.value)
            }),
            targetUsedEvidenceCounts: Dictionary(uniqueKeysWithValues: request.targetUsedEvidenceCounts.map {
                ($0.key.rawValue, $0.value)
            }),
            targetMaximumSpreadsMeters: Dictionary(uniqueKeysWithValues: request.targetMaximumSpreads.map {
                ($0.key.rawValue, Double($0.value))
            }),
            targetRawMaximumSpreadsMeters: Dictionary(uniqueKeysWithValues: request.targetRawMaximumSpreads.map {
                ($0.key.rawValue, Double($0.value))
            }),
            targetCenterMethods: Dictionary(uniqueKeysWithValues: request.targetCenterMethods.map {
                ($0.key.rawValue, $0.value)
            }),
            imageEvidence: request.imageEvidence,
            sourceCloudPoints: sourceCloud.count,
            targetCloudPoints: targetCloud.count,
            transform: matrixValues,
            solverRMSMeters: result.rmsError.isFinite ? Double(result.rmsError) : nil,
            landmarkRMSMeters: landmarkRMS.map(Double.init),
            scale: Double(scale),
            iterations: result.iterations,
            accepted: accepted,
            userOverrideAccepted: false,
            warnings: warnings)
        return ReceiverManualAlignmentOutcome(result: result, diagnostics: diagnostics)
    }

    static func finalize(
        bundle: MANTAValidatedBundle,
        outcome: ReceiverManualAlignmentOutcome,
        ephemeralReconstruction: ReceiverEphemeralReconstruction? = nil
    ) throws -> URL {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("manta-alignment-\(UUID().uuidString.lowercased())", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let diagnosticsURL = workspace.appendingPathComponent("manual_alignment_diagnostics.json")
        try MANTAJSON.makeEncoder().encode(outcome.diagnostics).write(to: diagnosticsURL, options: .atomic)

        var capture = bundle.capture
        var reconstruction = capture.reconstruction ?? MANTAReconstructionReference()
        reconstruction.modelToWorld = flattened(outcome.result.transform)
        reconstruction.worldCoordinateSystem = "arkit-world"
        let ephemeralModelPath = ephemeralReconstruction.map {
            "reconstruction/macos_\($0.detail.rawValue).usdz"
        }
        let ephemeralDiagnosticsPath = ephemeralReconstruction.map {
            "reconstruction/macos_\($0.detail.rawValue)_diagnostics.json"
        }
        let ephemeralPosesPath = ephemeralReconstruction.map { _ in
            "reconstruction/macos_poses.json"
        }
        if let ephemeralModelPath {
            reconstruction.objectCaptureModelPath = ephemeralModelPath
        }
        capture.reconstruction = reconstruction

        let replacementPaths = Set(
            [diagnosticsPath, ephemeralModelPath, ephemeralDiagnosticsPath, ephemeralPosesPath]
                .compactMap { $0 })
        var files = bundle.manifest.files.compactMap { entry -> MANTABundleFileSource? in
            guard entry.path != bundle.manifest.content.capture,
                  entry.path != bundle.manifest.content.changeLog,
                  !replacementPaths.contains(entry.path) else { return nil }
            return MANTABundleFileSource(
                path: entry.path,
                sourceURL: bundle.rootDirectory.appendingPathComponent(entry.path),
                mediaType: entry.mediaType,
                role: entry.role)
        }
        files.append(MANTABundleFileSource(
            path: diagnosticsPath,
            sourceURL: diagnosticsURL,
            mediaType: "application/json",
            role: "manual-alignment-diagnostics"))
        if let ephemeralReconstruction,
           let ephemeralModelPath,
           let ephemeralDiagnosticsPath,
           let ephemeralPosesPath {
            files.append(MANTABundleFileSource(
                path: ephemeralModelPath,
                sourceURL: ephemeralReconstruction.modelURL,
                mediaType: "model/vnd.usdz+zip",
                role: "photogrammetry-model-macos"))
            files.append(MANTABundleFileSource(
                path: ephemeralDiagnosticsPath,
                sourceURL: ephemeralReconstruction.diagnosticsURL,
                mediaType: "application/json",
                role: "reconstruction-diagnostics"))
            files.append(MANTABundleFileSource(
                path: ephemeralPosesPath,
                sourceURL: ephemeralReconstruction.posesURL,
                mediaType: "application/json",
                role: "reconstruction-camera-poses"))
        }

        let payloadBytes = files.reduce(Int64(0)) { partial, file in
            partial + Int64((try? file.sourceURL.resourceValues(
                forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let classicZIPPayloadLimit: Int64 = 3_950_000_000
        guard payloadBytes <= classicZIPPayloadLimit else {
            throw ReceiverReconstructionError.archiveTooLarge(payloadBytes)
        }

        let now = Date()
        var changeTargets = ["capture.json", diagnosticsPath]
        changeTargets.append(contentsOf: [
            ephemeralModelPath, ephemeralDiagnosticsPath, ephemeralPosesPath
        ].compactMap { $0 })
        let change = MANTAChangeRecord(
            changedAt: now,
            category: "manual-world-alignment",
            summary: outcome.diagnostics.userOverrideAccepted
                ? "Accepted a macOS landmark-guided \(outcome.diagnostics.strategy) model-to-world alignment with an explicit plausibility-warning override."
                : ephemeralReconstruction == nil
                    ? "Accepted a macOS landmark-guided \(outcome.diagnostics.strategy) model-to-world alignment."
                    : "Force-saved the session preview model with an accepted macOS landmark-guided \(outcome.diagnostics.strategy) model-to-world alignment.",
            targets: changeTargets)
        let revision = ReceiverProcessedBundlePolicy.revision(
            of: bundle, appending: change)
        let request = MANTABundleFinalizationRequest(
            capture: capture,
            producer: producer(),
            createdAt: bundle.manifest.createdAt,
            finalizedAt: now,
            bundleID: revision.bundleID,
            parentBundleID: revision.rawParentBundleID,
            changes: revision.changes,
            files: files,
            layoutPath: bundle.manifest.content.layout,
            filenameTag: "processed-staging")
        return try MANTABundleFinalizer().finalize(
            request, in: try derivedOutputDirectory()).archiveURL
    }

    private static func alignmentTarget(
        bundle: MANTAValidatedBundle, maxPoints: Int
    ) -> [SIMD3<Float>] {
        guard let reconstruction = bundle.capture.reconstruction,
              let path = reconstruction.headCroppedLidarMeshPath ?? reconstruction.lidarMeshPath else {
            return []
        }
        var points = ModelPointCloudLoader.load(
            url: bundle.rootDirectory.appendingPathComponent(path), maxPoints: maxPoints)
        if reconstruction.headCroppedLidarMeshPath == nil,
           let bounds = reconstruction.headBoundingBox {
            let center = SIMD3<Float>(
                Float(bounds.center.x), Float(bounds.center.y), Float(bounds.center.z))
            let half = SIMD3<Float>(
                Float(bounds.widthMeters / 2), Float(bounds.heightMeters / 2),
                Float(bounds.depthMeters / 2))
            points = points.filter {
                let delta = abs($0 - center)
                return delta.x <= half.x && delta.y <= half.y && delta.z <= half.z
            }
        }
        return points
    }

    private static func scaleHint(
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> Float? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        var ratios = [Float]()
        for i in 0..<(source.count - 1) {
            for j in (i + 1)..<source.count {
                let a = simd_distance(source[i], source[j])
                let b = simd_distance(target[i], target[j])
                if a > 1e-6, b.isFinite { ratios.append(b / a) }
            }
        }
        return ratios.sorted().dropFirst(ratios.count / 2).first
    }

    private static func rms(
        transform: simd_float4x4,
        source: [SIMD3<Float>],
        target: [SIMD3<Float>]
    ) -> Float {
        let sum = zip(source, target).reduce(Float.zero) { partial, pair in
            let moved = transform * SIMD4<Float>(pair.0, 1)
            return partial + simd_length_squared(SIMD3(moved.x, moved.y, moved.z) - pair.1)
        }
        return (sum / Float(source.count)).squareRoot()
    }

    private static func encoded(
        _ values: [FiducialKind: SIMD3<Float>]
    ) -> [String: [Double]] {
        Dictionary(uniqueKeysWithValues: values.map {
            ($0.key.rawValue, [Double($0.value.x), Double($0.value.y), Double($0.value.z)])
        })
    }

    private static func flattened(_ matrix: simd_float4x4) -> [Double] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
    }

    private static func derivedOutputDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("MANTA Receiver", isDirectory: true)
            .appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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

/// Writes reviewed world-space fiducials as a lineage-linked solved child. The
/// imported/raw bundle remains immutable and its original placement evidence is
/// retained alongside these reviewed coordinates.
nonisolated enum ReceiverFiducialCorrectionWorkflow {
    static func finalize(
        bundle: MANTAValidatedBundle,
        fiducials: [MANTAFiducialSolution]
    ) throws -> URL {
        var capture = bundle.capture
        capture.fiducials = fiducials

        let files = bundle.manifest.files.compactMap { entry -> MANTABundleFileSource? in
            guard entry.path != bundle.manifest.content.capture,
                  entry.path != bundle.manifest.content.changeLog else { return nil }
            return MANTABundleFileSource(
                path: entry.path,
                sourceURL: bundle.rootDirectory.appendingPathComponent(entry.path),
                mediaType: entry.mediaType,
                role: entry.role)
        }
        let now = Date()
        let change = MANTAChangeRecord(
            changedAt: now,
            category: "manual-fiducial-correction",
            summary: "Reviewed and repositioned fiducials on macOS against metric 3D evidence.",
            targets: ["capture.json"])
        let revision = ReceiverProcessedBundlePolicy.revision(
            of: bundle, appending: change)
        let request = MANTABundleFinalizationRequest(
            capture: capture,
            producer: producer(),
            createdAt: bundle.manifest.createdAt,
            finalizedAt: now,
            bundleID: revision.bundleID,
            parentBundleID: revision.rawParentBundleID,
            changes: revision.changes,
            files: files,
            layoutPath: bundle.manifest.content.layout,
            filenameTag: "processed-staging")
        return try MANTABundleFinalizer().finalize(
            request, in: try derivedOutputDirectory()).archiveURL
    }

    private static func derivedOutputDirectory() throws -> URL {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("MANTA Receiver", isDirectory: true)
            .appendingPathComponent("Derived", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
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
