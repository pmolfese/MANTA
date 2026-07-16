import Foundation
import MANTACore

// MARK: - Terminal helpers

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func bytesString(_ value: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
}

let usage = """
manta-reconstruct — offline Object Capture reconstruction for MANTA bundles

USAGE:
  manta-reconstruct <input> [options]

ARGUMENTS:
  <input>              Path to a `.manta` archive, or an already-extracted
                       bundle directory.

OPTIONS:
  -d, --detail LEVEL   Reconstruction detail: medium | full | raw   (default: full)
  -m, --input-mode M   images | depth   (default: images)
                       'depth' feeds each frame's LiDAR depth + gravity into
                       Object Capture; falls back to images-only if no frame
                       carries usable depth.
  -o, --output DIR     Directory for the reconstructed model, poses, and
                       diagnostics. Default: "<input-name>-reconstruction"
                       next to the input.
      --keep-workspace Keep the temporary Object Capture workspace instead of
                       deleting it when finished.
  -h, --help           Show this help.

OUTPUTS (written into --output):
  model.usdz           Reconstructed textured mesh.
  poses.json           Per-image camera poses (ARKit world, meters).
  diagnostics.json     Timing, skipped samples, and LiDAR-alignment metrics.
"""

// MARK: - Argument parsing

struct Options {
    var input: URL
    var detail: PhotogrammetryDetail = .full
    var inputMode: PhotogrammetryInputMode = .imagesOnly
    var output: URL?
    var keepWorkspace = false
}

func parseArguments() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())
    if args.contains("-h") || args.contains("--help") {
        print(usage)
        exit(0)
    }

    var input: String?
    var detail: PhotogrammetryDetail = .full
    var inputMode: PhotogrammetryInputMode = .imagesOnly
    var output: String?
    var keepWorkspace = false

    var index = 0
    func nextValue(for flag: String) -> String {
        index += 1
        guard index < args.count else {
            printErr("error: \(flag) requires a value")
            exit(2)
        }
        return args[index]
    }

    while index < args.count {
        let arg = args[index]
        switch arg {
        case "-d", "--detail":
            let raw = nextValue(for: arg).lowercased()
            guard let parsed = PhotogrammetryDetail(rawValue: raw) else {
                printErr("error: invalid detail '\(raw)'. Use medium, full, or raw.")
                exit(2)
            }
            detail = parsed
        case "-m", "--input-mode":
            let raw = nextValue(for: arg).lowercased()
            switch raw {
            case "images", "imagesonly", "images-only": inputMode = .imagesOnly
            case "depth", "depthguided", "depth-guided": inputMode = .depthGuided
            default:
                printErr("error: invalid input mode '\(raw)'. Use images or depth.")
                exit(2)
            }
        case "-o", "--output":
            output = nextValue(for: arg)
        case "--keep-workspace":
            keepWorkspace = true
        default:
            if arg.hasPrefix("-") {
                printErr("error: unknown option '\(arg)'")
                printErr(usage)
                exit(2)
            }
            if input == nil {
                input = arg
            } else {
                printErr("error: unexpected extra argument '\(arg)'")
                exit(2)
            }
        }
        index += 1
    }

    guard let input else {
        printErr("error: missing <input> path\n")
        printErr(usage)
        exit(2)
    }

    return Options(
        input: URL(fileURLWithPath: input),
        detail: detail,
        inputMode: inputMode,
        output: output.map { URL(fileURLWithPath: $0) },
        keepWorkspace: keepWorkspace)
}

// MARK: - Bundle loading

/// Loads the capture bundle, extracting a `.manta` archive into a temporary
/// directory when needed. Returns the validated bundle plus an optional cleanup
/// URL for any extraction the tool created.
func loadBundle(at input: URL) throws -> (bundle: MANTAValidatedBundle, cleanup: URL?) {
    let fileManager = FileManager.default
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: input.path, isDirectory: &isDirectory) else {
        throw ReconstructionError.processing("input path does not exist: \(input.path)")
    }

    if isDirectory.boolValue {
        // Lenient load: decode the manifest and capture document directly and
        // skip the strict integrity gates (size/undeclared-file checks). This is
        // a personal offline reconstruction tool, not a distribution integrity
        // checkpoint — we do not want a stray off-by-one in a saved bundle to
        // block a reconstruction.
        let root = input.standardizedFileURL
        let decoder = MANTAJSON.makeDecoder()
        let manifestURL = root.appendingPathComponent("manifest.json")
        let manifest = try decoder.decode(
            MANTABundleManifest.self,
            from: Data(contentsOf: manifestURL))
        let captureURL = root.appendingPathComponent(manifest.content.capture)
        let capture = try decoder.decode(
            MANTACaptureDocument.self,
            from: Data(contentsOf: captureURL))
        let bundle = MANTAValidatedBundle(
            rootDirectory: root, manifest: manifest, capture: capture, changeLog: nil)
        return (bundle, nil)
    }

    // Treat a file as a `.manta` archive and extract it into a scratch dir.
    let scratch = fileManager.temporaryDirectory
        .appendingPathComponent("manta-reconstruct-\(UUID().uuidString.lowercased())", isDirectory: true)
    let destination = scratch.appendingPathComponent("bundle", isDirectory: true)
    let bundle = try MANTAArchiveImporter().importBundle(at: input, to: destination)
    return (bundle, scratch)
}

