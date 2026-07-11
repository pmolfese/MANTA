//
//  SessionLibraryTests.swift
//  MANTATests
//
//  Covers session naming (timestamp always paired with the subject label) and
//  the persistence/listing that backs the subject library.
//

import Foundation
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

    @Test func exportBundleProducesZipNamedFromSession() throws {
        let store = try makeStore()
        let s = session(subjectLabel: "Subject B")
        try store.writeSession(s)

        let url = try store.exportSessionBundle(id: s.id)

        #expect(url.pathExtension == "zip")
        #expect(url.lastPathComponent == "\(s.fileSafeName).zip")
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        #expect(size > 0)
        try? FileManager.default.removeItem(at: url)
    }

    @Test func exportBundleThrowsForMissingSession() throws {
        let store = try makeStore()
        #expect(throws: (any Error).self) {
            try store.exportSessionBundle(id: UUID())
        }
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
