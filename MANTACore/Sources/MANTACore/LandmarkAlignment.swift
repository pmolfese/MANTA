//
//  LandmarkAlignment.swift
//  MANTACore
//
//  Fit-model choices and correspondence-quality diagnostics for landmark-based
//  registration, layered on top of the closed-form fits in WorldAlignment.swift.
//
//  Motivation: a similarity fit (rigid + one uniform scale) can only register two
//  point sets that are the *same shape*. When the world (target) landmarks are
//  geometrically distorted - e.g. per-frame depth reads short by a non-uniform
//  amount - no rotation/translation/scale can reconcile them, and the RMS floor
//  stays high no matter which solver runs. These helpers (a) let the caller relax
//  the fit model the way medical image registration does (rigid -> affine ->
//  nonlinear), and (b) score each correspondence so the offending landmark is
//  visible instead of hiding inside an aggregate RMS.
//

import Foundation
import simd

// MARK: - Fit model (degrees of freedom of the landmark transform)

/// How many degrees of freedom the landmark fit is allowed. Mirrors the classic
/// medical-imaging progression from most to least constrained.
public enum LandmarkFitModel: String, CaseIterable, Codable, Identifiable, Sendable {
    /// 6 DOF: rotation + translation, scale locked at 1. Correct when both point
    /// sets are already metric (e.g. a depth-guided reconstruction vs LiDAR).
    case rigid = "Rigid"
    /// 7 DOF: rotation + translation + one uniform scale (Horn similarity). The
    /// right model for a non-metric photogrammetry model whose shape is faithful.
    case similarity = "Similarity"
    /// 12 DOF: a full affine map (rotation, translation, non-uniform scale, shear).
    /// Can absorb a non-uniform distortion the similarity fit cannot, at the cost
    /// of needing >=4 non-coplanar correspondences and being prone to overfitting
    /// a small, noisy landmark set.
    case affine = "Affine"

    public var id: String { rawValue }

    public var explanation: String {
        switch self {
        case .rigid:
            return "Rotation + translation only, scale locked to 1. Use when both landmark sets are already metric."
        case .similarity:
            return "Rotation + translation + one uniform scale. Standard fit for a faithful but non-metric model."
        case .affine:
            return "Full affine (adds non-uniform scale + shear). Needs 4+ non-coplanar points; can overfit a small set."
        }
    }

    var scaleMode: AbsoluteOrientation.ScaleMode {
        switch self {
        case .rigid: .rigid
        case .similarity, .affine: .estimate
        }
    }
}

// MARK: - Affine (12-DOF) landmark fit

