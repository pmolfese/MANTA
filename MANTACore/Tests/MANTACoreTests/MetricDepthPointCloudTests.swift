import Testing
@testable import MANTACore

struct MetricDepthPointCloudTests {
    private let identity4: [Float] = [
        1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1
    ]

    @Test func repeatedMetricDepthPixelsFuseInWorldSpace() {
        var accumulator = MetricDepthPointCloudAccumulator()
        let bounds = HeadBoundingBox(
            center: Coordinate3D(x: 0, y: 0, z: -1),
            widthMeters: 0.4, heightMeters: 0.4, depthMeters: 0.4)
        let frame = MetricDepthPointFrame(
            depthValues: [1], confidenceValues: [2],
            depthWidth: 1, depthHeight: 1, imageWidth: 1, imageHeight: 1,
            intrinsics: [1, 0, 0, 0, 1, 0, 0.5, 0.5, 1],
            cameraToWorld: identity4, frameID: 1)

        #expect(accumulator.ingest(frame, inside: bounds) == 1)
        var second = frame
        second.frameID = 2
        #expect(accumulator.ingest(second, inside: bounds) == 1)

        let snapshot = accumulator.snapshot(minimumViews: 2)
        #expect(snapshot.points.count == 1)
        #expect(snapshot.viewCounts == [2])
        #expect(snapshot.points[0] == SIMD3<Float>(0, 0, -1))
        #expect(snapshot.contributingFrameCount == 2)
        #expect(snapshot.acceptedSampleCount == 2)
    }

    @Test func confidenceAndHeadBoundsRejectUnsupportedSamples() {
        var accumulator = MetricDepthPointCloudAccumulator()
        let bounds = HeadBoundingBox(
            center: Coordinate3D(x: 0, y: 0, z: -1),
            widthMeters: 0.2, heightMeters: 0.2, depthMeters: 0.2)
        let lowConfidence = MetricDepthPointFrame(
            depthValues: [1], confidenceValues: [1],
            depthWidth: 1, depthHeight: 1, imageWidth: 1, imageHeight: 1,
            intrinsics: [1, 0, 0, 0, 1, 0, 0.5, 0.5, 1],
            cameraToWorld: identity4, frameID: 1)
        #expect(accumulator.ingest(lowConfidence, inside: bounds) == 0)

        var outside = lowConfidence
        outside.confidenceValues = [2]
        outside.cameraToWorld[12] = 1
        #expect(accumulator.ingest(outside, inside: bounds) == 0)
        #expect(accumulator.snapshot().points.isEmpty)
    }

    @Test func rayQueryPrefersRepeatObservedFrontSurface() {
        let snapshot = MetricDepthPointCloudSnapshot(
            points: [
                SIMD3<Float>(0.002, 0, -0.5),
                SIMD3<Float>(0, 0, -0.508),
                SIMD3<Float>(0.05, 0, -0.3)
            ],
            viewCounts: [1, 3, 5])
        let hit = snapshot.nearestPoint(
            toRayOrigin: .zero,
            direction: SIMD3<Float>(0, 0, -1),
            maximumPerpendicularDistance: 0.01)
        #expect(hit == SIMD3<Float>(0, 0, -0.508))
    }
}
