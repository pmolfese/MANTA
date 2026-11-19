//
//  SessionLibraryTests.swift
//  MANTATests
//
//  Covers session naming (timestamp always paired with the subject label) and
//  the persistence/listing that backs the subject library.
//

import Foundation
import MANTACore
import Testing
@testable import MANTA

@MainActor
struct SessionLibraryTests {
    private func makeStore() throws -> CaptureArtifactStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTATests-\(UUID().uuidString)", isDirectory: true)
        return try CaptureArtifactStore(rootDirectory: root)
    }

    private func session(subjectLabel: String? = nil, createdAt: Date = Date()) -> ScanSession {
        var s = ScanSession.newSession()
        s.createdAt = createdAt
        s.subjectLabel = subjectLabel
        s.name = s.displayName
        return s
    }

    @Test @MainActor func observationCheckpointRecoversInterruptedMetadataWriteWithoutDuplicates() throws {
        let store = try makeStore()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        var original = session()
        try store.writeSession(original)
        let observation = CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: ImageResolution(width: 1, height: 1), hasSceneDepth: false,
            meshAnchorCount: 0, trackingSummary: "Normal")
        try store.writeObservationCheckpoint(observation, for: original)
        let recovered = try store.loadSession(id: original.id)
        #expect(recovered.captureObservations == [observation])
        original.captureObservations = [observation]
        try store.writeSession(original)
        #expect(try store.loadSession(id: original.id).captureObservations == [observation])
    }

    // MARK: - Naming

    @Test func timestampNameMatchesExpectedFormat() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 11
        components.hour = 14; components.minute = 30; components.second = 22
        let date = Calendar(identifier: .gregorian).date(from: components)!

        var s = ScanSession.newSession()
        s.createdAt = date
        #expect(s.timestampName == "2026-07-11_143022")
    }

    @Test func displayNameFallsBackToTimestampWhenUnlabeled() {
        let s = session(subjectLabel: nil)
        #expect(s.displayName == s.timestampName)
    }

    @Test func displayNameKeepsTimestampWhenLabeled() {
        let s = session(subjectLabel: "MRN123")
        #expect(s.displayName.hasPrefix("MRN123 · "))
        #expect(s.displayName.hasSuffix(s.timestampName))
    }

    @Test func blankLabelIsTreatedAsUnlabeled() {
        let s = session(subjectLabel: "   ")
        #expect(s.displayName == s.timestampName)
    }

    @Test func fileSafeNameSanitizesAndKeepsTimestampAtEnd() {
        let s = session(subjectLabel: "Jane Doe/#7")
        #expect(s.fileSafeName.hasSuffix("_\(s.timestampName)"))
        #expect(!s.fileSafeName.contains("/"))
        #expect(!s.fileSafeName.contains(" "))
    }

    // MARK: - Persistence

    @Test func writeThenLoadRoundTripsExactly() throws {
        let store = try makeStore()
        let original = session(subjectLabel: "Subject-A")
        try store.writeSession(original)

        let loaded = try store.loadSession(id: original.id)
        #expect(loaded == original)
    }

    @Test func listSummariesAreSortedNewestFirst() throws {
        let store = try makeStore()
        let now = Date()
        let older = session(subjectLabel: "Older", createdAt: now.addingTimeInterval(-3600))
        let newer = session(subjectLabel: "Newer", createdAt: now)
        // Persist out of order.
        try store.writeSession(newer)
        try store.writeSession(older)

        let summaries = store.listSessionSummaries()
        #expect(summaries.count == 2)
        #expect(summaries.first?.id == newer.id)
        #expect(summaries.last?.id == older.id)
        #expect(summaries.first?.subjectLabel == "Newer")
    }

    @Test func deleteRemovesSessionFromLibrary() throws {
        let store = try makeStore()
        let s = session(subjectLabel: "Temp")
        try store.writeSession(s)
        #expect(store.listSessionSummaries().count == 1)

        try store.deleteSession(id: s.id)
        #expect(store.listSessionSummaries().isEmpty)
    }

    // MARK: - Export bundle

    @Test func exportBundleProducesPHIFreeMANTASnapshot() throws {
        let store = try makeStore()
        let s = session(subjectLabel: "Subject B")
        try store.writeSession(s)

        let result = try store.exportSessionBundle(id: s.id)

        #expect(result.url.pathExtension == "manta")
        #expect(!result.url.lastPathComponent.contains("Subject"))
        let size = (try FileManager.default.attributesOfItem(atPath: result.url.path)[.size] as? Int) ?? 0
        #expect(size > 0)
        try? FileManager.default.removeItem(at: result.url.deletingLastPathComponent())
    }

    @Test func exportBundleThrowsForMissingSession() throws {
        let store = try makeStore()
        #expect(throws: (any Error).self) {
            try store.exportSessionBundle(id: UUID())
        }
    }

    @Test func exportBundleCarriesLiveDetectionRunProvenance() throws {
        let store = try makeStore()
        let s = session()
        try store.writeSession(s)
        let diagnostics = DetectionRunDiagnostics(
            id: s.id, mode: .live, startedAt: s.createdAt, completedAt: Date(),
            engine: "test-live-detector", engineVersion: "1",
            processedFrameIDs: [], rawDetectionCount: 0,
            directlyLocalizedElectrodeCount: 0, templatePredictedElectrodeCount: 0,
            suspectLabels: [], templateFitRMSMillimeters: nil,
            templateAnchorCount: nil, electrodes: [])
        try store.writeDetectionDiagnostics(diagnostics, for: s)

        let exported = try store.exportSessionBundle(id: s.id)
        // Capture exports are directory packages; don't feed the directory to
        // the legacy ZIP importer (large sessions intentionally avoid ZIP).
        let verified = try MANTABundleValidator().validate(directory: exported.url)

        #expect(FileManager.default.fileExists(
            atPath: verified.rootDirectory.appendingPathComponent("runs/live-current/run.json").path))
        try? FileManager.default.removeItem(at: exported.url.deletingLastPathComponent())
    }

    @Test func fullLiDARMeshSnapshotPersistsPortablePLYTopology() throws {
        let store = try makeStore()
        let s = session(subjectLabel: nil)
        let snapshot = LiDARMeshSnapshot(
            vertices: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)],
            triangleIndices: [0, 1, 2])

        let path = try store.writeLiDARMeshSnapshot(snapshot, for: s)
        let data = try Data(contentsOf: store.rootDirectory
            .appendingPathComponent(s.id.uuidString).appendingPathComponent(path))
        let prefix = String(decoding: data.prefix(220), as: UTF8.self)

        #expect(path == "reconstruction/lidar_mesh.ply")
        #expect(prefix.contains("format binary_little_endian 1.0"))
        #expect(prefix.contains("element vertex 3"))
        #expect(prefix.contains("element face 1"))
    }

    @Test func renamingPreservesCreatedAtAndTimestamp() {
        var s = session(subjectLabel: nil)
        let created = s.createdAt
        let stamp = s.timestampName

        s.subjectLabel = "Renamed"
        s.name = s.displayName

        #expect(s.createdAt == created)
        #expect(s.timestampName == stamp)
        #expect(s.displayName.hasSuffix(stamp))
    }
}

