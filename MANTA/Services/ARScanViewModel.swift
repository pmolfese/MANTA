//
//  ARScanViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import Combine
import simd

#if canImport(ARKit) && canImport(RealityKit)
import ARKit
import RealityKit

@MainActor
final class ARScanViewModel: NSObject, ObservableObject {
    @Published var status = LiveScanStatus(isSupported: ARWorldTrackingConfiguration.isSupported)
    @Published var observations: [CaptureObservation] = []

    private weak var arView: ARView?
    private var meshAnchorIDs = Set<UUID>()

    func attach(_ arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        status.isSupported = ARWorldTrackingConfiguration.isSupported
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported else {
            status.message = "AR world tracking is not available on this device."
            status.isSupported = false
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.environmentTexturing = .automatic

        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
        }

        meshAnchorIDs.removeAll()
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        status.isRunning = true
        status.message = "Move around the cap slowly; keep electrodes in view and avoid motion blur."
    }

    func pause() {
        arView?.session.pause()
        status.isRunning = false
        status.message = "Scan paused."
    }

    func sampleCurrentFrame() -> CaptureObservation? {
        guard let frame = arView?.session.currentFrame else {
            status.message = "No AR frame is available yet."
            return nil
        }

        let observation = makeObservation(from: frame)
        observations.append(observation)
        status.sampledFrameCount = observations.count
        status.lastSampledAt = observation.capturedAt
        status.message = "Sampled frame \(observations.count)."
        return observation
    }

    private func updateStatus(from frame: ARFrame) {
        status.frameCount += 1
        status.trackingSummary = trackingSummary(frame.camera.trackingState)
        status.hasSceneDepth = frame.sceneDepth != nil
        status.meshAnchorCount = meshAnchorIDs.count
    }

    private func makeObservation(from frame: ARFrame) -> CaptureObservation {
        let resolution = frame.camera.imageResolution

        return CaptureObservation(
            capturedAt: Date(),
            cameraTransform: frame.camera.transform.flattened,
            cameraIntrinsics: frame.camera.intrinsics.flattened,
            imageResolution: ImageResolution(width: Int(resolution.width), height: Int(resolution.height)),
            hasSceneDepth: frame.sceneDepth != nil,
            meshAnchorCount: meshAnchorIDs.count,
            trackingSummary: trackingSummary(frame.camera.trackingState)
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
            for anchor in anchors where anchor is ARMeshAnchor {
                self.meshAnchorIDs.insert(anchor.identifier)
            }
            self.status.meshAnchorCount = self.meshAnchorIDs.count
        }
    }

    nonisolated func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        Task { @MainActor in
            for anchor in anchors {
                self.meshAnchorIDs.remove(anchor.identifier)
            }
            self.status.meshAnchorCount = self.meshAnchorIDs.count
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

    func start() {}
    func pause() {}
    func sampleCurrentFrame() -> CaptureObservation? { nil }
}
#endif
