import Foundation
import MANTACore

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 4, arguments[0] == "--output" else {
    print("Usage: manta-consolidate --output NEW.manta SESSION_FOLDER SESSION_FOLDER [...]")
    exit(2)
}
do {
    let result = try MANTASessionConsolidator.consolidate(
        arguments.dropFirst(2).map { URL(fileURLWithPath: $0) },
        to: URL(fileURLWithPath: arguments[1]),
        producer: MANTAProducer(application: "MANTA Consolidator", version: "1", build: "1",
            platform: "macOS", operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            deviceModel: "Mac"))
    print("Saved \(result.bundle.capture.observations.count) frames to \(result.packageURL.path)")
    print("Original pass coordinates are preserved. Reconstruct with masked Images only, then review alignment.")
} catch {
    FileHandle.standardError.write(Data("Consolidation failed: \(error.localizedDescription)\n".utf8))
    exit(1)
}
