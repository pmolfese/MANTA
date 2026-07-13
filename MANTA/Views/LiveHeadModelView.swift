import SwiftUI
import MANTACore

#if canImport(SceneKit) && canImport(UIKit)
import SceneKit
import UIKit

/// Interactive, periodically refreshed view of the accumulated LiDAR surface and
/// the electrode/fiducial solution as it is collected.
///
/// The visualization is deliberately derived from in-memory capture evidence;
/// it does not alter the persisted mesh or any electrode solution. Rendering is
/// change-driven: the SceneKit scene is only rebuilt when the mesh vertex count
/// or the electrode/fiducial signature actually changes, so the periodic tick is
/// cheap when nothing new has been captured.
struct LiveHeadModelView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    /// Whether the model camera tracks the physical device pose. A drag on the
    /// model (or entering fiducial placement) drops to manual orbit; follow
    /// resumes automatically 5 s after the last touch.
    @State private var followDevice = true
    /// Sticky manual: set by the toggle to hold manual orbit indefinitely (no
    /// auto-resume), so the operator can study the model as long as they like.
    @State private var manualHold = false

    /// Total azimuth×elevation coverage buckets (`coverageSector` in ARScanViewModel:
    /// 8 azimuth bins × {upper, level, lower}).
    private static let coverageSectorTotal = 24

    var body: some View {
        // 2.0s keeps the live surface current without paying for a full snapshot
        // rebuild more often than ARKit meaningfully refines the mesh.
        TimelineView(.periodic(from: .now, by: 2.0)) { context in
            let snapshot = viewModel.displayMeshSnapshot()
            let electrodes = viewModel.visualizedElectrodes
            let fiducials = viewModel.session.fiducials
            let stats = ModelStats(
                electrodes: electrodes,
                fiducials: fiducials,
                snapshot: snapshot,
                channelCount: viewModel.session.layout.channelCount,
                coverageSectors: viewModel.captureCoverageSectorCount,
                coverageSectorTotal: Self.coverageSectorTotal)

            HeadMeshSceneView(
                snapshot: snapshot,
                electrodes: electrodes,
                fiducials: fiducials,
                refreshDate: context.date,
                placementActive: viewModel.isModelSurfacePlacementActive,
                // Placement wants a steady view, so follow yields to manual there.
                followDevice: followDevice && !viewModel.isModelSurfacePlacementActive,
                // Don't auto-resume while placing or when manual is held.
                manualSticky: manualHold || viewModel.isModelSurfacePlacementActive,
                deviceTransform: { viewModel.scanViewModel.currentCameraTransform() },
                onManualOverride: { followDevice = false; manualHold = false },
                onAutoResumeFollow: { followDevice = true; manualHold = false },
                onSurfaceRay: { origin, direction in
                    viewModel.handleModelSurfaceRay(origin: origin, direction: direction)
                }
            )
            .overlay(alignment: .topLeading) {
                modelStatus(stats: stats)
                    .padding(12)
            }
            .overlay(alignment: .topTrailing) {
                coverageBadge(stats: stats)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                markerLegend
                    .padding(12)
            }
            .overlay(alignment: .bottomTrailing) {
                if stats.hasSurface, !viewModel.isModelSurfacePlacementActive {
                    followToggle
                        .padding(12)
                }
            }
            .overlay(alignment: .bottom) {
                placementControl(hasSurface: stats.hasSurface)
                    .padding(12)
            }
        }
    }

    private var followToggle: some View {
        Button {
            if followDevice {
                followDevice = false
                manualHold = true
            } else {
                followDevice = true
                manualHold = false
            }
        } label: {
            Label(followDevice ? "Following device" : "Manual",
                  systemImage: followDevice ? "location.fill" : "hand.draw")
                .font(.caption2.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(followDevice ? .teal : .secondary)
    }

    @ViewBuilder
    private func placementControl(hasSurface: Bool) -> some View {
        if viewModel.isModelSurfacePlacementActive {
            let placed = viewModel.session.fiducials.filter { $0.coordinate != nil }.count
            HStack(spacing: 10) {
                Image(systemName: "hand.tap.fill")
                    .foregroundStyle(.purple)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.modelFiducialPlacementPrompt ?? "Tap the head model")
                        .font(.caption.weight(.semibold))
                    Text("\(placed)/3 placed · cameras can stay off")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel") { viewModel.cancelModelSurfacePlacement() }
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
        } else if hasSurface {
            Button {
                viewModel.beginModelSurfacePlacement()
            } label: {
                Label("Mark Fiducials on Model", systemImage: "scope")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
        }
    }

    private func modelStatus(stats: ModelStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle()
                    .fill(stats.hasSurface ? Color.teal : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(stats.hasSurface
                     ? "Building head surface · \(stats.coveragePercent)% coverage"
                     : "Start scanning to build the head surface")
                    .font(.caption.weight(.semibold))
            }
            if stats.hasSurface {
                Text("\(stats.localizedCount)/\(stats.channelCount) localized · \(stats.predictedCount) predicted · \(stats.vertexCount) vertices")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func coverageBadge(stats: ModelStats) -> some View {
        HStack(spacing: 8) {
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.3), lineWidth: 3)
                Circle()
                    .trim(from: 0, to: stats.coverageFraction)
                    .stroke(Color.teal, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 0) {
                Text("Coverage")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(stats.coverageSectors)/\(stats.coverageSectorTotal)")
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var markerLegend: some View {
        HStack(spacing: 12) {
            LegendDot(title: "Confirmed", color: .green, filled: true)
            LegendDot(title: "Provisional", color: .orange, filled: false)
            LegendDot(title: "Missing", color: .gray, filled: false)
            LegendDot(title: "Fiducials", color: .purple, filled: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
}

/// Summary counts derived for the HUD. Kept separate so the overlay is a pure
/// function of the current snapshot and solution.
private struct ModelStats {
    var hasSurface: Bool
    var vertexCount: Int
    var localizedCount: Int
    var predictedCount: Int
    var channelCount: Int
    var coverageSectors: Int
    var coverageSectorTotal: Int

    init(
        electrodes: [ElectrodeAnnotation], fiducials: [FiducialAnnotation],
        snapshot: LiDARMeshSnapshot, channelCount: Int,
        coverageSectors: Int, coverageSectorTotal: Int
    ) {
        hasSurface = !snapshot.vertices.isEmpty
        vertexCount = snapshot.vertices.count
        localizedCount = electrodes.filter { $0.confidence > 0 }.count
        predictedCount = electrodes.filter { $0.confidence == 0 }.count
        self.channelCount = channelCount
        self.coverageSectors = coverageSectors
        self.coverageSectorTotal = coverageSectorTotal
    }

    var coverageFraction: CGFloat {
        guard coverageSectorTotal > 0 else { return 0 }
        return min(1, CGFloat(coverageSectors) / CGFloat(coverageSectorTotal))
    }
    var coveragePercent: Int { Int((coverageFraction * 100).rounded()) }
}

private struct LegendDot: View {
    var title: String
    var color: Color
    var filled: Bool

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(filled ? color : .clear)
                .stroke(color, lineWidth: 2)
                .frame(width: 9, height: 9)
            Text(title)
                .font(.caption2)
        }
    }
}

private struct HeadMeshSceneView: UIViewRepresentable {
    var snapshot: LiDARMeshSnapshot
    var electrodes: [ElectrodeAnnotation]
    var fiducials: [FiducialAnnotation]
    var refreshDate: Date
    /// When true, a tap builds a world-space ray and reports it for offline
    /// fiducial placement instead of only orbiting the camera.
    var placementActive: Bool = false
    /// When true, the model camera mirrors the physical device pose each frame.
    var followDevice: Bool = false
    /// When true, manual orbit is held and follow does not auto-resume.
    var manualSticky: Bool = false
    var deviceTransform: @MainActor () -> simd_float4x4? = { nil }
    /// Called when the operator drags to take manual control of the camera.
    var onManualOverride: () -> Void = {}
    /// Called when follow re-engages after the idle timeout.
    var onAutoResumeFollow: () -> Void = {}
    var onSurfaceRay: (SIMD3<Float>, SIMD3<Float>) -> Void = { _, _ in }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(white: 0.035, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = SCNScene()
        configureLighting(in: view.scene!)

        let tap = UITapGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)

        let pan = UIPanGestureRecognizer(
            target: context.coordinator, action: #selector(Coordinator.handlePan(_:)))
        pan.delegate = context.coordinator
        view.addGestureRecognizer(pan)

        context.coordinator.attach(view: view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Timeline date intentionally participates in updates even when anchor
        // count is unchanged but ARKit has refined an existing mesh anchor.
        _ = refreshDate
        context.coordinator.placementActive = placementActive
        context.coordinator.onSurfaceRay = onSurfaceRay
        context.coordinator.onManualOverride = onManualOverride
        context.coordinator.onAutoResumeFollow = onAutoResumeFollow
        context.coordinator.deviceTransform = deviceTransform
        context.coordinator.manualSticky = manualSticky
        context.coordinator.setFollowDevice(followDevice, on: view)
        context.coordinator.update(
            in: view,
            snapshot: snapshot,
            electrodes: electrodes,
            fiducials: fiducials
        )
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.detach()
    }

    private func configureLighting(in scene: SCNScene) {
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 420
        ambient.light?.color = UIColor(white: 0.7, alpha: 1)
        scene.rootNode.addChildNode(ambient)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 850
        key.eulerAngles = SCNVector3(-0.7, 0.6, 0)
        scene.rootNode.addChildNode(key)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private let meshHolder = SCNNode()
        private let markerHolder = SCNNode()
        private var installed = false

        /// Set from `updateUIView`; drives whether a tap places a fiducial.
        var placementActive = false
        var onSurfaceRay: (SIMD3<Float>, SIMD3<Float>) -> Void = { _, _ in }
        var onManualOverride: () -> Void = {}
        var onAutoResumeFollow: () -> Void = {}
        var deviceTransform: @MainActor () -> simd_float4x4? = { nil }
        var manualSticky = false

        private var followDevice = false
        private weak var scnView: SCNView?
        private var displayLink: CADisplayLink?
        /// Time of the last camera interaction; follow resumes `autoResumeDelay`
        /// seconds after this when not held manual.
        private var lastInteraction: CFTimeInterval = 0
        private let autoResumeDelay: CFTimeInterval = 5

        /// Change-detection keys: the scene is only rebuilt when one of these
        /// changes, so an idle 2 s tick with no new mesh/detections is a no-op.
        private var lastVertexCount = -1
        private var lastMarkerSignature = 0

        func attach(view: SCNView) {
            scnView = view
            let link = CADisplayLink(target: self, selector: #selector(stepFollow))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func detach() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Applies the current follow mode: when following, the camera is driven
        /// by the device pose and SceneKit's manual orbit is disabled.
        func setFollowDevice(_ follow: Bool, on view: SCNView) {
            followDevice = follow
            view.allowsCameraControl = !follow
        }

        /// Per-frame camera update, decoupled from the 2 s content refresh so the
        /// follow motion stays smooth. Also handles resuming follow after the idle
        /// timeout when the operator stops interacting.
        @objc private func stepFollow() {
            guard let view = scnView, let pointOfView = view.pointOfView else { return }
            MainActor.assumeIsolated {
                let transform = deviceTransform()
                if followDevice {
                    if let transform { pointOfView.simdTransform = transform }
                    return
                }
                // Manual: resume follow once held-manual is off, a live pose is
                // available, and the operator has been idle long enough.
                guard !manualSticky, let transform,
                      CACurrentMediaTime() - lastInteraction >= autoResumeDelay else { return }
                setFollowDevice(true, on: view)
                pointOfView.simdTransform = transform
                onAutoResumeFollow()
            }
        }

        /// A drag hands control to manual orbit. The first drag disengages follow
        /// (which re-enables SceneKit's camera control); later drags orbit. Every
        /// drag refreshes the idle timer so follow only resumes after the operator
        /// stops touching for `autoResumeDelay`.
        @objc func handlePan(_ recognizer: UIPanGestureRecognizer) {
            lastInteraction = CACurrentMediaTime()
            guard followDevice, recognizer.state == .began, let view = recognizer.view as? SCNView
            else { return }
            setFollowDevice(false, on: view)
            onManualOverride()
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        /// Converts a tap into a world-space ray (near→far through the tapped
        /// pixel) and reports it. The view model intersects it with the mesh, so
        /// this path needs no live ARKit session.
        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard placementActive, let view = recognizer.view as? SCNView else { return }
            let location = recognizer.location(in: view)
            let near = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 0))
            let far = view.unprojectPoint(SCNVector3(Float(location.x), Float(location.y), 1))
            let origin = SIMD3<Float>(near.x, near.y, near.z)
            let direction = SIMD3<Float>(far.x - near.x, far.y - near.y, far.z - near.z)
            onSurfaceRay(origin, direction)
        }

        func update(
            in view: SCNView,
            snapshot: LiDARMeshSnapshot,
            electrodes: [ElectrodeAnnotation],
            fiducials: [FiducialAnnotation]
        ) {
            guard let scene = view.scene else { return }
            if !installed {
                scene.rootNode.addChildNode(meshHolder)
                scene.rootNode.addChildNode(markerHolder)
                installed = true
            }

            guard !snapshot.vertices.isEmpty else {
                if lastVertexCount != 0 {
                    meshHolder.childNodes.forEach { $0.removeFromParentNode() }
                    markerHolder.childNodes.forEach { $0.removeFromParentNode() }
                    lastVertexCount = 0
                    lastMarkerSignature = 0
                }
                return
            }

            let bounds = MeshBounds(vertices: snapshot.vertices)

            // Rebuild the mesh geometry only when the vertex count changes. ARKit
            // grows the mesh vertex-by-vertex, so this catches real refinement
            // while skipping identical ticks.
            if snapshot.vertices.count != lastVertexCount {
                meshHolder.childNodes.forEach { $0.removeFromParentNode() }
                meshHolder.addChildNode(meshNode(snapshot: snapshot))
                lastVertexCount = snapshot.vertices.count
            }

            // Rebuild markers only when the solution actually changed.
            let signature = markerSignature(electrodes: electrodes, fiducials: fiducials)
            if signature != lastMarkerSignature {
                rebuildMarkers(electrodes: electrodes, fiducials: fiducials, bounds: bounds)
                lastMarkerSignature = signature
            }

            if view.pointOfView == nil {
                frame(bounds: bounds, in: scene, view: view)
            }
        }

        private func rebuildMarkers(
            electrodes: [ElectrodeAnnotation],
            fiducials: [FiducialAnnotation],
            bounds: MeshBounds
        ) {
            markerHolder.childNodes.forEach { $0.removeFromParentNode() }
            let markerRadius = max(bounds.diagonal / 180, 0.0025)

            for electrode in electrodes {
                guard let point = worldPoint(electrode.coordinate, near: bounds) else { continue }
                let color: UIColor
                let isMissing = electrode.confidence == 0
                if isMissing {
                    color = .systemGray
                } else if electrode.state == .reviewed {
                    color = .systemGreen
                } else {
                    color = .systemOrange
                }
                markerHolder.addChildNode(markerNode(
                    at: point, radius: markerRadius, color: color,
                    wireframe: electrode.state != .reviewed || isMissing))

                // Label localized electrodes and cardinals; leave the dense grey
                // "missing" field unlabeled so the scene stays readable.
                if !isMissing || electrode.role == .cardinal {
                    markerHolder.addChildNode(labelNode(
                        electrode.label, at: point, offset: markerRadius * 2.4,
                        color: .white, scale: markerRadius))
                }
            }

            for fiducial in fiducials {
                guard let coordinate = fiducial.coordinate,
                      let point = worldPoint(coordinate, near: bounds) else { continue }
                markerHolder.addChildNode(markerNode(
                    at: point, radius: markerRadius * 1.35,
                    color: .systemPurple, wireframe: false))
                markerHolder.addChildNode(labelNode(
                    fiducial.kind.rawValue, at: point, offset: markerRadius * 3,
                    color: UIColor.systemPurple.withAlphaComponent(0.95), scale: markerRadius * 1.2))
            }
        }

        /// Cheap order-independent signature of the drawn solution. Coordinates
        /// are quantized to ~2 mm so sub-noise jitter doesn't force a rebuild.
        private func markerSignature(
            electrodes: [ElectrodeAnnotation], fiducials: [FiducialAnnotation]
        ) -> Int {
            var hasher = Hasher()
            hasher.combine(electrodes.count)
            for electrode in electrodes {
                hasher.combine(electrode.label)
                hasher.combine(electrode.state)
                hasher.combine(electrode.confidence == 0)
                hasher.combine(Int((electrode.coordinate.x * 500).rounded()))
                hasher.combine(Int((electrode.coordinate.y * 500).rounded()))
                hasher.combine(Int((electrode.coordinate.z * 500).rounded()))
            }
            for fiducial in fiducials {
                hasher.combine(fiducial.kind)
                if let c = fiducial.coordinate {
                    hasher.combine(Int((c.x * 500).rounded()))
                    hasher.combine(Int((c.y * 500).rounded()))
                    hasher.combine(Int((c.z * 500).rounded()))
                } else {
                    hasher.combine(-1)
                }
            }
            return hasher.finalize()
        }

        private func meshNode(snapshot: LiDARMeshSnapshot) -> SCNNode {
            let points = snapshot.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
            let source = SCNGeometrySource(vertices: points)
            let indexData = snapshot.triangleIndices.withUnsafeBytes { Data($0) }
            let element = SCNGeometryElement(
                data: indexData,
                primitiveType: .triangles,
                primitiveCount: snapshot.triangleIndices.count / 3,
                bytesPerIndex: MemoryLayout<UInt32>.size
            )
            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.diffuse.contents = UIColor.systemTeal.withAlphaComponent(0.28)
            material.emission.contents = UIColor.systemTeal.withAlphaComponent(0.16)
            material.fillMode = .lines
            material.isDoubleSided = true
            geometry.materials = [material]
            return SCNNode(geometry: geometry)
        }

        private func markerNode(
            at point: SIMD3<Float>, radius: Float, color: UIColor, wireframe: Bool
        ) -> SCNNode {
            let sphere = SCNSphere(radius: CGFloat(radius))
            sphere.segmentCount = 12
            let material = SCNMaterial()
            material.diffuse.contents = color
            material.emission.contents = color.withAlphaComponent(0.45)
            material.fillMode = wireframe ? .lines : .fill
            sphere.materials = [material]
            let node = SCNNode(geometry: sphere)
            node.simdPosition = point
            return node
        }

        /// A small camera-facing text label anchored just above `point`.
        private func labelNode(
            _ text: String, at point: SIMD3<Float>, offset: Float,
            color: UIColor, scale: Float
        ) -> SCNNode {
            let textGeometry = SCNText(string: text, extrusionDepth: 0)
            textGeometry.font = UIFont.systemFont(ofSize: 8, weight: .semibold)
            textGeometry.flatness = 0.4
            textGeometry.firstMaterial?.diffuse.contents = color
            textGeometry.firstMaterial?.emission.contents = color.withAlphaComponent(0.6)
            textGeometry.firstMaterial?.isDoubleSided = true

            let textNode = SCNNode(geometry: textGeometry)
            // SCNText is authored in points; normalize to the marker scale so the
            // label reads at a consistent physical size regardless of head extent.
            let unit = max(scale, 0.0008) * 0.09
            textNode.simdScale = SIMD3(repeating: unit)
            let (minBound, maxBound) = textGeometry.boundingBox
            textNode.pivot = SCNMatrix4MakeTranslation(
                (minBound.x + maxBound.x) / 2, minBound.y, 0)

            let holder = SCNNode()
            holder.simdPosition = point + SIMD3(0, offset, 0)
            holder.constraints = [SCNBillboardConstraint()]
            holder.addChildNode(textNode)
            return holder
        }

        private func worldPoint(_ coordinate: Coordinate3D, near bounds: MeshBounds) -> SIMD3<Float>? {
            var point = SIMD3(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z))
            // Core/export coordinates are millimetres; live AR observations are
            // metres. Only convert when the raw magnitude clearly cannot be ARKit metres.
            if simd_length(point) > 10 { point /= 1000 }
            let margin = max(bounds.diagonal * 0.5, 0.1)
            guard all(point .>= bounds.minimum - margin),
                  all(point .<= bounds.maximum + margin) else { return nil }
            return point
        }

        private func frame(bounds: MeshBounds, in scene: SCNScene, view: SCNView) {
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.zNear = 0.001
            camera.camera?.zFar = 20
            let distance = max(bounds.diagonal * 1.8, 0.35)
            camera.simdPosition = bounds.center + SIMD3(0, 0, distance)
            camera.look(at: SCNVector3(bounds.center.x, bounds.center.y, bounds.center.z))
            scene.rootNode.addChildNode(camera)
            view.pointOfView = camera
        }
    }
}

private struct MeshBounds {
    var minimum: SIMD3<Float>
    var maximum: SIMD3<Float>
    var center: SIMD3<Float> { (minimum + maximum) / 2 }
    var diagonal: Float { simd_length(maximum - minimum) }

    init(vertices: [SIMD3<Float>]) {
        minimum = vertices.reduce(SIMD3(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        maximum = vertices.reduce(SIMD3(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
    }
}
#else
struct LiveHeadModelView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    var body: some View {
        ContentUnavailableView("3D model unavailable", systemImage: "cube.transparent")
    }
}
#endif
