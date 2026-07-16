//
//  WorldAlignment.swift
//  MANTA
//
//  Registration of the photogrammetry model into the ARKit world frame.
//
//  Three interchangeable strategies are provided so they can be compared on real
//  scans:
//    - .fiducial       Rigid + scale fit to the 3 landmark correspondences (Horn).
//    - .icp            Iterative closest point between the two meshes' point clouds,
//                      optionally seeded by the fiducial fit.
//    - .depthAssisted  Rigid landmark fit, but scale is pinned from the LiDAR depth
//                      measurement instead of being solved from correspondences.
//
//  The numerics are pure functions over point arrays, so they are unit-testable
//  without a device (see WorldAlignmentTests).
//

import Foundation
import simd

public enum WorldAlignmentStrategy: String, CaseIterable, Codable, Identifiable, Sendable {
    case icp = "ICP"
    case fiducial = "Fiducial"
    case depthAssisted = "Depth-Assisted"

    public var id: String { rawValue }

    public var explanation: String {
        switch self {
        case .icp:
            return "Refines the fit by matching the photogrammetry surface to the dense fused depth (falling back to LiDAR). Seed it with the fiducials you place."
        case .fiducial:
            return "Aligns on the 3 fiducial landmarks (nasion, LPA, RPA)."
        case .depthAssisted:
            return "Landmark alignment with scale fixed from LiDAR depth."
        }
    }
}

/// How ICP is initialized before iterating. Exposed so the different seeds can be compared.
public enum AlignmentSeed: String, CaseIterable, Codable, Identifiable, Sendable {
    case identity = "None"
    case coarsePCA = "Coarse (PCA)"
    case landmarks = "Source Landmarks"

    public var id: String { rawValue }

    /// Whether this seed needs fiducials marked on the reconstructed model.
    public var requiresSourceLandmarks: Bool { self == .landmarks }

    public var explanation: String {
        switch self {
        case .identity:
            return "Start ICP from the identity transform."
        case .coarsePCA:
            return "Pre-align by matching centroids and principal axes (no landmarks needed)."
        case .landmarks:
            return "Seed ICP from fiducials marked on the reconstructed model."
        }
    }
}

/// Everything the solvers might need. Each strategy uses the subset relevant to it.
public struct WorldAlignmentInput {
    /// How ICP is initialized.
    public var seed: AlignmentSeed = .coarsePCA
    /// Landmarks in the photogrammetry model frame (source).
    public var sourceLandmarks: [SIMD3<Float>] = []
    /// Corresponding landmarks in the ARKit world frame (target).
    public var targetLandmarks: [SIMD3<Float>] = []
    /// Dense point cloud of the photogrammetry surface (source), for ICP.
    public var sourceCloud: [SIMD3<Float>] = []
    /// Dense point cloud of the LiDAR surface (target), for ICP.
    public var targetCloud: [SIMD3<Float>] = []
    /// Metric scale (target units per source unit) measured from LiDAR depth, for depth-assisted.
    public var metricScaleHint: Float?
    /// Degrees of freedom allowed for landmark fits (fiducial / depth-assisted).
    /// `.affine` relaxes the uniform-scale assumption; ignored by ICP, which fits
    /// its own scale from the dense clouds.
    public var landmarkFitModel: LandmarkFitModel = .similarity
    public var icpMaxIterations: Int = 30
    public var icpTolerance: Float = 1e-5

    public init() {}
}

public struct WorldAlignmentResult: Equatable, Sendable {
    /// Column-major rigid/similarity transform mapping source (model) points into the target (world) frame.
    public var transform: simd_float4x4
    /// RMS residual of the fit in target units, when computable.
    public var rmsError: Float
    public var iterations: Int

    public init(transform: simd_float4x4, rmsError: Float, iterations: Int) {
        self.transform = transform
        self.rmsError = rmsError
        self.iterations = iterations
    }

    public static let identity = WorldAlignmentResult(transform: matrix_identity_float4x4, rmsError: .nan, iterations: 0)
}

