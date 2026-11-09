import Foundation
import Testing
import simd
@testable import MANTACore

struct LiveMotionRecoveryTests {
    private var cloud: [SIMD3<Float>] {
        (0..<180).map { i in
            let angle = Float(i) * 2.399963
            let z = Float(i) / 179 * 2 - 1
            let r = sqrt(max(0, 1 - z * z))
            return SIMD3(0.09 * r * cos(angle) + 0.025 * z * z,
                         0.13 * z, 0.07 * r * sin(angle) * (1 + 0.3 * z))
        }
    }
    private var transform: simd_float4x4 {
        var t = simd_float4x4(simd_quatf(angle: 0.4, axis: simd_normalize(SIMD3<Float>(1,2,3))))
        t.columns.3 = SIMD4(0.035, -0.02, 0.01, 1)
        return t
    }
    private func result(_ t: simd_float4x4) -> SegmentRegistrationResult {
        .init(accepted: true, reason: "Fixture", referenceFromSource: SegmentRegistration.flatten(t),
              rmsMeters: 0, sourceOverlap: 1, referenceOverlap: 1)
    }

    @Test func automaticSolveNeedsThreeWithheldFramesAndRejectsRepeatedTimestamps() throws {
        let reference = cloud
        let moved = reference.map { SegmentRegistration.point($0, transform.inverse) }
        let solved = SegmentRegistration.solveAutomatic(source: moved, reference: reference)
        #expect(solved.accepted, "\(solved.reason)")
        var recovery = LiveMotionRecovery()
        let accepted1 = recovery.propose(solved, reference: reference, timestamp: 1)
        #expect(accepted1)
        let accepted2 = !recovery.validate(points: moved, timestamp: 1)
        #expect(accepted2)
        let accepted3 = !recovery.validate(points: moved, timestamp: 2)
        #expect(accepted3)
        let accepted4 = !recovery.validate(points: moved, timestamp: 2)
        #expect(accepted4)
        let accepted5 = !recovery.validate(points: moved, timestamp: 3)
        #expect(accepted5)
        #expect(recovery.transform == nil)
        let accepted6 = recovery.validate(points: moved, timestamp: 4)
        #expect(accepted6)
        let accepted = try #require(recovery.transform)
        #expect(zip(moved, reference).allSatisfy { simd_distance(SegmentRegistration.point($0, accepted), $1) < 0.002 })
    }

    @Test func continuedMovementAndMissingDepthDiscardCandidate() {
        var recovery = LiveMotionRecovery()
        let accepted7 = recovery.propose(result(matrix_identity_float4x4), reference: cloud, timestamp: 1)
        #expect(accepted7)
        let accepted8 = !recovery.validate(points: cloud, timestamp: 2)
        #expect(accepted8)
        let accepted9 = !recovery.validate(points: cloud.map { $0 + SIMD3(0.1,0,0) }, timestamp: 3)
        #expect(accepted9)
        #expect(!recovery.hasCandidate)
        #expect(recovery.transform == nil)
        let accepted10 = recovery.propose(result(matrix_identity_float4x4), reference: cloud, timestamp: 4)
        #expect(accepted10)
        let accepted11 = !recovery.validate(points: [], timestamp: 5)
        #expect(accepted11)
        #expect(!recovery.hasCandidate)
        var rejected = result(transform); rejected.accepted = false
        let accepted12 = !recovery.propose(rejected, reference: cloud, timestamp: 6)
        #expect(accepted12)
    }

    @Test func secondMovementUsesAbsoluteReferenceTransformRatherThanCompounding() throws {
        var recovery = LiveMotionRecovery()
        for (offset, t) in [(0, transform), (4, transform.inverse)] {
            let moved = cloud.map { SegmentRegistration.point($0, t.inverse) }
            let accepted13 = recovery.propose(result(t), reference: cloud, timestamp: Double(offset))
            #expect(accepted13)
            for step in 1...3 { _ = recovery.validate(points: moved, timestamp: Double(offset + step)) }
            #expect(SegmentRegistration.flatten(try #require(recovery.transform)) == SegmentRegistration.flatten(t))
        }
    }

