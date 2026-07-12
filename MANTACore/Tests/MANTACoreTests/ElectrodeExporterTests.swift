import Foundation
import Testing

@testable import MANTACore

struct ElectrodeExporterTests {
    @Test func portableFormatsApplyTheirUnitContracts() throws {
        var session = ScanSession.newSession()
        session.coordinateSpace = .headRASMillimeters
        session.electrodes = [
            ElectrodeAnnotation(
                label: "E1", role: .regular, coordinate: Coordinate3D(x: 10, y: 20, z: 30),
                confidence: 1, state: .reviewed)
        ]

        #expect(ElectrodeExporters.sfp(session) == "E1\t0.010000\t0.020000\t0.030000")
        #expect(ElectrodeExporters.egiCoordinatesXML(session).contains("<x>1.000000</x>"))
        #expect(try ElectrodeExporters.bidsCoordinateSystemJSON(session).contains("\"mm\""))
    }

    @Test func elpContainsBESASphericalAngles() {
        var session = ScanSession.newSession()
        session.electrodes = [
            ElectrodeAnnotation(
                label: "Cz", role: .cardinal, coordinate: Coordinate3D(x: 0, y: 1, z: 1),
                confidence: 1, state: .reviewed)
        ]

        #expect(ElectrodeExporters.elp(session) == "EEG\tCz\t0.000000\t45.000000")
    }
}