@MainActor
struct CaptureSessionLifecycleTests {
    private func fixture() throws -> (CaptureArtifactStore, UserDefaults) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("session-lifecycle-\(UUID())")
        return (try CaptureArtifactStore(rootDirectory: root),
                UserDefaults(suiteName: "session-lifecycle-\(UUID())")!)
    }

    private var mesh: LiDARMeshSnapshot {
        LiDARMeshSnapshot(vertices: [SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0)],
                          triangleIndices: [0, 1, 2])
    }

    @Test func stopSavesMeshAndKeepsIdentityWithoutPausingTracking() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let snapshot = mesh
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults,
                                         meshSnapshotProvider: { snapshot })
        #expect(model.startNewSession(subjectLabel: "  Subject-A  "))
        let original = model.session
        model.scanViewModel.status.isRunning = true
        #expect(model.stopAutoSampling())
        let saved = try store.loadSession(id: original.id)
        #expect(saved.subjectLabel == "Subject-A")
        #expect(saved.createdAt == original.createdAt)
        #expect(saved.lidarMeshFilename != nil)
        #expect(store.loadLiDARMeshSnapshot(for: saved)?.triangleIndices == [0, 1, 2])
        #expect(model.scanViewModel.status.isRunning)
        // Opening the library's Current row must not invalidate a live capture.
        #expect(model.openSession(id: original.id))
        #expect(model.scanViewModel.status.isRunning)
        model.pauseLiveScan()
        #expect(model.session.id == original.id)
        #expect(!model.scanViewModel.status.isRunning)
    }

    @Test func unlabeledSessionPersistsAndCanBeLabeledLater() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.startNewSession())
        let original = model.session
        #expect(original.subjectLabel == nil)
        #expect(!model.needsSessionName)
        #expect(try store.loadSession(id: original.id).subjectLabel == nil)
        let restored = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(restored.session.id == original.id)
        #expect(!restored.needsSessionName)
        restored.renameSubject("  Later label  ")
        let saved = try store.loadSession(id: original.id)
        #expect(saved.subjectLabel == "Later label")
        #expect(saved.createdAt == original.createdAt)
        #expect(restored.startNewSession(subjectLabel: " \n "))
        #expect(restored.session.subjectLabel == nil)
        #expect(restored.session.id != original.id)
    }

    @Test func newSessionSavesOldMeshAndRelaunchRestoresNamedIdentity() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let snapshot = mesh
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults,
                                         meshSnapshotProvider: { snapshot })
        #expect(model.startNewSession(subjectLabel: "First"))
        let firstID = model.session.id
        #expect(model.startNewSession(subjectLabel: "Second"))
        #expect(try store.loadSession(id: firstID).lidarMeshFilename != nil)
        #expect(model.session.id != firstID)
        #expect(model.session.captureObservations.isEmpty)
        #expect(model.session.lidarMeshFilename == nil)
        let restored = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(restored.session.id == model.session.id)
        #expect(restored.session.subjectLabel == "Second")
        #expect(!restored.needsSessionName)
    }

    @Test func layoutChangePreservesSessionAndDoesNotDiscardCapturedEvidence() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.startNewSession(subjectLabel: "Named"))
        let original = model.session
        let layout = try #require(model.availableLayouts.first(where: { $0.hasElectrodeNet }))
        model.selectLayout(named: layout.name)
        #expect(model.session.id == original.id)
        #expect(model.session.name == original.name)
        #expect(model.session.createdAt == original.createdAt)
        #expect(model.session.layout == layout)
        let observation = CaptureObservation(capturedAt: Date(), cameraTransform: [], cameraIntrinsics: [],
            imageResolution: ImageResolution(width: 1, height: 1), hasSceneDepth: false,
            meshAnchorCount: 0, trackingSummary: "Normal")
        model.session.captureObservations = [observation]
        model.selectLayout(named: ElectrodeLayout.headMeshOnly.name)
        #expect(model.session.layout == layout)
        #expect(model.session.captureObservations == [observation])
    }

    @Test func failedMeshSaveKeepsOldSessionForRetry() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let snapshot = mesh
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults,
                                         meshSnapshotProvider: { snapshot })
        #expect(model.startNewSession(subjectLabel: "Keep me"))
        let id = model.session.id
        // A file where a reconstruction directory should be forces a real I/O failure.
        let blocked = store.rootDirectory.appendingPathComponent(id.uuidString).appendingPathComponent("reconstruction")
        try Data([1]).write(to: blocked)
        #expect(!model.startNewSession(subjectLabel: "Next"))
        #expect(model.session.id == id)
        #expect(model.captureSaveError != nil)
        try FileManager.default.removeItem(at: blocked)
        #expect(model.startNewSession(subjectLabel: "Next"))
        #expect(try store.loadSession(id: id).lidarMeshFilename != nil)
    }

    @Test func endingSavesMeshLocksCaptureAndSurvivesRelaunch() async throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let snapshot = mesh
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults,
                                         meshSnapshotProvider: { snapshot })
        #expect(model.startNewSession(subjectLabel: "End this capture"))
        let id = model.session.id
        model.scanViewModel.status.isRunning = true
        await model.endSession()
        let saved = try store.loadSession(id: id)
        #expect(saved.endedAt != nil)
        #expect(saved.lidarMeshFilename != nil)
        #expect(!model.scanViewModel.status.isRunning)
        #expect(!model.isEndingSession)
        #expect(!model.scanViewModel.canEditCaptureSettings)
        // A mesh-only pass with no RGB samples is still saved and ended, with
        // the validation finding surfaced rather than silently asserting success.
        #expect(model.sessionEndSummary?.contains("no observations") == true)
        #expect(model.releaseCheckMessages.contains("File validation: failed"))
        #expect(store.listSessionSummaries().first?.endedAt == saved.endedAt)
        model.startLiveScan()
        model.startAutoSampling()
        model.sampleCurrentARFrame()
        await model.captureHighResolutionStill()
        #expect(!model.scanViewModel.status.isRunning)
        #expect(!model.isAutoSampling)
        #expect(model.session.captureObservations.isEmpty)
        await model.endSession()
        #expect(model.session.endedAt == saved.endedAt)
        let reopened = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(reopened.isSessionEnded)
        #expect(!reopened.canEndSession)
        #expect(!reopened.scanViewModel.canEditCaptureSettings)
        #expect(reopened.startNewSession(subjectLabel: "Next"))
        #expect(!reopened.isSessionEnded)
        #expect(reopened.scanViewModel.canEditCaptureSettings)
    }

    @Test func failedReceiptWriteKeepsCapturePausedAndAllowsRetry() async throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.startNewSession(subjectLabel: "Retry"))
        let receipt = store.rootDirectory.appendingPathComponent(model.session.id.uuidString)
            .appendingPathComponent("capture-receipt.json")
        try FileManager.default.createDirectory(at: receipt, withIntermediateDirectories: true)
        await model.endSession()
        #expect(!model.isSessionEnded)
        #expect(!model.scanViewModel.status.isRunning)
        #expect(model.captureSaveError != nil)
        #expect(try store.loadSession(id: model.session.id).endedAt == nil)
        try FileManager.default.removeItem(at: receipt)
        await model.endSession()
        #expect(model.isSessionEnded)
        #expect(model.captureSaveError == nil)
    }

    @Test func legacySessionWithoutCompletionMarkerStillDecodes() throws {
        let original = ScanSession.newSession()
        let encoded = try JSONEncoder().encode(original)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "endedAt")
        let decoded = try JSONDecoder().decode(ScanSession.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.endedAt == nil)
        #expect(decoded.id == original.id)
    }

    @Test func deleteCurrentDoesNotRecreateItsFolder() throws {
        let (store, defaults) = try fixture()
        defer { try? FileManager.default.removeItem(at: store.rootDirectory) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.startNewSession(subjectLabel: "Delete me"))
        let id = model.session.id
        model.deleteSession(id: id)
        #expect(model.needsSessionName)
        #expect(!FileManager.default.fileExists(atPath: store.rootDirectory.appendingPathComponent(id.uuidString).path))
        #expect(store.listSessionSummaries().isEmpty)
    }
}
