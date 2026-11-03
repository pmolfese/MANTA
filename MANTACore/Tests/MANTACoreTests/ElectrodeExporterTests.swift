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

    @Test func geoScanAndCentimeterSFPKeepGeometryAndFlagUnverifiedPoints() {
        var session = ScanSession.newSession()
        session.coordinateSpace = .headRASMillimeters
        session.electrodes = [
            ElectrodeAnnotation(label: "E1", role: .regular,
                coordinate: Coordinate3D(x: 10, y: -20, z: 30), confidence: 1, state: .reviewed),
            ElectrodeAnnotation(label: "E2", role: .regular,
                coordinate: Coordinate3D(x: 0, y: 0, z: 0), confidence: 0, state: .missing)
        ]
        session.fiducials = [FiducialAnnotation(kind: .nasion,
            coordinate: Coordinate3D(x: 0, y: 90, z: 0), state: .reviewed)]
        let sfp = ElectrodeExporters.export(session, as: .sfpCentimeters)
        #expect(sfp.contains("FidNz\t0.000000\t9.000000\t0.000000"))
        #expect(sfp.contains("E1\t1.000000\t-2.000000\t3.000000"))
        let geo = ElectrodeExporters.export(session, as: .geoScanTXT)
        #expect(geo.contains("# Units = cm"))
        #expect(geo.contains("# CoordinateFrame = head-ras"))
        #expect(geo.contains("FidNz 0.000000 9.000000 0.000000 1"))
        #expect(geo.contains("E1 1.000000 -2.000000 3.000000 1"))
        #expect(!geo.contains("E2 "))
    }

    @Test func geoScanWriterRespectsExplicitMeasurementProvenance() {
        let text = GeoScanTextExporter.export([
            GeoScanTextPoint(label: "E1", coordinate: Coordinate3D(x: 0.1, y: 0, z: 0), isEstimated: false),
            GeoScanTextPoint(label: "E2", coordinate: Coordinate3D(x: 0, y: 0.1, z: 0))
        ], sourceUnit: .meters, coordinateFrame: "arkit-world", labellingTemplate: "hydrocel_256.xml")
        #expect(text.contains("LabellingTemplate = hydrocel_256.xml"))
        #expect(text.contains("E1 10.000000 0.000000 0.000000 0"))
        #expect(text.contains("E2 0.000000 10.000000 0.000000 1"))
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

    @Test func egiXMLExportsCzAsTheReferenceSensor() {
        var session = ScanSession.newSession()
        session.layout = .fallback128
        session.electrodes = [
            ElectrodeAnnotation(
                label: "Cz", role: .cardinal,
                coordinate: Coordinate3D(x: 0, y: 0.1, z: 0),
                confidence: 1, state: .reviewed)
        ]

        let xml = ElectrodeExporters.egiCoordinatesXML(session)

        #expect(xml.contains("<name>VREF</name>"))
        #expect(xml.contains("<number>129</number>"))
        #expect(xml.contains("<type>1</type>"))
    }
}
