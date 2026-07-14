import Foundation
import MANTACore

struct LiveMetricDepthFusionUpdate: Sendable {
    var snapshot: MetricDepthPointCloudSnapshot
    var elapsedSeconds: Double
}

/// Serializes incremental fusion off the main actor. The 6 mm live preview is a
/// deliberately lighter derivative of the raw evidence; offline reconstruction
/// can still use every saved pixel at a stricter resolution.
actor LiveMetricDepthFusion {
    private var accumulator = MetricDepthPointCloudAccumulator(configuration: .init(
        voxelSizeMeters: 0.006,
        minimumConfidence: 2,
        minimumDepthMeters: 0.20,
        maximumDepthMeters: 2.0))
    private var activeSessionID: UUID?
    private var activeBounds: HeadBoundingBox?
    private var ingestedFrameCount = 0
    private var lastSnapshotAt: ContinuousClock.Instant?
    private let snapshotInterval = Duration.milliseconds(1_250)

    func reset(to sessionID: UUID?) {
        accumulator.reset()
        activeSessionID = sessionID
        activeBounds = nil
        ingestedFrameCount = 0
        lastSnapshotAt = nil
    }

    func ingest(
        _ frame: MetricDepthPointFrame,
        sessionID: UUID,
        bounds: HeadBoundingBox
    ) -> LiveMetricDepthFusionUpdate? {
        if activeSessionID == nil { activeSessionID = sessionID }
        guard activeSessionID == sessionID else { return nil }
        if activeBounds != bounds {
            accumulator.reset()
            activeBounds = bounds
            ingestedFrameCount = 0
            lastSnapshotAt = nil
        }

        let started = ContinuousClock.now
        guard accumulator.ingest(frame, inside: bounds) > 0 else { return nil }
        ingestedFrameCount += 1
        let now = ContinuousClock.now
        if let lastSnapshotAt,
           lastSnapshotAt.duration(to: now) < snapshotInterval {
            return nil
        }
        lastSnapshotAt = now
        let snapshot = accumulator.snapshot(
            minimumViews: ingestedFrameCount >= 3 ? 2 : 1,
            maximumPoints: 30_000)
        let elapsed = started.duration(to: .now)
        let components = elapsed.components
        let seconds = Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
        return LiveMetricDepthFusionUpdate(snapshot: snapshot, elapsedSeconds: seconds)
    }
}
