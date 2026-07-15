import Foundation
import MANTACore
import simd

/// Appends a rich per-solve record to a single growing JSON file so alignment
/// attempts can be reviewed together. This is a debugging aid: it captures the
/// exact landmark geometry (model vs world edge lengths and their per-edge scale
/// ratios), the solved scale/RMS, and any warnings, which together reveal whether
/// the correspondences are geometrically consistent.
nonisolated enum ReceiverAlignmentDebugLog {
    struct Entry: Codable {
        var timestamp: String
        var strategy: String
        var seed: String
        var pairedLandmarks: [String]
        var landmarkRMSmm: Double?
        var solverRMSmm: Double?
        var solvedScale: Double?
        var iterations: Int?
        var accepted: Bool?
        var sourceCloudPoints: Int?
        var targetCloudPoints: Int?
        var modelPoints: [String: [Double]]
        var worldPoints: [String: [Double]]
        var modelEdgeMM: [String: Double]
        var worldEdgeMM: [String: Double]
        var edgeScaleRatio: [String: Double]
        var perLandmarkResidualMM: [String: Double]
        var imageViewsPerLandmark: [String: Int]
        var maxImageSpreadMM: [String: Double]
        var warnings: [String]
        var error: String?
    }

    static let fileName = "alignment_debug_log.json"

    @discardableResult
    static func record(
        packageRoot: URL,
        request: ReceiverManualAlignmentRequest,
        outcome: ReceiverManualAlignmentOutcome?,
        errorMessage: String?
    ) -> URL? {
        let paired = FiducialKind.allCases.filter {
            request.sourceLandmarks[$0] != nil && request.targetLandmarks[$0] != nil
        }
        func encode(_ dict: [FiducialKind: SIMD3<Float>]) -> [String: [Double]] {
            Dictionary(uniqueKeysWithValues: paired.compactMap { kind in
                dict[kind].map { (kind.rawValue, [Double($0.x), Double($0.y), Double($0.z)]) }
            })
        }
        var modelEdge = [String: Double](), worldEdge = [String: Double]()
        var ratio = [String: Double]()
        for i in paired.indices {
            for j in (i + 1)..<paired.count {
                let a = paired[i], b = paired[j]
                guard let ma = request.sourceLandmarks[a], let mb = request.sourceLandmarks[b],
                      let wa = request.targetLandmarks[a], let wb = request.targetLandmarks[b]
                else { continue }
                let key = "\(a.rawValue)-\(b.rawValue)"
                let md = Double(simd_distance(ma, mb)), wd = Double(simd_distance(wa, wb))
                modelEdge[key] = md * 1_000
                worldEdge[key] = wd * 1_000
                if md > 1e-6 { ratio[key] = wd / md }
            }
        }
        var residual = [String: Double]()
        if let outcome {
            let t = outcome.result.transform
            for kind in paired {
                guard let m = request.sourceLandmarks[kind],
                      let w = request.targetLandmarks[kind] else { continue }
                let mapped = t * SIMD4<Float>(m, 1)
                residual[kind.rawValue] = Double(
                    simd_distance(SIMD3(mapped.x, mapped.y, mapped.z), w)) * 1_000
            }
        }
        let diagnostics = outcome?.diagnostics
        let entry = Entry(
            timestamp: ISO8601DateFormatter().string(from: Date()),
            strategy: request.strategy.rawValue,
            seed: request.seed.rawValue,
            pairedLandmarks: paired.map(\.rawValue),
            landmarkRMSmm: diagnostics?.landmarkRMSMeters.map { $0 * 1_000 },
            solverRMSmm: diagnostics?.solverRMSMeters.map { $0 * 1_000 },
            solvedScale: diagnostics.map(\.scale),
            iterations: diagnostics?.iterations,
            accepted: diagnostics?.accepted,
            sourceCloudPoints: diagnostics?.sourceCloudPoints,
            targetCloudPoints: diagnostics?.targetCloudPoints,
            modelPoints: encode(request.sourceLandmarks),
            worldPoints: encode(request.targetLandmarks),
            modelEdgeMM: modelEdge,
            worldEdgeMM: worldEdge,
            edgeScaleRatio: ratio,
            perLandmarkResidualMM: residual,
            imageViewsPerLandmark: Dictionary(uniqueKeysWithValues: paired.map {
                ($0.rawValue, request.targetEvidenceCounts[$0] ?? 0)
            }),
            maxImageSpreadMM: Dictionary(uniqueKeysWithValues: paired.map {
                ($0.rawValue, Double(request.targetMaximumSpreads[$0] ?? 0) * 1_000)
            }),
            warnings: diagnostics?.warnings ?? [],
            error: errorMessage)

        guard let url = logURL(packageRoot: packageRoot) else { return nil }
        var entries = (try? Data(contentsOf: url)).flatMap {
            try? JSONDecoder().decode([Entry].self, from: $0)
        } ?? []
        entries.append(entry)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(entries) {
            try? data.write(to: url, options: .atomic)
        }
        print("[MANTA alignment debug] appended solve #\(entries.count) to \(url.path)")
        return url
    }

    /// Logs live inside the package folder itself, under `logs/`, not in
    /// Application Support - the package is the single place everything about a
    /// capture lives.
    private static func logURL(packageRoot: URL) -> URL? {
        let dir = packageRoot.appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(fileName)
    }
}

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
        // Use every landmark placed on both the images and the model, in a
        // fixed order. The three cardinal fiducials are required; Cz (vertex) is
        // optional but, sitting off the nasion-LPA-RPA plane, it removes the
        // coplanar degeneracy that otherwise lets a mirror-image fit look
        // perfect and leaves the off-plane rotation under-constrained.
        let orderedKinds = FiducialKind.allCases.filter {
            request.sourceLandmarks[$0] != nil && request.targetLandmarks[$0] != nil
        }
        let sourceLandmarks = orderedKinds.map { request.sourceLandmarks[$0]! }
        let targetLandmarks = orderedKinds.map { request.targetLandmarks[$0]! }
        let hasCardinalPairs = FiducialKind.cardinal.allSatisfy(orderedKinds.contains)

        if request.strategy != .icp || request.seed == .landmarks, !hasCardinalPairs {
            throw ReceiverManualAlignmentError.missingLandmarks(
                "Nasion, LPA, and RPA on both the images and model")
        }

        var input = WorldAlignmentInput()
        input.seed = request.seed
        if hasCardinalPairs {
            input.sourceLandmarks = sourceLandmarks
            input.targetLandmarks = targetLandmarks
        }

        var sourceCloud = [SIMD3<Float>]()
        var targetCloud = [SIMD3<Float>]()
        if request.strategy == .icp {
            sourceCloud = ModelPointCloudLoader.load(
                url: modelURL, maxPoints: 2_500)
            // Prefer the dense, metric fused-depth cloud as the ICP target. It
            // is thousands of points in the correct ARKit-world frame, so it
            // constrains the whole photogrammetry surface and averages the
            // reconstruction warp. The sparse LiDAR head mesh (often only a few
            // hundred vertices) is a poor fallback used only when fusion yields
            // too little to register against.
            targetCloud = fusedDepthTarget(bundle: bundle, maxPoints: 4_000)
            if targetCloud.count < 300 {
                targetCloud = alignmentTarget(bundle: bundle, maxPoints: 2_500)
            }
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

        let landmarkRMS = hasCardinalPairs
            ? rms(transform: result.transform, source: input.sourceLandmarks, target: input.targetLandmarks)
            : nil
        var warnings = [String]()
        // Three cardinal fiducials are coplanar: a mirror-image fit scores an
        // identical residual and the rotation about that plane is only weakly
        // constrained, so a small landmark error swings scalp points far off the
        // surface while the RMS still looks good. Cz (off that plane) removes the
        // ambiguity. Warn whenever a landmark-based fit ran without it.
        if hasCardinalPairs, request.strategy != .icp || request.seed == .landmarks,
           !orderedKinds.contains(.vertex) {
            warnings.append(
                "Fit used only the 3 coplanar cardinal landmarks. Place Cz (vertex) on the images and model to constrain the off-plane rotation and prevent a mirror-flipped result.")
        }
        // With Cz placed there's enough redundancy (4 points) to tell whether
        // one landmark disagrees with the other three; the solver already
        // excludes it internally when fitting/seeding, but flag it here too so
        // it's clear which landmark is likely mis-clicked rather than just that
        // the residual is high.
        if orderedKinds.count >= 4,
           let robust = AbsoluteOrientation.fitRobust(
             source: sourceLandmarks, target: targetLandmarks, scale: .estimate),
           let excludedIndex = robust.excludedIndex {
            warnings.append(
                "\(orderedKinds[excludedIndex].rawValue) disagrees with the other placed landmarks and was excluded from the fit as a likely mis-click. Re-check its position in the image and on the model.")
        }
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

    /// Dense metric ICP target built by fusing the confidence-filtered RGB-D
    /// frames into a single ARKit-world point cloud. Returns an empty array when
    /// no depth is available or fusion fails, so the caller can fall back to the
    /// sparse LiDAR mesh.
    private static func fusedDepthTarget(
        bundle: MANTAValidatedBundle, maxPoints: Int
    ) -> [SIMD3<Float>] {
        let observations = bundle.capture.observations.filter { $0.depth != nil }
        guard !observations.isEmpty else { return [] }
        let reconstruction = bundle.capture.reconstruction
        let headMeshURL = (reconstruction?.headCroppedLidarMeshPath).map {
            bundle.rootDirectory.appendingPathComponent($0)
        }
        let fiducialCoordinates = (bundle.capture.fiducials ?? []).compactMap {
            fiducial -> SIMD3<Float>? in
            guard let point = fiducial.coordinate, point.count == 3 else { return nil }
            return SIMD3(Float(point[0]), Float(point[1]), Float(point[2]))
        }
        let input = ReceiverDepthFusionInput(
            rootDirectory: bundle.rootDirectory,
            observations: observations,
            declaredBounds: reconstruction?.headBoundingBox,
            headMeshURL: headMeshURL,
            fiducialCoordinates: fiducialCoordinates)
        guard let cloud = try? ReceiverDepthFusion.fuse(input), !cloud.points.isEmpty else {
            return []
        }
        guard cloud.points.count > maxPoints else { return cloud.points }
        let stride = cloud.points.count / maxPoints
        return cloud.points.enumerated().compactMap {
            $0.offset % stride == 0 ? $0.element : nil
        }
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

}

