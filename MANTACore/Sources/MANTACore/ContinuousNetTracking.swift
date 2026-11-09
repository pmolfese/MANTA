import Foundation
import simd

public struct NetPoseSample: Sendable {
    public var transform: simd_float4x4
    public var timestamp: Double
    public var landmarkTimestamp: Double
    public var labelCount: Int
    public var residualMeters: Float
}

/// Owned, bounded work for the background tracker. No camera buffers or mutable state.
public struct NetPoseTrackingRequest: Sendable {
    public var points: [SIMD3<Float>]
    public var reference: [SIMD3<Float>]
    public var seed: NetPoseSample
    public var timestamp: Double

    public func solve() -> NetPoseSample? {
        guard timestamp.isFinite, timestamp >= seed.timestamp,
              timestamp - seed.landmarkTimestamp <= ContinuousNetTracker.maximumLandmarkAge,
              seed.labelCount >= 4, SegmentRegistration.rigid(seed.transform),
              points.count >= 50, reference.count >= 50,
              (points + reference).allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else { return nil }
        func bounded(_ p: [SIMD3<Float>], count: Int) -> [SIMD3<Float>] {
            stride(from: 0, to: p.count, by: max(1, (p.count + count - 1) / count)).map { p[$0] }
        }
        let source = bounded(points, count: 192), target = bounded(reference, count: 768)
        guard SegmentRegistration.spatiallyDistributed(source) else { return nil }
        let fit = ICP.align(source: source, target: target, seed: seed.transform,
                            scaleMode: .rigid, maxIterations: 10, tolerance: 0.00001)
        guard SegmentRegistration.rigid(fit.transform) else { return nil }
        let displacement = sqrt(source.reduce(Float(0)) {
            $0 + simd_distance_squared(SegmentRegistration.point($1, fit.transform), SegmentRegistration.point($1, seed.transform))
        } / Float(source.count))
        let relative = fit.transform * seed.transform.inverse
        let rotation = simd_float3x3(SIMD3(relative[0].x, relative[0].y, relative[0].z),
                                    SIMD3(relative[1].x, relative[1].y, relative[1].z),
                                    SIMD3(relative[2].x, relative[2].y, relative[2].z))
        let angle = acos(min(1, max(-1, (rotation[0].x + rotation[1].y + rotation[2].z - 1) / 2)))
        let metrics = SegmentRegistration.metrics(source.map { SegmentRegistration.point($0, fit.transform) }, target)
        guard displacement <= 0.025, angle <= 12 * .pi / 180,
              metrics.overlap >= 0.8, metrics.rms <= 0.008 else { return nil }
        return NetPoseSample(transform: fit.transform, timestamp: timestamp,
            landmarkTimestamp: seed.landmarkTimestamp, labelCount: seed.labelCount, residualMeters: metrics.rms)
    }
}

/// Label identities anchor local depth tracking to a fixed net frame. Confirmed
/// anchors never follow incoming observations, preventing a moving reference.
public struct ContinuousNetTracker: Sendable {
    public static let maximumLandmarkAge: Double = 3
    public private(set) var anchors: [String: SIMD3<Float>] = [:]
    public private(set) var hasLandmarkConflict = false
    public private(set) var consecutivePoseCount = 0
    private var candidates: [String: (point: SIMD3<Float>, count: Int)] = [:]
    private var seeds: [NetPoseSample] = []
    private var poses: [NetPoseSample] = []
    private var lastLandmarkTimestamp = -Double.infinity
    private var lastPoseTimestamp = -Double.infinity

    public init() {}

