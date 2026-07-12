import SwiftUI
import MANTACore

#if canImport(SceneKit) && canImport(UIKit)
import SceneKit
import UIKit

/// Interactive, periodically refreshed view of the accumulated LiDAR surface.
/// The visualization is deliberately derived from in-memory capture evidence;
/// it does not alter the persisted mesh or any electrode solution.
struct LiveHeadModelView: View {
    @ObservedObject var viewModel: ScanSessionViewModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.5)) { context in
            let snapshot = viewModel.scanViewModel.fullMeshSnapshot()
            HeadMeshSceneView(
                snapshot: snapshot,
                electrodes: viewModel.visualizedElectrodes,
                fiducials: viewModel.session.fiducials,
                refreshDate: context.date
            )
            .overlay(alignment: .topLeading) {
                modelStatus(snapshot: snapshot)
                    .padding(12)
            }
            .overlay(alignment: .bottomLeading) {
                markerLegend
                    .padding(12)
            }
        }
    }

    private func modelStatus(snapshot: LiDARMeshSnapshot) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(snapshot.vertices.isEmpty ? Color.secondary : Color.teal)
                .frame(width: 8, height: 8)
            Text(snapshot.vertices.isEmpty
                 ? "Start scanning to build the head surface"
                 : "Live LiDAR surface · \(snapshot.vertices.count) vertices")
                .font(.caption.weight(.semibold))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }

    private var markerLegend: some View {
        HStack(spacing: 12) {
            LegendDot(title: "Reviewed", color: .green, filled: true)
            LegendDot(title: "Provisional", color: .orange, filled: false)
            LegendDot(title: "Predicted", color: .gray, filled: false)
            LegendDot(title: "Fiducials", color: .purple, filled: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
    }
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

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.backgroundColor = UIColor(white: 0.035, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = SCNScene()
        configureLighting(in: view.scene!)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        // Timeline date intentionally participates in updates even when anchor
        // count is unchanged but ARKit has refined an existing mesh anchor.
        _ = refreshDate
        context.coordinator.replaceContent(
            in: view,
            snapshot: snapshot,
            electrodes: electrodes,
            fiducials: fiducials
        )
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

    final class Coordinator {
        private let contentNode = SCNNode()
        private var installed = false

        func replaceContent(
            in view: SCNView,
            snapshot: LiDARMeshSnapshot,
            electrodes: [ElectrodeAnnotation],
            fiducials: [FiducialAnnotation]
        ) {
            guard let scene = view.scene else { return }
            if !installed {
                scene.rootNode.addChildNode(contentNode)
                installed = true
            }
            contentNode.childNodes.forEach { $0.removeFromParentNode() }

            guard !snapshot.vertices.isEmpty else { return }
            let bounds = MeshBounds(vertices: snapshot.vertices)
            contentNode.addChildNode(meshNode(snapshot: snapshot))

            let markerRadius = max(bounds.diagonal / 180, 0.0025)
            for electrode in electrodes {
                guard let point = worldPoint(electrode.coordinate, near: bounds) else { continue }
                let color: UIColor
                if electrode.confidence == 0 {
                    color = .systemGray
                } else if electrode.state == .reviewed {
                    color = .systemGreen
                } else {
                    color = .systemOrange
                }
                contentNode.addChildNode(markerNode(
                    at: point, radius: markerRadius, color: color,
                    wireframe: electrode.state != .reviewed || electrode.confidence == 0
                ))
            }
            for fiducial in fiducials {
                guard let coordinate = fiducial.coordinate,
                      let point = worldPoint(coordinate, near: bounds) else { continue }
                contentNode.addChildNode(markerNode(
                    at: point, radius: markerRadius * 1.35,
                    color: .systemPurple, wireframe: false
                ))
            }

            if view.pointOfView == nil {
                frame(bounds: bounds, in: scene, view: view)
            }
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
