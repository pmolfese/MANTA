import Foundation
import simd

/// One native-resolution metric-depth frame and the calibration needed to place
/// every depth pixel in the shared ARKit world coordinate system.
public struct MetricDepthPointFrame: Sendable {
    public var depthValues: [Float]
    public var confidenceValues: [UInt8]?
    public var depthWidth: Int
    public var depthHeight: Int
    public var imageWidth: Int
    public var imageHeight: Int
    /// Column-major 3x3 RGB camera intrinsics.
    public var intrinsics: [Float]
    /// Column-major 4x4 camera-to-world transform.
    public var cameraToWorld: [Float]
    /// Unique within an accumulator; used to count distinct contributing views.
    public var frameID: Int

    public init(
        depthValues: [Float], confidenceValues: [UInt8]? = nil,
        depthWidth: Int, depthHeight: Int, imageWidth: Int, imageHeight: Int,
        intrinsics: [Float], cameraToWorld: [Float], frameID: Int
    ) {
        self.depthValues = depthValues
        self.confidenceValues = confidenceValues
        self.depthWidth = depthWidth
        self.depthHeight = depthHeight
        self.imageWidth = imageWidth
        self.imageHeight = imageHeight
        self.intrinsics = intrinsics
        self.cameraToWorld = cameraToWorld
        self.frameID = frameID
    }
}

public struct MetricDepthPointCloudConfiguration: Sendable, Equatable {
    public var voxelSizeMeters: Float
    public var minimumConfidence: UInt8
    public var minimumDepthMeters: Float
    public var maximumDepthMeters: Float

    public init(
        voxelSizeMeters: Float = 0.005, minimumConfidence: UInt8 = 2,
        minimumDepthMeters: Float = 0.20, maximumDepthMeters: Float = 2.0
    ) {
        self.voxelSizeMeters = voxelSizeMeters
        self.minimumConfidence = minimumConfidence
        self.minimumDepthMeters = minimumDepthMeters
        self.maximumDepthMeters = maximumDepthMeters
    }
}

/// A compact display/solver snapshot. `viewCounts` parallels `points` and makes
/// single-view evidence distinguishable from repeat observations.
public struct MetricDepthPointCloudSnapshot: Sendable, Equatable {
    public var points: [SIMD3<Float>]
    public var viewCounts: [UInt16]
    public var acceptedSampleCount: Int
    public var contributingFrameCount: Int
    public var revision: Int

    public init(
        points: [SIMD3<Float>] = [], viewCounts: [UInt16] = [],
        acceptedSampleCount: Int = 0, contributingFrameCount: Int = 0,
        revision: Int = 0
    ) {
        self.points = points
        self.viewCounts = viewCounts
        self.acceptedSampleCount = acceptedSampleCount
        self.contributingFrameCount = contributingFrameCount
        self.revision = revision
    }

    public var repeatObservedPointCount: Int {
        viewCounts.count(where: { $0 >= 2 })
    }

    /// Finds the front-most measured point close to a world-space ray. Repeated
    /// observations are preferred; single-view points provide an early-preview
    /// fallback until a second pass covers that surface.
    public func nearestPoint(
        toRayOrigin origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        maximumPerpendicularDistance: Float = 0.010
    ) -> SIMD3<Float>? {
        let length = simd_length(direction)
        guard length.isFinite, length > 0,
              maximumPerpendicularDistance.isFinite,
              maximumPerpendicularDistance > 0 else { return nil }
        let ray = direction / length

        func frontMost(minimumViews: UInt16) -> (point: SIMD3<Float>, distance: Float)? {
            var bestPoint: SIMD3<Float>?
            var bestDistance = Float.greatestFiniteMagnitude
            for (index, point) in points.enumerated() {
                guard index < viewCounts.count, viewCounts[index] >= minimumViews else { continue }
                let offset = point - origin
                let distanceAlongRay = simd_dot(offset, ray)
                guard distanceAlongRay >= 0, distanceAlongRay < bestDistance else { continue }
                let perpendicular = simd_length(offset - ray * distanceAlongRay)
                guard perpendicular <= maximumPerpendicularDistance else { continue }
                bestDistance = distanceAlongRay
                bestPoint = point
            }
            return bestPoint.map { ($0, bestDistance) }
        }

        guard let any = frontMost(minimumViews: 1) else { return nil }
        if let repeated = frontMost(minimumViews: 2),
           repeated.distance <= any.distance + 0.015 {
            return repeated.point
        }
        return any.point
    }
}

/// Incremental confidence-filtered fusion of native depth pixels into world-space
/// voxels. This is intentionally a value type: callers can own it in an actor for
/// live use or run it synchronously in an offline solver.
public struct MetricDepthPointCloudAccumulator: Sendable {
    private struct VoxelKey: Hashable, Sendable {
        var x: Int32
        var y: Int32
        var z: Int32
    }

    private struct Voxel: Sendable {
        var positionSum = SIMD3<Double>.zero
        var sampleCount = 0
        var viewCount = 0
        var lastFrameID = Int.min
    }

    public let configuration: MetricDepthPointCloudConfiguration
    private var voxels = [VoxelKey: Voxel]()
    private var acceptedSampleCount = 0
    private var contributingFrameCount = 0
    private var revision = 0

    public init(configuration: MetricDepthPointCloudConfiguration = .init()) {
        self.configuration = configuration
        voxels.reserveCapacity(80_000)
    }

