import Foundation
import simd

public struct GeoScanPoint: Codable, Equatable, Sendable {
    public let label: String
    public let coordinates: [Double]
    public let estimated: Bool
}

public struct GeoScanDocument: Sendable {
    public let sourceUnit: DistanceUnit
    public let labellingTemplate: String?
    public let declaredFrame: String?
    public let points: [GeoScanPoint]
}

public struct GeoScanError: LocalizedError {
    public let message: String
    public var errorDescription: String? { message }
}

public enum GeoScanImporter {
    /// Unit is mandatory; anatomical size is never used to guess it.
    public static func parse(_ text: String, unit: DistanceUnit) throws -> GeoScanDocument {
        var points = [GeoScanPoint]()
        var labels = Set<String>()
        var template: String?
        var frame: String?
        for (index, raw) in text.components(separatedBy: .newlines).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\u{FEFF}", with: "")
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let fields = line.dropFirst().split(separator: "=", maxSplits: 1).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if fields.count == 2, fields[0] == "Units" {
                    let units: [String: DistanceUnit] = ["m": .meters, "cm": .centimeters, "mm": .millimeters]
                    guard units[fields[1]] == unit else {
                        throw GeoScanError(message: "Line \(index + 1): declared units conflict with selected units or are unsupported.")
                    }
                }
                if fields.count == 2, fields[0] == "CoordinateFrame" { frame = fields[1] }
                continue
            }
            if line.hasPrefix("LabellingTemplate") {
                let fields = line.split(separator: "=", maxSplits: 1)
                guard fields.count == 2, fields[0].trimmingCharacters(in: .whitespaces) == "LabellingTemplate",
                      template == nil, !fields[1].trimmingCharacters(in: .whitespaces).isEmpty else {
                    throw GeoScanError(message: "Line \(index + 1): invalid or duplicate template declaration.")
                }
                template = fields[1].trimmingCharacters(in: .whitespaces)
                continue
            }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 5,
                  let x = Double(fields[1]), let y = Double(fields[2]), let z = Double(fields[3]),
                  x.isFinite, y.isFinite, z.isFinite,
                  fields[4] == "0" || fields[4] == "1" else {
                throw GeoScanError(message: "Line \(index + 1): expected label, three finite coordinates, and Estimated 0 or 1.")
            }
            let label = String(fields[0])
            guard labels.insert(label).inserted else {
                throw GeoScanError(message: "Line \(index + 1): duplicate label \(label).")
            }
            points.append(GeoScanPoint(label: label, coordinates: [x, y, z], estimated: fields[4] == "1"))
        }
        guard !points.isEmpty else { throw GeoScanError(message: "No coordinate rows found.") }
        return GeoScanDocument(sourceUnit: unit, labellingTemplate: template, declaredFrame: frame, points: points)
    }
}

public struct CoordinateErrorSummary: Codable, Sendable {
    public let count: Int
    public let meanMM: Double
    public let medianMM: Double
    public let rmsMM: Double
    public let percentile95MM: Double
    public let maximumMM: Double

    init?(_ values: [Double]) {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        count = values.count
        meanMM = values.reduce(0, +) / Double(count)
        medianMM = count.isMultiple(of: 2) ? (sorted[count / 2 - 1] + sorted[count / 2]) / 2 : sorted[count / 2]
        rmsMM = sqrt(values.reduce(0) { $0 + $1 * $1 } / Double(count))
        percentile95MM = sorted[max(0, Int(ceil(Double(count) * 0.95)) - 1)]
        maximumMM = sorted[count - 1]
    }
}

public struct CoordinateComparisonRow: Codable, Sendable {
    public let label: String
    public let referenceEstimated: Bool
    public let candidateEstimated: Bool
    public let referenceMM: [Double]
    public let alignedCandidateMM: [Double]
    public let errorMM: Double
}

public struct GeoScanComparisonReport: Encodable, Sendable {
    public let schemaVersion: Int = 1
    public let alignment = "rigid least-squares FidNz/FidT9/FidT10; no scale fitting"
    public let percentileMethod = "nearest rank"
    public let referenceUnit: DistanceUnit
    public let candidateUnit: DistanceUnit
    /// Column-major candidate-to-reference matrix, translation in millimeters.
    public let candidateToReference: [Double]
    public let fiducials: [CoordinateComparisonRow]
    public let fiducialErrors: CoordinateErrorSummary?
    public let electrodes: [CoordinateComparisonRow]
    public let measuredOnlyErrors: CoordinateErrorSummary?
    public let allMatchedErrors: CoordinateErrorSummary?
    public let missingFromCandidate: [String]
    public let missingFromReference: [String]
    public let warnings: [String]
}

