import Foundation
import Testing
@testable import MANTACore

struct CaptureGeometryReviewTests {
    private func frame(x: Float = 0, z: Float = -0.5) -> CaptureObservation {
        let pose: [Float] = [1,0,0,0, 0,1,0,0, 0,0,1,0, x,0,z,1]
        let quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped",
            ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5,
            darkPixelFraction: 0, brightPixelFraction: 0, sharpnessScore: 0.1,
            translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "legacy")
        return .init(capturedAt: Date(), cameraTransform: pose, cameraIntrinsics: [],
            imageResolution: .init(width: 10, height: 10), hasSceneDepth: true,
            meshAnchorCount: 20, trackingSummary: "Normal", cameraSnapshotFilename: "image.png", quality: quality)
    }

    @Test func viewCoverageNeedsBoundsAndDoesNotCountRepeatedOrUnusableViews() {
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.captureObservations = [frame(), frame(), frame(x: 0.5, z: 0)]
        #expect(CaptureGeometryReview(session: session).viewSectorCount == nil)
        session.headBoundingBox = .init(center: .zero)
        #expect(CaptureGeometryReview(session: session).viewSectorCount == 2)
        var suspect = frame(x: -0.5, z: 0)
        suspect.quality?.motionAssessment = .init(segmentID: UUID(), state: .suspected)
        var blurry = frame(z: 0.5); blurry.quality?.warnings = ["possible-motion-blur"]
        var unknown = frame(z: 0.5); unknown.quality = nil
        var malformed = frame(z: 0.5); malformed.cameraTransform[12] = .nan
        var unsaved = frame(z: 0.5); unsaved.cameraSnapshotFilename = nil
        session.captureObservations += [suspect, blurry, unknown, malformed, unsaved]
        let result = CaptureGeometryReview(session: session)
        #expect(result.viewSectorCount == 2)
        #expect(result.motionSuspectCount == 1)
        #expect(result.motionUnknownCount == 7)
        #expect(result.blurWarningCount == 1)
        #expect(result.unknownSharpnessCount == 1)
    }

    @Test func sensorAvailabilityDoesNotInventRecordedDepthOrHeadSurface() {
        var session = ScanSession.newSession(layout: .headMeshOnly)
        var depth = frame()
        depth.rawDepthFilename = "depth.zlib"
        depth.rawDepthFormat = .init(width: 10, height: 10, scalarType: "float32", byteOrder: "little-endian",
            units: .meters, layout: "row-major", compression: "zlib")
        depth.quality?.motionAssessment = .init(segmentID: UUID(), state: .consistent)
        session.captureObservations = [frame(), depth]
        session.lidarMeshFilename = "environment.ply"
        let result = CaptureGeometryReview(session: session)
        #expect(result.observationCount == 2)
        #expect(result.depthFrameCount == 1)
        #expect(result.confidenceFrameCount == 0)
        #expect(result.environmentMeshRecorded)
        #expect(!result.headMeshRecorded)
        #expect(result.motionConsistentCount == 1 && result.motionUnknownCount == 1)
    }

    @Test func savedReviewRoundTripsAndOlderReviewsRemainReadable() throws {
        let original = CaptureReviewRecord(observationCount: 0, processedLiveFrameCount: 0,
            missingViews: [], unreadLabels: [], ambiguousLabels: [], singleViewLabels: [], motionFlagged: false)
        #expect(try JSONDecoder().decode(CaptureReviewRecord.self, from: JSONEncoder().encode(original)).geometry == nil)
        var updated = original
        updated.geometry = CaptureGeometryReview(session: .newSession(layout: .headMeshOnly))
        #expect(try JSONDecoder().decode(CaptureReviewRecord.self, from: JSONEncoder().encode(updated)) == updated)
    }
}