public enum AffineLandmarkFit {
    /// Least-squares affine transform mapping `source` onto `target`, i.e. the
    /// 3x4 `[A | t]` minimizing Σ |A·pᵢ + t − qᵢ|². Needs at least 4
    /// correspondences that are not all coplanar; returns nil when the normal
    /// equations are singular (degenerate configuration).
    public static func fit(
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> WorldAlignmentResult? {
        guard source.count == target.count, source.count >= 4 else { return nil }
        let n = source.count

        // Normal equations: with rows xᵢ = [px, py, pz, 1], each output axis k
        // solves (XᵀX) wₖ = Xᵀ yₖ independently. XᵀX (4x4) is shared across axes.
        var xtx = [[Double]](repeating: [Double](repeating: 0, count: 4), count: 4)
        var xty = [[Double]](repeating: [Double](repeating: 0, count: 3), count: 4)
        for i in 0..<n {
            let p = SIMD3<Double>(source[i])
            let q = SIMD3<Double>(target[i])
            let row = [p.x, p.y, p.z, 1.0]
            for a in 0..<4 {
                for b in 0..<4 { xtx[a][b] += row[a] * row[b] }
                for k in 0..<3 { xty[a][k] += row[a] * q[k] }
            }
        }
        guard let solution = solveLinearSystem(xtx, xty) else { return nil }

        // solution[a][k] is the a-th weight for output axis k. Column c of the
        // 3x3 linear part A is [solution[c][0], solution[c][1], solution[c][2]];
        // translation is row 3.
        func col(_ c: Int) -> SIMD4<Float> {
            SIMD4(Float(solution[c][0]), Float(solution[c][1]), Float(solution[c][2]), 0)
        }
        let translation = SIMD4<Float>(
            Float(solution[3][0]), Float(solution[3][1]), Float(solution[3][2]), 1)
        let transform = simd_float4x4(col(0), col(1), col(2), translation)

        var sumSquared = 0.0
        for i in 0..<n {
            let mapped = transform * SIMD4<Float>(source[i], 1)
            sumSquared += Double(simd_length_squared(SIMD3(mapped.x, mapped.y, mapped.z) - target[i]))
        }
        let rms = Float((sumSquared / Double(n)).squareRoot())
        return WorldAlignmentResult(transform: transform, rmsError: rms, iterations: 1)
    }

    /// Solves the 4x`k` system `A · W = B` for W (A is 4x4, B is 4x`k`) via
    /// Gaussian elimination with partial pivoting. Returns nil if A is singular.
    private static func solveLinearSystem(
        _ a: [[Double]], _ b: [[Double]]
    ) -> [[Double]]? {
        let n = 4
        let k = b[0].count
        var m = a
        var r = b
        for col in 0..<n {
            var pivot = col
            for row in (col + 1)..<n where abs(m[row][col]) > abs(m[pivot][col]) { pivot = row }
            guard abs(m[pivot][col]) > 1e-12 else { return nil }
            if pivot != col { m.swapAt(pivot, col); r.swapAt(pivot, col) }
            let diag = m[col][col]
            for j in 0..<n { m[col][j] /= diag }
            for j in 0..<k { r[col][j] /= diag }
            for row in 0..<n where row != col {
                let factor = m[row][col]
                guard factor != 0 else { continue }
                for j in 0..<n { m[row][j] -= factor * m[col][j] }
                for j in 0..<k { r[row][j] -= factor * r[col][j] }
            }
        }
        return r
    }
}

// MARK: - Unified landmark fit entry point

public extension AbsoluteOrientation {
    /// Fits `source` onto `target` under the chosen model. Similarity and rigid
    /// use Horn's closed form; affine uses a linear least-squares solve.
    static func fit(
        source: [SIMD3<Float>], target: [SIMD3<Float>], model: LandmarkFitModel
    ) -> WorldAlignmentResult? {
        switch model {
        case .rigid, .similarity:
            return fit(source: source, target: target, scale: model.scaleMode)
        case .affine:
            return AffineLandmarkFit.fit(source: source, target: target)
        }
    }
}

// MARK: - Per-correspondence plausibility

/// Quality diagnostics for a single landmark correspondence, computed *without*
/// solving the full transform so a bad click can be flagged the moment it is
/// placed.
public struct LandmarkPlausibility: Sendable, Equatable {
    /// Median disagreement, in meters, between this landmark's edges to the other
    /// landmarks and the length a single consistent scale predicts. High values
    /// mean this point's geometry is inconsistent with the rest - the signature
    /// of a mis-click or a locally biased depth reading.
    public var geometryErrorMeters: Float
    /// This landmark's largest edge-scale-ratio divided by its smallest. 1.0 is
    /// perfectly consistent; a similarity fit cannot do better than this spread.
    public var edgeRatioSpread: Float
    /// True when this landmark is the clear geometric outlier of the set.
    public var isLikelyOutlier: Bool

