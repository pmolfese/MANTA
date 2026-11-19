import Foundation
import MANTACore
import Testing
import UIKit
import simd
@testable import MANTA

@MainActor
struct CaptureSafeguardsIntegrationTests {
    @Test func automaticMovementKeepsCaptureRunningAndPreservesSavedEvidence() {
        let scan = ARScanViewModel()
        scan.status.isRunning = true
        let id = scan.motionSegmentID
        let trusted = CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: ImageResolution(width: 1, height: 1), hasSceneDepth: true,
            meshAnchorCount: 0, trackingSummary: "Normal")
        scan.observations = [trusted]
        var events: [String] = []
        scan.eventHandler = { events.append($0.kind) }
        for time in 1...3 {
            _ = scan.assessCaptureMotion(.init(segmentID: id, state: .suspected), timestamp: Double(time))
        }
        #expect(scan.status.isRunning)
        #expect(!scan.motionStopped)
        #expect(scan.motionFusionHeld)
        #expect(scan.motionSegmentID == id)
        #expect(scan.observations.count == 1)
        #expect(scan.observations.first?.id == trusted.id)
        #expect(events == ["motion-fusion-held"])
        #expect(scan.assessCaptureMotion(.init(segmentID: id, state: .consistent), timestamp: 4).state == .suspected)
        scan.resetForNewCapture()
        #expect(!scan.motionFusionHeld)
        #expect(scan.assessCaptureMotion(.init(segmentID: scan.motionSegmentID, state: .consistent), timestamp: 1).state == .consistent)
    }

    @Test func validatedAlignmentResumesWithoutResettingCaptureAndCorrectsSavedPose() throws {
        let scan = ARScanViewModel()
        scan.status.isRunning = true
        let segment = scan.motionSegmentID
        let reference: [SIMD3<Float>] = (0..<120).map { i in
            let x = Float(i % 6) * 0.025
            let y = Float((i / 6) % 5) * 0.03
            let z = Float(i / 30) * 0.035 + Float(i % 3) * 0.004
            return SIMD3<Float>(x, y, z)
        }
        var transform = matrix_identity_float4x4
        transform.columns.3 = SIMD4(0.04, -0.02, 0.01, 1)
        let moved = reference.map { SegmentRegistration.point($0, transform.inverse) }
        let indices = [0, 5, 24, 90]
        let result = SegmentRegistration.solve(source: moved, reference: reference,
            sourceLandmarks: indices.map { moved[$0] }, referenceLandmarks: indices.map { reference[$0] })
        #expect(result.accepted)
        for time in 1...3 { _ = scan.assessCaptureMotion(.init(segmentID: segment, state: .suspected), timestamp: Double(time)) }
        #expect(scan.acceptMotionAlignment(result, reference: reference, timestamp: 3))
        #expect(scan.assessMotionPoints(moved, timestamp: 4).state != .consistent)
        #expect(scan.assessMotionPoints(moved, timestamp: 5).state != .consistent)
        #expect(scan.assessMotionPoints(moved, timestamp: 6).state == .consistent)
        #expect(!scan.motionFusionHeld)
        #expect(scan.status.isRunning && !scan.motionStopped)
        #expect(scan.motionSegmentID == segment)
        var quality = CaptureQualityMetrics(arFrameTimestamp: 6, worldMappingStatus: "mapped", ambientIntensity: nil,
            ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
            sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: segment, state: .consistent)
        let original = SegmentRegistration.flatten(matrix_identity_float4x4)
        var observation = CaptureObservation(capturedAt: Date(), cameraTransform: original, cameraIntrinsics: [],
            imageResolution: .init(width: 1, height: 1), hasSceneDepth: true, meshAnchorCount: 0,
            trackingSummary: "Normal", quality: quality)
        scan.applyMotionCorrection(to: &observation)
        let correction = try #require(observation.quality?.liveMotionCorrection)
        #expect(correction.originalCameraToWorld == original)
        #expect(correction.matches(camera: observation.cameraTransform))
        #expect(observation.cameraTransform != original)
        let corrected = observation.cameraTransform
        scan.applyMotionCorrection(to: &observation)
        #expect(observation.cameraTransform == corrected) // Never apply twice.
        observation.quality?.liveMotionCorrection = nil
        observation.cameraTransform = []
        scan.applyMotionCorrection(to: &observation)
        #expect(observation.quality?.motionAssessment?.state == .insufficientEvidence)
        scan.resetForNewCapture()
        #expect(!scan.acceptMotionAlignment(result, reference: reference, timestamp: 3))
    }

    @Test func continuousNetTrackingCorrectsMovingFramesAndHoldsWhenDisabled() throws {
        let scan = ARScanViewModel()
        scan.status.isRunning = true
        let segment = scan.motionSegmentID
        let reference: [SIMD3<Float>] = (0..<120).map { i in
            let x = Float(i % 6) * 0.025
            let y = Float((i / 6) % 5) * 0.03
            let z = Float(i / 30) * 0.035 + Float(i % 3) * 0.004
            return SIMD3<Float>(x, y, z)
        }
        for time in 1...3 { _ = scan.assessCaptureMotion(.init(segmentID: segment, state: .suspected), timestamp: Double(time)) }
        #expect(scan.acceptMotionAlignment(SegmentRegistration.referenceIdentity(points: reference), reference: reference, timestamp: 3))
        for time in 4...6 { _ = scan.assessMotionPoints(reference, timestamp: Double(time)) }
        scan.continuousNetTrackingEnabled = true
        func observation(_ timestamp: Double) -> CaptureObservation {
            var quality = CaptureQualityMetrics(arFrameTimestamp: timestamp, worldMappingStatus: "mapped", ambientIntensity: nil,
                ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
                sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
            quality.motionAssessment = .init(segmentID: segment, state: .consistent)
            return .init(capturedAt: Date(), cameraTransform: SegmentRegistration.flatten(matrix_identity_float4x4), cameraIntrinsics: [],
                imageResolution: .init(width: 1, height: 1), hasSceneDepth: true, meshAnchorCount: 0,
                trackingSummary: "Normal", quality: quality)
        }
        let labels = [0, 5, 24, 90, 119].enumerated().map { LabeledDetection(label: "E\($0.offset + 1)", world: reference[$0.element]) }
        for time in [7.0, 7.1, 7.2] { scan.observeNetLandmarks(labels, observation: observation(time)) }
        for step in 3...5 {
            let offset = Float(step - 2) * 0.002
            let points = reference.map { $0 - SIMD3(offset, 0, 0) }
            #expect(scan.assessMotionPoints(points, timestamp: 7 + Double(step) / 10).state == .consistent)
        }
        var saved = observation(7.5)
        scan.applyMotionCorrection(to: &saved)
        let correction = try #require(saved.quality?.liveMotionCorrection)
        #expect(correction.method == "net-anchored-continuous-rigid-v1")
        #expect(correction.trackedLabelCount == 5)
        #expect(correction.landmarkTimestamp == 7.2)
        #expect(abs(saved.cameraTransform[12] - 0.006) < 0.002)
        #expect(scan.status.isRunning && !scan.motionFusionHeld)
        scan.continuousNetTrackingEnabled = false
        #expect(scan.motionFusionHeld && scan.status.isRunning)
        scan.resetForNewCapture()
    }

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
