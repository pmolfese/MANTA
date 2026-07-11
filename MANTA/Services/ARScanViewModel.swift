//
//  ARScanViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
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
        }

        observations.append(observation)
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

    private func updateStatus(from frame: ARFrame) {
        status.frameCount += 1
        status.trackingSummary = trackingSummary(frame.camera.trackingState)
        status.hasSceneDepth = frame.sceneDepth != nil
        status.meshAnchorCount = meshAnchors.count
    }

    private func makeObservation(from frame: ARFrame) -> CaptureObservation {
        let resolution = frame.camera.imageResolution

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
            depthSummary: nil
        )
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
