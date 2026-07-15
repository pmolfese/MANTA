import Foundation
import MANTACore
import RealityKit
import simd

enum ReceiverReconstructionOutputMode: String, CaseIterable, Identifiable, Sendable {
    case preview = "Preview in App"
    case derivedBundle = "Save / Update PROCESSED"
    var id: String { rawValue }
}

/// How the images are handed to Object Capture. `imagesOnly` feeds a folder of
/// RGB images and lets `PhotogrammetrySession` solve its own arbitrary-scale
/// structure-from-motion. `depthGuided` instead feeds `PhotogrammetrySample`s
/// carrying each frame's LiDAR depth (which gives the reconstruction real metric
/// scale) and a per-frame gravity vector derived from the stored camera pose.
enum ReceiverPhotogrammetryInputMode: String, CaseIterable, Identifiable, Sendable {
    case imagesOnly = "Images only"
    case depthGuided = "Depth-guided"

    var id: String { rawValue }
    var title: String { rawValue }
    var usesDepth: Bool { self == .depthGuided }

    var explanation: String {
        switch self {
        case .imagesOnly:
            return "Object Capture solves geometry from the RGB images alone. The model comes out in an arbitrary scale and pose that the Align step must recover."
        case .depthGuided:
            return "Feeds each frame's LiDAR depth and a gravity vector to Object Capture, so the model comes out metric and gravity-oriented. Needs frames with saved depth."
        }
    }
}

/// One frame's inputs for a depth-guided `PhotogrammetrySample`, resolved to
/// workspace-local file URLs so the runner never has to reach back into the
/// bundle. `depthURL` is nil when a frame has no usable depth; that frame still
/// contributes its RGB image and gravity.
struct ReceiverReconstructionSampleDescriptor: Sendable {
    var sampleID: Int
    var imageURL: URL
    var depthURL: URL?
    var depthWidth: Int
    var depthHeight: Int
    var depthCompression: String
    var cameraToWorld: [Double]
}

enum ReceiverReconstructionLogLevel: String, Codable, Sendable {
    case info
    case warning
    case error
    case success
}

struct ReceiverReconstructionLogEntry: Identifiable, Sendable {
    var id = UUID()
    var timestamp = Date()
    var level: ReceiverReconstructionLogLevel
    var message: String
}

enum ReceiverPhotogrammetryDetail: String, CaseIterable, Identifiable, Sendable {
    case medium
    case full
    case raw

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var explanation: String {
        switch self {
        case .medium: "Moderate geometry and memory use; useful for a quick Mac reconstruction."
        case .full: "High-detail reconstruction suitable for analysis and interactive inspection."
        case .raw: "Maximum recovered geometry; very large and intended for offline processing."
        }
    }

    fileprivate var requestDetail: PhotogrammetrySession.Request.Detail {
        switch self {
        case .medium: .medium
        case .full: .full
        case .raw: .raw
        }
    }

    fileprivate func conservativeWorkingBytes(sourceImageBytes: Int64) -> Int64 {
        switch self {
        case .medium: max(2_000_000_000, sourceImageBytes * 2)
        case .full: max(5_000_000_000, sourceImageBytes * 4)
        case .raw: max(20_000_000_000, sourceImageBytes * 12)
        }
    }
}

struct ReceiverReconstructionEstimate: Sendable {
    var imageCount: Int
    var sourceImageBytes: Int64
    var requiredWorkingBytes: Int64
    var availableBytes: Int64?

    var hasEnoughSpace: Bool {
        guard let availableBytes else { return true }
        return availableBytes >= requiredWorkingBytes
    }
}

struct ReceiverReconstructionPreparation: Sendable {
    var workspace: URL
    var inputDirectory: URL
    var modelURL: URL
    var posesURL: URL
    var diagnosticsURL: URL
    var detail: ReceiverPhotogrammetryDetail
    var imageCount: Int
    var sourceImageBytes: Int64
    var inputMode: ReceiverPhotogrammetryInputMode = .imagesOnly
    /// Populated only for `depthGuided`; empty otherwise.
    var sampleDescriptors: [ReceiverReconstructionSampleDescriptor] = []
}

struct ReceiverPhotogrammetryRun: Sendable {
    var startedAt: Date
    var completedAt: Date
    var skippedSampleIDs: [String]
    var automaticDownsampling: Bool
}

struct ReceiverDerivedReconstruction: Sendable {
    var archiveURL: URL
    var alignmentRMSMeters: Float?
    var alignmentAccepted: Bool
}

/// Session-scoped Object Capture output. Object Capture requires a destination
/// URL, so this lives in a temporary workspace rather than literally in RAM.
/// The Receiver owns and deletes that workspace when the preview is replaced.
struct ReceiverEphemeralReconstruction: Sendable {
    var modelURL: URL
    var posesURL: URL
    var diagnosticsURL: URL
    var detail: ReceiverPhotogrammetryDetail
    var modelToWorld: simd_float4x4?
    var alignmentRMSMeters: Float?
    var alignmentAccepted: Bool
}

