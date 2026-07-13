import Foundation
import Testing
@testable import MANTACore

struct ReconstructionReferenceTests {
    @Test func reconstructionAssetsAndAlignmentRoundTrip() throws {
        let document = MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: UUID(),
            captureMode: "both",
            layoutID: "hydrocel-128",
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world", handedness: "right", units: .meters,
                    description: "ARKit world frame")
            ],
            observations: [],
            reconstruction: MANTAReconstructionReference(
                lidarMeshPath: "reconstruction/lidar_mesh.ply",
                objectCaptureModelPath: "reconstruction/model.usdz",
                headBoundingBox: HeadBoundingBox(
                    center: Coordinate3D(x: 0.1, y: 0.2, z: -0.4)),
                modelToWorld: Array(repeating: 0, count: 16),
                worldCoordinateSystem: "arkit-world"))

        let encoded = try MANTAJSON.canonicalData(document)
        let decoded = try MANTAJSON.makeDecoder().decode(MANTACaptureDocument.self, from: encoded)

        #expect(decoded.reconstruction == document.reconstruction)
    }
}