public enum WorldAlignmentSolver {
    public static func solve(strategy: WorldAlignmentStrategy, input: WorldAlignmentInput) -> WorldAlignmentResult {
        switch strategy {
        case .fiducial:
            // Affine has no closed-form robust variant here and needs every
            // point (>=4, non-coplanar); fit it directly.
            if input.landmarkFitModel == .affine {
                return AffineLandmarkFit.fit(
                    source: input.sourceLandmarks, target: input.targetLandmarks) ?? .identity
            }
            // Robust to a single bad landmark when a 4th (e.g. Cz) is placed:
            // with only the anatomical minimum of 3, any 3 points fit each
            // other perfectly, so there is no redundancy to catch a bad one.
            return AbsoluteOrientation.fitRobust(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: input.landmarkFitModel.scaleMode
            )?.result ?? .identity

        case .depthAssisted:
            let scaleMode: AbsoluteOrientation.ScaleMode = input.metricScaleHint.map { .fixed($0) } ?? .estimate
            return AbsoluteOrientation.fitRobust(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: scaleMode
            )?.result ?? .identity

        case .icp:
            var seed = seedTransform(for: input)
            let scaleBoundFraction: Float = 0.20
            let scaleMode: AbsoluteOrientation.ScaleMode

            // Scale must come from the dense surface, never from the landmarks.
            // A 3-4 point landmark fit's scale is systematically wrong here: the
            // per-frame depth used to place image landmarks reads several cm
            // short, which shrinks the whole world-landmark triangle and drags
            // its scale to roughly half of truth (observed ~0.2 vs a measured
            // ~0.44). The clouds' spread ratio uses thousands of points and is
            // not corrupted this way - it matches the reconstruction's own
            // measured scale.
            //
            // So for a landmark seed we keep only its rotation (which resolves
            // the front/back flip a roughly symmetric head is otherwise prone
            // to) and replace its scale and position from the clouds, then let
            // ICP refine within a bound around that reliable cloud scale. A
            // free scale would let a shrunk source model collapse to nestle
            // inside a subset of the target cloud and report a deceptively low
            // one-way RMS; the bound prevents that while still allowing a modest
            // correction.
            if input.seed == .identity {
                scaleMode = .estimate
            } else if let cloudScale = CoarseAlignment.momentScale(
                        source: input.sourceCloud, target: input.targetCloud) {
                if input.seed == .landmarks {
                    seed = reseeded(
                        seed, scale: cloudScale,
                        source: input.sourceCloud, target: input.targetCloud)
                }
                scaleMode = .bounded(
                    cloudScale * (1 - scaleBoundFraction), cloudScale * (1 + scaleBoundFraction))
            } else {
                scaleMode = .fixed(uniformScale(of: seed))
            }
            return ICP.align(
                source: input.sourceCloud,
                target: input.targetCloud,
                seed: seed,
                scaleMode: scaleMode,
                maxIterations: input.icpMaxIterations,
                tolerance: input.icpTolerance
            )
        }
    }

    /// Initial transform for ICP, per the selected seed strategy.
    static func seedTransform(for input: WorldAlignmentInput) -> simd_float4x4 {
        switch input.seed {
        case .identity:
            return matrix_identity_float4x4
        case .landmarks:
            return AbsoluteOrientation.fitRobust(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: .estimate
            )?.result.transform ?? matrix_identity_float4x4
        case .coarsePCA:
            return CoarseAlignment.pca(
                source: input.sourceCloud,
                target: input.targetCloud
            )?.transform ?? matrix_identity_float4x4
        }
    }

    /// Median of all pairwise target/source landmark-distance ratios. Robust to a
    /// single bad correspondence: with N landmarks there are N(N-1)/2 ratios, and
    /// the median only moves if more than half disagree with the true scale.
    private static func robustPairwiseScale(
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> Float? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        var ratios = [Float]()
        for i in 0..<(source.count - 1) {
            for j in (i + 1)..<source.count {
                let sourceDistance = simd_distance(source[i], source[j])
                let targetDistance = simd_distance(target[i], target[j])
                guard sourceDistance > 1e-6, targetDistance.isFinite else { continue }
                ratios.append(targetDistance / sourceDistance)
            }
        }
        guard !ratios.isEmpty else { return nil }
        ratios.sort()
        return ratios[ratios.count / 2]
    }

