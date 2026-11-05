import Foundation
import MANTACore
import Testing
import UIKit
@testable import MANTA

@MainActor
struct CaptureSafeguardsIntegrationTests {
    @Test func interfaceOrientationUsesRearCameraSensorCoordinates() {
        #expect(ARScanViewModel.imageOrientation(for: .landscapeRight) == "up")
        #expect(ARScanViewModel.imageOrientation(for: .landscapeLeft) == "down")
        #expect(ARScanViewModel.imageOrientation(for: .portrait) == "right")
        #expect(ARScanViewModel.imageOrientation(for: .portraitUpsideDown) == "left")
        #expect(ARScanViewModel.imageOrientation(for: nil) == "up")
    }

    @Test func storageWarningPausesAtReserveAndNeverAutoResumes() {
        let scan = ARScanViewModel()
        var states: [String] = []
        scan.eventHandler = { event in
            if let state = event.details["state"] { states.append(state) }
        }
        scan.status.isRunning = true
        #expect(scan.checkStorage(2_000_000_000))
        #expect(scan.status.isRunning)
        #expect(scan.storageMessage != nil)
        #expect(scan.checkStorage(1_500_000_000))
        #expect(!scan.checkStorage(1_000_000_000))
        #expect(!scan.status.isRunning)
        #expect(scan.checkStorage(4_000_000_000))
        #expect(!scan.status.isRunning)
        #expect(scan.storageMessage == nil)
        #expect(states == ["warning", "stop", "ready"])
        scan.status.isRunning = true
        #expect(!scan.checkStorage(nil))
        #expect(!scan.status.isRunning)
    }

    @Test func presetChangesRequireANewSessionAfterEvidenceIsSaved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("capture-presets-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ScanSessionViewModel(
            artifactStore: try CaptureArtifactStore(rootDirectory: root),
            sessionDefaults: UserDefaults(suiteName: "capture-presets-\(UUID())")!)
        #expect(model.scanViewModel.highResolutionStills)
        #expect(!model.scanViewModel.automaticHighResolutionStills)
        model.applyCapturePreset(.validation)
        #expect(model.scanViewModel.automaticHighResolutionStills)
        #expect(model.session.captureMode == .both)
        #expect(model.scanViewModel.highResolutionStills)
        #expect(model.scanViewModel.selectBestFrames)
        #expect(model.scanViewModel.preserveComparisonFrames)
        let observation = CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: ImageResolution(width: 1, height: 1), hasSceneDepth: true,
            meshAnchorCount: 0, trackingSummary: "Normal")
        model.scanViewModel.observations = [observation]
        #expect(!model.scanViewModel.canEditCaptureSettings)
        model.applyCapturePreset(.baseline)
        model.setCaptureMode(.photogrammetry)
        #expect(model.scanViewModel.highResolutionStills)
        #expect(model.session.captureMode == .both)
        model.scanViewModel.resetForNewCapture()
        model.applyCapturePreset(.baseline)
        #expect(!model.scanViewModel.highResolutionStills)
        #expect(!model.scanViewModel.automaticHighResolutionStills)
        #expect(!model.scanViewModel.selectBestFrames)
        #expect(!model.scanViewModel.preserveComparisonFrames)
    }
}
