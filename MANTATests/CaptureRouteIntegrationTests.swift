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

    @Test func movementRecoveryPreservesOldPassAndLinksNewPass() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        #expect(model.startNewSession(subjectLabel: "Same subject"))
        let oldID = model.session.id
        let preserved = try store.sessionDirectory(for: model.session).appendingPathComponent("preserved-evidence.bin")
        let bytes = Data([1, 7, 3, 9])
        try bytes.write(to: preserved)
        model.markSubjectMoved()
        for _ in 0..<200 where !model.canNavigateCaptureRoute { await Task.yield() }
        #expect(model.scanViewModel.motionStopped)
        #expect(model.captureRouteStep == .reference)
        await model.startNewStationaryPass()
        #expect(model.session.id != oldID)
        #expect(model.session.subjectLabel == "Same subject")
        #expect(model.session.captureRoute?.previousSessionID == oldID)
        #expect(model.captureRouteStep == .reference)
        #expect(model.captureVisualMode == .split)
        #expect(!model.scanViewModel.hasMotionReference(for: model.session.headBoundingBox))
        #expect(try store.loadSession(id: oldID).endedAt != nil)
        #expect(try Data(contentsOf: preserved) == bytes)
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
        #expect(model.session.id != oldID)
        #expect(model.session.captureRoute?.previousSessionID == oldID)
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
