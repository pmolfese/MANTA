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
        let destination = exported.url.deletingLastPathComponent()
            .appendingPathComponent("verified-\(UUID().uuidString)", isDirectory: true)
        _ = try MANTAArchiveImporter().importBundle(at: exported.url, to: destination)

        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("runs/live-current/run.json").path))
        try? FileManager.default.removeItem(at: destination)
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