    /// Rebuilds a similarity transform, keeping its rotation but substituting a
    /// new uniform scale and re-deriving translation so the two clouds' centroids
    /// coincide. Used to graft a trustworthy cloud-derived scale onto a landmark
    /// seed's (trustworthy) rotation. In Horn's method rotation is scale-
    /// independent, so the landmark seed's rotation is valid even though its own
    /// scale was not.
    private static func reseeded(
        _ transform: simd_float4x4, scale: Float,
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> simd_float4x4 {
        let currentScale = uniformScale(of: transform)
        guard currentScale > 1e-9, !source.isEmpty, !target.isEmpty else { return transform }
        func column(_ c: SIMD4<Float>) -> SIMD3<Float> {
            SIMD3(c.x, c.y, c.z) / currentScale
        }
        let r0 = column(transform.columns.0)
        let r1 = column(transform.columns.1)
        let r2 = column(transform.columns.2)
        let sourceCentroid = source.reduce(SIMD3<Float>.zero, +) / Float(source.count)
        let targetCentroid = target.reduce(SIMD3<Float>.zero, +) / Float(target.count)
        let rotatedScaledCentroid = scale
            * (r0 * sourceCentroid.x + r1 * sourceCentroid.y + r2 * sourceCentroid.z)
        let translation = targetCentroid - rotatedScaledCentroid
        return simd_float4x4(
            SIMD4(scale * r0, 0), SIMD4(scale * r1, 0), SIMD4(scale * r2, 0),
            SIMD4(translation, 1))
    }

    private static func uniformScale(of transform: simd_float4x4) -> Float {
        let scales = [
            simd_length(SIMD3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z)),
            simd_length(SIMD3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z)),
            simd_length(SIMD3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        ]
        return scales.reduce(0, +) / 3
    }
}

// MARK: - Coarse pre-alignment (principal-axis / moment matching)

enum CoarseAlignment {
    /// The similarity scale implied by matching the two clouds' overall spread
    /// (RMS distance from centroid). This is a surface-based scale: it uses
    /// every point in both clouds, so unlike a 3-4 point landmark fit it is not
    /// corrupted by a per-landmark depth bias. It matches the scale the dense
    /// reconstruction ICP independently measures.
    static func momentScale(source: [SIMD3<Float>], target: [SIMD3<Float>]) -> Float? {
        guard source.count >= 3, target.count >= 3 else { return nil }
        let sourceSpread = moments(source).spread
        let targetSpread = moments(target).spread
        guard sourceSpread > 1e-9 else { return nil }
        return Float(targetSpread / sourceSpread)
    }

    /// Similarity transform that matches centroids, principal axes, and spread of the two clouds.
    /// Resolves the eigenvector sign ambiguity by trying the four proper-rotation candidates and
    /// keeping the one with the lowest sampled residual. Intended as an ICP seed, not a final fit.
    static func pca(source: [SIMD3<Float>], target: [SIMD3<Float>]) -> WorldAlignmentResult? {
        guard source.count >= 3, target.count >= 3 else { return nil }

        let sourceMoments = moments(source)
        let targetMoments = moments(target)
        guard sourceMoments.spread > 1e-9, targetMoments.spread > 1e-9 else { return nil }

        let scale = targetMoments.spread / sourceMoments.spread
        let targetAxes = simd_double3x3(targetMoments.axes[0], targetMoments.axes[1], targetMoments.axes[2])

        // The principal-axis assignment is ambiguous in both order and sign. Try every signed
        // permutation of the source axes that yields a proper rotation (24 of them) and keep the
        // one whose sampled residual is lowest.
        let permutations = [[0, 1, 2], [0, 2, 1], [1, 0, 2], [1, 2, 0], [2, 0, 1], [2, 1, 0]]
        let signCombos: [SIMD3<Double>] = [
            SIMD3(1, 1, 1), SIMD3(1, 1, -1), SIMD3(1, -1, 1), SIMD3(-1, 1, 1),
            SIMD3(1, -1, -1), SIMD3(-1, 1, -1), SIMD3(-1, -1, 1), SIMD3(-1, -1, -1)
        ]

        var best: WorldAlignmentResult?
        for perm in permutations {
            for signs in signCombos {
                let c0 = signs.x * sourceMoments.axes[perm[0]]
                let c1 = signs.y * sourceMoments.axes[perm[1]]
                let c2 = signs.z * sourceMoments.axes[perm[2]]
                // Keep only proper (right-handed) bases so the result is a rotation, not a reflection.
                guard simd_dot(c0, simd_cross(c1, c2)) > 0 else { continue }

                let candidate = simd_double3x3(c0, c1, c2)
                let rotation = targetAxes * candidate.transpose
                let translation = targetMoments.centroid - scale * (rotation * sourceMoments.centroid)
                let transform = makeTransform(rotation: rotation, scale: scale, translation: translation)
                let rms = sampledRMS(transform: transform, source: source, target: target)

                if best == nil || rms < best!.rmsError {
                    best = WorldAlignmentResult(transform: transform, rmsError: rms, iterations: 0)
                }
            }
        }

        return best
    }

