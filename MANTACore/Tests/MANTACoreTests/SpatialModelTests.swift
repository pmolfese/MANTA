import Foundation
import Testing

@testable import MANTACore

struct SpatialModelTests {
    @Test func distanceConversionsUseExpectedClinicalScales() {
        #expect(DistanceUnit.meters.convert(0.005, to: .millimeters) == 5)
        #expect(DistanceUnit.centimeters.convert(1.25, to: .millimeters) == 12.5)
        #expect(
            Coordinate3D(x: 1, y: 2, z: 3).converted(from: .centimeters, to: .millimeters)
                == Coordinate3D(x: 10, y: 20, z: 30))
    }

    @Test func newSessionsAndLayoutsDeclareTheirCoordinateSpaces() {
        let session = ScanSession.newSession()
        #expect(session.coordinateSpace == .arkitWorldMeters)
        #expect(session.modelCoordinateSpace == .photogrammetryModelMeters)
        #expect(session.layout.coordinateSpace == .egiLayoutCentimeters)
        #expect(session.layout.id == "hydrocel-128")
    }

    @Test func sessionJSONWithoutRequiredSpatialKeysIsRejected() throws {
        let encoded = try JSONEncoder().encode(ScanSession.newSession())
        let completeObject = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        for key in ["coordinateSpace", "modelCoordinateSpace"] {
            var object = completeObject
            object.removeValue(forKey: key)
            let incompleteData = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ScanSession.self, from: incompleteData)
            }
        }

        for key in ["id", "coordinateSpace"] {
            var object = completeObject
            var layout = try #require(object["layout"] as? [String: Any])
            layout.removeValue(forKey: key)
            object["layout"] = layout
            let incompleteData = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(ScanSession.self, from: incompleteData)
            }
        }
    }

    @Test func captureDepthUnitsAreTypedAndRoundTrip() throws {
        let format = RawDepthFormat(
            width: 2, height: 2, scalarType: "Float32", byteOrder: "littleEndian",
            units: .meters, layout: "rowMajorNoPadding", compression: "zlib")
        let decoded = try JSONDecoder().decode(
            RawDepthFormat.self, from: JSONEncoder().encode(format))
        #expect(decoded.units == .meters)
    }

    @Test func captureQualityMetricsRoundTripForDeferredThresholdTuning() throws {
        let quality = CaptureQualityMetrics(
            arFrameTimestamp: 12.5, worldMappingStatus: "mapped",
            ambientIntensity: 800, ambientColorTemperature: 5_000,
            meanLuminance: 0.5, darkPixelFraction: 0.1, brightPixelFraction: 0.02,
            sharpnessScore: 0.08, translationFromPreviousSampleMeters: 0.04,
            rotationFromPreviousSampleDegrees: 9, coverageSector: "azimuth-3-upper",
            validDepthFraction: 0.9, highConfidenceDepthFraction: 0.8,
            warnings: ["near-duplicate-view"])

        let decoded = try JSONDecoder().decode(
            CaptureQualityMetrics.self, from: JSONEncoder().encode(quality))

        #expect(decoded == quality)
    }
}
