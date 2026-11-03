import Foundation
import MANTACore
import Testing
@testable import MANTA

@MainActor
struct CaptureSafeguardsIntegrationTests {
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

    @Test func presetChangesRequireANewSessionAfterEvidenceIsSaved() {
        let model = ScanSessionViewModel()
        model.applyCapturePreset(.validation)
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
        #expect(!model.scanViewModel.selectBestFrames)
        #expect(!model.scanViewModel.preserveComparisonFrames)
    }
}
