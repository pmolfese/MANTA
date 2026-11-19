import Foundation
import Testing

@testable import MANTACore

struct MANTAWorkingSessionLoaderTests {
    @Test func mergesChronologicallyWithoutOverwritingMetadataOrInventingOrphanFrames() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let checkpoints = root.appendingPathComponent("acquisition/observations")
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        let saved = observation(time: 20)
        session.captureObservations = [saved]
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        var stale = saved
        stale.trackingSummary = "stale checkpoint"
        let earlier = observation(time: 10)
        try JSONEncoder().encode(stale).write(to: checkpoints.appendingPathComponent("a.json"))
        try JSONEncoder().encode(earlier).write(to: checkpoints.appendingPathComponent("b.json"))
        try JSONEncoder().encode(earlier).write(to: checkpoints.appendingPathComponent("c.json"))
        try Data("unfinished checkpoint".utf8).write(to: checkpoints.appendingPathComponent("pending.partial"))
        try Data("orphan image".utf8).write(to: root.appendingPathComponent("orphan.png"))

        let loaded = try MANTAWorkingSessionLoader.load(from: root)
        #expect(loaded.captureObservations == [earlier, saved])
    }

    @Test func acceptsLegacyButRejectsCorruptOrUnreadableCheckpointDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let acquisition = root.appendingPathComponent("acquisition")
        try FileManager.default.createDirectory(at: acquisition, withIntermediateDirectories: true)
        let session = ScanSession.newSession(layout: .headMeshOnly)
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        #expect(try MANTAWorkingSessionLoader.load(from: root).id == session.id)
        let checkpoints = acquisition.appendingPathComponent("observations")
        try Data().write(to: checkpoints)
        #expect(throws: (any Error).self) { try MANTAWorkingSessionLoader.load(from: root) }
        try FileManager.default.removeItem(at: checkpoints)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        try Data("invalid JSON".utf8).write(to: checkpoints.appendingPathComponent("broken.json"))
        #expect(throws: (any Error).self) { try MANTAWorkingSessionLoader.load(from: root) }
    }

    private func observation(time: TimeInterval) -> CaptureObservation {
        CaptureObservation(
            capturedAt: Date(timeIntervalSince1970: time),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal")
    }
}
