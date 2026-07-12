//
//  ARScanViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import MANTACore
import Combine
import CoreGraphics
import simd

#if canImport(ARKit) && canImport(RealityKit)
import ARKit
import RealityKit

@MainActor
final class ARScanViewModel: NSObject, ObservableObject {
    @Published var status = LiveScanStatus(isSupported: ARWorldTrackingConfiguration.isSupported)
    @Published var observations: [CaptureObservation] = []

    private weak var arView: ARView?
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var lastSampledTransform: simd_float4x4?

    func attach(_ arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        status.isSupported = ARWorldTrackingConfiguration.isSupported
    }

    func start(captureMode: CaptureMode = .both) {
        guard ARWorldTrackingConfiguration.isSupported else {
            status.message = "AR world tracking is not available on this device."
            status.isSupported = false
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .automatic

        // LiDAR depth + mesh are only enabled for modes that use them. Photogrammetry-only
        // capture still runs world tracking so every RGB frame carries an ARKit pose.
        if captureMode.usesLiDAR {
            if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
                configuration.frameSemantics.insert(.sceneDepth)
            }

            if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
                configuration.sceneReconstruction = .mesh
            }
        }

        meshAnchors.removeAll()
        lastSampledTransform = nil
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        status.isRunning = true
        status.message = captureMode.usesLiDAR
            ? "Move around the cap slowly; keep electrodes in view and avoid motion blur."
            : "Circle the head, keeping frames sharp and well-lit for photogrammetry."
    }

    func pause() {
        arView?.session.pause()
        status.isRunning = false
        status.message = "Scan paused."
    }

    func sampleCurrentFrame(artifactStore: CaptureArtifactStore, session: ScanSession) throws -> CaptureObservation? {
        guard let frame = arView?.session.currentFrame else {
            status.message = "No AR frame is available yet."
            return nil
        }

        var observation = makeObservation(from: frame)
        observation.cameraSnapshotFilename = try artifactStore.writeCameraSnapshot(
            pixelBuffer: frame.capturedImage,
            observationID: observation.id,
            for: session
        )

        if session.captureMode.usesLiDAR, let depthMap = frame.sceneDepth?.depthMap {
            let depthArtifact = try artifactStore.writeDepthSnapshot(
                depthMap: depthMap,
                confidenceMap: frame.sceneDepth?.confidenceMap,
                observationID: observation.id,
                for: session
            )
            observation.depthSnapshotFilename = depthArtifact.filename
            observation.rawDepthFilename = depthArtifact.rawDepthFilename
            observation.rawDepthFormat = depthArtifact.rawDepthFormat
            observation.rawConfidenceFilename = depthArtifact.rawConfidenceFilename
            observation.rawConfidenceFormat = depthArtifact.rawConfidenceFormat
            observation.confidenceSummary = depthArtifact.confidenceSummary
            observation.depthSummary = depthArtifact.summary
            let totalDepthPixels = depthArtifact.summary.width * depthArtifact.summary.height
            observation.quality?.validDepthFraction = totalDepthPixels > 0
                ? Double(depthArtifact.summary.validPixelCount) / Double(totalDepthPixels) : nil
            if let summary = depthArtifact.confidenceSummary {
                let total = summary.lowConfidenceCount + summary.mediumConfidenceCount
                    + summary.highConfidenceCount + summary.unknownConfidenceCount
                observation.quality?.highConfidenceDepthFraction = total > 0
                    ? Double(summary.highConfidenceCount) / Double(total) : nil
            }
            if let fraction = observation.quality?.validDepthFraction, fraction < 0.5 {
                observation.quality?.warnings.append("low-depth-coverage")
            }
        }

        observations.append(observation)
        lastSampledTransform = frame.camera.transform
        status.sampledFrameCount = observations.count
        status.lastSampledAt = observation.capturedAt
        status.message = observation.depthSnapshotFilename == nil
            ? "Sampled frame \(observations.count) with camera snapshot."
            : "Sampled frame \(observations.count) with camera and depth snapshots."
        return observation
    }

    /// Ray-casts a point in the AR view (view coordinates) against the scanned
    /// mesh/estimated surface and returns the hit in world coordinates. Used to
    /// place nasion/LPA/RPA fiducials by tapping the live scan.
    func raycastToWorld(viewPoint: CGPoint) -> SIMD3<Float>? {
        guard let arView else { return nil }

        let alignments: [ARRaycastQuery.TargetAlignment] = [.any]
        for alignment in alignments {
            if let query = arView.makeRaycastQuery(from: viewPoint, allowing: .estimatedPlane, alignment: alignment),
               let result = arView.session.raycast(query).first {
                let t = result.worldTransform.columns.3
                return SIMD3<Float>(t.x, t.y, t.z)
            }
        }
        return nil
    }

    /// World-space point cloud of the accumulated LiDAR reconstruction mesh.
    /// Vertices are transformed by each anchor's pose and roughly capped to `maxPoints`
    /// by subsampling so downstream ICP stays tractable.
    func meshWorldPoints(maxPoints: Int = 6000) -> [SIMD3<Float>] {
        let anchors = Array(meshAnchors.values)
        guard !anchors.isEmpty else { return [] }

        let totalVertices = anchors.reduce(0) { $0 + $1.geometry.vertices.count }
        guard totalVertices > 0 else { return [] }
        let stride = max(1, totalVertices / max(1, maxPoints))

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(min(totalVertices, maxPoints) + anchors.count)

        var globalIndex = 0
        for anchor in anchors {
            let vertices = anchor.geometry.vertices
            let buffer = vertices.buffer.contents()
            let transform = anchor.transform

            for i in 0..<vertices.count {
                defer { globalIndex += 1 }
                guard globalIndex % stride == 0 else { continue }

                let pointer = buffer
                    .advanced(by: vertices.offset + i * vertices.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self)
                let local = pointer.pointee
                let world = transform * SIMD4<Float>(local.0, local.1, local.2, 1)
                points.append(SIMD3<Float>(world.x, world.y, world.z))
            }
        }

        return points
    }

    /// Complete accumulated mesh evidence for persistence and deferred solving.
    /// Vertices are transformed into ARKit world coordinates and face indices
    /// are rebased into the combined vertex array.
    func fullMeshSnapshot() -> LiDARMeshSnapshot {
        var vertices = [SIMD3<Float>]()
        var triangles = [UInt32]()
        for anchor in meshAnchors.values {
            let geometry = anchor.geometry
            let baseIndex = UInt32(vertices.count)
            let source = geometry.vertices
            let buffer = source.buffer.contents()
            for index in 0..<source.count {
                let pointer = buffer.advanced(by: source.offset + index * source.stride)
                    .assumingMemoryBound(to: (Float, Float, Float).self)
                let local = pointer.pointee
                let world = anchor.transform * SIMD4<Float>(local.0, local.1, local.2, 1)
                vertices.append(SIMD3(world.x, world.y, world.z))
            }
            let faces = geometry.faces
            guard faces.indexCountPerPrimitive == 3 else { continue }
            let faceBuffer = faces.buffer.contents()
            for face in 0..<faces.count {
                for corner in 0..<3 {
                    let offset = (face * 3 + corner) * faces.bytesPerIndex
                    let value: UInt32
                    if faces.bytesPerIndex == 2 {
                        value = UInt32(faceBuffer.advanced(by: offset).load(as: UInt16.self))
                    } else {
                        value = faceBuffer.advanced(by: offset).load(as: UInt32.self)
                    }
                    triangles.append(baseIndex + value)
                }
            }
        }
        return LiDARMeshSnapshot(vertices: vertices, triangleIndices: triangles)
    }

    private func updateStatus(from frame: ARFrame) {
        status.frameCount += 1
        status.trackingSummary = trackingSummary(frame.camera.trackingState)
        status.hasSceneDepth = frame.sceneDepth != nil
        status.meshAnchorCount = meshAnchors.count
    }

    private func makeObservation(from frame: ARFrame) -> CaptureObservation {
        let resolution = frame.camera.imageResolution
        let imageMetrics = imageQuality(frame.capturedImage)
        let novelty = poseNovelty(frame.camera.transform)
        var warnings = [String]()
        if imageMetrics.sharpness < 0.025 { warnings.append("possible-motion-blur") }
        if imageMetrics.darkFraction > 0.25 { warnings.append("underexposed") }
        if imageMetrics.brightFraction > 0.25 { warnings.append("overexposed-or-glare") }
        if let translation = novelty.translation, let rotation = novelty.rotationDegrees,
           translation < 0.02, rotation < 5 {
            warnings.append("near-duplicate-view")
        }
        let light = frame.lightEstimate

        return CaptureObservation(
            capturedAt: Date(),
            cameraTransform: frame.camera.transform.flattened,
            cameraIntrinsics: frame.camera.intrinsics.flattened,
            imageResolution: ImageResolution(width: Int(resolution.width), height: Int(resolution.height)),
            hasSceneDepth: frame.sceneDepth != nil,
            meshAnchorCount: meshAnchors.count,
            trackingSummary: trackingSummary(frame.camera.trackingState),
            cameraSnapshotFilename: nil,
            depthSnapshotFilename: nil,
            rawDepthFilename: nil,
            rawDepthFormat: nil,
            rawConfidenceFilename: nil,
            rawConfidenceFormat: nil,
            confidenceSummary: nil,
            depthSummary: nil,
            quality: CaptureQualityMetrics(
                arFrameTimestamp: frame.timestamp,
                worldMappingStatus: worldMappingSummary(frame.worldMappingStatus),
                ambientIntensity: light.map { Double($0.ambientIntensity) },
                ambientColorTemperature: light.map { Double($0.ambientColorTemperature) },
                meanLuminance: imageMetrics.mean,
                darkPixelFraction: imageMetrics.darkFraction,
                brightPixelFraction: imageMetrics.brightFraction,
                sharpnessScore: imageMetrics.sharpness,
                translationFromPreviousSampleMeters: novelty.translation,
                rotationFromPreviousSampleDegrees: novelty.rotationDegrees,
                coverageSector: coverageSector(frame.camera.transform),
                warnings: warnings)
        )
    }

    private func poseNovelty(_ transform: simd_float4x4) -> (translation: Double?, rotationDegrees: Double?) {
        guard let previous = lastSampledTransform else { return (nil, nil) }
        let translation = simd_distance(previous.columns.3.xyz, transform.columns.3.xyz)
        let previousMatrix = simd_float3x3(
            previous.columns.0.xyz, previous.columns.1.xyz, previous.columns.2.xyz)
        let rotationMatrix = simd_float3x3(
            transform.columns.0.xyz, transform.columns.1.xyz, transform.columns.2.xyz)
        let previousRotation = simd_quatf(previousMatrix)
        let rotation = simd_quatf(rotationMatrix)
        let dot = min(1, abs(simd_dot(previousRotation.vector, rotation.vector)))
        let radians: Float = 2 * acos(dot)
        let degrees = radians * 180 / Float.pi
        return (Double(translation), Double(degrees))
    }

    private func coverageSector(_ transform: simd_float4x4) -> String {
        let direction = simd_normalize(-transform.columns.2.xyz)
        var azimuth = atan2(direction.x, -direction.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let azimuthBin = Int((azimuth + 22.5) / 45) % 8
        let elevation = asin(max(-1, min(1, direction.y))) * 180 / .pi
        let elevationBin = elevation > 20 ? "upper" : elevation < -20 ? "lower" : "level"
        return "azimuth-\(azimuthBin)-\(elevationBin)"
    }

    private func imageQuality(_ pixelBuffer: CVPixelBuffer) -> (
        mean: Double, darkFraction: Double, brightFraction: Double, sharpness: Double
    ) {
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        let plane = CVPixelBufferGetPlaneCount(pixelBuffer) > 0 ? 0 : -1
        guard let base = plane >= 0
            ? CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBaseAddress(pixelBuffer) else { return (0, 1, 0, 0) }
        let width = plane >= 0 ? CVPixelBufferGetWidthOfPlane(pixelBuffer, plane) : CVPixelBufferGetWidth(pixelBuffer)
        let height = plane >= 0 ? CVPixelBufferGetHeightOfPlane(pixelBuffer, plane) : CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = plane >= 0
            ? CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            : CVPixelBufferGetBytesPerRow(pixelBuffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, dark = 0, bright = 0, count = 0
        var gradient = 0
        let step = 8
        for y in stride(from: step, to: height, by: step) {
            for x in stride(from: step, to: width, by: step) {
                let value = Int(pixels[y * bytesPerRow + x])
                sum += value; count += 1
                if value <= 20 { dark += 1 }
                if value >= 235 { bright += 1 }
                gradient += abs(value - Int(pixels[y * bytesPerRow + x - step]))
                gradient += abs(value - Int(pixels[(y - step) * bytesPerRow + x]))
            }
        }
        guard count > 0 else { return (0, 1, 0, 0) }
        return (
            Double(sum) / Double(count) / 255,
            Double(dark) / Double(count), Double(bright) / Double(count),
            Double(gradient) / Double(count * 2) / 255)
    }

    private func worldMappingSummary(_ status: ARFrame.WorldMappingStatus) -> String {
        switch status {
        case .notAvailable: "not-available"
        case .limited: "limited"
        case .extending: "extending"
        case .mapped: "mapped"
        @unknown default: "unknown"
        }
    }

    private func trackingSummary(_ trackingState: ARCamera.TrackingState) -> String {
        switch trackingState {
        case .normal:
            return "Normal"
        case .notAvailable:
            return "Not available"
        case .limited(let reason):
            switch reason {
            case .excessiveMotion:
                return "Limited: excessive motion"
            case .insufficientFeatures:
                return "Limited: insufficient features"
            case .initializing:
                return "Limited: initializing"
            case .relocalizing:
                return "Limited: relocalizing"
            @unknown default:
                return "Limited"
            }
        }
    }
}

struct LiDARMeshSnapshot {
    var vertices: [SIMD3<Float>]
    var triangleIndices: [UInt32]
}

extension ARScanViewModel: ARSessionDelegate {
    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        Task { @MainActor in
            self.updateStatus(from: frame)
        }
    }

    nonisolated func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        Task { @MainActor in
            for case let anchor as ARMeshAnchor in anchors {
                self.meshAnchors[anchor.identifier] = anchor
            }
            self.status.meshAnchorCount = self.meshAnchors.count
        }
    }

    nonisolated func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        Task { @MainActor in
            for case let anchor as ARMeshAnchor in anchors {
                self.meshAnchors[anchor.identifier] = anchor
            }
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.meshAnchors.removeValue(forKey: anchor.identifier)
            }
            self.status.meshAnchorCount = self.meshAnchors.count
        }
    }
}

private extension simd_float4x4 {
    var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z, columns.0.w,
            columns.1.x, columns.1.y, columns.1.z, columns.1.w,
            columns.2.x, columns.2.y, columns.2.z, columns.2.w,
            columns.3.x, columns.3.y, columns.3.z, columns.3.w
        ]
    }
}

private extension simd_float3x3 {
    var flattened: [Float] {
        [
            columns.0.x, columns.0.y, columns.0.z,
            columns.1.x, columns.1.y, columns.1.z,
            columns.2.x, columns.2.y, columns.2.z
        ]
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3(x, y, z) }
}
#else
@MainActor
final class ARScanViewModel: ObservableObject {
    @Published var status = LiveScanStatus(message: "ARKit is unavailable in this build.")
    @Published var observations: [CaptureObservation] = []

    func start(captureMode: CaptureMode = .both) {}
    func pause() {}
    func sampleCurrentFrame(artifactStore: CaptureArtifactStore, session: ScanSession) throws -> CaptureObservation? { nil }
    func meshWorldPoints(maxPoints: Int = 6000) -> [SIMD3<Float>] { [] }
    func raycastToWorld(viewPoint: CGPoint) -> SIMD3<Float>? { nil }
}
#endif
