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

struct FiducialRaycastResult {
    var point: SIMD3<Float>
    var rayOrigin: SIMD3<Float>?
    var rayDirection: SIMD3<Float>?
    var hitMethod: String
    var observationID: UUID?
}

#if canImport(ARKit) && canImport(RealityKit)
import ARKit
import RealityKit

@MainActor
final class ARScanViewModel: NSObject, ObservableObject {
    @Published var status = LiveScanStatus(isSupported: ARWorldTrackingConfiguration.isSupported)
    @Published var observations: [CaptureObservation] = []
    var eventHandler: ((AcquisitionEvent) -> Void)?

    // The capture session outlives an individual SwiftUI Camera/Model tab.
    // Keeping the ARView strongly owned here prevents a visual-mode switch from
    // tearing down RealityKit and silently pausing an otherwise running scan.
    private var arView: ARView?
    private var meshAnchors: [UUID: ARMeshAnchor] = [:]
    private var lastSampledTransform: simd_float4x4?
    private var lastReportedTrackingSummary: String?
    private var hasReportedFirstFrame = false

    func attach(_ arView: ARView) {
        self.arView = arView
        arView.session.delegate = self
        // `attach` is called by `UIViewRepresentable.makeUIView`, while SwiftUI
        // is still updating its view hierarchy. Publishing synchronously from
        // that callback triggers "Publishing changes from within view updates"
        // and can cause SwiftUI to discard or repeat the update. Yield to the
        // next main-actor turn and ignore the write if this ARView was replaced
        // before then.
        Task { @MainActor [weak self, weak arView] in
            await Task.yield()
            guard let self, let arView, self.arView === arView else { return }
            self.status.isSupported = ARWorldTrackingConfiguration.isSupported
        }
    }

    /// Returns the single ARView backing this capture session. SwiftUI may
    /// remove and recreate its representable while switching visual modes, but
    /// the AR session and accumulated anchors remain attached to this view.
    func captureView() -> ARView {
        if let arView { return arView }
        let view = ARView(frame: .zero)
        view.automaticallyConfigureSession = false
        attach(view)
        return view
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

        if let format = highestResolutionVideoFormat(usesLiDAR: captureMode.usesLiDAR) {
            configuration.videoFormat = format
        }

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
        hasReportedFirstFrame = false
        arView?.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        status.isRunning = true
        status.message = captureMode.usesLiDAR
            ? "Move around the cap slowly; keep electrodes in view and avoid motion blur."
            : "Circle the head, keeping frames sharp and well-lit for photogrammetry."

        // Probe 1 (requested): record the camera format and semantics we asked the
        // device for. Comparing this to the first delivered frame reveals a silent
        // ARKit fallback or missing scene depth before a subject is captured.
        let requested = configuration.videoFormat.imageResolution
        eventHandler?(AcquisitionEvent(
            kind: "video-format-selected",
            message: "Requested \(Int(requested.width))x\(Int(requested.height)) camera format.",
            details: [
                "requestedWidth": String(Int(requested.width)),
                "requestedHeight": String(Int(requested.height)),
                "requestedFPS": String(configuration.videoFormat.framesPerSecond),
                "sceneDepthRequested": String(configuration.frameSemantics.contains(.sceneDepth)),
                "sceneReconstructionMesh": String(configuration.sceneReconstruction == .mesh),
                "supportedFormatCount": String(ARWorldTrackingConfiguration.supportedVideoFormats.count)
            ]))
    }

    /// Chooses the highest-resolution camera format the device offers so the RGB
    /// record carries as much disk/label detail as possible.
    ///
    /// For LiDAR modes the dedicated high-resolution-frame format is excluded: on
    /// current hardware it disables synchronized scene depth, and keeping depth and
    /// color registered to a single frame is worth more to the solvers than extra
    /// RGB pixels. Photogrammetry-only capture has no depth to preserve, so it takes
    /// the largest format available. Returns `nil` to leave the ARKit default in
    /// place when no better format exists.
    private func highestResolutionVideoFormat(usesLiDAR: Bool) -> ARConfiguration.VideoFormat? {
        let formats = ARWorldTrackingConfiguration.supportedVideoFormats
        let candidates: [ARConfiguration.VideoFormat]
        if usesLiDAR,
           let hiRes = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing {
            candidates = formats.filter { $0.imageResolution != hiRes.imageResolution }
        } else {
            candidates = formats
        }
        return candidates.max {
            $0.imageResolution.width * $0.imageResolution.height
                < $1.imageResolution.width * $1.imageResolution.height
        }
    }

