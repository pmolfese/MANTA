import Foundation
import Testing
import simd
@testable import MANTACore

struct SegmentRegistrationTests {
    private var cloud: [SIMD3<Float>] {
        (0..<120).map { i in
            let x = Float(i % 6) * 0.025
            let y = Float((i / 6) % 5) * 0.03
            let z = Float(i / 30) * 0.035 + Float(i % 3) * 0.004
            return SIMD3<Float>(x, y, z)
        }
    }
    private var landmarks: [SIMD3<Float>] { [SIMD3(0,0,0), SIMD3(0.15,0,0), SIMD3(0,0.15,0), SIMD3(0,0,0.15)] }
    private var truth: simd_float4x4 {
        var t = simd_float4x4(simd_quatf(angle: 0.3, axis: simd_normalize(SIMD3<Float>(1,2,3))))
        t.columns.3 = SIMD4(0.03, -0.02, 0.04, 1); return t
    }
    @Test func recoversRigidMotionAndPreservesMetricScale() throws {
        let result = SegmentRegistration.solve(source: cloud, reference: cloud.map { SegmentRegistration.point($0, truth) },
            sourceLandmarks: landmarks, referenceLandmarks: landmarks.map { SegmentRegistration.point($0, truth) })
        #expect(result.accepted)
        let matrix = try #require(result.referenceFromSource.flatMap(SegmentRegistration.matrix))
        #expect(SegmentRegistration.rigid(matrix))
        for point in cloud { #expect(simd_distance(SegmentRegistration.point(point, matrix), SegmentRegistration.point(point, truth)) < 0.0001) }
    }
    @Test func rejectsDegenerateScaleAndPoorOverlapRatherThanIdentityFallback() {
        let line = (0..<60).map { SIMD3<Float>(Float($0) * 0.01, 0, 0) }
        #expect(!SegmentRegistration.solve(source: line, reference: line, sourceLandmarks: landmarks, referenceLandmarks: landmarks).accepted)
        let scaled = SegmentRegistration.solve(source: cloud, reference: cloud.map { $0 * 1.3 }, sourceLandmarks: landmarks, referenceLandmarks: landmarks.map { $0 * 1.3 })
        #expect(!scaled.accepted)
        #expect(scaled.referenceFromSource == nil)
        let far = SegmentRegistration.solve(source: cloud, reference: cloud.map { $0 + SIMD3<Float>(1,1,1) }, sourceLandmarks: landmarks, referenceLandmarks: landmarks)
        #expect(!far.accepted)
        #expect(!SegmentRegistration.frameAgrees(points: cloud.map { $0 + SIMD3<Float>(1,0,0) }, reference: cloud, transform: matrix_identity_float4x4))
    }
    @Test func correctionMovesCameraRaysAndPointsTogetherWithoutMutatingOriginal() throws {
        let original = matrix_identity_float4x4
        let corrected = SegmentRegistration.camera(original, referenceFromSource: truth)
        let point = SIMD3<Float>(0.02, 0.03, -0.5)
        let cameraPoint = corrected * SIMD4(point, 1)
        #expect(simd_distance(SIMD3(cameraPoint.x,cameraPoint.y,cameraPoint.z), SegmentRegistration.point(point, truth)) < 0.00001)
        #expect(abs(simd_length(SegmentRegistration.direction(SIMD3(0,0,-1), truth)) - 1) < 0.00001)
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped", ambientIntensity: nil,
            ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
            sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        let segment = UUID()
        quality.motionAssessment = .init(segmentID: segment, state: .suspected)
        quality.motionCorrection = .init(runID: UUID(), sourceBundleID: UUID(), sourceSegmentID: segment,
            referenceSegmentID: UUID(), transform: truth, originalCameraToWorld: SegmentRegistration.flatten(original).map(Double.init))
        try CaptureMotionPolicy.requireStationary([quality])
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireObjectCaptureCompatible([quality]) }
        try CaptureMotionPolicy.requireObjectCaptureCompatible([nil])
        #expect(quality.motionAssessment?.state == .suspected)
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary([quality, nil]) }
        var inconsistent = quality
        var shifted = truth
        shifted.columns.3.x += 0.01
        inconsistent.motionCorrection = .init(runID: quality.motionCorrection!.runID, sourceBundleID: quality.motionCorrection!.sourceBundleID,
            sourceSegmentID: segment, referenceSegmentID: quality.motionCorrection!.referenceSegmentID,
            transform: shifted, originalCameraToWorld: SegmentRegistration.flatten(original).map(Double.init))
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary([quality, inconsistent]) }
        quality.motionCorrection?.referenceFromSource[0] = 2
        #expect(throws: (any Error).self) { try CaptureMotionPolicy.requireStationary([quality]) }
    }
}
