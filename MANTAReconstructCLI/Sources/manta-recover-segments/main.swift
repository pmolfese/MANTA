import Foundation
import MANTACore
import MANTAProcessing

let usage = """
manta-recover-segments --request selection.json --output NEW_DIRECTORY [--emit-derived]

Register explicitly reviewed stable intervals from directory .manta packages.
The first segment defines reference head coordinates (meters). At least three named,
noncollinear corresponding landmarks and three high-confidence depth frames per
segment are required. RGB-only frames need selected depth evidence within one second.
Default: report only. --emit-derived creates a NEW experimental package only if all
geometric and per-frame checks pass. Original acquisitions are never modified.
This is not validated automatic motion correction. See Docs/SEGMENT_RECOVERY.md.
"""
do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("--help") { print(usage); exit(0) }
    var requestPath: String?, outputPath: String?
    var emit = false
    var index = 0
    while index < args.count {
        switch args[index] {
        case "--request" where requestPath == nil && index + 1 < args.count: index += 1; requestPath = args[index]
        case "--output" where outputPath == nil && index + 1 < args.count: index += 1; outputPath = args[index]
        case "--emit-derived" where !emit: emit = true
        default: throw NSError(domain: "manta-recover-segments", code: 1, userInfo: [NSLocalizedDescriptionKey: usage])
        }
        index += 1
    }
    guard let requestPath, let outputPath else { throw NSError(domain: "manta-recover-segments", code: 1, userInfo: [NSLocalizedDescriptionKey: usage]) }
    let requestURL = URL(fileURLWithPath: requestPath)
    guard let size = try requestURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 1_048_576 else {
        throw NSError(domain: "manta-recover-segments", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selection JSON exceeds 1 MiB."])
    }
    let data = try Data(contentsOf: requestURL)
    let request = try JSONDecoder().decode(StableSegmentRecoveryRequest.self, from: data)
    let report = try StableSegmentRecovery.run(request, output: URL(fileURLWithPath: outputPath), emitDerived: emit)
    print(report.accepted ? "Geometric gates passed (experimental)." : "Registration rejected; no derived package created.")
    print("Report: \(outputPath)/registration.json")
    if !report.accepted { exit(2) }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
