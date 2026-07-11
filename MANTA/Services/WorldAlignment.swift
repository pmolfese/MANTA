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

enum WorldAlignmentStrategy: String, CaseIterable, Codable, Identifiable {
    case icp = "ICP"
    case fiducial = "Fiducial"
    case depthAssisted = "Depth-Assisted"

    var id: String { rawValue }

    var explanation: String {
        switch self {
        case .icp:
            return "Iterative closest point between the LiDAR and photogrammetry surfaces."
        case .fiducial:
            return "Aligns on the 3 fiducial landmarks (nasion, LPA, RPA)."
        case .depthAssisted:
            return "Landmark alignment with scale fixed from LiDAR depth."
        }
    }
}

/// How ICP is initialized before iterating. Exposed so the different seeds can be compared.
enum AlignmentSeed: String, CaseIterable, Codable, Identifiable {
    case identity = "None"
    case coarsePCA = "Coarse (PCA)"
    case landmarks = "Source Landmarks"

    var id: String { rawValue }

    /// Whether this seed needs fiducials marked on the reconstructed model.
    var requiresSourceLandmarks: Bool { self == .landmarks }

    var explanation: String {
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
struct WorldAlignmentInput {
    /// How ICP is initialized.
    var seed: AlignmentSeed = .coarsePCA
    /// Landmarks in the photogrammetry model frame (source).
    var sourceLandmarks: [SIMD3<Float>] = []
    /// Corresponding landmarks in the ARKit world frame (target).
    var targetLandmarks: [SIMD3<Float>] = []
    /// Dense point cloud of the photogrammetry surface (source), for ICP.
    var sourceCloud: [SIMD3<Float>] = []
    /// Dense point cloud of the LiDAR surface (target), for ICP.
    var targetCloud: [SIMD3<Float>] = []
    /// Metric scale (target units per source unit) measured from LiDAR depth, for depth-assisted.
    var metricScaleHint: Float?
    var icpMaxIterations: Int = 30
    var icpTolerance: Float = 1e-5
}

struct WorldAlignmentResult: Equatable {
    /// Column-major rigid/similarity transform mapping source (model) points into the target (world) frame.
    var transform: simd_float4x4
    /// RMS residual of the fit in target units, when computable.
    var rmsError: Float
    var iterations: Int

    static let identity = WorldAlignmentResult(transform: matrix_identity_float4x4, rmsError: .nan, iterations: 0)
}

enum WorldAlignmentSolver {
    static func solve(strategy: WorldAlignmentStrategy, input: WorldAlignmentInput) -> WorldAlignmentResult {
        switch strategy {
        case .fiducial:
            return AbsoluteOrientation.fit(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: .estimate
            ) ?? .identity

        case .depthAssisted:
            let scaleMode: AbsoluteOrientation.ScaleMode = input.metricScaleHint.map { .fixed($0) } ?? .estimate
            return AbsoluteOrientation.fit(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: scaleMode
            ) ?? .identity

        case .icp:
            let seed = seedTransform(for: input)
            // The photogrammetry model's scale is arbitrary relative to the metric LiDAR target,
            // so ICP estimates scale as it iterates.
            return ICP.align(
                source: input.sourceCloud,
                target: input.targetCloud,
                seed: seed,
                estimateScale: true,
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
            return AbsoluteOrientation.fit(
                source: input.sourceLandmarks,
                target: input.targetLandmarks,
                scale: .estimate
            )?.transform ?? matrix_identity_float4x4
        case .coarsePCA:
            return CoarseAlignment.pca(
                source: input.sourceCloud,
                target: input.targetCloud
            )?.transform ?? matrix_identity_float4x4
        }
    }
}

// MARK: - Coarse pre-alignment (principal-axis / moment matching)

enum CoarseAlignment {
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

enum AbsoluteOrientation {
    enum ScaleMode {
        case rigid          // scale fixed at 1
        case estimate       // solve scale from correspondences
        case fixed(Float)   // externally supplied scale
    }

    /// Least-squares similarity transform mapping `source` onto `target`.
    /// Needs at least 3 non-degenerate correspondences. Returns nil if under-determined.
    static func fit(source: [SIMD3<Float>], target: [SIMD3<Float>], scale: ScaleMode) -> WorldAlignmentResult? {
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
        estimateScale: Bool = false,
        maxIterations: Int,
        tolerance: Float
    ) -> WorldAlignmentResult {
        guard source.count >= 3, target.count >= 3 else {
            return WorldAlignmentResult(transform: seed, rmsError: .nan, iterations: 0)
        }
        let scaleMode: AbsoluteOrientation.ScaleMode = estimateScale ? .estimate : .rigid

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