// MARK: - Run

let options = parseArguments()
let runner = PhotogrammetryRunner()

guard runner.isSupported else {
    printErr("error: \(ReconstructionError.unsupported.localizedDescription)")
    exit(1)
}

let outputDirectory = options.output
    ?? options.input.deletingPathExtension()
        .deletingLastPathComponent()
        .appendingPathComponent(options.input.deletingPathExtension().lastPathComponent + "-reconstruction", isDirectory: true)

func log(_ level: ReconstructionLogLevel, _ message: String) {
    let prefix: String
    switch level {
    case .info: prefix = "•"
    case .warning: prefix = "⚠"
    case .error: prefix = "✗"
    case .success: prefix = "✓"
    }
    printErr("\(prefix) \(message)")
}

var lastPercent = -1
func reportProgress(_ fraction: Double, _ label: String) {
    let percent = Int(fraction * 100)
    guard percent != lastPercent else { return }
    lastPercent = percent
    printErr(String(format: "  [%3d%%] %@", percent, label))
}

// Cancel cleanly on Ctrl-C so Object Capture releases the GPU.
let signalSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
signal(SIGINT, SIG_IGN)
signalSource.setEventHandler {
    printErr("\n⚠ Interrupted — cancelling reconstruction…")
    runner.cancel()
}
signalSource.resume()

Task {
    var cleanupURL: URL?
    var preparation: ReconstructionPreparation?
    do {
        log(.info, "Loading capture bundle: \(options.input.path)")
        let (bundle, cleanup) = try loadBundle(at: options.input)
        cleanupURL = cleanup

        let estimate = ReconstructionWorkflow.estimate(bundle: bundle, detail: options.detail)
        log(.info, "\(estimate.imageCount) source images, \(bytesString(estimate.sourceImageBytes)).")
        log(.info, "Estimated working space required: \(bytesString(estimate.requiredWorkingBytes)) at \(options.detail.title) detail.")
        if let available = estimate.availableBytes {
            log(estimate.hasEnoughSpace ? .info : .warning,
                "Available on volume: \(bytesString(available)).")
        }

        let prep = try ReconstructionWorkflow.prepare(
            bundle: bundle, detail: options.detail, inputMode: options.inputMode)
        preparation = prep
        log(.info, "Prepared workspace with \(prep.imageCount) linked images (\(prep.inputMode.title)).")
        if options.inputMode.usesDepth, !prep.inputMode.usesDepth {
            log(.warning, "No frames carried usable LiDAR depth; falling back to images-only.")
        }

        let run = try await runner.reconstruct(
            preparation: prep, progress: reportProgress, log: log)

        let preview = try ReconstructionWorkflow.makePreview(
            bundle: bundle, preparation: prep, run: run, progress: reportProgress, log: log)

        // Copy artifacts to the output directory.
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        func place(_ source: URL, as name: String) throws -> URL {
            let destination = outputDirectory.appendingPathComponent(name)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.copyItem(at: source, to: destination)
            return destination
        }
        let modelOut = try place(preview.modelURL, as: "model.usdz")
        _ = try place(preview.posesURL, as: "poses.json")
        _ = try place(preview.diagnosticsURL, as: "diagnostics.json")

        let elapsed = run.completedAt.timeIntervalSince(run.startedAt)
        log(.success, String(format: "Reconstruction finished in %.1fs.", elapsed))
        if preview.alignmentAccepted, let rms = preview.alignmentRMSMeters {
            log(.success, String(format: "LiDAR alignment accepted (symmetric RMS %.1f mm).", rms * 1_000))
        } else {
            log(.warning, "LiDAR alignment not accepted; model saved without a world transform.")
        }
        log(.success, "Output written to: \(outputDirectory.path)")
        print(modelOut.path)

        if options.keepWorkspace {
            log(.info, "Kept workspace: \(prep.workspace.path)")
        } else {
            ReconstructionWorkflow.removeWorkspace(prep)
        }
        if let cleanupURL {
            try? fileManager.removeItem(at: cleanupURL)
        }
        exit(0)
    } catch {
        log(.error, (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        if let preparation, !options.keepWorkspace {
            ReconstructionWorkflow.removeWorkspace(preparation)
        }
        if let cleanupURL {
            try? FileManager.default.removeItem(at: cleanupURL)
        }
        exit(1)
    }
}

dispatchMain()
