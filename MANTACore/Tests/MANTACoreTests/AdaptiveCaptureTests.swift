import Foundation
import Testing
@testable import MANTACore

struct AdaptiveCaptureTests {
    @Test func adaptiveGateKeepsOverlapAndRejectsBlurEvenAtMaximumGap() {
        #expect(!AdaptiveCapturePolicy.shouldSample(elapsed: 0.2, minimumGap: 0.75, sharpness: 1, translation: 1, rotationDegrees: 30, newSector: true))
        #expect(!AdaptiveCapturePolicy.shouldSample(elapsed: 1, minimumGap: 0.75, sharpness: 1, translation: 0, rotationDegrees: 0, newSector: false))
        #expect(AdaptiveCapturePolicy.shouldSample(elapsed: 3, minimumGap: 0.75, sharpness: 1, translation: 0, rotationDegrees: 0, newSector: false))
        #expect(!AdaptiveCapturePolicy.shouldSample(elapsed: 10, minimumGap: 0.75, sharpness: 0, translation: 1, rotationDegrees: 30, newSector: true))
        #expect(AdaptiveCapturePolicy.shouldSample(elapsed: 1, minimumGap: 0.75, sharpness: 1, translation: 0.03, rotationDegrees: 0, newSector: false))
    }
    @Test func stillGateRequiresSteadinessFreshnessSharpnessAndUnsavedSector() {
        #expect(AdaptiveCapturePolicy.canTakeStill(stableSeconds: 0.4, sharpness: 0.1, fresh: true, sectorSaved: false))
        #expect(!AdaptiveCapturePolicy.canTakeStill(stableSeconds: 0.2, sharpness: 0.1, fresh: true, sectorSaved: false))
        #expect(!AdaptiveCapturePolicy.canTakeStill(stableSeconds: 1, sharpness: 0.1, fresh: false, sectorSaved: false))
        #expect(!AdaptiveCapturePolicy.canTakeStill(stableSeconds: 1, sharpness: 0.1, fresh: true, sectorSaved: true))
        #expect(!AdaptiveCapturePolicy.canTakeStill(stableSeconds: 1, sharpness: .nan, fresh: true, sectorSaved: false))
    }
    @Test func coverageNeedsDistinctViewsAndDoesNotInflateDuplicateReads() {
        var coverage = LiveLabelCoverage()
        var pose: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let item = LiveLabelSighting(label: "E1", confidence: 0.9, imageX: 1, imageY: 1)
        let id = UUID()
        coverage.ingest([item], observationID: id, pose: pose)
        coverage.ingest([item], observationID: id, pose: pose)
        coverage.ingest([item], observationID: UUID(), pose: pose)
        #expect(coverage.seenLabels == ["E1"])
        #expect(coverage.supportedLabels.isEmpty)
        pose[12] = 0.03
        coverage.ingest([item], observationID: UUID(), pose: pose)
        #expect(coverage.supportedLabels == ["E1"])
        coverage.ingest([item, item], observationID: UUID(), pose: pose)
        #expect(coverage.ambiguousLabels == ["E1"])
        #expect(coverage.seenLabels.isEmpty)
        #expect(coverage.supportedLabels.isEmpty)
    }
    @Test func lowConfidenceAndInvalidPoseNeverCompleteCoverage() {
        var coverage = LiveLabelCoverage()
        coverage.ingest([.init(label: "E1", confidence: 0.3, imageX: 1, imageY: 1)], observationID: UUID(),
                        pose: [1,0,0,0,0,1,0,0,0,0,1,0,0,0,0,1])
        coverage.ingest([.init(label: "E2", confidence: 1, imageX: 1, imageY: 1)], observationID: UUID(), pose: [])
        #expect(coverage.seenLabels.isEmpty)
    }
}