struct ReceiverMacReconstructionDiagnostics: Codable, Sendable {
    var detail: String
    var inputMode: String = ReceiverPhotogrammetryInputMode.imagesOnly.rawValue
    var depthGuidedSampleCount: Int = 0
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

enum ReceiverReconstructionError: LocalizedError {
    case unsupported
    case noImages
    case insufficientStorage(required: Int64, available: Int64)
    case processing(String)
    case cancelled
    case missingOutput
    case archiveTooLarge(Int64)

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
        case .archiveTooLarge(let bytes):
            "The derived bundle would be \(Self.bytes(bytes)), above the current .manta archive limit. Try Full detail; ZIP64 bundle support is still needed for a model this large."
        }
    }

    private static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
}

@MainActor
final class ReceiverPhotogrammetryRunner {
    private var session: PhotogrammetrySession?

    var isSupported: Bool { PhotogrammetrySession.isSupported }

    func cancel() {
        session?.cancel()
    }

    func reconstruct(
        preparation: ReceiverReconstructionPreparation,
        progress: @escaping @MainActor (Double, String) -> Void,
        log: @escaping @MainActor (ReceiverReconstructionLogLevel, String) -> Void
    ) async throws -> ReceiverPhotogrammetryRun {
        guard PhotogrammetrySession.isSupported else {
            throw ReceiverReconstructionError.unsupported
        }
        var configuration = PhotogrammetrySession.Configuration()
        configuration.sampleOrdering = .sequential
        configuration.featureSensitivity = .high
        let active: PhotogrammetrySession
        if preparation.inputMode.usesDepth, !preparation.sampleDescriptors.isEmpty {
            let withDepth = preparation.sampleDescriptors.count(where: { $0.depthURL != nil })
            active = try PhotogrammetrySession(
                input: ReceiverPhotogrammetrySampleSequence(
                    descriptors: preparation.sampleDescriptors),
                configuration: configuration)
            log(.info, "Object Capture started with \(preparation.sampleDescriptors.count) depth-guided samples (\(withDepth) carrying LiDAR depth) at \(preparation.detail.title) detail.")
        } else {
            active = try PhotogrammetrySession(
                input: preparation.inputDirectory, configuration: configuration)
            log(.info, "Object Capture started with \(preparation.imageCount) input images at \(preparation.detail.title) detail.")
        }
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
        try active.process(requests: [request])

        do {
            for try await output in active.outputs {
                if Task.isCancelled {
                    active.cancel()
                    throw ReceiverReconstructionError.cancelled
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
                    throw ReceiverReconstructionError.processing(error.localizedDescription)
                case .processingCancelled:
                    log(.warning, "Object Capture reported cancellation at \(Int(currentProgress * 100))%.")
                    throw ReceiverReconstructionError.cancelled
                case .processingComplete:
                    guard FileManager.default.fileExists(atPath: preparation.modelURL.path) else {
                        log(.error, "Object Capture completed but did not produce a model file.")
                        throw ReceiverReconstructionError.missingOutput
                    }
                    log(.success, "Object Capture model generation completed.")
                    return ReceiverPhotogrammetryRun(
                        startedAt: startedAt,
                        completedAt: Date(),
                        skippedSampleIDs: skipped,
                        automaticDownsampling: automaticDownsampling)
                default:
                    continue
                }
            }
        } catch is CancellationError {
            throw ReceiverReconstructionError.cancelled
        }
        throw ReceiverReconstructionError.missingOutput
    }
}

