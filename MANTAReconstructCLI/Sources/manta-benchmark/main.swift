import Foundation
import CryptoKit
import ImageIO
import Vision
import MANTACore

struct Configuration: Codable {
    var revision: Int
    var maximumImageDimension: Int
    var minimumTextHeight: Float
    var orientations: [String]
    var channelCount: Int
}
struct ImageCase: Codable {
    var id: String
    var image: String
    var expectedLabels: [String]
}
struct ComparisonCase: Codable {
    var id: String
    var reference: String
    var referenceUnit: DistanceUnit
    var candidate: String
    var candidateUnit: DistanceUnit
}
struct Manifest: Codable {
    var schemaVersion: Int
    var datasetID: String
    var configuration: Configuration
    var images: [ImageCase]
    var comparisons: [ComparisonCase]
}
struct ImageResult: Encodable {
    var id: String
    var sha256: String?
    var seconds: Double
    var recognizedText: [String]
    var metrics: LabelBenchmarkMetrics?
    var precision: Double?
    var recall: Double?
    var error: String?
}
struct ComparisonResult: Encodable {
    var id: String
    var seconds: Double
    var run: GeoScanComparisonRun?
    var error: String?
}
struct Report: Encodable {
    var schemaVersion = 1
    var runnerVersion = 1
    var aggregateOCRMetricsExcludeFailedCases = true
    var generatedAt = Date()
    var operatingSystem = ProcessInfo.processInfo.operatingSystemVersionString
    var manifestSHA256: String
    var manifest: Manifest
    var images: [ImageResult]
    var comparisons: [ComparisonResult]
    var failedCases: Int
    var truePositiveCount: Int
    var falsePositiveCount: Int
    var falseNegativeCount: Int
    var microPrecision: Double?
    var microRecall: Double?
}
func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func fail(_ message: String) -> NSError { NSError(domain: "manta-benchmark", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
let orientations: [String: CGImagePropertyOrientation] = ["up": .up, "right": .right, "down": .down, "left": .left]

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--help"] {
        print("manta-benchmark --manifest dataset.json --report report.json\nRuns sequential offline OCR and GeoScan comparison cases; never overwrites reports.")
        exit(0)
    }
    guard args.count == 4, args[0] == "--manifest", args[2] == "--report" else { throw fail("Use --manifest dataset.json --report report.json") }
    let manifestURL = URL(fileURLWithPath: args[1])
    let reportURL = URL(fileURLWithPath: args[3])
    guard !FileManager.default.fileExists(atPath: reportURL.path) else { throw fail("Report already exists; choose a new path.") }
    let data = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(Manifest.self, from: data)
    let config = manifest.configuration
    guard manifest.schemaVersion == 1, !manifest.datasetID.isEmpty,
          config.channelCount == 128 || config.channelCount == 256,
          (64...16384).contains(config.maximumImageDimension),
          config.minimumTextHeight.isFinite, (0...1).contains(config.minimumTextHeight),
          VNRecognizeTextRequest.supportedRevisions.contains(config.revision),
          !config.orientations.isEmpty, config.orientations.allSatisfy({ orientations[$0] != nil }),
          !manifest.images.isEmpty || !manifest.comparisons.isEmpty else { throw fail("Invalid benchmark configuration or empty dataset.") }
    let ids = manifest.images.map(\.id) + manifest.comparisons.map(\.id)
    guard ids.allSatisfy({ !$0.isEmpty }), Set(ids).count == ids.count else { throw fail("Case IDs must be nonempty and unique.") }
    let validNumbers = Set(1...config.channelCount)
    let validLabels = Set(validNumbers.map { "E\($0)" })
    guard manifest.images.allSatisfy({ Set($0.expectedLabels).isSubset(of: validLabels) && Set($0.expectedLabels).count == $0.expectedLabels.count }) else { throw fail("Expected OCR labels must be unique E1...E\(config.channelCount); use [] for negative images.") }
    func resolve(_ path: String) -> URL { URL(fileURLWithPath: path, relativeTo: manifestURL.deletingLastPathComponent()).standardizedFileURL }
    var images = [ImageResult]()
    for item in manifest.images {
        let start = Date()
        var imageHash: String?
        do {
            let result: ImageResult = try autoreleasepool {
                let bytes = try Data(contentsOf: resolve(item.image))
                imageHash = hash(bytes)
                guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceThumbnailMaxPixelSize: config.maximumImageDimension,
                        kCGImageSourceCreateThumbnailWithTransform: false
                      ] as CFDictionary) else { throw fail("Cannot decode image") }
                var strings = [String]()
                for orientation in config.orientations {
                    let request = VNRecognizeTextRequest()
                    request.revision = config.revision
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.minimumTextHeight = config.minimumTextHeight
                    request.customWords = validNumbers.sorted().flatMap { [String($0), "E\($0)"] }
                    try VNImageRequestHandler(cgImage: image, orientation: orientations[orientation]!).perform([request])
                    strings += (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                }
                let predicted = LabelBenchmarkMetrics.predictedLabels(from: strings, channelCount: config.channelCount)
                let metrics = LabelBenchmarkMetrics(expected: Set(item.expectedLabels), predicted: predicted)
                return ImageResult(id: item.id, sha256: imageHash, seconds: Date().timeIntervalSince(start), recognizedText: strings,
                    metrics: metrics, precision: metrics.precision, recall: metrics.recall)
            }
            images.append(result)
        } catch {
            images.append(ImageResult(id: item.id, sha256: imageHash, seconds: Date().timeIntervalSince(start), recognizedText: [], error: error.localizedDescription))
        }
    }
    var comparisons = [ComparisonResult]()
    for item in manifest.comparisons {
        let start = Date()
        do {
            let run = try GeoScanComparisonRun.make(reference: Data(contentsOf: resolve(item.reference)), referenceUnit: item.referenceUnit,
                candidate: Data(contentsOf: resolve(item.candidate)), candidateUnit: item.candidateUnit)
            comparisons.append(ComparisonResult(id: item.id, seconds: Date().timeIntervalSince(start), run: run))
        } catch { comparisons.append(ComparisonResult(id: item.id, seconds: Date().timeIntervalSince(start), error: error.localizedDescription)) }
    }
    let failed = images.filter { $0.error != nil }.count + comparisons.filter { $0.error != nil }.count
    let tp = images.reduce(0) { $0 + ($1.metrics?.truePositives.count ?? 0) }
    let fp = images.reduce(0) { $0 + ($1.metrics?.falsePositives.count ?? 0) }
    let fn = images.reduce(0) { $0 + ($1.metrics?.falseNegatives.count ?? 0) }
    let report = Report(manifestSHA256: hash(data), manifest: manifest, images: images, comparisons: comparisons, failedCases: failed,
        truePositiveCount: tp, falsePositiveCount: fp, falseNegativeCount: fn,
        microPrecision: tp + fp == 0 ? nil : Double(tp) / Double(tp + fp), microRecall: tp + fn == 0 ? nil : Double(tp) / Double(tp + fn))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(report).write(to: reportURL, options: .withoutOverwriting)
    print("Wrote \(reportURL.path): \(ids.count) cases, \(failed) failures. Aggregate OCR metrics exclude failed cases.")
    exit(failed == 0 ? 0 : 1)
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8)); exit(2)
}
