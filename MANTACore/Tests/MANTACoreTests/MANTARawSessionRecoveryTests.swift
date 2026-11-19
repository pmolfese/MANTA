import Foundation
import Testing

@testable import MANTACore

struct MANTARawSessionRecoveryTests {
    @Test func opensInPlacePreservesSourcesAndReopensStableIndex() throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.createdAt = Date(timeIntervalSince1970: 1_784_035_954.123456)
        let original = try JSONEncoder().encode(session)
        try original.write(to: root.appendingPathComponent("session.json"))
        let producer = MANTAProducer(application: "test", version: "1", build: "1",
            platform: "test", operatingSystemVersion: "test", deviceModel: "test")
        var progress: [MANTACaptureReadProgress] = []
        let first = try MANTARawSessionRecovery().openDirectoryInPlace(root, producer: producer) { progress.append($0) }
        let second = try MANTARawSessionRecovery().openDirectoryInPlace(root, producer: producer)
        #expect(first.manifest.bundleID == second.manifest.bundleID)
        #expect(first.rootDirectory == root.resolvingSymlinksInPath())
        #expect(second.integrityWarnings.isEmpty)
        #expect(try Data(contentsOf: root.appendingPathComponent("session.json")) == original)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == ["session.json", "derivatives"])
        #expect(first.manifest.content.capture == "derivatives/acquisition/capture.json")
        #expect(progress.contains { $0.fraction == 1 })
        session.captureMode = .photogrammetry
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        #expect(throws: MANTABundleValidationError.self) {
            try MANTARawSessionRecovery().openDirectoryInPlace(root, producer: producer)
        }
    }

    @Test func recoversWorkingSessionDirectoryAsValidatedRawPackage() throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent(
            "042D4749-4CE7-4303-AC6C-4427460DBF55", isDirectory: true)
        let assets = sessionDirectory.appendingPathComponent("assets", isDirectory: true)
        let acquisition = sessionDirectory.appendingPathComponent("acquisition", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: acquisition, withIntermediateDirectories: true)
        try Data("camera".utf8).write(to: assets.appendingPathComponent("camera-one.jpg"))
        try Data("{\"site\":\"lab\"}".utf8).write(
            to: acquisition.appendingPathComponent("context.json"))

        var session = ScanSession.newSession(layout: .fallback128)
        session.id = UUID(uuidString: "042D4749-4CE7-4303-AC6C-4427460DBF55")!
        session.captureMode = .photogrammetry
        session.fiducials[0].coordinate = Coordinate3D(x: 0, y: 0.1, z: -0.2)
        session.fiducials[0].state = .reviewed
        session.captureObservations = [
            CaptureObservation(
                id: UUID(uuidString: "202833E5-A082-4865-BDAD-849FA49975D7")!,
                capturedAt: Date(timeIntervalSince1970: 1_784_035_954),
                cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.2, 0, -0.5, 1],
                cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
                imageResolution: ImageResolution(width: 2, height: 2),
                hasSceneDepth: false,
                meshAnchorCount: 0,
                trackingSummary: "Normal",
                cameraSnapshotFilename: "assets/camera-one.jpg")
        ]
        // Simulate termination after the completed observation checkpoint but
        // before session.json is refreshed. Mac recovery must retain the frame.
        let checkpoints = acquisition.appendingPathComponent("observations", isDirectory: true)
        try FileManager.default.createDirectory(at: checkpoints, withIntermediateDirectories: true)
        let completed = session.captureObservations[0]
        let labels = acquisition.appendingPathComponent("live-labels")
        try FileManager.default.createDirectory(at: labels, withIntermediateDirectories: true)
        let labelPath = "acquisition/live-labels/\(completed.id.uuidString).json"
        try Data("{\"sightings\":[]}".utf8).write(to: sessionDirectory.appendingPathComponent(labelPath))
        try JSONEncoder().encode(completed).write(to: checkpoints.appendingPathComponent("completed.json"))
        var staleSession = session
        staleSession.captureObservations = []
        try JSONEncoder().encode(staleSession).write(
            to: sessionDirectory.appendingPathComponent("session.json"))

        let destination = root.appendingPathComponent("recovered.manta", isDirectory: true)
        let result = try MANTARawSessionRecovery().recoverDirectoryPackage(
            from: sessionDirectory,
            to: destination,
            producer: MANTAProducer(
                application: "MANTAReceiver", version: "0.1", build: "1", platform: "test",
                operatingSystemVersion: "test", deviceModel: "test"))

        #expect(result.packageURL == destination)
        #expect(result.bundle.rootDirectory == destination)
        #expect(result.bundle.capture.sessionID == session.id)
        #expect(result.bundle.capture.observations.count == 1)
        #expect(result.bundle.manifest.files.contains { $0.path == labelPath && $0.role == "live-label-evidence" })
        #expect(try JSONDecoder().decode(ScanSession.self, from: Data(
            contentsOf: sessionDirectory.appendingPathComponent("session.json"))).captureObservations.isEmpty)
        #expect(result.bundle.capture.electrodes == nil)
        #expect(result.bundle.capture.fiducials?.first?.kind == FiducialKind.nasion.rawValue)
        #expect(result.bundle.capture.fiducials?.first?.coordinate == [0, 0.1, -0.2])
        #expect(result.bundle.manifest.content.layout == "layouts/recovered-layout.json")
        let recoveredLayout = try MANTAJSON.makeDecoder().decode(
            ElectrodeLayout.self,
            from: Data(contentsOf: destination.appendingPathComponent("layouts/recovered-layout.json")))
        #expect(recoveredLayout.id == ElectrodeLayout.fallback128.id)
        #expect(recoveredLayout.electrodes.count == 128)
        #expect(result.bundle.manifest.files.contains { $0.path == "assets/camera-one.jpg" })
        #expect(result.bundle.manifest.files.contains { $0.path == "acquisition/context.json" })
        #expect(FileManager.default.fileExists(
            atPath: destination.appendingPathComponent("manifest.json").path))
    }

    @Test func rejectsUnsafeReferencedPaths() throws {
        let root = temporaryURL()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessionDirectory = root.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.captureObservations = [
            CaptureObservation(
                capturedAt: Date(),
                cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
                cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
                imageResolution: ImageResolution(width: 2, height: 2),
                hasSceneDepth: false,
                meshAnchorCount: 0,
                trackingSummary: "Normal",
                cameraSnapshotFilename: "../outside.jpg")
        ]
        try JSONEncoder().encode(session).write(
            to: sessionDirectory.appendingPathComponent("session.json"))

        #expect(throws: MANTARawSessionRecoveryError.invalidReferencedPath("../outside.jpg")) {
            try MANTARawSessionRecovery().recoverDirectoryPackage(
                from: sessionDirectory,
                to: root.appendingPathComponent("recovered.manta", isDirectory: true),
                producer: MANTAProducer(
                    application: "MANTAReceiver", version: "0.1", build: "1",
                    platform: "test", operatingSystemVersion: "test", deviceModel: "test"))
        }
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTARawSessionRecovery-\(UUID().uuidString)", isDirectory: true)
    }
}