public enum GeoScanComparison {
    public static func compare(reference: GeoScanDocument, candidate: GeoScanDocument) throws -> GeoScanComparisonReport {
        let names = ["FidNz", "FidT9", "FidT10"]
        let ref = Dictionary(uniqueKeysWithValues: reference.points.map { ($0.label, $0) })
        let cand = Dictionary(uniqueKeysWithValues: candidate.points.map { ($0.label, $0) })
        func millimeters(_ p: GeoScanPoint, _ unit: DistanceUnit) -> SIMD3<Float> {
            SIMD3(p.coordinates.map { Float(unit.convert($0, to: .millimeters)) })
        }
        func landmarks(_ points: [String: GeoScanPoint], _ unit: DistanceUnit) throws -> [SIMD3<Float>] {
            let result = try names.map { name -> SIMD3<Float> in
                guard let p = points[name] else { throw GeoScanError(message: "Missing required fiducial \(name).") }
                return millimeters(p, unit)
            }
            let a = result[1] - result[0], b = result[2] - result[0]
            guard result.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }),
                  simd_length(a) > 1e-6, simd_length(b) > 1e-6,
                  simd_length(simd_cross(a, b)) / (simd_length(a) * simd_length(b)) > 1e-4 else {
                throw GeoScanError(message: "Fiducials are coincident, collinear, or outside supported numeric range.")
            }
            return result
        }
        let target = try landmarks(ref, reference.sourceUnit)
        let source = try landmarks(cand, candidate.sourceUnit)
        guard let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .rigid) else {
            throw GeoScanError(message: "Rigid fiducial alignment failed.")
        }
        func row(_ label: String) throws -> CoordinateComparisonRow {
            let r = ref[label]!, c = cand[label]!
            let rp = millimeters(r, reference.sourceUnit)
            let cp = fit.transform * SIMD4(millimeters(c, candidate.sourceUnit), 1)
            let error = Double(simd_distance(rp, SIMD3(cp.x, cp.y, cp.z)))
            guard error.isFinite else { throw GeoScanError(message: "Coordinate range unsupported for \(label).") }
            return CoordinateComparisonRow(label: label, referenceEstimated: r.estimated,
                candidateEstimated: c.estimated, referenceMM: [Double(rp.x), Double(rp.y), Double(rp.z)],
                alignedCandidateMM: [Double(cp.x), Double(cp.y), Double(cp.z)], errorMM: error)
        }
        let fiducials = try names.map(row)
        let rLabels = Set(ref.keys).subtracting(names), cLabels = Set(cand.keys).subtracting(names)
        let electrodes = try rLabels.intersection(cLabels).sorted().map(row)
        guard !electrodes.isEmpty else { throw GeoScanError(message: "No common non-fiducial labels to compare.") }
        let measured = electrodes.filter { !$0.referenceEstimated && !$0.candidateEstimated }
        var warnings = ["Agreement is not absolute accuracy; verify source units and physical marker definitions."]
        if measured.isEmpty { warnings.append("No mutually measured electrodes: primary measured-only metrics are unavailable.") }
        if fiducials.contains(where: { $0.referenceEstimated || $0.candidateEstimated }) {
            warnings.append("Alignment includes estimated or provenance-unverified fiducials.")
        }
        return GeoScanComparisonReport(referenceUnit: reference.sourceUnit, candidateUnit: candidate.sourceUnit,
            candidateToReference: (0..<4).flatMap { c in (0..<4).map { Double(fit.transform[c][$0]) } },
            fiducials: fiducials, fiducialErrors: CoordinateErrorSummary(fiducials.map(\.errorMM)),
            electrodes: electrodes, measuredOnlyErrors: CoordinateErrorSummary(measured.map(\.errorMM)),
            allMatchedErrors: CoordinateErrorSummary(electrodes.map(\.errorMM)),
            missingFromCandidate: rLabels.subtracting(cLabels).sorted(),
            missingFromReference: cLabels.subtracting(rLabels).sorted(), warnings: warnings)
    }
}
