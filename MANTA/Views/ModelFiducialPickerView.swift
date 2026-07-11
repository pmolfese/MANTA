//
//  ModelFiducialPickerView.swift
//  MANTA
//
//  Lets the user mark the fiducial landmarks (nasion, LPA, RPA) directly on the
//  reconstructed photogrammetry model. These become the "source landmarks" used to
//  seed / drive world registration.
//

import SwiftUI

struct ModelFiducialPickerView: View {
    @ObservedObject var viewModel: ScanSessionViewModel
    @State private var currentKind: FiducialKind = .nasion

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let url = viewModel.reconstructedModelURL {
                    ModelSceneView(
                        url: url,
                        currentKind: currentKind,
                        fiducials: viewModel.session.modelFiducials
                    ) { kind, point in
                        viewModel.setModelFiducial(kind, at: point)
                        advance(after: kind)
                    }
                } else {
                    ContentUnavailableView(
                        "No model yet",
                        systemImage: "cube.transparent",
                        description: Text("Reconstruct a model before marking fiducials.")
                    )
                }

                Divider()

                controls
            }
            .navigationTitle("Mark Fiducials")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") { viewModel.finishModelFiducials(skipped: true) }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { viewModel.finishModelFiducials(skipped: false) }
                        .disabled(!viewModel.session.modelFiducialsReady)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Picker("Landmark", selection: $currentKind) {
                ForEach(FiducialKind.allCases) { kind in
                    Text(kind.rawValue).tag(kind)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 16) {
                ForEach(viewModel.session.modelFiducials) { fiducial in
                    statusLabel(for: fiducial)
                }
            }

            Text("Rotate the model, then tap the surface to place the selected landmark.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding()
    }

    private func statusLabel(for fiducial: FiducialAnnotation) -> some View {
        let placed = fiducial.coordinate != nil
        return Label(
            fiducial.kind.rawValue,
            systemImage: placed ? "checkmark.circle.fill" : "circle"
        )
        .font(.caption)
        .foregroundStyle(placed ? Color.green : Color.secondary)
    }

    private func advance(after kind: FiducialKind) {
        let kinds = FiducialKind.allCases
        // Move to the next kind that still needs a coordinate.
        if let next = kinds.first(where: { candidate in
            candidate != kind && viewModel.session.modelFiducials.first(where: { $0.kind == candidate })?.coordinate == nil
        }) {
            currentKind = next
        }
    }
}

#if canImport(SceneKit) && canImport(UIKit)
import SceneKit
import UIKit

/// SceneKit view that renders the reconstructed model and reports tapped surface points.
struct ModelSceneView: UIViewRepresentable {
    let url: URL
    var currentKind: FiducialKind
    var fiducials: [FiducialAnnotation]
    var onPick: (FiducialKind, SIMD3<Float>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = (try? SCNScene(url: url)) ?? SCNScene()
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = true
        view.backgroundColor = .clear

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        view.addGestureRecognizer(tap)
        context.coordinator.scnView = view
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.renderMarkers(fiducials)
    }

    final class Coordinator: NSObject {
        var parent: ModelSceneView
        weak var scnView: SCNView?
        private var markerNodes: [FiducialKind: SCNNode] = [:]

        init(_ parent: ModelSceneView) { self.parent = parent }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = scnView else { return }
            let location = gesture.location(in: view)
            let hits = view.hitTest(location, options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.closest.rawValue
            ])
            guard let hit = hits.first(where: { $0.node.geometry != nil }) else { return }
            let w = hit.worldCoordinates
            parent.onPick(parent.currentKind, SIMD3<Float>(Float(w.x), Float(w.y), Float(w.z)))
        }

        func renderMarkers(_ fiducials: [FiducialAnnotation]) {
            guard let scene = scnView?.scene else { return }
            let radius = markerRadius(in: scene)

            for fiducial in fiducials {
                guard let coordinate = fiducial.coordinate else {
                    markerNodes[fiducial.kind]?.removeFromParentNode()
                    markerNodes[fiducial.kind] = nil
                    continue
                }

                let node: SCNNode
                if let existing = markerNodes[fiducial.kind] {
                    node = existing
                } else {
                    node = makeMarker(kind: fiducial.kind, radius: radius)
                    scene.rootNode.addChildNode(node)
                    markerNodes[fiducial.kind] = node
                }
                node.position = SCNVector3(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z))
            }
        }

        private func markerRadius(in scene: SCNScene) -> CGFloat {
            let (minB, maxB) = scene.rootNode.boundingBox
            let extent = max(
                abs(maxB.x - minB.x),
                abs(maxB.y - minB.y),
                abs(maxB.z - minB.z)
            )
            return max(0.003, CGFloat(extent) * 0.02)
        }

        private func makeMarker(kind: FiducialKind, radius: CGFloat) -> SCNNode {
            let sphere = SCNSphere(radius: radius)
            sphere.firstMaterial?.diffuse.contents = color(for: kind)
            sphere.firstMaterial?.lightingModel = .constant
            return SCNNode(geometry: sphere)
        }

        private func color(for kind: FiducialKind) -> UIColor {
            switch kind {
            case .nasion: return .systemOrange
            case .leftPreauricular: return .systemBlue
            case .rightPreauricular: return .systemTeal
            }
        }
    }
}
#else
struct ModelSceneView: View {
    let url: URL
    var currentKind: FiducialKind
    var fiducials: [FiducialAnnotation]
    var onPick: (FiducialKind, SIMD3<Float>) -> Void

    var body: some View {
        ContentUnavailableView("3D picking unavailable", systemImage: "cube.transparent")
    }
}
#endif
