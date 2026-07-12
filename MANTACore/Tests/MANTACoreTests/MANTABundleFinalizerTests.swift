import Foundation
import Testing

@testable import MANTACore

struct MANTABundleFinalizerTests {
    @Test func identicalRequestsProduceByteIdenticalArchives() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("camera-bytes".utf8).write(to: source)
        let request = makeRequest(source: source)
        let firstDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let secondDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)

        let first = try MANTABundleFinalizer().finalize(request, in: firstDirectory)
        let second = try MANTABundleFinalizer().finalize(request, in: secondDirectory)
        let firstData = try Data(contentsOf: first.archiveURL)
        let secondData = try Data(contentsOf: second.archiveURL)

        #expect(first.archiveURL.pathExtension == "manta")
        #expect(firstData == secondData)
        #expect(firstData.prefix(4) == Data([0x50, 0x4b, 0x03, 0x04]))
        #expect(first.manifest.files.map(\.path) == ["assets/camera.jpg", "capture.json"])
        #expect(first.manifest.files.allSatisfy { $0.sha256.count == 64 })
        try verifyZIP(first.archiveURL)
    }

    @Test func derivedFinalizationRequiresAndRecordsChangeLog() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("camera-bytes".utf8).write(to: source)
        var request = makeRequest(source: source)
        request.parentBundleID = UUID(uuidString: "86b20bb6-f31e-4b0b-b423-cf93ae2742bc")!
        request.changes = [
            MANTAChangeRecord(
                id: UUID(uuidString: "918521d9-b574-4811-a88e-130c3580913e")!,
                changedAt: request.finalizedAt,
                category: "session-export",
                summary: "Exported a revised working session.",
                targets: ["capture.json"])
        ]

        let result = try MANTABundleFinalizer().finalize(
            request,
            in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        #expect(result.manifest.content.changeLog == "log_manta.json")
        #expect(result.manifest.files.contains { $0.path == "log_manta.json" })
    }

    @Test func finalizedBundleCannotBeOverwritten() throws {
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("camera-bytes".utf8).write(to: source)
        let request = makeRequest(source: source)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        _ = try MANTABundleFinalizer().finalize(request, in: directory)

        #expect(throws: MANTABundleFinalizationError.destinationExists("20260714_133222.manta")) {
            try MANTABundleFinalizer().finalize(request, in: directory)
        }
    }

    @Test func canonicalJSONRejectsNonFiniteNumbers() {
        #expect(throws: EncodingError.self) {
            try MANTAJSON.canonicalData([Double.nan])
        }
    }

    private func makeRequest(source: URL) -> MANTABundleFinalizationRequest {
        let sessionID = UUID(uuidString: "c75cf330-8751-46f3-bcd4-7bef70b28ee8")!
        let capture = MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: sessionID,
            captureMode: "both",
            layoutID: "hydrocel-128",
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world", handedness: "right", units: .meters,
                    description: "ARKit world frame.")
            ],
            observations: [])
        return MANTABundleFinalizationRequest(
            capture: capture,
            producer: MANTAProducer(
                application: "MANTA", version: "0.1", build: "1", platform: "test",
                operatingSystemVersion: "test", deviceModel: "test"),
            createdAt: Date(timeIntervalSince1970: 1_784_035_822),
            finalizedAt: Date(timeIntervalSince1970: 1_784_035_942),
            bundleID: UUID(uuidString: "c69e776c-551e-4a68-b837-f9a0357df3ce")!,
            files: [
                MANTABundleFileSource(
                    path: "assets/camera.jpg", sourceURL: source, mediaType: "image/jpeg",
                    role: "camera-image")
            ])
    }

    private func verifyZIP(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-tqq", url.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
