import Foundation
import Testing
@testable import MANTACore

struct CaptureReviewTests {
    private func frame() -> CaptureObservation {
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped",
            ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0,
            brightPixelFraction: 0, sharpnessScore: 0.1, translationFromPreviousSampleMeters: nil,
            rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.captureSource = "high-resolution-still"
        quality.guidedView = .front
        quality.recaptureTargetLabel = "E1"
        return CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: .init(width: 10, height: 10), hasSceneDepth: false, meshAnchorCount: 0,
            trackingSummary: "Normal", cameraSnapshotFilename: "assets/still.png", quality: quality)
    }
    @Test func checklistRequiresSavedSharpTaggedStillAndRejectsMotion() {
        let saved = frame()
        #expect(CaptureReviewPolicy.savedViews([saved, saved]) == [.front])
        var queued = saved; queued.cameraSnapshotFilename = nil
        var blurred = saved; blurred.quality?.sharpnessScore = 0
        var regular = saved; regular.quality?.captureSource = "current-frame"
        var untagged = saved; untagged.quality?.guidedView = nil
        var moved = saved; moved.quality?.motionAssessment = .init(segmentID: UUID(), state: .suspected)
        #expect(CaptureReviewPolicy.savedViews([queued, blurred, regular, untagged, moved]).isEmpty)
    }
    @Test func newerCheckpointInvalidatesPriorReview() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoints = root.appendingPathComponent("acquisition/observations")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.acquisitionContext = AcquisitionContext()
        session.lastRawExportedBundleID = UUID()
        session.lastExportedBundleID = UUID()
        session.acquisitionContext?.captureReview = .init(observationCount: 0, processedLiveFrameCount: 0,
            missingViews: [], unreadLabels: [], ambiguousLabels: [], singleViewLabels: [], motionFlagged: false)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        #expect(try MANTAWorkingSessionLoader.load(from: root).acquisitionContext?.captureReview != nil)
        try JSONEncoder().encode(frame()).write(to: checkpoints.appendingPathComponent("new.json"))
        let recovered = try MANTAWorkingSessionLoader.load(from: root)
        #expect(recovered.captureObservations.count == 1)
        #expect(recovered.acquisitionContext?.captureReview == nil)
        #expect(recovered.lastRawExportedBundleID == nil)
        #expect(recovered.lastExportedBundleID == nil)
    }

    @Test func viewTagsAndReviewSnapshotRoundTripWithoutChangingCalibration() throws {
        let original = frame()
        let decoded = try JSONDecoder().decode(CaptureObservation.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.cameraTransform == original.cameraTransform)
        #expect(decoded.quality?.guidedView == .front)
        var context = AcquisitionContext()
        context.captureReview = .init(observationCount: 1, processedLiveFrameCount: 0,
            missingViews: ["left", "right", "back", "top"], unreadLabels: ["E2"],
            ambiguousLabels: ["E3"], singleViewLabels: ["E1"], motionFlagged: false)
        #expect(try JSONDecoder().decode(AcquisitionContext.self, from: JSONEncoder().encode(context)) == context)
        #expect(try JSONDecoder().decode(AcquisitionContext.self, from: Data("{}".utf8)).captureReview == nil)
    }
}
