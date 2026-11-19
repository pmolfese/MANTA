import Foundation
import MANTACore

let usage = """
manta-compare --reference geoscan.txt --reference-unit cm \
--candidate manta_coordinates_head-ras_cm.txt --candidate-unit cm --report comparison.json

Units are mandatory: m, cm, mm. Inputs use GeoScan five-column TXT syntax.
FidNz/FidT9/FidT10 must mean nasion/LPA/RPA. Alignment is rigid, never scaled.
Estimated flags are preserved; primary metrics include only mutually measured points.
Existing reports are not overwritten. A successful report is not an accuracy pass.
"""


do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") || args.contains("-h") { print(usage); exit(0) }
    let allowed = Set(["--reference", "--reference-unit", "--candidate", "--candidate-unit", "--report"])
    var options = [String: String]()
    var i = 0
    while i < args.count {
        guard allowed.contains(args[i]), options[args[i]] == nil, i + 1 < args.count,
              !args[i + 1].hasPrefix("--") else {
            throw NSError(domain: "manta-compare", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid, repeated, or incomplete argument: \(args[i])"])
        }
        options[args[i]] = args[i + 1]
        i += 2
    }
    func required(_ flag: String) throws -> String {
        guard let value = options[flag] else {
            throw NSError(domain: "manta-compare", code: 2, userInfo: [NSLocalizedDescriptionKey: "Missing \(flag).\n\(usage)"])
        }
        return value
    }
    func unit(_ flag: String) throws -> DistanceUnit {
        let value = try required(flag)
        guard let unit = ["m": DistanceUnit.meters, "cm": .centimeters, "mm": .millimeters][value] else {
            throw NSError(domain: "manta-compare", code: 2, userInfo: [NSLocalizedDescriptionKey: "\(flag) must be m, cm, or mm."])
        }
        return unit
    }
    let referenceURL = URL(fileURLWithPath: try required("--reference"))
    let candidateURL = URL(fileURLWithPath: try required("--candidate"))
    let reportURL = URL(fileURLWithPath: try required("--report"))
    let referenceData = try Data(contentsOf: referenceURL)
    let candidateData = try Data(contentsOf: candidateURL)
    let report = try GeoScanComparisonRun.make(
        reference: referenceData, referenceUnit: unit("--reference-unit"),
        candidate: candidateData, candidateUnit: unit("--candidate-unit"))
    let comparison = report.comparison
    try report.jsonData().write(to: reportURL, options: .withoutOverwriting)
    print("Compared \(comparison.electrodes.count) matched points. Report: \(reportURL.path)")
    for warning in comparison.warnings { print("Note: \(warning)") }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
