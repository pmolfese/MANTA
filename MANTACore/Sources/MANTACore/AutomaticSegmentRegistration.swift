import Foundation
import simd

extension SegmentRegistration {
    /// Bounded deterministic geometry-only initialization. PCA axis permutations
    /// cover large rotations; world-axis starts provide alternatives when crops
    /// change the principal axes. No scale estimation or learned dependencies.
    public static func solveAutomatic(source: [SIMD3<Float>], reference: [SIMD3<Float>]) -> SegmentRegistrationResult {
        let method = "geometry-multistart-rigid-icp-v1"
        func reject(_ reason: String) -> SegmentRegistrationResult {
            var result = SegmentRegistrationResult(accepted: false, reason: reason)
            result.method = method
            return result
        }
        guard source.count >= 50, reference.count >= 50,
              (source + reference).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return reject("Automatic alignment needs finite, supported depth on both passes.")
        }
        // Sort before subsampling to remove dependence on voxel/dictionary order.
        func bounded(_ points: [SIMD3<Float>], _ count: Int) -> [SIMD3<Float>] {
            let sorted = points.sorted { a, b in
                if a.x != b.x { return a.x < b.x }; if a.y != b.y { return a.y < b.y }; return a.z < b.z
            }
            return stride(from: 0, to: sorted.count, by: max(1, (sorted.count + count - 1) / count)).map { sorted[$0] }
        }
        let a = bounded(source, 512), b = bounded(reference, 512)
        guard spatiallyDistributed(a), spatiallyDistributed(b) else {
            return reject("Depth is spatially degenerate. Select more head coverage or use landmarks.")
        }
        let ca = a.reduce(.zero, +) / Float(a.count), cb = b.reduce(.zero, +) / Float(b.count)
        func axes(_ points: [SIMD3<Float>], _ center: SIMD3<Float>) -> simd_float3x3 {
            var covariance = Array(repeating: Array(repeating: Double(0), count: 3), count: 3)
            for point in points { let d = point - center
                for i in 0..<3 { for j in 0..<3 { covariance[i][j] += Double(d[i] * d[j]) } }
            }
            let eigen = JacobiEigen.solve(symmetric: covariance, size: 3)
            let order = (0..<3).sorted { eigen.values[$0] > eigen.values[$1] }
            let columns = order.map { i in SIMD3<Float>(Float(eigen.vectors[0][i]), Float(eigen.vectors[1][i]), Float(eigen.vectors[2][i])) }
            return simd_float3x3(columns[0], columns[1], columns[2])
        }
        let aa = axes(a, ca), bb = axes(b, cb)
        let permutations = [[0,1,2], [0,2,1], [1,0,2], [1,2,0], [2,0,1], [2,1,0]]
        var rotations: [simd_float3x3] = []
        for permutation in permutations {
            for x: Float in [-1, 1] { for y: Float in [-1, 1] { for z: Float in [-1, 1] {
                let basis = simd_float3x3(bb[permutation[0]] * x, bb[permutation[1]] * y, bb[permutation[2]] * z)
                let rotation = basis * aa.transpose
                if simd_determinant(rotation) > 0.99 { rotations.append(rotation) }
            } } }
        }
        for axis in [SIMD3<Float>(1,0,0), SIMD3<Float>(0,1,0), SIMD3<Float>(0,0,1)] {
            for i in 0..<8 { rotations.append(simd_float3x3(simd_quatf(angle: Float(i) * .pi / 4, axis: axis))) }
        }
        let coarseA = bounded(a, 128), coarseB = bounded(b, 128)
        func seed(_ rotation: simd_float3x3) -> simd_float4x4 {
            let t = cb - rotation * ca
            return simd_float4x4(SIMD4(rotation[0], 0), SIMD4(rotation[1], 0), SIMD4(rotation[2], 0), SIMD4(t, 1))
        }
        // A clipped bidirectional cost includes unmatched points rather than
        // rewarding an excellent fit to a tiny patch.
        func cost(_ transform: simd_float4x4, _ source: [SIMD3<Float>], _ target: [SIMD3<Float>]) -> Float {
            let moved = source.map { point($0, transform) }
            func one(_ x: [SIMD3<Float>], _ y: [SIMD3<Float>]) -> Float {
                x.reduce(Float(0)) { total, p in
                    total + min(0.0016, y.reduce(Float.infinity) { min($0, simd_distance_squared(p, $1)) })
                } / Float(x.count)
            }
            return (one(moved, target) + one(target, moved)) / 2
        }
        var coarse: [(simd_float4x4, Float)] = rotations.map { rotation in
            let fit = ICP.align(source: coarseA, target: coarseB, seed: seed(rotation), scaleMode: .rigid,
                maxIterations: 16, tolerance: 0.00001).transform
            return (fit, cost(fit, coarseA, coarseB))
        }
        coarse.sort { $0.1 < $1.1 }
        // Keep distinct orientations so symmetric alternatives survive refinement.
        func separation(_ lhs: simd_float4x4, _ rhs: simd_float4x4) -> Float {
            sqrt(a.reduce(Float(0)) { $0 + simd_distance_squared(point($1, lhs), point($1, rhs)) } / Float(a.count))
        }
        var seeds: [simd_float4x4] = []
        for candidate in coarse where rigid(candidate.0) {
            if !seeds.contains(where: { separation($0, candidate.0) < 0.008 }) { seeds.append(candidate.0) }
            if seeds.count >= 12 { break }
        }
        let candidates = seeds.map {
            ICP.align(source: a, target: b, seed: $0, scaleMode: .rigid, maxIterations: 35, tolerance: 0.000001).transform
        }.filter(rigid).map { ($0, cost($0, a, b)) }.sorted { $0.1 < $1.1 }
        guard let best = candidates.first else { return reject("No rigid alignment found. Place matching landmarks.") }
        var result = evaluate(a, b, [], [], best.0)
        result.method = method
        guard result.accepted else {
            result.reason = "Automatic alignment failed overlap or residual checks. Adjust intervals/head regions or place matching landmarks."
            return result
        }
        if candidates.dropFirst().contains(where: { separation($0.0, best.0) > 0.012 && $0.1 <= best.1 * 1.15 + 0.000004 }) {
            result.accepted = false
            result.referenceFromSource = nil
            result.reason = "Alignment ambiguous: different head poses fit similarly. Place matching landmarks to resolve orientation."
            return result
        }
        result.reason = "Automatic geometric checks passed. Inspect the overlay; similar head shapes can still hide incorrect alignment."
        return result
    }

    public static func referenceIdentity(points: [SIMD3<Float>]) -> SegmentRegistrationResult {
        var result = evaluate(points, points, [], [], matrix_identity_float4x4)
        result.method = "reference-coordinate-frame"
        result.reason = "Reference coordinate frame; individual frames are checked for agreement."
        return result
    }
}
