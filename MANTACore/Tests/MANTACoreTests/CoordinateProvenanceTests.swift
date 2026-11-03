import Foundation
import Testing
@testable import MANTACore

struct CoordinateProvenanceTests {
    @Test func reviewDoesNotTurnInferredCoordinatesIntoMeasurements() throws {
        var point = ElectrodeAnnotation(label: "E1", role: .regular,
            coordinate: Coordinate3D(x: 10, y: 20, z: 30), confidence: 1,
            state: .needsReview, provenance: .templateInferred)
        point.state = .reviewed
        var session = ScanSession.newSession()
        session.coordinateSpace = .headRASMillimeters
        session.electrodes = [point]
        #expect(ElectrodeExporters.geoScanTXT(session).contains("E1 1.000000 2.000000 3.000000 1"))
        session.electrodes[0].provenance = .imageDepthObserved
        #expect(ElectrodeExporters.geoScanTXT(session).contains("E1 1.000000 2.000000 3.000000 0"))
        session.electrodes[0].provenance = .manualPlacement
        #expect(ElectrodeExporters.geoScanTXT(session).contains("E1 1.000000 2.000000 3.000000 1"))
    }

    @Test func oldRecordsRemainUnknownAndNewProvenanceSurvivesBundleCoding() throws {
        let solution = MANTAElectrodeSolution(label: "E1", role: "Regular", coordinateSystem: "arkit-world",
            coordinate: [0.1, 0.2, 0.3], confidence: 1, state: "Reviewed", provenance: .imageDepthObserved)
        let data = try JSONEncoder().encode(solution)
        #expect(try JSONDecoder().decode(MANTAElectrodeSolution.self, from: data).provenance == .imageDepthObserved)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "provenance")
        let old = try JSONDecoder().decode(MANTAElectrodeSolution.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.provenance == nil)
    }

    @Test func pairedValidationContextRoundTrips() throws {
        let context = AcquisitionContext(pairedReferenceSessionID: "pair-001",
            acquisitionOrder: "mantaThenGeoScan", netMovementNotes: "No adjustment observed",
            coordinateTarget: "visibleDiscCupCenter")
        #expect(try JSONDecoder().decode(AcquisitionContext.self, from: JSONEncoder().encode(context)) == context)
        let old = try JSONDecoder().decode(AcquisitionContext.self, from: Data("{}".utf8))
        #expect(old.pairedReferenceSessionID == nil)
        #expect(old.coordinateTarget == nil)
    }
}