nonisolated enum ReceiverReconstructionWorkflow {
    private struct PoseRecord: Codable {
        var imageFilename: String
        var observationID: UUID
        var cameraToWorld: [Double]
        var intrinsics: [Double]
        var imageOrientation: String
    }

    static func estimate(
        bundle: MANTAValidatedBundle,
        detail: ReceiverPhotogrammetryDetail
    ) -> ReceiverReconstructionEstimate {
        let sources = imageSources(bundle: bundle)
        let bytes = sources.reduce(Int64(0)) { partial, item in
            partial + Int64((try? item.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let available = try? bundle.rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        return ReceiverReconstructionEstimate(
            imageCount: sources.count,
            sourceImageBytes: bytes,
            requiredWorkingBytes: detail.conservativeWorkingBytes(sourceImageBytes: bytes),
            availableBytes: available ?? nil)
    }

    static func prepare(
        bundle: MANTAValidatedBundle,
        detail: ReceiverPhotogrammetryDetail,
        inputMode: ReceiverPhotogrammetryInputMode = .imagesOnly
    ) throws -> ReceiverReconstructionPreparation {
        let estimate = estimate(bundle: bundle, detail: detail)
        guard estimate.imageCount > 0 else { throw ReceiverReconstructionError.noImages }
        if let available = estimate.availableBytes, !estimate.hasEnoughSpace {
            throw ReceiverReconstructionError.insufficientStorage(
                required: estimate.requiredWorkingBytes, available: available)
        }

        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
        let workspace = support
            .appendingPathComponent("MANTA Receiver", isDirectory: true)
            .appendingPathComponent("Reconstruction Workspaces", isDirectory: true)
            .appendingPathComponent(UUID().uuidString.lowercased(), isDirectory: true)
        let input = workspace.appendingPathComponent("Input", isDirectory: true)
        try fileManager.createDirectory(at: input, withIntermediateDirectories: true)

        var poses = [PoseRecord]()
        var sampleDescriptors = [ReceiverReconstructionSampleDescriptor]()
        do {
            for (index, item) in imageSources(bundle: bundle).enumerated() {
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

                guard inputMode.usesDepth else { continue }
                // Link the frame's depth alongside its image so the runner is
                // self-contained. A frame missing usable depth still yields an
                // RGB+gravity sample, so record it with a nil depth URL.
                var depthURL: URL?
                var depthWidth = 0
                var depthHeight = 0
                var depthCompression = "none"
                if let depth = item.observation.depth,
                   depth.scalarType.lowercased() == "float32",
                   depth.units == .meters,
                   depth.byteOrder.lowercased() == "little-endian",
                   depth.layout.lowercased().replacingOccurrences(of: "-", with: "")
                       .hasPrefix("rowmajor"),
                   depth.imageMapping.lowercased() == "resolution-scale" {
                    let source = bundle.rootDirectory.appendingPathComponent(depth.path)
                    if fileManager.fileExists(atPath: source.path) {
                        let depthFilename = "\(item.observation.id.uuidString.lowercased()).depth"
                        let depthDestination = input.appendingPathComponent(depthFilename)
                        do {
                            try fileManager.linkItem(at: source, to: depthDestination)
                        } catch {
                            try? fileManager.copyItem(at: source, to: depthDestination)
                        }
                        if fileManager.fileExists(atPath: depthDestination.path) {
                            depthURL = depthDestination
                            depthWidth = depth.dimensions.width
                            depthHeight = depth.dimensions.height
                            depthCompression = depth.compression
                        }
                    }
                }
                sampleDescriptors.append(ReceiverReconstructionSampleDescriptor(
                    sampleID: index,
                    imageURL: destination,
                    depthURL: depthURL,
                    depthWidth: depthWidth,
                    depthHeight: depthHeight,
                    depthCompression: depthCompression,
                    cameraToWorld: item.observation.cameraToWorld))
            }
            let posesURL = workspace.appendingPathComponent("macos-poses.json")
            let encoder = MANTAJSON.makeEncoder()
            try encoder.encode(poses).write(to: posesURL, options: .atomic)
            // A depth-guided run with no frame carrying usable depth would be
            // identical to images-only but mislabeled; fall back explicitly.
            let resolvedMode: ReceiverPhotogrammetryInputMode =
                inputMode.usesDepth && sampleDescriptors.contains { $0.depthURL != nil }
                    ? .depthGuided : .imagesOnly
            let stem = "macos_\(detail.rawValue)"
                + (resolvedMode.usesDepth ? "_depthguided" : "")
            return ReceiverReconstructionPreparation(
                workspace: workspace,
                inputDirectory: input,
                modelURL: workspace.appendingPathComponent("\(stem).usdz"),
                posesURL: posesURL,
                diagnosticsURL: workspace.appendingPathComponent("\(stem)_diagnostics.json"),
                detail: detail,
                imageCount: poses.count,
                sourceImageBytes: estimate.sourceImageBytes,
                inputMode: resolvedMode,
                sampleDescriptors: resolvedMode.usesDepth ? sampleDescriptors : [])
        } catch {
            try? fileManager.removeItem(at: workspace)
            throw error
        }
    }


    static func makePreview(
        bundle: MANTAValidatedBundle,
        preparation: ReceiverReconstructionPreparation,
        run: ReceiverPhotogrammetryRun,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        log: (@Sendable (ReceiverReconstructionLogLevel, String) -> Void)? = nil
    ) throws -> ReceiverEphemeralReconstruction {
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
        let diagnostics = ReceiverMacReconstructionDiagnostics(
            detail: preparation.detail.rawValue,
            inputMode: preparation.inputMode.rawValue,
            depthGuidedSampleCount: preparation.sampleDescriptors.count(where: { $0.depthURL != nil }),
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
        return ReceiverEphemeralReconstruction(
            modelURL: preparation.modelURL,
            posesURL: preparation.posesURL,
            diagnosticsURL: preparation.diagnosticsURL,
            detail: preparation.detail,
            modelToWorld: alignmentAccepted ? alignment?.transform : nil,
            alignmentRMSMeters: diagnostics.alignmentRMSMeters,
            alignmentAccepted: alignmentAccepted)
    }

    static func removeWorkspace(_ preparation: ReceiverReconstructionPreparation) {
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

    private static func flattened(_ matrix: simd_float4x4) -> [Double] {
        [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            .flatMap { [Double($0.x), Double($0.y), Double($0.z), Double($0.w)] }
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
