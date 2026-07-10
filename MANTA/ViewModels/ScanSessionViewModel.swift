//
//  ScanSessionViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import Combine

final class ScanSessionViewModel: ObservableObject {
    @Published var session = ScanSession.newSession()
    @Published var availableLayouts: [ElectrodeLayout] = [.fallback128]
    @Published var selectedLayoutName = ElectrodeLayout.fallback128.name
    @Published var scanViewModel = ARScanViewModel()
    @Published var selectedFormat: ElectrodeExportFormat = .csv
    @Published var exportPreview = ""
    @Published var isDetecting = false
    @Published var statusMessage = "Ready to start a LiDAR scan."

    private let detectionPipeline: ElectrodeDetectionPipeline

    init(detectionPipeline: ElectrodeDetectionPipeline = MockElectrodeDetectionPipeline()) {
        self.detectionPipeline = detectionPipeline

        do {
            let layouts = try HydroCelLayoutLoader().loadLayouts()
            availableLayouts = layouts
            if let firstLayout = layouts.first {
                selectedLayoutName = firstLayout.name
                session = ScanSession.newSession(layout: firstLayout)
            }
        } catch {
            availableLayouts = [.fallback128]
            selectedLayoutName = ElectrodeLayout.fallback128.name
            session = ScanSession.newSession(layout: .fallback128)
            statusMessage = "Using fallback layout: \(error.localizedDescription)"
        }

        refreshExportPreview()
    }

    func runInitialDetection() async {
        isDetecting = true
        statusMessage = "Detecting reflective electrodes..."

        do {
            session.electrodes = try await detectionPipeline.detectElectrodes(for: session.layout)
            seedFiducialsForPrototype()
            statusMessage = "Detected \(session.detectedElectrodeCount) electrodes. Review labels and landmarks next."
        } catch {
            statusMessage = "Detection failed: \(error.localizedDescription)"
        }

        isDetecting = false
        refreshExportPreview()
    }

    func markReviewed(_ electrode: ElectrodeAnnotation) {
        guard let index = session.electrodes.firstIndex(where: { $0.id == electrode.id }) else {
            return
        }

        session.electrodes[index].state = .reviewed
        refreshExportPreview()
    }

    func updateFormat(_ format: ElectrodeExportFormat) {
        selectedFormat = format
        refreshExportPreview()
    }

    func selectLayout(named name: String) {
        guard let layout = availableLayouts.first(where: { $0.name == name }) else {
            return
        }

        selectedLayoutName = name
        session = ScanSession.newSession(layout: layout)
        statusMessage = "Ready to scan with \(layout.name)."
        refreshExportPreview()
    }

    func startLiveScan() {
        scanViewModel.start()
        statusMessage = "Live LiDAR scan running."
    }

    func pauseLiveScan() {
        scanViewModel.pause()
        statusMessage = "Live scan paused."
    }

    func sampleCurrentARFrame() {
        guard let observation = scanViewModel.sampleCurrentFrame() else {
            statusMessage = scanViewModel.status.message
            return
        }

        session.captureObservations.append(observation)
        statusMessage = "Sampled \(session.captureObservations.count) AR frames for \(session.layout.channelCount)-channel layout."
    }

    private func refreshExportPreview() {
        exportPreview = ElectrodeExporters.export(session, as: selectedFormat)
    }

    private func seedFiducialsForPrototype() {
        for index in session.fiducials.indices {
            switch session.fiducials[index].kind {
            case .nasion:
                session.fiducials[index].coordinate = session.layout.fiducialCoordinatePriors[.nasion] ?? Coordinate3D(x: 0, y: 95, z: 20)
            case .leftPreauricular:
                session.fiducials[index].coordinate = session.layout.fiducialCoordinatePriors[.leftPreauricular] ?? Coordinate3D(x: -78, y: 0, z: 0)
            case .rightPreauricular:
                session.fiducials[index].coordinate = session.layout.fiducialCoordinatePriors[.rightPreauricular] ?? Coordinate3D(x: 78, y: 0, z: 0)
            }

            session.fiducials[index].state = .needsReview
        }
    }
}
