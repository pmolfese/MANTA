import Foundation
import Testing
import simd
@testable import MANTACore

struct ContinuousNetTrackingTests {
    private var cloud: [SIMD3<Float>] {
        (0..<180).map { i in
            let a = Float(i) * 2.399963
            let z = Float(i) / 179 * 2 - 1
            let r = sqrt(max(0, 1 - z * z))
            return SIMD3(0.09 * r * cos(a) + 0.025 * z * z,
                         0.13 * z, 0.07 * r * sin(a) * (1 + 0.3 * z))
        }
    }
    private var labels: [LabeledDetection] {
        [0, 25, 70, 120, 160].enumerated().map { .init(label: "E\($0.offset + 1)", world: cloud[$0.element]) }
    }
    private func trained() -> ContinuousNetTracker {
        var tracker = ContinuousNetTracker()
        for time in [0.0, 0.1, 0.2] { tracker.observe(labels, timestamp: time, trustedReferenceFromWorld: matrix_identity_float4x4) }
        return tracker
    }
    private func translation(_ x: Float) -> simd_float4x4 {
        var t = matrix_identity_float4x4; t.columns.3.x = x; return t
    }

    @Test func movingNetIsTrackedContinuouslyInFixedReferenceCoordinates() throws {
        var tracker = trained()
        let anchors = tracker.anchors
        #expect(anchors.count == 5)
        for step in 3...24 {
            let timestamp = Double(step) / 10
            let truth = translation(Float(step - 2) * 0.002)
            let moved = cloud.map { SegmentRegistration.point($0, truth.inverse) }
            let request = try #require(tracker.request(points: moved, reference: cloud, timestamp: timestamp))
            let pose = try #require(request.solve())
            _ = tracker.record(pose)
            #expect(zip(moved, cloud).allSatisfy { simd_distance(SegmentRegistration.point($0, pose.transform), $1) < 0.002 })
            if step >= 5 { #expect(tracker.isTracking) }
        }
        #expect(tracker.anchors == anchors)
        #expect(tracker.request(points: cloud, reference: cloud, timestamp: 3.3) == nil)
    }

    @Test func heldLabelsCanReacquireFarAwayWithoutBecomingReferenceMeasurements() throws {
        var tracker = trained()
        let anchors = tracker.anchors
        let truth = translation(0.25)
        let movedLabels = labels.map { LabeledDetection(label: $0.label, world: SegmentRegistration.point($0.world, truth.inverse)) }
        tracker.observe(movedLabels + [.init(label: "E99", world: SIMD3(1,1,1))], timestamp: 1, trustedReferenceFromWorld: nil)
        #expect(tracker.anchors["E99"] == nil)
        #expect(tracker.anchors == anchors)
        let moved = cloud.map { SegmentRegistration.point($0, truth.inverse) }
        for time in [1.1, 1.2, 1.3] {
            let pose = try #require(tracker.request(points: moved, reference: cloud, timestamp: time)?.solve())
            _ = tracker.record(pose)
        }
        #expect(tracker.isTracking)
        let seed = try #require(tracker.seed(at: 1.3))
        #expect(abs(seed.transform.columns.3.x - 0.25) < 0.002)
    }

    @Test func deformationRejectsPoseAndCannotMoveConfirmedAnchors() {
        var tracker = trained()
        let original = tracker.anchors
        var deformed = labels
        deformed[0].world.x += 0.04
        tracker.observe(deformed, timestamp: 1, trustedReferenceFromWorld: nil)
        #expect(tracker.hasLandmarkConflict)
        #expect(tracker.seed(at: 1.1) == nil)
        #expect(tracker.anchors == original)
        tracker.observe(labels, timestamp: 1.2, trustedReferenceFromWorld: nil)
        #expect(!tracker.hasLandmarkConflict)
        #expect(tracker.seed(at: 1.3) != nil)
    }

    @Test func delayedLabelConfirmationRefreshesNewerDepthPoses() throws {
        var tracker = trained()
        for time in [0.3, 0.4, 0.5, 0.6, 0.7] {
            let pose = try #require(tracker.request(points: cloud, reference: cloud, timestamp: time)?.solve())
            _ = tracker.record(pose)
        }
        tracker.observe(labels, timestamp: 0.5, trustedReferenceFromWorld: nil)
        #expect(tracker.seed(at: 0.7)?.landmarkTimestamp == 0.5)
        #expect(tracker.isTracking)
        // Repeated or out-of-order OCR cannot refresh identity support indefinitely.
        tracker.observe(labels, timestamp: 0.5, trustedReferenceFromWorld: nil)
        #expect(tracker.seed(at: 3.6) == nil)
    }

    @Test func depthLossLargeJumpsAndDuplicateIdentitiesDoNotEstablishTracking() throws {
        var tracker = trained()
        #expect(tracker.request(points: [], reference: cloud, timestamp: 0.3)?.solve() == nil)
        let far = cloud.map { $0 + SIMD3<Float>(0.2,0,0) }
        #expect(tracker.request(points: far, reference: cloud, timestamp: 0.4)?.solve() == nil)
        let pose = try #require(tracker.request(points: cloud, reference: cloud, timestamp: 0.5)?.solve())
        _ = tracker.record(pose)
        _ = tracker.record(pose)
        #expect(!tracker.isTracking)
        tracker.miss(at: 0.6)
        #expect(tracker.consecutivePoseCount == 0)
        var ambiguous = ContinuousNetTracker()
        let duplicated = Array(labels.prefix(4)) + [labels[0]]
        for time in [0.0, 0.1, 0.2] { ambiguous.observe(duplicated, timestamp: time, trustedReferenceFromWorld: matrix_identity_float4x4) }
        #expect(ambiguous.seed(at: 0.3) == nil)
    }

    @Test func unrelatedSurfacesAreExcludedFromNetRegistration() throws {
        let tracker = trained()
        let background = (0..<100).map { SIMD3<Float>(Float($0) / 100, 1, 1) }
        let request = try #require(tracker.request(points: cloud + background, reference: cloud + background, timestamp: 0.3))
        #expect(request.points.count <= cloud.count)
        #expect(request.reference.count <= cloud.count)
        #expect(request.solve() != nil)
    }

    @Test func continuousCorrectionRequiresFreshIdentitiesAndRoundTrips() throws {
        var correction = LiveMotionCorrection(referenceSegmentID: UUID(), transform: translation(0.02),
            originalCameraToWorld: SegmentRegistration.flatten(matrix_identity_float4x4), validatedFrameCount: 3)
        correction.method = "net-anchored-continuous-rigid-v1"
        #expect(correction.correctedCameraToWorld == nil)
        correction.trackedLabelCount = 4
        correction.landmarkTimestamp = 2
        #expect(correction.supportsFrame(timestamp: 2.1))
        #expect(!correction.supportsFrame(timestamp: 1.9))
        #expect(!correction.supportsFrame(timestamp: 5.1))
        let decoded = try JSONDecoder().decode(LiveMotionCorrection.self, from: JSONEncoder().encode(correction))
        #expect(decoded == correction)
        #expect(decoded.matches(camera: try #require(decoded.correctedCameraToWorld)))
    }
}
