import Foundation
import simd

public struct SegmentRegistrationResult: Codable, Sendable {
    public var accepted: Bool
    public var reason: String
    public var referenceFromSource: [Float]?
    public var rmsMeters: Float?
    public var sourceOverlap: Float?
    public var referenceOverlap: Float?
    public var landmarkRMSMeters: Float?
    public var method = "landmark-seeded-rigid-icp-v1"
    public var confidence = "uncalibrated-geometric-gates"
}

/// Conservative, metric rigid alignment. No estimated scale, identity fallback,
/// assumption that a small residual proves accuracy. The automatic extension
/// supplies a separate bounded multistart initialization.
public enum SegmentRegistration {
    public static let correspondenceMeters: Float = 0.015
    public static let maximumRMSMeters: Float = 0.008
    public static let minimumOverlap: Float = 0.6

    public static func solve(source: [SIMD3<Float>], reference: [SIMD3<Float>],
                             sourceLandmarks: [SIMD3<Float>], referenceLandmarks: [SIMD3<Float>]) -> SegmentRegistrationResult {
        func reject(_ reason: String) -> SegmentRegistrationResult {
            .init(accepted: false, reason: reason)
        }
        guard source.count >= 50, reference.count >= 50,
              (source + reference + sourceLandmarks + referenceLandmarks).allSatisfy(finite),
              sourceLandmarks.count == referenceLandmarks.count,
              noncollinear(sourceLandmarks), noncollinear(referenceLandmarks) else {
            return reject("Insufficient finite depth support or noncollinear matched landmarks.")
        }
        // Bounded computation; callers should voxelize before deterministic subsampling.
        let a = sample(source), b = sample(reference)
        guard spatiallyDistributed(a), spatiallyDistributed(b) else {
            return reject("Depth support is spatially degenerate; alignment is not observable.")
        }
        guard let seed = AbsoluteOrientation.fit(source: sourceLandmarks, target: referenceLandmarks, scale: .rigid),
              seed.rmsError.isFinite, seed.rmsError <= maximumRMSMeters else {
            return reject("Landmarks disagree under a rigid metric transform (scale or correspondence mismatch).")
        }
        let fit = ICP.align(source: a, target: b, seed: seed.transform, scaleMode: .rigid,
                            maxIterations: 20, tolerance: 0.00001)
        let candidates = [seed.transform, fit.transform].filter { rigid($0) }
        // ICP is permitted only if it still agrees with independently matched landmarks.
        let valid = candidates.filter { matrix in
            zip(sourceLandmarks, referenceLandmarks).allSatisfy { simd_distance(point($0.0, matrix), $0.1) <= maximumRMSMeters }
        }
        let evaluated = valid.map { evaluate(a, b, sourceLandmarks, referenceLandmarks, $0) }
        guard let result = evaluated.sorted(by: { lhs, rhs in
            if lhs.accepted != rhs.accepted { return lhs.accepted }
            return (lhs.rmsMeters ?? .infinity) < (rhs.rmsMeters ?? .infinity)
        }).first else {
            return reject("Refinement violated landmark constraints.")
        }
        return result
    }