    private static func moments(_ points: [SIMD3<Float>]) -> (centroid: SIMD3<Double>, axes: [SIMD3<Double>], spread: Double) {
        let p = points.map { SIMD3<Double>($0) }
        let centroid = p.reduce(SIMD3<Double>.zero, +) / Double(p.count)

        var cov = [[Double]](repeating: [0, 0, 0], count: 3)
        for point in p {
            let d = point - centroid
            for a in 0..<3 {
                for b in 0..<3 {
                    cov[a][b] += d[a] * d[b]
                }
            }
        }
        let inv = 1.0 / Double(p.count)
        for a in 0..<3 { for b in 0..<3 { cov[a][b] *= inv } }

        let (values, vectors) = JacobiEigen.solve(symmetric: cov, size: 3)
        // Sort axes by descending eigenvalue for a stable, comparable basis.
        let order = [0, 1, 2].sorted { values[$0] > values[$1] }
        let axes = order.map { index in
            SIMD3<Double>(vectors[0][index], vectors[1][index], vectors[2][index])
        }
        let spread = (values[0] + values[1] + values[2]).squareRoot()
        return (centroid, axes, spread)
    }

    private static func sampledRMS(transform: simd_float4x4, source: [SIMD3<Float>], target: [SIMD3<Float>]) -> Float {
        let step = max(1, source.count / 400)
        var sum: Float = 0
        var count = 0
        var i = 0
        while i < source.count {
            let moved = transform * SIMD4<Float>(source[i], 1)
            let point = SIMD3<Float>(moved.x, moved.y, moved.z)
            var nearest = Float.greatestFiniteMagnitude
            var j = 0
            while j < target.count {
                nearest = min(nearest, simd_length_squared(target[j] - point))
                j += max(1, target.count / 400)
            }
            sum += nearest
            count += 1
            i += step
        }
        return count > 0 ? (sum / Float(count)).squareRoot() : .greatestFiniteMagnitude
    }

    private static func makeTransform(rotation: simd_double3x3, scale: Double, translation: SIMD3<Double>) -> simd_float4x4 {
        let c0 = scale * rotation.columns.0
        let c1 = scale * rotation.columns.1
        let c2 = scale * rotation.columns.2
        return simd_float4x4(
            SIMD4<Float>(Float(c0.x), Float(c0.y), Float(c0.z), 0),
            SIMD4<Float>(Float(c1.x), Float(c1.y), Float(c1.z), 0),
            SIMD4<Float>(Float(c2.x), Float(c2.y), Float(c2.z), 0),
            SIMD4<Float>(Float(translation.x), Float(translation.y), Float(translation.z), 1)
        )
    }
}

// MARK: - Horn's absolute orientation (closed-form similarity fit)

public enum AbsoluteOrientation {
    public enum ScaleMode {
        case rigid          // scale fixed at 1
        case estimate       // solve scale from correspondences
        case fixed(Float)   // externally supplied scale
        case bounded(Float, Float)  // solve scale, then clamp to [min, max]
    }

