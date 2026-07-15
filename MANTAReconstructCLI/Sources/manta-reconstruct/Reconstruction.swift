import Foundation
import MANTACore
import RealityKit
import simd

// Photogrammetry reconstruction driver, ported from the MANTA receiver's
// ReceiverPhotogrammetryReconstruction so it can run from the command line.
// It depends only on Foundation / RealityKit / simd / MANTACore — no SwiftUI —
// so the same Object Capture pipeline the app uses is reproduced here.

enum ReconstructionLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
    case success
}

enum PhotogrammetryDetail: String, CaseIterable, Identifiable, Sendable {
    case medium
    case full
    case raw

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var requestDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .medium: .medium
        case .full: .full
        case .raw: .raw
        }
    }

    func conservativeWorkingBytes(sourceImageBytes: Int64) -> Int64 {
        switch self {
        case .medium: max(2_000_000_000, sourceImageBytes * 2)
        case .full: max(5_000_000_000, sourceImageBytes * 4)
        case .raw: max(20_000_000_000, sourceImageBytes * 12)
        }
    }
}

struct ReconstructionEstimate: Sendable {
    var imageCount: Int
    var sourceImageBytes: Int64
    var requiredWorkingBytes: Int64
    var availableBytes: Int64?

    var hasEnoughSpace: Bool {
        guard let availableBytes else { return true }
        return availableBytes >= requiredWorkingBytes
    }
}

struct ReconstructionPreparation: Sendable {
    var workspace: URL
    var inputDirectory: URL
    var modelURL: URL
    var posesURL: URL
    var diagnosticsURL: URL
    var detail: PhotogrammetryDetail
    var imageCount: Int
    var sourceImageBytes: Int64
}

struct PhotogrammetryRun: Sendable {
    var startedAt: Date
    var completedAt: Date
    var skippedSampleIDs: [String]
    var automaticDownsampling: Bool
}

struct EphemeralReconstruction: Sendable {
    var modelURL: URL
    var posesURL: URL
    var diagnosticsURL: URL
    var detail: PhotogrammetryDetail
    var modelToWorld: simd_float4x4?
    var alignmentRMSMeters: Float?
    var alignmentAccepted: Bool
}

struct MacReconstructionDiagnostics: Codable, Sendable {
    var detail: String
    var inputImageCount: Int
    var sourceImageBytes: Int64
    var startedAt: Date
    var completedAt: Date
    var elapsedSeconds: Double
    var skippedSampleIDs: [String]
    var automaticDownsampling: Bool
    var modelBytes: Int64
    var alignmentSourcePoints: Int
    var alignmentTargetPoints: Int
    var alignmentRMSMeters: Float?
    var alignmentScale: Float?
    var alignmentSymmetricRMSMeters: Float?
    var alignmentAccepted: Bool
    var alignmentMethod: String
}

enum ReconstructionError: LocalizedError {
    case unsupported
    case noImages
    case insufficientStorage(required: Int64, available: Int64)
    case processing(String)
    case cancelled
    case missingOutput

