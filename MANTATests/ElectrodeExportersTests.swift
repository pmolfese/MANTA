//
//  ElectrodeExportersTests.swift
//  MANTATests
//
//  Created by Codex on 7/10/26.
//

import Testing
@testable import MANTA

struct ElectrodeExportersTests {
    @Test func csvIncludesHeaderAndElectrodeMetadata() {
        let session = makeSession()

        let csv = ElectrodeExporters.csv(session)

        #expect(csv.contains("label,x,y,z,role,state,confidence"))
        #expect(csv.contains("Cz,1.000,2.000,3.000,Cardinal,Reviewed,0.990"))
    }

    @Test func sfpExportsTabSeparatedCoordinates() {
        let session = makeSession()

        let sfp = ElectrodeExporters.sfp(session)

        #expect(sfp == "Cz\t1.000\t2.000\t3.000")
    }

    @Test func sfpEmitsFiducialsWithMNELabels() {
        var session = makeSession()
        session.fiducials = [
            FiducialAnnotation(kind: .nasion, coordinate: Coordinate3D(x: 0, y: 95, z: 20), state: .reviewed),
            FiducialAnnotation(kind: .leftPreauricular, coordinate: Coordinate3D(x: -78, y: 0, z: 0), state: .reviewed),
            FiducialAnnotation(kind: .rightPreauricular, coordinate: Coordinate3D(x: 78, y: 0, z: 0), state: .reviewed)
        ]

        let sfp = ElectrodeExporters.sfp(session)
        let lines = sfp.split(separator: "\n")

        #expect(lines.first == "FidNz\t0.000\t95.000\t20.000")
        #expect(sfp.contains("FidT9\t-78.000\t0.000\t0.000"))
        #expect(sfp.contains("FidT10\t78.000\t0.000\t0.000"))
        // Electrodes follow the fiducials.
        #expect(sfp.contains("Cz\t1.000\t2.000\t3.000"))
    }

    @Test func bidsElectrodesTSVUsesNameAndTypeColumns() {
        let session = makeSession()

        let tsv = ElectrodeExporters.bidsElectrodesTSV(session)

        #expect(tsv.contains("name\tx\ty\tz\ttype"))
        #expect(tsv.contains("Cz\t1.000\t2.000\t3.000\tEEG"))
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