    @Test func correctionRoundTripsAndMovesCameraRaysAndDepthTogether() throws {
        let original = SegmentRegistration.flatten(matrix_identity_float4x4)
        let correction = LiveMotionCorrection(referenceSegmentID: UUID(), transform: transform,
            originalCameraToWorld: original, validatedFrameCount: 3)
        let decoded = try JSONDecoder().decode(LiveMotionCorrection.self, from: JSONEncoder().encode(correction))
        #expect(decoded == correction)
        let camera = try #require(decoded.correctedCameraToWorld)
        #expect(decoded.matches(camera: camera))
        #expect(!decoded.matches(camera: original))
        #expect(decoded.originalCameraToWorld == original)
        let local = SIMD3<Float>(0.02, 0.01, -0.6)
        let pose = try #require(SegmentRegistration.matrix(camera))
        #expect(simd_distance(SegmentRegistration.point(local, pose), SegmentRegistration.point(local, transform)) < 0.00001)
        var bad = decoded; bad.validatedFrameCount = 2
        #expect(bad.correctedCameraToWorld == nil)
    }

    @Test func bundleValidatorChecksCorrectionAgainstStoredCamera() throws {
        let source = try #require(Bundle.module.url(forResource: "Minimal128", withExtension: nil, subdirectory: "Fixtures"))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.copyItem(at: source, to: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.json")
        var capture = try MANTAJSON.makeDecoder().decode(MANTACaptureDocument.self, from: Data(contentsOf: url))
        let segment = UUID()
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped", ambientIntensity: nil,
            ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
            sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: segment, state: .consistent)
        let original = capture.observations[0].cameraToWorld.map(Float.init)
        let correction = LiveMotionCorrection(referenceSegmentID: segment, transform: transform,
            originalCameraToWorld: original, validatedFrameCount: 3)
        quality.liveMotionCorrection = correction
        capture.observations[0].quality = quality
        capture.observations[0].cameraToWorld = try #require(correction.correctedCameraToWorld).map(Double.init)
        try MANTAJSON.makeEncoder().encode(capture).write(to: url)
        let loaded = try MANTABundleValidator().validate(directory: root)
        #expect(loaded.capture.observations[0].quality?.liveMotionCorrection == correction)
        capture.observations[0].quality?.liveMotionCorrection?.method = "net-anchored-continuous-rigid-v1"
        capture.observations[0].quality?.liveMotionCorrection?.trackedLabelCount = 4
        capture.observations[0].quality?.liveMotionCorrection?.landmarkTimestamp = 1
        try MANTAJSON.makeEncoder().encode(capture).write(to: url)
        _ = try MANTABundleValidator().validate(directory: root)
        capture.observations[0].quality?.liveMotionCorrection?.landmarkTimestamp = 1.1
        try MANTAJSON.makeEncoder().encode(capture).write(to: url)
        #expect(throws: (any Error).self) { try MANTABundleValidator().validate(directory: root) }
        capture.observations[0].quality?.liveMotionCorrection?.landmarkTimestamp = 1
        // A later explicit movement flag may withdraw trust without destroying provenance/export.
        capture.observations[0].quality?.motionAssessment?.state = .suspected
        try MANTAJSON.makeEncoder().encode(capture).write(to: url)
        _ = try MANTABundleValidator().validate(directory: root)
        capture.observations[0].cameraToWorld[12] += 0.1
        try MANTAJSON.makeEncoder().encode(capture).write(to: url)
        #expect(throws: (any Error).self) { try MANTABundleValidator().validate(directory: root) }
    }

    @Test func metricSelectionRetainsTrustedFramesWithoutHidingOtherSegments() throws {
        let id = UUID()
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped", ambientIntensity: nil,
            ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
            sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: id, state: .consistent)
        let trusted = quality
        quality.motionAssessment?.state = .suspected
        let held = quality
        quality.motionAssessment?.state = .consistent
        quality.liveMotionCorrection = .init(referenceSegmentID: id, transform: transform,
            originalCameraToWorld: SegmentRegistration.flatten(matrix_identity_float4x4), validatedFrameCount: 3)
        let raw = [trusted, held, quality]
        let admitted = CaptureMotionPolicy.metricFrames(raw, quality: { $0 })
        #expect(admitted.count == 2)
        #expect(raw.count == 3)
        try CaptureMotionPolicy.requireStationary(admitted)
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireObjectCaptureCompatible(admitted) }
        #expect(CaptureMotionPolicy.needsIndependentImageSolve(admitted))
        var other = held; other.motionAssessment?.segmentID = UUID()
        let mixed = CaptureMotionPolicy.metricFrames(raw + [other], quality: { $0 })
        #expect(mixed.count == 3)
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary(mixed) }
        #expect(CaptureMotionPolicy.metricFrames([trusted, held], quality: { $0 }).count == 2)
    }
}
