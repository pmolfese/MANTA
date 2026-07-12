//
//  HydroCelLayoutLoaderTests.swift
//  MANTATests
//
//  Created by Codex on 7/10/26.
//

import Foundation
import MANTACore
import Testing
@testable import MANTA

struct HydroCelLayoutLoaderTests {
    @Test func loadsHydroCel128FromCoordinatesSensorLayoutAndMetadata() throws {
        let layouts = try makeLoader().loadLayouts()

        let layout = try #require(layouts.first { $0.channelCount == 128 })

        #expect(layout.name == "HydroCel GSN 128 1.0")
        #expect(layout.id == "hydrocel-128")
        #expect(layout.coordinateSpace == .egiLayoutCentimeters)
        #expect(layout.electrodes.count == 128)
        #expect(layout.referenceSensor == 129)
        #expect(layout.referenceLabel == "VREF")
        #expect(layout.cardinalLabels.contains("E17"))
        #expect(layout.fiducialSensorHints[.nasion] == 17)
        #expect(layout.fiducialSensorHints[.leftPreauricular] == 45)
        #expect(layout.fiducialSensorHints[.rightPreauricular] == 108)
        #expect(layout.fiducialCoordinatePriors[.nasion] == Coordinate3D(x: 0.000, y: 10.356, z: -2.694))
        #expect(layout.electrodes[0].displayPosition == Coordinate2D(x: 162.908, y: -158.388))
        #expect(layout.electrodes[0].neighbors.contains(2))
    }

    @Test func loadsHydroCel256FromCoordinatesSensorLayoutAndMetadata() throws {
        let layouts = try makeLoader().loadLayouts()

        let layout = try #require(layouts.first { $0.channelCount == 256 })

        #expect(layout.name == "HydroCel GSN 256 1.0")
        #expect(layout.id == "hydrocel-256")
        #expect(layout.coordinateSpace == .egiLayoutCentimeters)
        #expect(layout.electrodes.count == 256)
        #expect(layout.referenceSensor == 257)
        #expect(layout.referenceLabel == "VREF")
        #expect(layout.cardinalLabels.contains("E31"))
        #expect(layout.fiducialSensorHints[.nasion] == 31)
        #expect(layout.fiducialSensorHints[.leftPreauricular] == 74)
        #expect(layout.fiducialSensorHints[.rightPreauricular] == 192)
        #expect(layout.fiducialCoordinatePriors[.rightPreauricular] == Coordinate3D(x: 8.592, y: 0.498, z: -4.128))
        #expect(layout.electrodes[0].displayPosition == Coordinate2D(x: 224.168, y: -199.371))
        #expect(layout.electrodes[0].neighbors.contains(2))
    }

    private func makeLoader() -> HydroCelLayoutLoader {
        HydroCelLayoutLoader()
    }
}