    public mutating func reset() {
        voxels.removeAll(keepingCapacity: true)
        acceptedSampleCount = 0
        contributingFrameCount = 0
        revision &+= 1
    }

    /// Adds one complete depth frame. Invalid calibration, dimensions, or buffer
    /// lengths reject the frame without changing the accumulator.
    @discardableResult
    public mutating func ingest(
        _ frame: MetricDepthPointFrame, inside bounds: HeadBoundingBox
    ) -> Int {
        let count = frame.depthWidth * frame.depthHeight
        guard frame.depthWidth > 0, frame.depthHeight > 0,
              frame.imageWidth > 0, frame.imageHeight > 0,
              frame.depthValues.count == count,
              frame.confidenceValues == nil || frame.confidenceValues?.count == count,
              frame.intrinsics.count == 9, frame.cameraToWorld.count == 16,
              configuration.voxelSizeMeters.isFinite,
              configuration.voxelSizeMeters > 0 else { return 0 }

        let fx = frame.intrinsics[0]
        let fy = frame.intrinsics[4]
        let cx = frame.intrinsics[6]
        let cy = frame.intrinsics[7]
        guard fx.isFinite, fy.isFinite, fx != 0, fy != 0 else { return 0 }

        let center = SIMD3<Float>(
            Float(bounds.center.x), Float(bounds.center.y), Float(bounds.center.z))
        let halfExtent = SIMD3<Float>(
            Float(bounds.widthMeters / 2), Float(bounds.heightMeters / 2),
            Float(bounds.depthMeters / 2))
        guard all(halfExtent .> 0), all(center .< .infinity), all(center .> -.infinity) else {
            return 0
        }

        let transform = Self.matrix(frame.cameraToWorld)
        let scaleX = Float(frame.imageWidth) / Float(frame.depthWidth)
        let scaleY = Float(frame.imageHeight) / Float(frame.depthHeight)
        let voxelSize = configuration.voxelSizeMeters
        var accepted = 0

        for y in 0..<frame.depthHeight {
            for x in 0..<frame.depthWidth {
                let index = y * frame.depthWidth + x
                if let confidence = frame.confidenceValues,
                   confidence[index] < configuration.minimumConfidence { continue }
                let depth = frame.depthValues[index]
                guard depth.isFinite,
                      depth >= configuration.minimumDepthMeters,
                      depth <= configuration.maximumDepthMeters else { continue }

                let imageX = (Float(x) + 0.5) * scaleX
                let imageY = (Float(y) + 0.5) * scaleY
                let camera = SIMD4<Float>(
                    (imageX - cx) / fx * depth,
                    -(imageY - cy) / fy * depth,
                    -depth,
                    1)
                let transformed = transform * camera
                let world = SIMD3(transformed.x, transformed.y, transformed.z)
                let delta = abs(world - center)
                guard delta.x <= halfExtent.x,
                      delta.y <= halfExtent.y,
                      delta.z <= halfExtent.z else { continue }

                let key = VoxelKey(
                    x: Int32(floor(world.x / voxelSize)),
                    y: Int32(floor(world.y / voxelSize)),
                    z: Int32(floor(world.z / voxelSize)))
                var voxel = voxels[key] ?? Voxel()
                voxel.positionSum += SIMD3<Double>(world)
                voxel.sampleCount += 1
                if voxel.lastFrameID != frame.frameID {
                    voxel.viewCount += 1
                    voxel.lastFrameID = frame.frameID
                }
                voxels[key] = voxel
                accepted += 1
            }
        }

        guard accepted > 0 else { return 0 }
        acceptedSampleCount += accepted
        contributingFrameCount += 1
        revision &+= 1
        return accepted
    }

    /// Produces a deterministic, bounded snapshot suitable for rendering or
    /// solver input. The accumulator retains all voxels regardless of this cap.
    public func snapshot(
        minimumViews: Int = 1, maximumPoints: Int = 80_000
    ) -> MetricDepthPointCloudSnapshot {
        guard maximumPoints > 0 else {
            return MetricDepthPointCloudSnapshot(
                acceptedSampleCount: acceptedSampleCount,
                contributingFrameCount: contributingFrameCount,
                revision: revision)
        }
        var retained = voxels.values.filter { $0.viewCount >= minimumViews }
        retained.sort {
            let left = $0.positionSum / Double(max(1, $0.sampleCount))
            let right = $1.positionSum / Double(max(1, $1.sampleCount))
            if left.x != right.x { return left.x < right.x }
            if left.y != right.y { return left.y < right.y }
            return left.z < right.z
        }
        let stride = max(1, Int(ceil(Double(retained.count) / Double(maximumPoints))))
        let selected = Swift.stride(from: 0, to: retained.count, by: stride).map { retained[$0] }
        return MetricDepthPointCloudSnapshot(
            points: selected.map { SIMD3<Float>($0.positionSum / Double($0.sampleCount)) },
            viewCounts: selected.map { UInt16(clamping: $0.viewCount) },
            acceptedSampleCount: acceptedSampleCount,
            contributingFrameCount: contributingFrameCount,
            revision: revision)
    }

    private static func matrix(_ values: [Float]) -> simd_float4x4 {
        simd_float4x4(
            SIMD4(values[0], values[1], values[2], values[3]),
            SIMD4(values[4], values[5], values[6], values[7]),
            SIMD4(values[8], values[9], values[10], values[11]),
            SIMD4(values[12], values[13], values[14], values[15]))
    }
}
