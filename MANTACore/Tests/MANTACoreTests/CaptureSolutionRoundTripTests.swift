import Foundation
import Testing
@testable import MANTACore

/// Fiducials and electrodes embedded in the capture document must survive the
/// finalize → immutable archive → import/validate round trip, so an offline
/// placement is readable by the receiver.
struct CaptureSolutionRoundTripTests {
    private func captureWithSolution(sessionID: UUID) -> MANTACaptureDocument {
        MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: sessionID,
            captureMode: "both",
            layoutID: "hydrocel-128",
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world", handedness: "right", units: .meters,
                    description: "ARKit world frame.")
            ],
            observations: [],
            fiducials: [
                MANTAFiducialSolution(
                    kind: "Nasion", coordinateSystem: "arkit-world",
                    coordinate: [0.01, 0.02, -0.30], state: "Reviewed"),
                MANTAFiducialSolution(
                    kind: "RPA", coordinateSystem: "arkit-world",
                    coordinate: nil, state: "Needs Review")
            ],
            electrodes: [
                MANTAElectrodeSolution(
                    label: "E17", role: "Cardinal", coordinateSystem: "arkit-world",
                    coordinate: [0.03, 0.05, -0.28], confidence: 0.9, state: "Detected")
            ])
    }

    private func request(capture: MANTACaptureDocument, source: URL) -> MANTABundleFinalizationRequest {
        MANTABundleFinalizationRequest(
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

    @Test func solutionSurvivesFinalizeAndImport() throws {
        let sessionID = UUID(uuidString: "c75cf330-8751-46f3-bcd4-7bef70b28ee8")!
        let source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("camera-bytes".utf8).write(to: source)

        let finalized = try MANTABundleFinalizer().finalize(
            request(capture: captureWithSolution(sessionID: sessionID), source: source),
            in: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        let imported = try MANTAArchiveImporter().importBundle(
            at: finalized.archiveURL,
            to: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))

        let fiducials = try #require(imported.capture.fiducials)
        #expect(fiducials.count == 2)
        #expect(fiducials.first { $0.kind == "Nasion" }?.coordinate == [0.01, 0.02, -0.30])
        #expect(fiducials.first { $0.kind == "RPA" }?.coordinate == nil)

        let electrodes = try #require(imported.capture.electrodes)
        #expect(electrodes.count == 1)
        #expect(electrodes.first?.label == "E17")
        #expect(electrodes.first?.coordinate == [0.03, 0.05, -0.28])
    }

    @Test func captureWithoutSolutionStillDecodes() throws {
        // Backward compatibility: a document with no solution fields round-trips
        // with nil arrays (older bundles).
        let capture = MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: UUID(),
            captureMode: "lidar",
            layoutID: "hydrocel-128",
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world", handedness: "right", units: .meters, description: "w")
            ],
            observations: [])
        let data = try MANTAJSON.makeEncoder().encode(capture)
        let decoded = try MANTAJSON.makeDecoder().decode(MANTACaptureDocument.self, from: data)
        #expect(decoded.fiducials == nil)
        #expect(decoded.electrodes == nil)
    }
}
