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

/// Capture admission is separate from metric admission. A held frame is still saved.
/// Sustained disagreement latches until a new capture (or a future validated alignment).
public struct CaptureMotionGate: Sendable {
    public private(set) var isHolding = false
    public private(set) var requiresAlignment = false
    private var disagreements = 0
    private var agreements = 0
    private var lastTimestamp: Double?

    public init() {}

    public mutating func holdForAlignment() {
        isHolding = true
        requiresAlignment = true
        agreements = 0
    }

    /// Called only after the recovery controller validates withheld frames.
    public mutating func resumeAfterAlignment(at timestamp: Double? = nil) {
        if let timestamp, !timestamp.isFinite || lastTimestamp.map({ timestamp <= $0 }) == true { return }
        isHolding = false
        requiresAlignment = false
        disagreements = 0
        agreements = 0
    }

    public mutating func assess(_ assessment: CaptureMotionAssessment, timestamp: Double) -> CaptureMotionAssessment {
        var result = assessment
        guard timestamp.isFinite, lastTimestamp.map({ timestamp > $0 }) ?? true else {
            result.state = requiresAlignment ? .suspected : .insufficientEvidence
            return result
        }
        lastTimestamp = timestamp
        if requiresAlignment { result.state = .suspected; return result }
        switch assessment.state {
        case .suspected:
            isHolding = true
            agreements = 0
            disagreements += 1
            if disagreements >= 3 { requiresAlignment = true }
        case .insufficientEvidence:
            isHolding = true
            agreements = 0
            disagreements = 0
        case .consistent:
            disagreements = 0
            if isHolding {
                agreements += 1
                if agreements >= 3 { isHolding = false; agreements = 0 }
            }
        case .unassessed:
            disagreements = 0
            agreements = 0
        }
        if isHolding { result.state = requiresAlignment ? .suspected : .insufficientEvidence }
        return result
    }
}

public enum CaptureMotionPolicy {
    /// Only a capture with validated live recovery can omit held frames from a
    /// metric solve. Other segments and malformed corrections still reach the
    /// normal rejection policy. Raw capture and export keep every frame.
    public static func metricFrames<Frame>(_ frames: [Frame], quality: (Frame) -> CaptureQualityMetrics?) -> [Frame] {
        let references = Set(frames.compactMap { frame -> UUID? in
            guard let q = quality(frame), q.motionAssessment?.state == .consistent,
                  let live = q.liveMotionCorrection, live.supportsFrame(timestamp: q.arFrameTimestamp),
                  q.motionAssessment?.segmentID == live.referenceSegmentID else { return nil }
            return live.referenceSegmentID
        })
        guard references.count == 1, let reference = references.first else { return frames }
        return frames.filter { frame in
            guard let q = quality(frame), q.liveMotionCorrection == nil, q.motionCorrection == nil,
                  q.motionAssessment?.segmentID == reference else { return true }
            return q.motionAssessment?.state != .suspected && q.motionAssessment?.state != .insufficientEvidence
        }
    }

    public static func needsIndependentImageSolve(_ qualities: [CaptureQualityMetrics?]) -> Bool {
        let motion = qualities.compactMap { $0?.motionAssessment }
        return motion.contains { $0.state == .suspected || $0.state == .insufficientEvidence }
            || Set(motion.map(\.segmentID)).count > 1
            || qualities.contains { $0?.motionCorrection != nil || $0?.liveMotionCorrection != nil }
    }

    /// Masked independent reconstruction estimates its own cameras without AR
    /// pose or gravity constraints. Camera-local depth may assist scale, but
    /// does not establish registration to any original coordinate world.
    public static func requireObjectCaptureCompatible(_ qualities: [CaptureQualityMetrics?], maskedIndependentSamples: Bool = false) throws {
        if maskedIndependentSamples { return }
        try requireStationary(qualities)
        if qualities.contains(where: { $0?.motionCorrection != nil || $0?.liveMotionCorrection != nil }) {
            throw MotionError.requiresMaskedReconstruction
        }
    }

    public static func requireStationary(_ qualities: [CaptureQualityMetrics?]) throws {
        for quality in qualities {
            if let live = quality?.liveMotionCorrection {
                guard let quality, live.supportsFrame(timestamp: quality.arFrameTimestamp), quality.motionCorrection == nil,
                      quality.motionAssessment?.state == .consistent,
                      quality.motionAssessment?.segmentID == live.referenceSegmentID else {
                    throw MotionError.requiresReview
                }
            }
        }
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
        if motion.contains(where: { $0.state == .suspected || $0.state == .insufficientEvidence }) || Set(motion.map(\.segmentID)).count > 1 {
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
