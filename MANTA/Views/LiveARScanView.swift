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

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.automaticallyConfigureSession = false
        scanViewModel.attach(arView)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    static func dismantleUIView(_ uiView: ARView, coordinator: ()) {
        uiView.session.pause()
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
