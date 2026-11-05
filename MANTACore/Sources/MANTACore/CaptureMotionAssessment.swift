import Foundation
import simd

public struct CaptureMotionAssessment: Codable, Equatable, Hashable, Sendable {
    public enum State: String, Codable, Sendable { case unassessed, insufficientEvidence, consistent, suspected }
    public var segmentID: UUID
    public var state: State
    public var residualMeters: Float?
    public var overlapFraction: Float?
    public init(segmentID: UUID, state: State, residualMeters: Float? = nil, overlapFraction: Float? = nil) {
        self.segmentID = segmentID; self.state = state
        self.residualMeters = residualMeters; self.overlapFraction = overlapFraction
    }
}

/// Conservative consistency advisory, not a motion transform or calibrated error.
/// Reference points are frozen by the operator and never absorb incoming samples.
public enum CaptureMotionCheck {
    public static func assess(points: [SIMD3<Float>], reference: [SIMD3<Float>], segmentID: UUID) -> CaptureMotionAssessment {
        let finite = points.filter { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }
        guard finite.count >= 20, reference.count >= 50 else {
            return .init(segmentID: segmentID, state: .insufficientEvidence)
        }
        let distances = finite.map { point in
            reference.reduce(Float.infinity) { min($0, simd_distance(point, $1)) }
        }.sorted()
        let overlap = Float(distances.filter { $0 < 0.06 }.count) / Float(distances.count)
        guard overlap >= 0.5 else {
            return .init(segmentID: segmentID, state: .insufficientEvidence, overlapFraction: overlap)
        }
        let residual = distances[distances.count / 2]
        return .init(segmentID: segmentID, state: residual > 0.025 ? .suspected : .consistent,
                     residualMeters: residual, overlapFraction: overlap)
    }
}

public enum CaptureMotionPolicy {
    public static func needsIndependentImageSolve(_ qualities: [CaptureQualityMetrics?]) -> Bool {
        let motion = qualities.compactMap { $0?.motionAssessment }
        return motion.contains { $0.state == .suspected }
            || Set(motion.map(\.segmentID)).count > 1
            || qualities.contains { $0?.motionCorrection != nil }
    }

    /// Masked independent reconstruction estimates its own cameras without AR
    /// pose or gravity constraints. Camera-local depth may assist scale, but
    /// does not establish registration to any original coordinate world.
    public static func requireObjectCaptureCompatible(_ qualities: [CaptureQualityMetrics?], maskedIndependentSamples: Bool = false) throws {
        if maskedIndependentSamples { return }
        try requireStationary(qualities)
        if qualities.contains(where: { $0?.motionCorrection != nil }) {
            throw MotionError.requiresMaskedReconstruction
        }
    }

    public static func requireStationary(_ qualities: [CaptureQualityMetrics?]) throws {
        let corrections = qualities.compactMap { $0?.motionCorrection }
        if !corrections.isEmpty {
            guard corrections.count == qualities.count, corrections.allSatisfy(\.isValid),
                  Set(corrections.map(\.referenceSegmentID)).count == 1,
                  Set(corrections.map(\.runID)).count == 1,
                  qualities.allSatisfy({ q in q?.motionAssessment == nil || q?.motionAssessment?.segmentID == q?.motionCorrection?.sourceSegmentID }) else {
                throw MotionError.requiresReview
            }
            for group in Dictionary(grouping: corrections, by: \.sourceSegmentID).values {
                guard let first = group.first, group.allSatisfy({
                    $0.sourceBundleID == first.sourceBundleID && $0.referenceFromSource == first.referenceFromSource
                }) else { throw MotionError.requiresReview }
            }
            return
        }
        let motion = qualities.compactMap { $0?.motionAssessment }
        if motion.contains(where: { $0.state == .suspected }) || Set(motion.map(\.segmentID)).count > 1 {
            throw MotionError.requiresReview
        }
    }
    private enum MotionError: LocalizedError {
        case requiresReview
        case requiresMaskedReconstruction
        var errorDescription: String? {
            switch self {
            case .requiresReview:
                "Metric processing requires stationary or registered passes. Use masked Images only for a visual reconstruction across passes, or the reviewed stable-segment recovery workflow for depth and calibrated rays."
            case .requiresMaskedReconstruction:
                "Recovered segments support depth fusion and calibrated image rays. Use masked Images only for a fresh Object Capture reconstruction; depth-guided Object Capture cannot reuse the corrected camera poses."
            }
        }
    }
}
