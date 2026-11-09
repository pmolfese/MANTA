import Foundation

/// Operator-assigned view labels. These never change calibration or coordinate frames.
public enum CaptureGuidedView: String, Codable, CaseIterable, Sendable {
    case front, left, right, back, top
    public var title: String { rawValue.capitalized }
    public var guidance: String {
        switch self {
        case .front: "Face the participant; include the forehead and front electrodes."
        case .left: "Move to the participant’s left; include the ear and nearby electrodes."
        case .right: "Move to the participant’s right; include the ear and nearby electrodes."
        case .back: "Move behind the participant; include the rear and lower electrodes."
        case .top: "Look down toward the crown; keep a comfortable distance."
        }
    }
    public var headGuidance: String {
        switch self {
        case .front: "Face the participant; include the forehead and both sides of the face."
        case .left: "Move to the participant’s left; include the ear and side of the head."
        case .right: "Move to the participant’s right; include the ear and side of the head."
        case .back: "Move behind the participant; include the rear and lower head."
        case .top: "Look down toward the crown; keep a comfortable distance."
        }
    }
}

public enum CaptureReviewPolicy {
    /// Only committed, sharp, non-suspect stills satisfy a view checkpoint. A queued
    /// request, ordinary video sample, or untagged still never checks a box silently.
    public static func savedViews(_ observations: [CaptureObservation]) -> Set<CaptureGuidedView> {
        Set(observations.compactMap { observation in
            guard observation.cameraSnapshotFilename != nil,
                  observation.quality?.captureSource == "high-resolution-still",
                  (observation.quality?.sharpnessScore ?? 0) >= 0.025,
                  observation.quality?.motionAssessment?.state != .suspected,
                  observation.quality?.motionAssessment?.state != .insufficientEvidence else { return nil }
            return observation.quality?.guidedView
        })
    }
}

/// An operator review snapshot, not a certificate of measurement completeness.
public struct CaptureReviewRecord: Codable, Equatable, Hashable, Sendable {
    public var reviewedAt: Date
    public var observationCount: Int
    public var processedLiveFrameCount: Int
    public var missingViews: [String]
    public var unreadLabels: [String]
    public var ambiguousLabels: [String]
    public var singleViewLabels: [String]
    public var motionFlagged: Bool
    public var geometry: CaptureGeometryReview?
    public init(reviewedAt: Date = Date(), observationCount: Int, processedLiveFrameCount: Int,
                missingViews: [String], unreadLabels: [String], ambiguousLabels: [String],
                singleViewLabels: [String], motionFlagged: Bool, geometry: CaptureGeometryReview? = nil) {
        self.reviewedAt = reviewedAt; self.observationCount = observationCount
        self.processedLiveFrameCount = processedLiveFrameCount; self.missingViews = missingViews
        self.unreadLabels = unreadLabels; self.ambiguousLabels = ambiguousLabels
        self.singleViewLabels = singleViewLabels; self.motionFlagged = motionFlagged
        self.geometry = geometry
    }
}
