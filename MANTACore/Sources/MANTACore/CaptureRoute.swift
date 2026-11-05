import Foundation

public enum CaptureRouteStep: String, Codable, CaseIterable, Hashable, Sendable {
    case setup, reference, orbit, photos, review, finish
    public var title: String { rawValue.capitalized }
    public var index: Int { Self.allCases.firstIndex(of: self)! }
    public var next: Self? { Self.allCases.dropFirst(index + 1).first }
}

/// Operator workflow, separate from measured evidence and file-validation results.
/// Advancing never invents completed checks; skipped stops remain visible.
public struct CaptureRouteProgress: Codable, Equatable, Sendable {
    public var selectedStep: CaptureRouteStep = .setup
    public var acknowledgedSteps: Set<CaptureRouteStep> = []
    public var skippedSteps: Set<CaptureRouteStep> = []
    public var reviewedObservationCount: Int?
    public var previousSessionID: UUID?

    public init() {}

    public mutating func select(_ step: CaptureRouteStep, acknowledgingCurrent: Bool = false) {
        if acknowledgingCurrent, selectedStep != .finish {
            acknowledgedSteps.insert(selectedStep)
            skippedSteps.remove(selectedStep)
        }
        if step.index > selectedStep.index {
            for passed in CaptureRouteStep.allCases[selectedStep.index..<step.index]
                where !acknowledgedSteps.contains(passed) {
                skippedSteps.insert(passed)
            }
        }
        selectedStep = step
    }

    public mutating func invalidateReview() {
        reviewedObservationCount = nil
        if acknowledgedSteps.remove(.review) != nil { skippedSteps.insert(.review) }
    }

    public mutating func flagMovement() {
        invalidateReview()
        for step in [CaptureRouteStep.reference, .orbit, .photos] {
            acknowledgedSteps.remove(step)
            skippedSteps.insert(step)
        }
        selectedStep = .reference
    }
}