    static func evaluate(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>], _ landmarks: [SIMD3<Float>],
                                 _ referenceLandmarks: [SIMD3<Float>], _ transform: simd_float4x4) -> SegmentRegistrationResult {
        let moved = a.map { point($0, transform) }
        let forward = metrics(moved, b), reverse = metrics(b, moved)
        let landmarkRMS: Float? = landmarks.isEmpty ? nil : sqrt(zip(landmarks, referenceLandmarks).map { simd_distance_squared(point($0.0, transform), $0.1) }.reduce(0, +) / Float(landmarks.count))
        let accepted = forward.overlap >= minimumOverlap && reverse.overlap >= minimumOverlap
            && forward.rms <= maximumRMSMeters && reverse.rms <= maximumRMSMeters
        return .init(accepted: accepted, reason: accepted ? "Provisional geometric gates passed; independent accuracy validation remains required." : "Insufficient bidirectional overlap or excessive depth residual.",
                     referenceFromSource: accepted ? flatten(transform) : nil,
                     rmsMeters: max(forward.rms, reverse.rms), sourceOverlap: forward.overlap,
                     referenceOverlap: reverse.overlap, landmarkRMSMeters: landmarkRMS)
    }

    public static func frameAgrees(points: [SIMD3<Float>], reference: [SIMD3<Float>], transform: simd_float4x4) -> Bool {
        guard points.count >= 20, reference.count >= 50, rigid(transform), points.allSatisfy(finite), reference.allSatisfy(finite) else { return false }
        let check = metrics(sample(points).map { point($0, transform) }, sample(reference))
        return check.overlap >= minimumOverlap && check.rms <= maximumRMSMeters
    }
    public static func point(_ p: SIMD3<Float>, _ t: simd_float4x4) -> SIMD3<Float> {
        let v = t * SIMD4(p, 1); return SIMD3(v.x, v.y, v.z)
    }
    public static func direction(_ d: SIMD3<Float>, _ t: simd_float4x4) -> SIMD3<Float> {
        let v = t * SIMD4(d, 0); return SIMD3(v.x, v.y, v.z)
    }
    public static func camera(_ cameraToSource: simd_float4x4, referenceFromSource: simd_float4x4) -> simd_float4x4 {
        referenceFromSource * cameraToSource
    }
    public static func matrix(_ values: [Float]) -> simd_float4x4? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        return simd_float4x4(columns: (SIMD4(values[0],values[1],values[2],values[3]), SIMD4(values[4],values[5],values[6],values[7]),
            SIMD4(values[8],values[9],values[10],values[11]), SIMD4(values[12],values[13],values[14],values[15])))
    }
    public static func flatten(_ matrix: simd_float4x4) -> [Float] { (0..<4).flatMap { c in (0..<4).map { matrix[c][$0] } } }
    public static func rigid(_ t: simd_float4x4) -> Bool {
        guard flatten(t).allSatisfy(\.isFinite), abs(t[0].w) < 0.0001, abs(t[1].w) < 0.0001,
              abs(t[2].w) < 0.0001, abs(t[3].w - 1) < 0.0001 else { return false }
        let r = simd_float3x3(SIMD3(t[0].x,t[0].y,t[0].z), SIMD3(t[1].x,t[1].y,t[1].z), SIMD3(t[2].x,t[2].y,t[2].z))
        return abs(simd_determinant(r) - 1) < 0.001 && (0..<3).allSatisfy { i in
            (0..<3).allSatisfy { j in abs(simd_dot(r[i], r[j]) - (i == j ? 1 : 0)) < 0.001 }
        }
    }
    private static func finite(_ p: SIMD3<Float>) -> Bool { p.x.isFinite && p.y.isFinite && p.z.isFinite }
    private static func sample(_ points: [SIMD3<Float>]) -> [SIMD3<Float>] {
        stride(from: 0, to: points.count, by: max(1, (points.count + 511) / 512)).map { points[$0] }
    }
    public static func noncollinear(_ p: [SIMD3<Float>]) -> Bool {
        guard p.count >= 3 else { return false }
        return (1..<p.count).contains { i in ((i+1)..<p.count).contains { j in
            simd_length(simd_cross(p[i] - p[0], p[j] - p[0])) > 0.001
        } }
    }
    static func spatiallyDistributed(_ p: [SIMD3<Float>]) -> Bool {
        let center = p.reduce(SIMD3<Float>.zero, +) / Float(p.count)
        var covariance = simd_float3x3(0)
        for v in p { let d = v - center; for i in 0..<3 { for j in 0..<3 { covariance[i][j] += d[i] * d[j] / Float(p.count) } } }
        return simd_determinant(covariance) > 1e-12
    }
    static func metrics(_ a: [SIMD3<Float>], _ b: [SIMD3<Float>]) -> (overlap: Float, rms: Float) {
        let distances = a.map { p in b.reduce(Float.infinity) { min($0, simd_distance_squared(p, $1)) } }
        let inliers = distances.filter { $0 <= correspondenceMeters * correspondenceMeters }
        return (Float(inliers.count) / Float(max(1, a.count)),
                inliers.isEmpty ? 1 : sqrt(inliers.reduce(0, +) / Float(inliers.count)))
    }
}

public struct SegmentMotionCorrection: Codable, Equatable, Hashable, Sendable {
    public var runID: UUID
    public var sourceBundleID: UUID
    public var sourceSegmentID: UUID
    public var referenceSegmentID: UUID
    public var referenceFromSource: [Float]
    public var sourceFromReference: [Float]
    public var originalCameraToWorld: [Double]
    public var method: String
    public init(runID: UUID, sourceBundleID: UUID, sourceSegmentID: UUID, referenceSegmentID: UUID,
                transform: simd_float4x4, originalCameraToWorld: [Double]) {
        self.runID = runID; self.sourceBundleID = sourceBundleID; self.sourceSegmentID = sourceSegmentID
        self.referenceSegmentID = referenceSegmentID
        referenceFromSource = SegmentRegistration.flatten(transform)
        sourceFromReference = SegmentRegistration.flatten(transform.inverse)
        self.originalCameraToWorld = originalCameraToWorld
        method = "reviewed-stable-segment-rigid-v1-uncalibrated"
    }
    public var isValid: Bool {
        guard method == "reviewed-stable-segment-rigid-v1-uncalibrated",
              let forward = SegmentRegistration.matrix(referenceFromSource), SegmentRegistration.rigid(forward),
              let reverse = SegmentRegistration.matrix(sourceFromReference), SegmentRegistration.rigid(reverse),
              let original = SegmentRegistration.matrix(originalCameraToWorld.map(Float.init)), SegmentRegistration.rigid(original) else { return false }
        return zip(SegmentRegistration.flatten(forward * reverse), SegmentRegistration.flatten(matrix_identity_float4x4)).allSatisfy { abs($0 - $1) < 0.0001 }
    }
}
