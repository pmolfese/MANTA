//
//  LiveARScanView.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import SwiftUI

#if canImport(ARKit) && canImport(RealityKit)
import ARKit
import RealityKit

struct LiveARScanView: UIViewRepresentable {
    @ObservedObject var scanViewModel: ARScanViewModel
    var onTap: (CGPoint) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap)
    }

    func makeUIView(context: Context) -> ARView {
        let arView = scanViewModel.captureView()

        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        context.coordinator.tapRecognizer = tap
        arView.addGestureRecognizer(tap)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.onTap = onTap
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        // A Camera ↔ Live Model switch removes this representable, but it must
        // not stop capture. The view model owns the ARView/session; only remove
        // presentation-specific gestures here. Explicit Pause remains the sole
        // control that pauses the session.
        if let tap = coordinator.tapRecognizer {
            uiView.removeGestureRecognizer(tap)
        }
    }

    final class Coordinator {
        var onTap: (CGPoint) -> Void
        weak var tapRecognizer: UITapGestureRecognizer?

        init(onTap: @escaping (CGPoint) -> Void) {
            self.onTap = onTap
        }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onTap(recognizer.location(in: view))
        }
    }
}
#else
struct LiveARScanView: View {
    @ObservedObject var scanViewModel: ARScanViewModel

    var body: some View {
        ContentUnavailableView("AR unavailable", systemImage: "camera.viewfinder")
    }
}
#endif