    var errorDescription: String? {
        switch self {
        case .unsupported:
            "Object Capture is not supported on this Mac."
        case .noImages:
            "The capture contains no source RGB images for photogrammetry."
        case .insufficientStorage(let required, let available):
            "Reconstruction needs approximately \(Self.bytes(required)) free; \(Self.bytes(available)) is available."
        case .processing(let message):
            "macOS photogrammetry failed: \(message)"
        case .cancelled:
            "Reconstruction was cancelled."
        case .missingOutput:
            "Object Capture completed without producing the requested model."
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

final class PhotogrammetryRunner {
    private var session: PhotogrammetrySession?

    var isSupported: Bool { PhotogrammetrySession.isSupported }

    func cancel() {
        session?.cancel()
    }

    func reconstruct(
        preparation: ReconstructionPreparation,
        progress: @escaping (Double, String) -> Void,
        log: @escaping (ReconstructionLogLevel, String) -> Void
    ) async throws -> PhotogrammetryRun {
        guard PhotogrammetrySession.isSupported else {
            throw ReconstructionError.unsupported
        }
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        let active = try PhotogrammetrySession(
            input: preparation.inputDirectory, configuration: configuration)
        session = active
        defer { session = nil }

        let request = PhotogrammetrySession.Request.modelFile(
            url: preparation.modelURL,
            detail: preparation.detail.requestDetail)
        let startedAt = Date()
        var skipped = [String]()
        var automaticDownsampling = false
        var currentProgress = 0.0
        progress(0, "Starting Object Capture")
        log(.info, "Object Capture started with \(preparation.imageCount) input images at \(preparation.detail.title) detail.")
        try active.process(requests: [request])

        do {
            for try await output in active.outputs {
                if Task.isCancelled {
                    active.cancel()
                    throw ReconstructionError.cancelled
                }
                switch output {
                case .requestProgress(_, let fraction):
                    currentProgress = fraction
                    progress(fraction, "Reconstructing \(preparation.detail.title) model")
                case .skippedSample(let id):
                    let sample = String(describing: id)
                    skipped.append(sample)
                    log(.warning, "Object Capture skipped input sample \(sample).")
                case .automaticDownsampling:
                    automaticDownsampling = true
                    log(.warning, "Object Capture enabled automatic image downsampling.")
                case .requestError(_, let error):
                    log(.error, "Object Capture request failed: \(error.localizedDescription)")
                    throw ReconstructionError.processing(error.localizedDescription)
                case .processingCancelled:
                    log(.warning, "Object Capture reported cancellation at \(Int(currentProgress * 100))%.")
                    throw ReconstructionError.cancelled
                case .processingComplete:
                    guard FileManager.default.fileExists(atPath: preparation.modelURL.path) else {
                        log(.error, "Object Capture completed but did not produce a model file.")
                        throw ReconstructionError.missingOutput
                    }
                    log(.success, "Object Capture model generation completed.")
                    return PhotogrammetryRun(
                        startedAt: startedAt,
                        completedAt: Date(),
                        skippedSampleIDs: skipped,
                        automaticDownsampling: automaticDownsampling)
                default:
                    continue
                }
            }
        } catch is CancellationError {
            throw ReconstructionError.cancelled
        }
        throw ReconstructionError.missingOutput
    }
}

enum ReconstructionWorkflow {
    private struct PoseRecord: Codable {
        var imageFilename: String
        var observationID: UUID
        var cameraToWorld: [Double]
        var intrinsics: [Double]
        var imageOrientation: String
    }

    static func estimate(
        bundle: MANTAValidatedBundle,
        detail: PhotogrammetryDetail
    ) -> ReconstructionEstimate {
        let sources = imageSources(bundle: bundle)
        let bytes = sources.reduce(Int64(0)) { partial, item in
            partial + Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let available = try? bundle.rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return ReconstructionEstimate(
            imageCount: sources.count,
            sourceImageBytes: bytes,
            requiredWorkingBytes: detail.conservativeWorkingBytes(sourceImageBytes: bytes),
            availableBytes: available ?? nil)
    }

    static func prepare(
        bundle: MANTAValidatedBundle,
        detail: PhotogrammetryDetail
    ) throws -> ReconstructionPreparation {
        let estimate = estimate(bundle: bundle, detail: detail)
        guard estimate.imageCount > 0 else { throw ReconstructionError.noImages }
        if let available = estimate.availableBytes, !estimate.hasEnoughSpace {
            throw ReconstructionError.insufficientStorage(
                required: estimate.requiredWorkingBytes, available: available)
        }

        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let workspace = support
            .appendingPathComponent("MANTA Reconstruct CLI", isDirectory: true)
            .appendingPathComponent("Reconstruction Workspaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let input = workspace.appendingPathComponent("Input", isDirectory: true)
        try fileManager.createDirectory(at: input, withIntermediateDirectories: true)

        var poses = [PoseRecord]()
        do {
            for item in imageSources(bundle: bundle) {
                let extensionName = item.url.pathExtension.lowercased()
                let filename = "\(item.observation.id.uuidString.lowercased()).\(extensionName)"
                let destination = input.appendingPathComponent(filename)
                do {
                    try fileManager.linkItem(at: item.url, to: destination)
                } catch {
                    try fileManager.copyItem(at: item.url, to: destination)
                }
                poses.append(PoseRecord(
                    imageFilename: filename,
                    observationID: item.observation.id,
                    cameraToWorld: item.observation.cameraToWorld,
                    intrinsics: item.observation.intrinsics,
                    imageOrientation: item.observation.imageOrientation))
            }
            let posesURL = workspace.appendingPathComponent("macos-poses.json")
            let encoder = MANTAJSON.makeEncoder()
            try encoder.encode(poses).write(to: posesURL, options: .atomic)
            let stem = "macos_\(detail.rawValue)"
            return ReconstructionPreparation(
                workspace: workspace,
                inputDirectory: input,
                modelURL: workspace.appendingPathComponent("\(stem).usdz"),
                posesURL: posesURL,
                diagnosticsURL: workspace.appendingPathComponent("\(stem)_diagnostics.json"),
                detail: detail,
                imageCount: poses.count,
                sourceImageBytes: estimate.sourceImageBytes)
        } catch {
            try? fileManager.removeItem(at: workspace)
            throw error
        }
    }

    static func makePreview(
        bundle: MANTAValidatedBundle,
        preparation: ReconstructionPreparation,
        run: PhotogrammetryRun,
        progress: ((Double, String) -> Void)? = nil,
        log: ((ReconstructionLogLevel, String) -> Void)? = nil
    ) throws -> EphemeralReconstruction {
        progress?(0.01, "Loading reconstruction geometry")
        let source = ModelPointCloudLoader.load(url: preparation.modelURL, maxPoints: 8_000)
        let target = alignmentTarget(bundle: bundle, maxPoints: 8_000)
        log?(.info, "Loaded \(source.count) photogrammetry alignment points.")
        log?(.info, "Loaded \(target.count) LiDAR/fused-depth alignment target points.")
        var alignment: WorldAlignmentResult?
        if source.count >= 100, target.count >= 100 {
            var input = WorldAlignmentInput()
            input.seed = .coarsePCA
            input.sourceCloud = source
            input.targetCloud = target
            input.icpMaxIterations = 40
            alignment = WorldAlignmentSolver.solve(strategy: .icp, input: input)
        } else {
            if source.count < 100 {
                log?(.warning, "Photogrammetry model supplied only \(source.count) usable points; at least 100 are required for automatic alignment.")
            }
            if target.count < 100 {
                log?(.warning, "Only \(target.count) usable LiDAR/fused-depth points were found; at least 100 are required for automatic alignment.")
            }
        }
        let alignmentScale = alignment.map { uniformScale($0.transform) }
        let symmetricRMS = alignment.map {
            bidirectionalRMS(
                transform: $0.transform, source: source, target: target,
                maximumPointsPerDirection: 800)
        }
        // A one-way source-to-target RMS rewards degenerate scale collapse: a
        // tiny model near the target centroid can be close to some target points
        // while explaining almost none of the target surface. Require both
        // directions to agree before declaring an automatic alignment usable.
        let alignmentAccepted = symmetricRMS?.isFinite == true
            && (symmetricRMS ?? .greatestFiniteMagnitude) <= 0.05
        if let symmetricRMS, symmetricRMS.isFinite {
            log?(
                alignmentAccepted ? .success : .warning,
                String(
                    format: "Automatic alignment symmetric RMS: %.1f mm%@.",
                    symmetricRMS * 1_000,
                    alignmentAccepted ? " (accepted)" : " (not accepted)"))
        } else {
            log?(.warning, "Automatic alignment did not produce a finite RMS value.")
        }

        let modelBytes = Int64((try? preparation.modelURL.resourceValues(
            forKeys: [.fileSizeKey]).fileSize) ?? 0)
        let diagnostics = MacReconstructionDiagnostics(
            detail: preparation.detail.rawValue,
            inputImageCount: preparation.imageCount,
            sourceImageBytes: preparation.sourceImageBytes,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            elapsedSeconds: run.completedAt.timeIntervalSince(run.startedAt),
            skippedSampleIDs: run.skippedSampleIDs,
            automaticDownsampling: run.automaticDownsampling,
            modelBytes: modelBytes,
            alignmentSourcePoints: source.count,
            alignmentTargetPoints: target.count,
            alignmentRMSMeters: symmetricRMS?.isFinite == true ? symmetricRMS : nil,
            alignmentScale: alignmentScale,
            alignmentSymmetricRMSMeters: symmetricRMS?.isFinite == true ? symmetricRMS : nil,
            alignmentAccepted: alignmentAccepted,
            alignmentMethod: "scale-locked-coarse-pca-seeded-symmetric-icp")
        try MANTAJSON.makeEncoder().encode(diagnostics).write(
            to: preparation.diagnosticsURL, options: .atomic)
        log?(.info, "Wrote reconstruction diagnostics.")
        return EphemeralReconstruction(
            modelURL: preparation.modelURL,
            posesURL: preparation.posesURL,
            diagnosticsURL: preparation.diagnosticsURL,
            detail: preparation.detail,
            modelToWorld: alignmentAccepted ? alignment?.transform : nil,
            alignmentRMSMeters: diagnostics.alignmentRMSMeters,
            alignmentAccepted: alignmentAccepted)
    }

    static func removeWorkspace(_ preparation: ReconstructionPreparation) {
        try? FileManager.default.removeItem(at: preparation.workspace)
    }

    private static func imageSources(
        bundle: MANTAValidatedBundle
    ) -> [(observation: MANTACaptureObservation, url: URL)] {
        bundle.capture.observations.compactMap { observation in
            guard let path = observation.losslessImagePath ?? observation.imagePath else { return nil }
            let url = bundle.rootDirectory.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path),
                  ["png", "heic", "jpg", "jpeg"].contains(url.pathExtension.lowercased()) else {
                return nil
            }
            return (observation, url)
        }
    }

    private static func alignmentTarget(
        bundle: MANTAValidatedBundle, maxPoints: Int
    ) -> [SIMD3<Float>] {
        guard let reconstruction = bundle.capture.reconstruction,
              let path = reconstruction.headCroppedLidarMeshPath
                ?? reconstruction.lidarMeshPath else { return [] }
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

    private static func uniformScale(_ transform: simd_float4x4) -> Float {
        let axes = [transform.columns.0, transform.columns.1, transform.columns.2]
        return axes.reduce(Float.zero) { partial, column in
            partial + simd_length(SIMD3(column.x, column.y, column.z))
        } / 3
    }

    private static func bidirectionalRMS(
        transform: simd_float4x4,
        source: [SIMD3<Float>],
        target: [SIMD3<Float>],
        maximumPointsPerDirection: Int
    ) -> Float {
        let moved = sampled(source, maximum: maximumPointsPerDirection).map { point -> SIMD3<Float> in
            let value = transform * SIMD4<Float>(point, 1)
            return SIMD3(value.x, value.y, value.z)
        }
        let sampledTarget = sampled(target, maximum: maximumPointsPerDirection)
        guard !moved.isEmpty, !sampledTarget.isEmpty else { return .nan }
        let forward = nearestNeighborRMS(source: moved, target: sampledTarget)
        let reverse = nearestNeighborRMS(source: sampledTarget, target: moved)
        return max(forward, reverse)
    }

    private static func sampled(
        _ points: [SIMD3<Float>], maximum: Int
    ) -> [SIMD3<Float>] {
        guard points.count > maximum else { return points }
        let step = Double(points.count) / Double(maximum)
        return (0..<maximum).map { points[min(points.count - 1, Int(Double($0) * step))] }
    }

    private static func nearestNeighborRMS(
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> Float {
        let sum = source.reduce(Float.zero) { partial, point in
            let nearest = target.reduce(Float.greatestFiniteMagnitude) {
                min($0, simd_length_squared($1 - point))
            }
            return partial + nearest
        }
        return (sum / Float(source.count)).squareRoot()
    }
}