    /// Input landmarks are always in original AR coordinates, including held frames.
    /// Only independently admitted frames can establish new reference anchors.
    public mutating func observe(_ landmarks: [LabeledDetection], timestamp: Double,
                                 trustedReferenceFromWorld: simd_float4x4?) {
        guard timestamp.isFinite, timestamp > lastLandmarkTimestamp else { return }
        lastLandmarkTimestamp = timestamp
        let groups = Dictionary(grouping: landmarks, by: \.label)
        let unique = groups.values.compactMap { group -> LabeledDetection? in
            guard group.count == 1, let point = group.first, point.quality >= 0.9,
                  point.world.x.isFinite, point.world.y.isFinite, point.world.z.isFinite else { return nil }
            return point
        }.sorted { $0.label < $1.label }
        if let trusted = trustedReferenceFromWorld, SegmentRegistration.rigid(trusted), !hasLandmarkConflict {
            for point in unique where anchors[point.label] == nil {
                let position = SegmentRegistration.point(point.world, trusted)
                let prior = candidates[point.label]
                if let prior, simd_distance(prior.point, position) <= 0.008 {
                    let count = prior.count + 1
                    let mean = (prior.point * Float(prior.count) + position) / Float(count)
                    candidates[point.label] = (mean, count)
                    if count >= 3 { anchors[point.label] = mean; candidates[point.label] = nil }
                } else { candidates[point.label] = (position, 1) }
            }
        }
        let matched = unique.filter { anchors[$0.label] != nil }
        guard matched.count >= 4 else { return }
        let source = matched.map(\.world), target = matched.map { anchors[$0.label]! }
        guard SegmentRegistration.noncollinear(source), SegmentRegistration.noncollinear(target),
              let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .rigid),
              SegmentRegistration.rigid(fit.transform), fit.rmsError <= 0.005,
              zip(source, target).allSatisfy({ simd_distance(SegmentRegistration.point($0, fit.transform), $1) <= 0.008 }) else {
            hasLandmarkConflict = true
            consecutivePoseCount = 0
            poses = []
            seeds = []
            return
        }
        hasLandmarkConflict = false
        let prior = poses.last { $0.timestamp <= timestamp && timestamp - $0.timestamp <= 0.25 }
        let agreesWithHistory = prior.map { pose in
            zip(source, target).allSatisfy { simd_distance(SegmentRegistration.point($0, pose.transform), $1) <= 0.01 }
        } ?? false
        if agreesWithHistory {
            // Delayed OCR confirms the corresponding historical pose, then refreshes
            // the identity support of newer depth poses derived from that history.
            for index in poses.indices where poses[index].timestamp >= timestamp {
                poses[index].landmarkTimestamp = timestamp
                poses[index].labelCount = matched.count
            }
        } else {
            poses = []
            consecutivePoseCount = 0
        }
        seeds.append(.init(transform: fit.transform, timestamp: timestamp, landmarkTimestamp: timestamp,
                           labelCount: matched.count, residualMeters: fit.rmsError))
        if seeds.count > 16 { seeds.removeFirst() }
    }

    public func seed(at timestamp: Double) -> NetPoseSample? {
        guard !hasLandmarkConflict else { return nil }
        let landmark = seeds.last { $0.timestamp <= timestamp && timestamp - $0.timestamp <= Self.maximumLandmarkAge }
        guard let landmark else { return nil }
        // A newly observed label pose supersedes older depth-only extrapolation.
        return poses.last { $0.timestamp <= timestamp && $0.timestamp >= landmark.timestamp && $0.landmarkTimestamp == landmark.timestamp } ?? landmark
    }

    public func request(points: [SIMD3<Float>], reference: [SIMD3<Float>], timestamp: Double) -> NetPoseTrackingRequest? {
        guard let seed = seed(at: timestamp) else { return nil }
        // Register the observed net neighborhood, rather than unrelated face/body
        // or room surfaces that happen to lie inside the coarse head box.
        let centers = Array(anchors.values)
        func nearNet(_ point: SIMD3<Float>) -> Bool {
            centers.contains { simd_distance_squared(point, $0) <= 0.07 * 0.07 }
        }
        let localPoints = points.filter { nearNet(SegmentRegistration.point($0, seed.transform)) }
        let localReference = reference.filter(nearNet)
        return .init(points: localPoints, reference: localReference, seed: seed, timestamp: timestamp)
    }

    /// Out-of-order camera/capture callbacks cannot change the current tracking state.
    @discardableResult
    public mutating func record(_ pose: NetPoseSample) -> Bool {
        guard !hasLandmarkConflict, pose.timestamp.isFinite, pose.landmarkTimestamp.isFinite,
              pose.timestamp >= pose.landmarkTimestamp, pose.timestamp > lastPoseTimestamp,
              pose.labelCount >= 4, SegmentRegistration.rigid(pose.transform),
              pose.residualMeters.isFinite, pose.residualMeters <= 0.008,
              pose.timestamp - pose.landmarkTimestamp <= Self.maximumLandmarkAge else { return false }
        if pose.timestamp - lastPoseTimestamp > 0.6 { consecutivePoseCount = 0 }
        lastPoseTimestamp = pose.timestamp
        poses.append(pose)
        if poses.count > 64 { poses.removeFirst() }
        consecutivePoseCount += 1
        return consecutivePoseCount >= 3
    }

    public mutating func miss(at timestamp: Double) {
        guard timestamp > lastPoseTimestamp else { return }
        lastPoseTimestamp = timestamp
        consecutivePoseCount = 0
    }

    public var isTracking: Bool { consecutivePoseCount >= 3 && !hasLandmarkConflict }
}
