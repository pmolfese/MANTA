import Foundation
import Testing
import simd
@testable import MANTACore

struct CaptureMotionTests {
    let id = UUID()
    var reference: [SIMD3<Float>] { (0..<100).map { SIMD3(Float($0 % 10) * 0.01, Float($0 / 10) * 0.01, 0) } }
    @Test func distinguishesConsistencyDisplacementAndMissingOverlap() {
        #expect(CaptureMotionCheck.assess(points: reference, reference: reference, segmentID: id).state == .consistent)
        let shifted = reference.map { $0 + SIMD3<Float>(0, 0, 0.035) }
        #expect(CaptureMotionCheck.assess(points: shifted, reference: reference, segmentID: id).state == .suspected)
        let far = reference.map { $0 + SIMD3<Float>(0, 0, 0.2) }
        #expect(CaptureMotionCheck.assess(points: far, reference: reference, segmentID: id).state == .insufficientEvidence)
        #expect(CaptureMotionCheck.assess(points: [], reference: reference, segmentID: id).state == .insufficientEvidence)
    }
    @Test func durableMovementMarkerFlagsRecoveredCheckpoint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let acquisition = root.appendingPathComponent("acquisition")
        let checkpoints = acquisition.appendingPathComponent("observations")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let session = ScanSession.newSession(layout: .headMeshOnly)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped",
            ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5,
            darkPixelFraction: 0, brightPixelFraction: 0, sharpnessScore: 1,
            translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: id, state: .consistent)
        let observation = CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: .init(width: 2, height: 2), hasSceneDepth: false, meshAnchorCount: 0,
            trackingSummary: "Normal", quality: quality)
        try JSONEncoder().encode(observation).write(to: checkpoints.appendingPathComponent("frame.json"))
        try JSONEncoder().encode(Date()).write(to: acquisition.appendingPathComponent("motion-stop.json"))
        let recovered = try MANTAWorkingSessionLoader.load(from: root)
        #expect(recovered.captureObservations.first?.quality?.motionAssessment?.state == .suspected)
        #expect(throws: (any Error).self) {
            try CaptureMotionPolicy.requireStationary(recovered.captureObservations.map(\.quality))
        }
    }

    @Test func motionEvidenceRoundTripsAndBlocksUnsafeSolve() throws {
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped",
            ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5,
            darkPixelFraction: 0, brightPixelFraction: 0, sharpnessScore: 1,
            translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: id, state: .suspected, residualMeters: 0.035)
        let decoded = try JSONDecoder().decode(CaptureQualityMetrics.self, from: JSONEncoder().encode(quality))
        #expect(decoded == quality)
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary([decoded]) }
        quality.motionAssessment = nil
        try CaptureMotionPolicy.requireStationary([nil, quality])
        quality.motionAssessment = .init(segmentID: id, state: .consistent)
        var other = quality
        other.motionAssessment?.segmentID = UUID()
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary([quality, other]) }
    }
}