    /// Least-squares similarity transform mapping `source` onto `target`.
    /// Needs at least 3 non-degenerate correspondences. Returns nil if under-determined.
    public static func fit(source: [SIMD3<Float>], target: [SIMD3<Float>], scale: ScaleMode) -> WorldAlignmentResult? {
        guard source.count == target.count, source.count >= 3 else { return nil }
        let n = source.count

        let p = source.map { SIMD3<Double>($0) }
        let q = target.map { SIMD3<Double>($0) }
        let pBar = p.reduce(SIMD3<Double>.zero, +) / Double(n)
        let qBar = q.reduce(SIMD3<Double>.zero, +) / Double(n)
        let pc = p.map { $0 - pBar }
        let qc = q.map { $0 - qBar }

        // Cross-covariance S = Σ pc_i qc_iᵀ
        var s = [[Double]](repeating: [0, 0, 0], count: 3)
        for i in 0..<n {
            for a in 0..<3 {
                for b in 0..<3 {
                    s[a][b] += pc[i][a] * qc[i][b]
                }
            }
        }

        let quaternion = maximizingQuaternion(forCrossCovariance: s)
        let rotation = matrix(from: quaternion)

        let sourceVariance = pc.reduce(0.0) { $0 + simd_length_squared($1) }
        guard sourceVariance > 1e-12 else { return nil }

        let solvedScale: Double
        switch scale {
        case .rigid:
            solvedScale = 1
        case .fixed(let value):
            solvedScale = Double(value)
        case .estimate:
            // s = Σ qc_i · (R pc_i) / Σ |pc_i|²
            var numerator = 0.0
            for i in 0..<n {
                numerator += simd_dot(qc[i], rotation * pc[i])
            }
            solvedScale = numerator / sourceVariance
        case .bounded(let lower, let upper):
            var numerator = 0.0
            for i in 0..<n {
                numerator += simd_dot(qc[i], rotation * pc[i])
            }
            let free = numerator / sourceVariance
            solvedScale = min(max(free, Double(lower)), Double(upper))
        }

        let translation = qBar - solvedScale * (rotation * pBar)
        let transform = makeTransform(rotation: rotation, scale: solvedScale, translation: translation)

        // RMS residual in target units.
        var sumSquared = 0.0
        for i in 0..<n {
            let mapped = solvedScale * (rotation * p[i]) + translation
            sumSquared += simd_length_squared(mapped - q[i])
        }
        let rms = Float((sumSquared / Double(n)).squareRoot())

        return WorldAlignmentResult(transform: transform, rmsError: rms, iterations: 1)
    }

    public struct RobustFitResult {
        public var result: WorldAlignmentResult
        /// Index into the input arrays of the correspondence dropped as an
        /// outlier, if any.
        public var excludedIndex: Int?
    }

    /// `fit`, but with automatic single-outlier rejection when there is enough
    /// redundancy to detect one: a similarity transform has 7 degrees of
    /// freedom, so exactly 3 correspondences (the anatomical minimum: nasion,
    /// LPA, RPA) leave no slack to tell a bad point from a good one - any 3
    /// points fit each other perfectly by construction. A 4th point (e.g. Cz)
    /// changes that.
    ///
    /// This uses leave-one-out, not the full fit's own per-point residuals:
    /// with only 4 correspondences, a single bad point's error is partly
    /// absorbed into the whole least-squares transform rather than landing on
    /// itself, so it does not reliably show up as the single worst residual in
    /// a fit that includes it (verified against synthetic cases - the full fit
    /// can make a *different*, clean point look like the worst one). Instead,
    /// for each point, fit using every other point and measure how far off
    /// that fit's prediction is for the held-out point. It is a coarse
    /// M-estimator, not full RANSAC - it looks only at the single worst point,
    /// enough for the common failure mode here (one mis-clicked landmark), not
    /// multiple simultaneous bad ones.
    public static func fitRobust(
        source: [SIMD3<Float>], target: [SIMD3<Float>], scale: ScaleMode
    ) -> RobustFitResult? {
        guard let full = fit(source: source, target: target, scale: scale) else { return nil }
        guard source.count >= 4 else { return RobustFitResult(result: full, excludedIndex: nil) }

        var heldOutErrors = [Float](repeating: 0, count: source.count)
        var reducedFits = [WorldAlignmentResult?](repeating: nil, count: source.count)
        for i in source.indices {
            let reducedSource = source.indices.filter { $0 != i }.map { source[$0] }
            let reducedTarget = target.indices.filter { $0 != i }.map { target[$0] }
            guard let reduced = fit(source: reducedSource, target: reducedTarget, scale: scale)
            else { continue }
            reducedFits[i] = reduced
            let mapped = reduced.transform * SIMD4<Float>(source[i], 1)
            heldOutErrors[i] = simd_distance(SIMD3(mapped.x, mapped.y, mapped.z), target[i])
        }
        guard let worstIndex = heldOutErrors.indices.max(by: { heldOutErrors[$0] < heldOutErrors[$1] }),
              let reduced = reducedFits[worstIndex]
        else { return RobustFitResult(result: full, excludedIndex: nil) }

        let worst = heldOutErrors[worstIndex]
        let others = heldOutErrors.indices.filter { $0 != worstIndex }.map { heldOutErrors[$0] }.sorted()
        let othersMedian = others[others.count / 2]
        // Exclude only when the worst point is both a clear outlier relative to
        // the rest and large enough in absolute terms to matter. The "others"
        // here are contaminated too - their own leave-one-out fits still
        // include the actually-bad point in 2 of their 3 fitting points - so
        // the achievable margin is modest; 1.3x is where it's reliably
        // distinguishable from ordinary click noise in synthetic testing.
        guard worst > 0.015, worst > othersMedian * 1.3 else {
            return RobustFitResult(result: full, excludedIndex: nil)
        }
        return RobustFitResult(result: reduced, excludedIndex: worstIndex)
    }

