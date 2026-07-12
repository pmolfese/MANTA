//
//  ElectrodeExportersTests.swift
//  MANTATests
//
//  Created by Codex on 7/10/26.
//

import Testing
import MANTACore
@testable import MANTA

struct ElectrodeExportersTests {
    @Test func csvIncludesHeaderAndElectrodeMetadata() {
        let session = makeSession()

        let csv = ElectrodeExporters.csv(session)

        #expect(csv.contains("label,x,y,z,unit,coordinate_frame,role,state,confidence"))
        #expect(csv.contains("Cz,1.000,2.000,3.000,meters,arkit-world,Cardinal,Reviewed,0.990"))
    }

    @Test func sfpExportsTabSeparatedCoordinates() {
        let session = makeSession()

        let sfp = ElectrodeExporters.sfp(session)

        #expect(sfp == "Cz\t1.000000\t2.000000\t3.000000")
    }

    @Test func sfpConvertsHeadMillimetersToMetersAndEmitsMNEFiducials() {
        var session = makeSession()
        session.coordinateSpace = .headRASMillimeters
        session.fiducials = [
            FiducialAnnotation(kind: .nasion, coordinate: Coordinate3D(x: 0, y: 95, z: 20), state: .reviewed),
            FiducialAnnotation(kind: .leftPreauricular, coordinate: Coordinate3D(x: -78, y: 0, z: 0), state: .reviewed),
            FiducialAnnotation(kind: .rightPreauricular, coordinate: Coordinate3D(x: 78, y: 0, z: 0), state: .reviewed)
        ]

        let sfp = ElectrodeExporters.sfp(session)
        let lines = sfp.split(separator: "\n")

        #expect(lines.first == "FidNz\t0.000000\t0.095000\t0.020000")
        #expect(sfp.contains("FidT9\t-0.078000\t0.000000\t0.000000"))
        #expect(sfp.contains("FidT10\t0.078000\t0.000000\t0.000000"))
        // Electrodes follow the fiducials.
        #expect(sfp.contains("Cz\t0.001000\t0.002000\t0.003000"))
    }

    @Test func sfpConvertsEGICentimetersToMeters() {
        var session = makeSession()
        session.coordinateSpace = .egiLayoutCentimeters

        let sfp = ElectrodeExporters.sfp(session)

        #expect(sfp == "Cz\t0.010000\t0.020000\t0.030000")
    }

    @Test func bidsElectrodesTSVUsesNameAndTypeColumns() {
        let session = makeSession()

        let tsv = ElectrodeExporters.bidsElectrodesTSV(session)

        #expect(tsv.contains("name\tx\ty\tz\ttype"))
        #expect(tsv.contains("Cz\t1.000\t2.000\t3.000\tEEG"))
    }

    @Test func bidsExportDeclaresCoordinateFrameAndUnit() throws {
        var session = makeSession()
        session.coordinateSpace = .headRASMillimeters

        let sidecar = try ElectrodeExporters.bidsCoordinateSystemJSON(session)

        #expect(sidecar.contains("\"EEGCoordinateSystem\" : \"Other\""))
        #expect(sidecar.contains("\"EEGCoordinateSystemDescription\" : \"head-ras\""))
        #expect(sidecar.contains("\"EEGCoordinateUnits\" : \"mm\""))
    }

    @Test func elpExportsSphericalAnglesRatherThanCartesianXYZ() {
        var session = makeSession()
        session.electrodes[0].coordinate = Coordinate3D(x: 0, y: 1, z: 1)

        let elp = ElectrodeExporters.elp(session)

        #expect(elp == "EEG\tCz\t0.000000\t45.000000")
    }

    @Test func egiXMLConvertsHeadMillimetersToCentimeters() {
        var session = makeSession()
        session.coordinateSpace = .headRASMillimeters
        session.electrodes[0].coordinate = Coordinate3D(x: 10, y: 20, z: 30)

        let xml = ElectrodeExporters.egiCoordinatesXML(session)

        #expect(xml.contains("http://www.egi.com/coordinates_mff"))
        #expect(xml.contains("<x>1.000000</x>"))
        #expect(xml.contains("<y>2.000000</y>"))
        #expect(xml.contains("<z>3.000000</z>"))
    }

    private func makeSession() -> ScanSession {
        var session = ScanSession.newSession()
        session.electrodes = [
            ElectrodeAnnotation(
                label: "Cz",
                role: .cardinal,
                coordinate: Coordinate3D(x: 1, y: 2, z: 3),
                confidence: 0.99,
                state: .reviewed
            )
        ]
        return session
    }
}
