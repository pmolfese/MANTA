import Foundation
import Testing
@testable import MANTACore

struct MANTASessionConsolidatorTests {
    @Test func linkedPassesPreserveFramesAndOriginalsInOnePackage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let producer = MANTAProducer(application: "test", version: "1", build: "1", platform: "test", operatingSystemVersion: "test", deviceModel: "test")
        var previous: UUID?
        var paths = [URL]()
        var originals = [Data]()
        for index in 0..<3 {
            var session = ScanSession.newSession(layout: .headMeshOnly)
            session.createdAt = Date(timeIntervalSince1970: Double(index))
            session.captureRoute = CaptureRouteProgress()
            session.captureRoute?.previousSessionID = previous
            previous = session.id
            session.captureObservations = [CaptureObservation(capturedAt: session.createdAt,
                cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, Float(index),0,0,1],
                cameraIntrinsics: [100,0,0, 0,100,0, 1,1,1], imageResolution: .init(width: 2, height: 2),
                hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal", cameraSnapshotFilename: "assets/same-name.png")]
            let path = root.appendingPathComponent(session.id.uuidString)
            try FileManager.default.createDirectory(at: path.appendingPathComponent("assets"), withIntermediateDirectories: true)
            try Data([UInt8(index)]).write(to: path.appendingPathComponent("assets/same-name.png"))
            let data = try JSONEncoder().encode(session)
            try data.write(to: path.appendingPathComponent("session.json"))
            paths.append(path); originals.append(data)
        }
        let result = try MANTASessionConsolidator.consolidate(paths.reversed(), to: root.appendingPathComponent("combined.manta"), producer: producer)
        #expect(result.bundle.capture.observations.count == 3)
        #expect(result.bundle.capture.capturePasses?.count == 3)
        #expect(result.bundle.capture.reconstruction == nil)
        #expect(Set(result.bundle.capture.observations.compactMap(\.imagePath)).count == 3)
        for (index, observation) in result.bundle.capture.observations.enumerated() {
            #expect(try Data(contentsOf: result.packageURL.appendingPathComponent(observation.imagePath!)) == Data([UInt8(index)]))
            #expect(observation.cameraToWorld[12] == Double(index))
            #expect(try Data(contentsOf: paths[index].appendingPathComponent("session.json")) == originals[index])
        }
        _ = try MANTABundleValidator().validate(directory: result.packageURL)
        #expect(throws: (any Error).self) {
            try MANTASessionConsolidator.consolidate([paths[0], paths[2]], to: root.appendingPathComponent("unlinked.manta"), producer: producer)
        }
    }
}