    public init(geometryErrorMeters: Float, edgeRatioSpread: Float, isLikelyOutlier: Bool) {
        self.geometryErrorMeters = geometryErrorMeters
        self.edgeRatioSpread = edgeRatioSpread
        self.isLikelyOutlier = isLikelyOutlier
    }
}

public enum LandmarkPlausibilityAnalyzer {
    /// Scores each correspondence by how consistent it is with the others.
    /// Returns an array aligned with the inputs; entries are nil when there is too
    /// little data (fewer than 3 correspondences).
    ///
    /// This is the geometric core behind the "which click is wrong" table: it
    /// needs only the two point sets, not the final transform, so it updates live.
    ///
    /// `geometryErrorMeters` comes from a **leave-one-out** similarity fit when
    /// there are >=4 correspondences: fit all-but-one, then measure how far that
    /// fit's prediction lands from the held-out point. A mis-clicked landmark, once
    /// excluded, leaves a clean set that predicts a large error for it. With only
    /// 3 correspondences there is no redundancy - any 3 points fit any 3 points -
    /// so no landmark can be singled out and `isLikelyOutlier` is never set (only
    /// the edge-ratio spread is reported, as context).
    public static func evaluate(
        source: [SIMD3<Float>], target: [SIMD3<Float>]
    ) -> [LandmarkPlausibility?] {
        let n = source.count
        guard n == target.count, n >= 3 else {
            return [LandmarkPlausibility?](repeating: nil, count: n)
        }

        // Per-landmark edge-ratio spread (context that works for any n >= 3).
        var spread = [Float](repeating: 1, count: n)
        for i in 0..<n {
            var ratios = [Float]()
            for j in 0..<n where j != i {
                let md = simd_distance(source[i], source[j])
                let wd = simd_distance(target[i], target[j])
                if md > 1e-6, wd.isFinite { ratios.append(wd / md) }
            }
            if let lo = ratios.min(), let hi = ratios.max(), lo > 1e-9 { spread[i] = hi / lo }
        }

        var geomError = [Float](repeating: 0, count: n)
        var canFlag = false
        if n >= 4 {
            canFlag = true
            for i in 0..<n {
                let reducedSource = source.indices.filter { $0 != i }.map { source[$0] }
                let reducedTarget = target.indices.filter { $0 != i }.map { target[$0] }
                guard let fit = AbsoluteOrientation.fit(
                    source: reducedSource, target: reducedTarget, scale: .estimate) else { continue }
                let mapped = fit.transform * SIMD4<Float>(source[i], 1)
                geomError[i] = simd_distance(SIMD3(mapped.x, mapped.y, mapped.z), target[i])
            }
        }

        var scores: [LandmarkPlausibility?] = (0..<n).map { i in
            LandmarkPlausibility(
                geometryErrorMeters: geomError[i], edgeRatioSpread: spread[i], isLikelyOutlier: false)
        }

        // Flag the single dominant outlier only when there is redundancy to
        // detect one, mirroring AbsoluteOrientation.fitRobust's 1.3x margin.
        if canFlag,
           let worst = geomError.indices.max(by: { geomError[$0] < geomError[$1] }) {
            let others = geomError.indices.filter { $0 != worst }.map { geomError[$0] }.sorted()
            let othersMedian = others.isEmpty ? 0 : others[others.count / 2]
            if geomError[worst] > 0.015, geomError[worst] > othersMedian * 1.3 {
                scores[worst]?.isLikelyOutlier = true
            }
        }
        return scores
    }
}

// MARK: - Symmetric surface RMS

public enum SurfaceAlignmentMetrics {
    /// Symmetric (bidirectional) nearest-neighbour RMS between a transformed
    /// `source` cloud and a `target` cloud, in target units. Taking the max of
    /// both directions defeats the degenerate collapse a one-way RMS rewards - a
    /// shrunk source nestled inside a subset of the target scores a low forward
    /// RMS but a large reverse one. Returns NaN when either cloud is empty.
    public static func symmetricRMS(
        transform: simd_float4x4,
        source: [SIMD3<Float>],
        target: [SIMD3<Float>],
        maximumPointsPerDirection: Int = 800
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

    private static func sampled(_ points: [SIMD3<Float>], maximum: Int) -> [SIMD3<Float>] {
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
