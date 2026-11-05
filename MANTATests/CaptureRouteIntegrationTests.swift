import Foundation
import Testing
import MANTACore
@testable import MANTA

@MainActor
struct CaptureRouteIntegrationTests {
    @Test func skippingReferenceNeverArmsMotionAndSelectingFinishNeverEndsSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(model.startNewSession(subjectLabel: "Route"))
        model.selectCaptureRouteStep(.reference)
        model.advanceCaptureRoute()
        #expect(model.captureRouteStep == .orbit)
        #expect(!model.captureRouteCompleted(.reference))
        #expect(model.session.captureRoute?.skippedSteps.contains(.reference) == true)
        model.selectCaptureRouteStep(.finish)
        #expect(!model.isSessionEnded)
        #expect(try store.loadSession(id: model.session.id).captureRoute == model.session.captureRoute)
        #expect(!model.scanViewModel.hasMotionReference(for: model.session.headBoundingBox))
    }

    @Test func movementRecoveryKeepsOneSessionAndArchivesPreviousPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let mesh = LiDARMeshSnapshot(vertices: [SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0)], triangleIndices: [0, 1, 2])
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!, meshSnapshotProvider: { mesh })
        #expect(model.startNewSession(subjectLabel: "Same subject"))
        var quality = CaptureQualityMetrics(arFrameTimestamp: 1, worldMappingStatus: "mapped",
            ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5,
            darkPixelFraction: 0, brightPixelFraction: 0, sharpnessScore: 1,
            translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
        quality.motionAssessment = .init(segmentID: model.scanViewModel.motionSegmentID, state: .consistent)
        let frame = CaptureObservation(capturedAt: Date(), cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
            cameraIntrinsics: [100,0,0, 0,100,0, 1,1,1], imageResolution: .init(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal", quality: quality)
        model.session.captureObservations = [frame]
        let oldID = model.session.id
        let preserved = try store.sessionDirectory(for: model.session).appendingPathComponent("preserved-evidence.bin")
        let bytes = Data([1, 7, 3, 9])
        try bytes.write(to: preserved)
        model.markSubjectMoved()
        for _ in 0..<200 where !model.canNavigateCaptureRoute { await Task.yield() }
        #expect(model.scanViewModel.motionStopped)
        #expect(model.captureRouteStep == .reference)
        await model.startNewStationaryPass()
        #expect(model.session.id == oldID)
        #expect(model.session.subjectLabel == "Same subject")
        #expect(model.session.captureRoute?.previousSessionID == nil)
        #expect(model.session.capturePasses?.count == 1)
        #expect(model.captureRouteStep == .reference)
        #expect(model.captureVisualMode == .split)
        #expect(!model.scanViewModel.hasMotionReference(for: model.session.headBoundingBox))
        #expect(try store.loadSession(id: oldID).endedAt == nil)
        #expect(store.listSessionSummaries().count == 1)
        #expect(try Data(contentsOf: preserved) == bytes)
        #expect(model.session.captureObservations.map(\.id) == [frame.id])
        let pass = try #require(model.session.capturePasses?.first)
        let saved = try store.loadSession(id: oldID)
        #expect(saved.captureObservations.map(\.id) == [frame.id])
        #expect(saved.capturePasses == [pass])
        let archivedMesh = try #require(pass.artifactPaths.first { $0.hasSuffix("lidar_mesh.ply") })
        let directory = try store.sessionDirectory(for: model.session)
        let meshBytes = try Data(contentsOf: directory.appendingPathComponent(archivedMesh))
        // A later checkpoint overwrites the active mesh, never the archived pass.
        try Data([9, 9]).write(to: directory.appendingPathComponent("reconstruction/lidar_mesh.ply"))
        #expect(try Data(contentsOf: directory.appendingPathComponent(archivedMesh)) == meshBytes)
    }

    @Test func failedSavePreventsMovementRecoveryFromAbandoningPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(model.startNewSession(subjectLabel: "Retry pass"))
        let oldID = model.session.id
        model.markSubjectMoved()
        for _ in 0..<200 where !model.canNavigateCaptureRoute { await Task.yield() }
        let receipt = try store.sessionDirectory(for: model.session).appendingPathComponent("capture-receipt.json")
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        await model.startNewStationaryPass()
        #expect(model.session.id == oldID)
        #expect(!model.isSessionEnded)
        #expect(model.captureSaveError != nil)
        #expect(model.scanViewModel.motionStopped)
        #expect(try store.loadSession(id: oldID).endedAt == nil)
        try FileManager.default.removeItem(at: receipt)
        await model.startNewStationaryPass()
        #expect(model.session.id == oldID)
        #expect(model.session.captureRoute?.previousSessionID == nil)
        #expect(model.session.capturePasses?.count == 1)
    }

    @Test func endedRouteInspectionDoesNotRewriteSavedProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(model.startNewSession(subjectLabel: "Read only"))
        model.selectCaptureRouteStep(.finish)
        await model.endSession()
        #expect(model.isSessionEnded)
        let saved = try store.loadSession(id: model.session.id)
        model.selectCaptureRouteStep(.reference)
        #expect(model.captureRouteStep == .reference)
        #expect(model.session.captureRoute == saved.captureRoute)
        #expect(try store.loadSession(id: model.session.id).captureRoute == saved.captureRoute)
    }
}
