import Foundation
import Testing
@testable import MANTACore

struct GeoScanComparisonTests {
    private let reference = """
    # File format: ElectrodeName X Y Z Estimated
    LabellingTemplate = /Applications/GeoScan/templates/hydrocel_256.xml
    FidNz 0 10 0 0
    FidT9 -7 0 0 0
    FidT10 7 0 0 0
    E1 1 2 8 0
    E2 -2 3 9 1
    Cz 0 0 10 0
    """

    @Test func sharedRunHashesExactInputBytesAndEncodesBothFrontendsReport() throws {
        let data = Data(reference.utf8)
        let run = try GeoScanComparisonRun.make(reference: data, referenceUnit: .centimeters,
                                                candidate: Data((reference + "\n").utf8), candidateUnit: .centimeters)
        #expect(run.referenceSHA256.count == 64)
        #expect(run.referenceSHA256 != run.candidateSHA256)
        #expect(try #require(run.comparison.allMatchedErrors).maximumMM < 0.001)
        let json = try #require(JSONSerialization.jsonObject(with: run.jsonData()) as? [String: Any])
        #expect(json["referenceSHA256"] as? String == run.referenceSHA256)
        #expect(json["comparison"] != nil)
        #expect(json["generatedAt"] is String)
        #expect(throws: GeoScanError.self) {
            try GeoScanComparisonRun.make(reference: Data([0xff]), referenceUnit: .centimeters,
                                           candidate: data, candidateUnit: .centimeters)
        }
    }

    @Test func strictParsingPreservesFlagsUnitsAndTemplate() throws {
        let doc = try GeoScanImporter.parse(reference.replacingOccurrences(of: "\n", with: "\r\n"), unit: .centimeters)
        #expect(doc.points.count == 6)
        #expect(doc.points[4].estimated)
        #expect(doc.points[3].coordinates == [1, 2, 8])
        #expect(doc.sourceUnit == .centimeters)
        #expect(doc.labellingTemplate?.hasSuffix("hydrocel_256.xml") == true)
        for invalid in ["E1 1 2 3 2", "E1 nan 2 3 0", "E1 1 2 3", "E1 1 2 3 0 extra", "E1 1 2 3 0\nE1 4 5 6 0", "# empty", "# Units = mm\nE1 1 2 3 0"] {
            #expect(throws: GeoScanError.self) { try GeoScanImporter.parse(invalid, unit: .centimeters) }
        }
    }

    @Test func rigidAlignmentHandlesRotationTranslationUnitsAndFlags() throws {
        let ref = try GeoScanImporter.parse(reference, unit: .centimeters)
        // Rotate 90 degrees about Z, translate, and express candidate in mm.
        let text = ref.points.map { p in
            "\(p.label) \(-p.coordinates[1] * 10 + 250) \(p.coordinates[0] * 10 - 120) \(p.coordinates[2] * 10 + 30) \(p.estimated ? 1 : 0)"
        }.joined(separator: "\n")
        let result = try GeoScanComparison.compare(reference: ref,
            candidate: GeoScanImporter.parse(text, unit: .millimeters))
        #expect(result.measuredOnlyErrors?.count == 2)
        #expect(result.allMatchedErrors?.count == 3)
        #expect(try #require(result.allMatchedErrors).maximumMM < 0.001)
        #expect(try #require(result.fiducialErrors).maximumMM < 0.001)
    }

    @Test func scaleErrorsCannotBeFittedAwayAndMissingLabelsAreReported() throws {
        let ref = try GeoScanImporter.parse(reference, unit: .centimeters)
        let candidate = try GeoScanImporter.parse("""
        FidNz 0 20 0 0
        FidT9 -14 0 0 0
        FidT10 14 0 0 0
        E1 2 4 16 0
        E3 0 0 0 1
        """, unit: .centimeters)
        let report = try GeoScanComparison.compare(reference: ref, candidate: candidate)
        #expect(try #require(report.fiducialErrors).rmsMM > 50)
        #expect(try #require(report.measuredOnlyErrors).rmsMM > 50)
        #expect(report.missingFromCandidate == ["Cz", "E2"])
        #expect(report.missingFromReference == ["E3"])
    }

    @Test func electrodeErrorsDoNotAffectAlignmentAndStatisticsAreInMillimeters() throws {
        let ref = try GeoScanImporter.parse(reference, unit: .centimeters)
        let candidate = try GeoScanImporter.parse(
            reference.replacingOccurrences(of: "E1 1 2 8 0", with: "E1 1.3 2.4 8 0"), unit: .centimeters)
        let report = try GeoScanComparison.compare(reference: ref, candidate: candidate)
        let errors = try #require(report.measuredOnlyErrors)
        #expect(abs(errors.meanMM - 2.5) < 0.001)
        #expect(abs(errors.medianMM - 2.5) < 0.001)
        #expect(abs(errors.rmsMM - sqrt(12.5)) < 0.001)
        #expect(abs(errors.percentile95MM - 5) < 0.001)
        #expect(try #require(report.fiducialErrors).maximumMM < 0.001)
    }

    @Test func rejectsMissingAndDegenerateFiducials() throws {
        let ref = try GeoScanImporter.parse(reference, unit: .centimeters)
        for text in ["E1 1 2 3 0", "FidNz 0 0 0 0\nFidT9 1 0 0 0\nFidT10 2 0 0 0\nE1 0 2 0 0"] {
            let candidate = try GeoScanImporter.parse(text, unit: .centimeters)
            #expect(throws: GeoScanError.self) { try GeoScanComparison.compare(reference: ref, candidate: candidate) }
        }
    }

    @Test func estimatedOnlyResultsDoNotBecomeMeasuredAccuracy() throws {
        let ref = try GeoScanImporter.parse(reference, unit: .centimeters)
        let candidate = try GeoScanImporter.parse(reference.replacingOccurrences(of: " 0\n", with: " 1\n") + "\n", unit: .centimeters)
        // Explicitly mark all records estimated, including the last line.
        let allEstimated = candidate.points.map { p in
            "\(p.label) \(p.coordinates[0]) \(p.coordinates[1]) \(p.coordinates[2]) 1"
        }.joined(separator: "\n")
        let report = try GeoScanComparison.compare(reference: ref,
            candidate: GeoScanImporter.parse(allEstimated, unit: .centimeters))
        #expect(report.measuredOnlyErrors == nil)
        #expect(report.allMatchedErrors?.count == 3)
        #expect(report.warnings.count == 3)
    }
}