    /// Quaternion (as SIMD4 w,x,y,z) that maximizes rotation alignment, via the largest
    /// eigenvector of Horn's 4x4 N matrix built from the cross-covariance S.
    private static func maximizingQuaternion(forCrossCovariance s: [[Double]]) -> SIMD4<Double> {
        let sxx = s[0][0], sxy = s[0][1], sxz = s[0][2]
        let syx = s[1][0], syy = s[1][1], syz = s[1][2]
        let szx = s[2][0], szy = s[2][1], szz = s[2][2]

        let n: [[Double]] = [
            [sxx + syy + szz, syz - szy,        szx - sxz,        sxy - syx],
            [syz - szy,       sxx - syy - szz,  sxy + syx,        szx + sxz],
            [szx - sxz,       sxy + syx,        -sxx + syy - szz, syz + szy],
            [sxy - syx,       szx + sxz,        syz + szy,        -sxx - syy + szz]
        ]

        let (values, vectors) = JacobiEigen.solve(symmetric: n, size: 4)
        var maxIndex = 0
        for i in 1..<4 where values[i] > values[maxIndex] { maxIndex = i }

        var q = SIMD4<Double>(
            vectors[0][maxIndex],
            vectors[1][maxIndex],
            vectors[2][maxIndex],
            vectors[3][maxIndex]
        )
        let length = simd_length(q)
        if length > 1e-12 { q /= length } else { q = SIMD4<Double>(1, 0, 0, 0) }
        // Canonical sign (w >= 0).
        if q.x < 0 { q = -q }
        return q
    }

    /// Rotation matrix from quaternion stored as (w, x, y, z).
    private static func matrix(from q: SIMD4<Double>) -> simd_double3x3 {
        let w = q.x, x = q.y, y = q.z, z = q.w
        return simd_double3x3(
            SIMD3<Double>(1 - 2*(y*y + z*z), 2*(x*y + w*z),     2*(x*z - w*y)),
            SIMD3<Double>(2*(x*y - w*z),     1 - 2*(x*x + z*z), 2*(y*z + w*x)),
            SIMD3<Double>(2*(x*z + w*y),     2*(y*z - w*x),     1 - 2*(x*x + y*y))
        )
    }

    private static func makeTransform(rotation: simd_double3x3, scale: Double, translation: SIMD3<Double>) -> simd_float4x4 {
        let c0 = scale * rotation.columns.0
        let c1 = scale * rotation.columns.1
        let c2 = scale * rotation.columns.2
        return simd_float4x4(
            SIMD4<Float>(Float(c0.x), Float(c0.y), Float(c0.z), 0),
            SIMD4<Float>(Float(c1.x), Float(c1.y), Float(c1.z), 0),
            SIMD4<Float>(Float(c2.x), Float(c2.y), Float(c2.z), 0),
            SIMD4<Float>(Float(translation.x), Float(translation.y), Float(translation.z), 1)
        )
    }
}

// MARK: - Iterative closest point

