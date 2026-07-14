import Foundation
import Testing
import simd

@testable import MANTACore

struct SharedSolverMigrationTests {
    @Test func headFrameConvertsMetersToCanonicalMillimeters() throws {
        var session = ScanSession.newSession()
        session.fiducials = [
            FiducialAnnotation(
                kind: .nasion, coordinate: Coordinate3D(x: 0, y: 0.1, z: 0),
                state: .reviewed),
            FiducialAnnotation(
                kind: .leftPreauricular, coordinate: Coordinate3D(x: -0.075, y: 0, z: 0),
                state: .reviewed),
            FiducialAnnotation(
                kind: .rightPreauricular, coordinate: Coordinate3D(x: 0.075, y: 0, z: 0),
                state: .reviewed)
        ]
        session.electrodes = [
            ElectrodeAnnotation(
                label: "E1", role: .regular, coordinate: Coordinate3D(x: 0.075, y: 0, z: 0),
                confidence: 1, state: .detected)
        ]

        let converted = try #require(HeadCoordinateFrame.apply(to: session))

        #expect(converted.coordinateSpace == .headRASMillimeters)
        #expect(abs(converted.electrodes[0].coordinate.x - 75) < 0.01)
    }

    @Test func templateFitAndNeighborValidationRunInCore() throws {
        let layout = syntheticLayout()
        let detected: [String: SIMD3<Float>] = [
            "E1": SIMD3(0, 0, 0), "E2": SIMD3(0.01, 0, 0),
            "E3": SIMD3(0, 0.01, 0), "E4": SIMD3(0.01, 0.01, 0)
        ]

        let fit = try #require(ElectrodeTemplateFitter.fit(detected: detected, layout: layout))
        let validation = ElectrodeNeighborValidator.validate(positions: detected, layout: layout)

        #expect(fit.anchorCount == 4)
        #expect(validation.scale > 0)
        #expect(validation.suspectLabels.isEmpty)
    }

    @Test func robustCapOrientationRejectsAMislabeledAnchor() throws {
        let points = [
            SIMD3<Float>(0, 0, 0), SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, 1, 0),
            SIMD3<Float>(1, 1, 0), SIMD3<Float>(0.5, 0.5, 1), SIMD3<Float>(0.2, 0.8, 0.6)
        ]
        let electrodes = points.enumerated().map { index, point in
            ElectrodeDefinition(
                number: index + 1, label: "E\(index + 1)", role: .regular,
                coordinatePrior: Coordinate3D(
                    x: Double(point.x), y: Double(point.y), z: Double(point.z)),
                displayPosition: nil, neighbors: [])
        }
        let layout = ElectrodeLayout(
            id: "robust-6", name: "Robust", channelCount: 6,
            labels: electrodes.map(\.label), cardinalLabels: [], electrodes: electrodes,
            fiducialCoordinatePriors: [:], fiducialSensorHints: [:],
            referenceSensor: nil, referenceLabel: nil)
        var detected = Dictionary(uniqueKeysWithValues: points.enumerated().map {
            ("E\($0.offset + 1)", $0.element * 0.01 + SIMD3<Float>(0.1, 0.2, 0.3))
        })
        detected["E6"] = SIMD3<Float>(0.7, -0.4, 0.9)

        let fit = try #require(ElectrodeCapOrientation.estimateRobust(
            detected: detected, layout: layout, maxRMSMeters: 0.002,
            inlierThresholdMeters: 0.003))

        #expect(fit.isReliable)
        #expect(fit.anchorCount == 5)
        #expect(fit.rmsError < 0.001)
    }

    @Test func portableDetectionConsumesTextDepthSamplesWithoutAppleFrameworks() {
        let camera = PinholeCamera(
            fx: 100, fy: 100, cx: 50, cy: 50,
            cameraToWorld: matrix_identity_float4x4)
        let frames = [
            PortableDetectionFrame(camera: camera, samples: [
                RecognizedElectrodeSample(
                    text: "1", imageCenter: SIMD2(50, 50), confidence: 0.9,
                    depthMeters: 1)
            ])
        ]
        let result = PortableElectrodeDetectionOrchestrator(
            confidenceThreshold: 0.1, validatesNeighbors: false,
            fillsMissingFromTemplate: false
        ).detect(layout: syntheticLayout(), frames: frames)

        #expect(result.count == 1)
        #expect(result[0].label == "E1")
        #expect(result[0].state == .detected)
    }

    @Test func portableLayoutLoaderParsesMetadataAndBothXMLDialects() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(metadata.utf8).write(to: directory.appendingPathComponent("HydroCelLayoutMetadata.json"))
        try Data(coordinatesXML.utf8).write(to: directory.appendingPathComponent("coordinates.xml"))
        try Data(layoutXML.utf8).write(to: directory.appendingPathComponent("layout.xml"))

        let layouts = try HydroCelLayoutFileLoader(resourceDirectory: directory).loadLayouts()
        let layout = try #require(layouts.first)

        #expect(layout.id == "test-2")
        #expect(layout.electrodes.count == 2)
        #expect(layout.electrodes[0].neighbors == [2])
        #expect(layout.fiducialCoordinatePriors[.nasion] == Coordinate3D(x: 0, y: 9, z: 0))
    }

    private func syntheticLayout() -> ElectrodeLayout {
        let points = [
            Coordinate3D(x: 0, y: 0, z: 0), Coordinate3D(x: 1, y: 0, z: 0),
            Coordinate3D(x: 0, y: 1, z: 0), Coordinate3D(x: 1, y: 1, z: 0)
        ]
        let electrodes = points.enumerated().map { index, point in
            ElectrodeDefinition(
                number: index + 1, label: "E\(index + 1)", role: .regular,
                coordinatePrior: point, displayPosition: nil,
                neighbors: (1...4).filter { $0 != index + 1 })
        }
        return ElectrodeLayout(
            id: "synthetic-4", name: "Synthetic", channelCount: 4,
            labels: electrodes.map(\.label), cardinalLabels: [], electrodes: electrodes,
            fiducialCoordinatePriors: [:], fiducialSensorHints: [:],
            referenceSensor: nil, referenceLabel: nil)
    }

    private var metadata: String {
        """
        {"layouts":[{"id":"test-2","name":"Test","channelCount":2,
        "coordinatesFile":"coordinates","sensorLayoutFile":"layout",
        "referenceSensor":null,"referenceLabel":null,"cardinalSensors":[1],
        "fiducialSensorHints":{"nasion":1}}]}
        """
    }
    private var coordinatesXML: String {
        """
        <coordinates><sensorLayout><sensors>
        <sensor><name></name><number>1</number><type>0</type><x>0</x><y>0</y><z>1</z></sensor>
        <sensor><name></name><number>2</number><type>0</type><x>1</x><y>0</y><z>1</z></sensor>
        <sensor><name>Nasion</name><number>2002</number><type>2</type><x>0</x><y>9</y><z>0</z></sensor>
        </sensors></sensorLayout></coordinates>
        """
    }
    private var layoutXML: String {
        """
        <layout><sensors>
        <sensor><number>1</number><type>0</type><x>0</x><y>0</y></sensor>
        <sensor><number>2</number><type>0</type><x>1</x><y>0</y></sensor>
        </sensors><neighbors><ch n="1">2</ch><ch n="2">1</ch></neighbors></layout>
        """
    }
}
