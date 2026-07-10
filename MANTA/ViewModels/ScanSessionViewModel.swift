//
//  ScanSessionViewModel.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import Combine

@MainActor
final class ScanSessionViewModel: ObservableObject {
    @Published var session = ScanSession.newSession()
    @Published var availableLayouts: [ElectrodeLayout] = [.fallback128]
    @Published var selectedLayoutName = ElectrodeLayout.fallback128.name
    @Published var scanViewModel = ARScanViewModel()
    @Published var selectedFormat: ElectrodeExportFormat = .csv
    @Published var exportPreview = ""
    @Published var isDetecting = false
    @Published var isAutoSampling = false
    @Published var autoSamplingInterval = 0.75
    @Published var statusMessage = "Ready to start a LiDAR scan."
    @Published var diagnosticsPath = ""

    private let detectionPipeline: ElectrodeDetectionPipeline
    private let artifactStore: CaptureArtifactStore?
    private var autoSamplingTask: Task<Void, Never>?

    init(detectionPipeline: ElectrodeDetectionPipeline? = nil) {
        self.detectionPipeline = detectionPipeline ?? MockElectrodeDetectionPipeline()
        artifactStore = try? CaptureArtifactStore()

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

        stopAutoSampling()
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
        stopAutoSampling()
        scanViewModel.pause()
        statusMessage = "Live scan paused."
    }

    func startAutoSampling() {
        guard artifactStore != nil else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        guard scanViewModel.status.isSupported else {
            statusMessage = scanViewModel.status.message
            return
        }

        if !scanViewModel.status.isRunning {
            scanViewModel.start()
        }

        autoSamplingTask?.cancel()
        isAutoSampling = true
        statusMessage = "Auto-sampling started."

        autoSamplingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                if self.canAutoSample {
                    self.sampleCurrentARFrame()
                } else if self.scanViewModel.status.isRunning {
                    self.statusMessage = "Auto-sampling waiting for normal tracking and depth."
                }

                let nanoseconds = UInt64(max(0.25, self.autoSamplingInterval) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
            }
        }
    }

    func stopAutoSampling() {
        autoSamplingTask?.cancel()
        autoSamplingTask = nil
        isAutoSampling = false
    }

    func sampleCurrentARFrame() {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        do {
            guard let observation = try scanViewModel.sampleCurrentFrame(artifactStore: artifactStore, session: session) else {
                statusMessage = scanViewModel.status.message
                return
            }

            session.captureObservations.append(observation)
            let diagnosticsURL = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status)
            diagnosticsPath = diagnosticsURL.path
            statusMessage = isAutoSampling
                ? "Auto-saved sample \(session.captureObservations.count)."
                : "Saved sample \(session.captureObservations.count) and diagnostics JSON."
        } catch {
            statusMessage = "Could not save AR sample: \(error.localizedDescription)"
        }
    }

    func exportDiagnostics() {
        guard let artifactStore else {
            statusMessage = "Could not access the app Documents folder."
            return
        }

        do {
            let diagnosticsURL = try artifactStore.writeDiagnostics(for: session, scanStatus: scanViewModel.status)
            diagnosticsPath = diagnosticsURL.path
            statusMessage = "Diagnostics saved."
        } catch {
            statusMessage = "Could not save diagnostics: \(error.localizedDescription)"
        }
    }

    private func refreshExportPreview() {
        exportPreview = ElectrodeExporters.export(session, as: selectedFormat)
    }

    private var canAutoSample: Bool {
        scanViewModel.status.isRunning
            && scanViewModel.status.hasSceneDepth
            && scanViewModel.status.trackingSummary == "Normal"
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