    func pause() {
        arView?.session.pause()
        status.isRunning = false
        status.message = "Scan paused."
    }

    func sampleCurrentFrame(
        artifactStore: CaptureArtifactStore, session: ScanSession,
        includeCompressedImage: Bool = false
    ) throws -> CaptureObservation? {
        guard let frame = arView?.session.currentFrame else {
            status.message = "No AR frame is available yet."
            return nil
        }

        var observation = makeObservation(from: frame)
        let cameraArtifact = try artifactStore.writeCameraSnapshot(
            pixelBuffer: frame.capturedImage,
            observationID: observation.id,
            for: session,
            includeCompressedImage: includeCompressedImage
        )
        observation.cameraSnapshotFilename = cameraArtifact.primaryFilename
        observation.compressedCameraSnapshotFilename = cameraArtifact.compressedFilename

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
    /// surface and returns the hit in world coordinates. Used to place
    /// nasion/LPA/RPA fiducials by tapping the live scan.
    ///
    /// The reconstructed LiDAR mesh is tried first: for a curved head that hits
    /// the actual scalp, whereas ARKit's estimated-plane fit only approximates it.
    /// If no mesh has been built yet, it falls back to an estimated-plane raycast
    /// so early taps still land somewhere sensible.
    func raycastToWorld(viewPoint: CGPoint) -> FiducialRaycastResult? {
        guard let arView else { return nil }

        if let (origin, direction) = arView.ray(through: viewPoint) {
            let mesh = fullMeshSnapshot()
            if let hit = MeshRaycaster.firstHit(
                origin: origin, direction: direction,
                vertices: mesh.vertices, triangleIndices: mesh.triangleIndices) {
                return FiducialRaycastResult(
                    point: hit, rayOrigin: origin, rayDirection: direction,
                    hitMethod: "lidar-mesh-raycast", observationID: observations.last?.id)
            }
        }

        if let query = arView.makeRaycastQuery(from: viewPoint, allowing: .estimatedPlane, alignment: .any),
           let result = arView.session.raycast(query).first {
            let t = result.worldTransform.columns.3
            return FiducialRaycastResult(
                point: SIMD3<Float>(t.x, t.y, t.z), rayOrigin: nil, rayDirection: nil,
                hitMethod: "estimated-plane-raycast", observationID: observations.last?.id)
        }
        return nil
    }

    /// Nearest hit of an arbitrary world-space ray against the accumulated mesh.
    /// Used by the offline (cameras-off) model view, where the ray comes from the
    /// 3D view's virtual camera instead of the ARKit camera.
    func raycastMesh(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? {
        let mesh = fullMeshSnapshot()
        return MeshRaycaster.firstHit(
            origin: origin, direction: direction,
            vertices: mesh.vertices, triangleIndices: mesh.triangleIndices)
    }

    /// Current device (camera-to-world) transform, for driving the Live Model's
    /// camera so the head rotates to match the operator's physical viewpoint.
    /// Nil when no frame is available (session not running yet).
    func currentCameraTransform() -> simd_float4x4? {
        arView?.session.currentFrame?.camera.transform
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
        let summary = trackingSummary(frame.camera.trackingState)
        status.trackingSummary = summary
        status.hasSceneDepth = frame.sceneDepth != nil
        status.meshAnchorCount = meshAnchors.count
        if !hasReportedFirstFrame {
            hasReportedFirstFrame = true
            reportFirstFrame(frame)
        }
        if summary != lastReportedTrackingSummary {
            eventHandler?(AcquisitionEvent(
                kind: "tracking-state-changed", message: summary,
                details: ["worldMappingStatus": worldMappingSummary(frame.worldMappingStatus)]))
            lastReportedTrackingSummary = summary
        }
    }

    /// Probe 2 (delivered): records what the first real frame actually carried, so
    /// it can be compared to `video-format-selected`. A resolution that differs from
    /// the request means ARKit fell back to another format; absent scene depth in a
    /// LiDAR mode means the depth-fusion assumption is broken for this session.
    private func reportFirstFrame(_ frame: ARFrame) {
        let resolution = frame.camera.imageResolution
        var details = [
            "actualImageWidth": String(Int(resolution.width)),
            "actualImageHeight": String(Int(resolution.height)),
            "sceneDepthPresent": String(frame.sceneDepth != nil),
            "worldMappingStatus": worldMappingSummary(frame.worldMappingStatus)
        ]
        if let depthMap = frame.sceneDepth?.depthMap {
            details["depthWidth"] = String(CVPixelBufferGetWidth(depthMap))
            details["depthHeight"] = String(CVPixelBufferGetHeight(depthMap))
        }
        eventHandler?(AcquisitionEvent(
            kind: "first-frame-observed",
            message: "Delivered \(Int(resolution.width))x\(Int(resolution.height)) frame.",
            details: details))
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
            imageOrientation: storedImageOrientation(),
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

    /// ARKit supplies sensor-native landscape pixels. Record the EXIF transform
    /// consumers must apply to display those pixels in the interface orientation.
    private func storedImageOrientation() -> String {
        switch arView?.window?.windowScene?.interfaceOrientation {
        case .portrait: "right"
        case .portraitUpsideDown: "left"
        case .landscapeLeft: "up"
        case .landscapeRight: "down"
        default: "up"
        }
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

    func cropped(to bounds: HeadBoundingBox) -> LiDARMeshSnapshot {
        let center = SIMD3<Float>(
            Float(bounds.center.x), Float(bounds.center.y), Float(bounds.center.z))
        let half = SIMD3<Float>(
            Float(bounds.widthMeters / 2), Float(bounds.heightMeters / 2),
            Float(bounds.depthMeters / 2))
        func isInside(_ index: UInt32) -> Bool {
            guard Int(index) < vertices.count else { return false }
            let delta = abs(vertices[Int(index)] - center)
            return delta.x <= half.x && delta.y <= half.y && delta.z <= half.z
        }

        var remap = [UInt32: UInt32]()
        var croppedVertices = [SIMD3<Float>]()
        var croppedIndices = [UInt32]()
        for face in stride(from: 0, to: triangleIndices.count - 2, by: 3) {
            let source = [triangleIndices[face], triangleIndices[face + 1], triangleIndices[face + 2]]
            guard source.allSatisfy(isInside) else { continue }
            for index in source {
                if let mapped = remap[index] {
                    croppedIndices.append(mapped)
                } else {
                    let mapped = UInt32(croppedVertices.count)
                    remap[index] = mapped
                    croppedVertices.append(vertices[Int(index)])
                    croppedIndices.append(mapped)
                }
            }
        }
        return LiDARMeshSnapshot(vertices: croppedVertices, triangleIndices: croppedIndices)
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

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-failed", message: error.localizedDescription))
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-interrupted", message: "AR session was interrupted."))
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        Task { @MainActor in
            self.eventHandler?(AcquisitionEvent(
                kind: "ar-session-interruption-ended", message: "AR session interruption ended."))
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
    var eventHandler: ((AcquisitionEvent) -> Void)?

    func start(captureMode: CaptureMode = .both) {}
    func pause() {}
    func sampleCurrentFrame(
        artifactStore: CaptureArtifactStore, session: ScanSession,
        includeCompressedImage: Bool = false
    ) throws -> CaptureObservation? { nil }
    func meshWorldPoints(maxPoints: Int = 6000) -> [SIMD3<Float>] { [] }
    func raycastToWorld(viewPoint: CGPoint) -> FiducialRaycastResult? { nil }
    func raycastMesh(origin: SIMD3<Float>, direction: SIMD3<Float>) -> SIMD3<Float>? { nil }
    func fullMeshSnapshot() -> LiDARMeshSnapshot { LiDARMeshSnapshot(vertices: [], triangleIndices: []) }
    func currentCameraTransform() -> simd_float4x4? { nil }
}
#endif