enum ICP {
    static func align(
        source: [SIMD3<Float>],
        target: [SIMD3<Float>],
        seed: simd_float4x4,
        scaleMode: AbsoluteOrientation.ScaleMode,
        maxIterations: Int,
        tolerance: Float
    ) -> WorldAlignmentResult {
        guard source.count >= 3, target.count >= 3 else {
            return WorldAlignmentResult(transform: seed, rmsError: .nan, iterations: 0)
        }

        var transform = seed
        var previousError = Float.greatestFiniteMagnitude
        var lastRMS = Float.nan
        var performed = 0

        for iteration in 1...max(1, maxIterations) {
            performed = iteration
            var correspondencesSource: [SIMD3<Float>] = []
            var correspondencesTarget: [SIMD3<Float>] = []
            correspondencesSource.reserveCapacity(source.count)
            correspondencesTarget.reserveCapacity(source.count)

            var sumSquared: Float = 0
            for point in source {
                let moved = apply(transform, to: point)
                let (nearest, distanceSquared) = nearestNeighbor(to: moved, in: target)
                correspondencesSource.append(point)
                correspondencesTarget.append(nearest)
                sumSquared += distanceSquared
            }

            lastRMS = (sumSquared / Float(source.count)).squareRoot()

            // Re-solve the absolute (rigid) transform for the current correspondences.
            guard let step = AbsoluteOrientation.fit(
                source: correspondencesSource,
                target: correspondencesTarget,
                scale: scaleMode
            ) else { break }

            transform = step.transform

            if abs(previousError - lastRMS) < tolerance { break }
            previousError = lastRMS
        }

        return WorldAlignmentResult(transform: transform, rmsError: lastRMS, iterations: performed)
    }

    private static func apply(_ transform: simd_float4x4, to point: SIMD3<Float>) -> SIMD3<Float> {
        let result = transform * SIMD4<Float>(point, 1)
        return SIMD3<Float>(result.x, result.y, result.z)
    }

    private static func nearestNeighbor(to point: SIMD3<Float>, in cloud: [SIMD3<Float>]) -> (SIMD3<Float>, Float) {
        var best = cloud[0]
        var bestDistance = Float.greatestFiniteMagnitude
        for candidate in cloud {
            let distance = simd_length_squared(candidate - point)
            if distance < bestDistance {
                bestDistance = distance
                best = candidate
            }
        }
        return (best, bestDistance)
    }
}

// MARK: - Symmetric eigensolver (cyclic Jacobi)

enum JacobiEigen {
    /// Eigen-decomposition of a real symmetric `size`x`size` matrix.
    /// Returns eigenvalues and eigenvectors as columns of `vectors` (vectors[row][col]).
    static func solve(symmetric input: [[Double]], size n: Int, sweepLimit: Int = 100) -> (values: [Double], vectors: [[Double]]) {
        var a = input
        var v = [[Double]](repeating: [Double](repeating: 0, count: n), count: n)
        for i in 0..<n { v[i][i] = 1 }

        for _ in 0..<sweepLimit {
            // Sum of off-diagonal magnitudes.
            var offNorm = 0.0
            for p in 0..<n {
                for q in (p + 1)..<n {
                    offNorm += abs(a[p][q])
                }
            }
            if offNorm < 1e-14 { break }

            for p in 0..<n {
                for q in (p + 1)..<n where abs(a[p][q]) > 1e-300 {
                    let app = a[p][p], aqq = a[q][q], apq = a[p][q]
                    let phi = 0.5 * atan2(2 * apq, aqq - app)
                    let c = cos(phi), s = sin(phi)

                    // Rotate rows/columns p,q.
                    for k in 0..<n {
                        let akp = a[k][p], akq = a[k][q]
                        a[k][p] = c * akp - s * akq
                        a[k][q] = s * akp + c * akq
                    }
                    for k in 0..<n {
                        let apk = a[p][k], aqk = a[q][k]
                        a[p][k] = c * apk - s * aqk
                        a[q][k] = s * apk + c * aqk
                    }
                    for k in 0..<n {
                        let vkp = v[k][p], vkq = v[k][q]
                        v[k][p] = c * vkp - s * vkq
                        v[k][q] = s * vkp + c * vkq
                    }
                }
            }
        }

        let values = (0..<n).map { a[$0][$0] }
        return (values, v)
    }
}
