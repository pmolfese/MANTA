//
//  SyntheticScanHarnessTests.swift
//  MANTATests
//
//  Drives the real OCRElectrodeDetectionPipeline with synthetic scans of the
//  actual HydroCel templates and measures recovered-vs-truth accuracy. Runs for
//  both the 128- and 256-channel nets, so the layout-agnostic pipeline is
//  proven on both. This validates the whole geometry + fusion + labeling chain
//  end to end and acts as a regression bed for tuning.
//

import Foundation
import Testing
import simd
@testable import MANTA

struct SyntheticScanHarnessTests {
    /// Both nets MANTA needs to support.
    static let channelCounts = [128, 256]

    private func loadLayout(channelCount: Int) throws -> ElectrodeLayout {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MANTA/Resources/Layouts")
        let layouts = try HydroCelLayoutLoader(resourceDirectory: url).loadLayouts()
        return try #require(layouts.first { $0.channelCount == channelCount })
    }

    /// Runs detection only (template fill off) so these measure OCR + fusion +
    /// validation accuracy. Template fill is covered by its own test.
    private func run(_ scan: SyntheticScan, layout: ElectrodeLayout) async throws -> [ElectrodeAnnotation] {
        let context = DetectionContext(layout: layout, observations: scan.observations, frameProvider: scan.source)
        // Recognizer and provider are the same synthetic object.
        let pipeline = OCRElectrodeDetectionPipeline(recognizer: scan.source, fillsMissingFromTemplate: false)
        return try await pipeline.detectElectrodes(in: context)
    }

    @Test(arguments: channelCounts)
    func zeroNoiseRecoversTruthExactly(channelCount: Int) async throws {
        let layout = try loadLayout(channelCount: channelCount)
        let scan = SyntheticScanGenerator.generate(layout: layout, config: SyntheticScanConfig())
        let annotations = try await run(scan, layout: layout)
        let accuracy = DetectionAccuracy.compare(annotations: annotations, truth: scan.truth)

        // A full orbit should see most of the net's disks.
        #expect(scan.emitted.count > Int(Double(channelCount) * 0.85))
        // Every read-back label is recovered, at essentially zero error.
        #expect(accuracy.recoveredCount == scan.emitted.count)
        #expect(accuracy.maxErrorMeters < 1e-3)
    }

    @Test(arguments: channelCounts)
    func realisticNoiseStaysAccurate(channelCount: Int) async throws {
        let layout = try loadLayout(channelCount: channelCount)
        var config = SyntheticScanConfig()
        config.pixelNoise = 1.5      // ~1.5 px OCR-center jitter
        config.depthNoise = 0.002    // 2 mm depth noise
        config.dropoutRate = 0.2     // 20% of visible disks unread per frame
        let scan = SyntheticScanGenerator.generate(layout: layout, config: config)
        let annotations = try await run(scan, layout: layout)
        let accuracy = DetectionAccuracy.compare(annotations: annotations, truth: scan.truth)

        #expect(accuracy.recoveredCount > Int(Double(channelCount) * 0.85))
        // Fusion across frames should keep mean error well under 5 mm.
        #expect(accuracy.meanErrorMeters < 0.005)
        #expect(accuracy.maxErrorMeters < 0.02)
    }

    @Test(arguments: channelCounts)
    func misreadsAreRejectedByFusion(channelCount: Int) async throws {
        let layout = try loadLayout(channelCount: channelCount)
        var config = SyntheticScanConfig()
        config.pixelNoise = 1.0
        config.depthNoise = 0.002
        config.misreadRate = 0.05    // 5% of reads get a wrong label
        let scan = SyntheticScanGenerator.generate(layout: layout, config: config)
        let annotations = try await run(scan, layout: layout)
        let accuracy = DetectionAccuracy.compare(annotations: annotations, truth: scan.truth)

        // Misreads scatter a few bad observations onto other labels, but the
        // aggregator's median-based outlier rejection should keep gross errors
        // rare relative to the number of recovered electrodes.
        #expect(accuracy.recoveredCount > Int(Double(channelCount) * 0.8))
        #expect(Float(accuracy.grossErrorCount) < Float(accuracy.recoveredCount) * 0.1)
        // Whatever gross errors survive fusion should be caught by neighbor-graph
        // validation and marked needs-review, not left as confident detections.
        #expect(accuracy.grossErrorAmongDetectedCount == 0)
    }

    @Test(arguments: channelCounts)
    func templateFillCoversUnscannedElectrodes(channelCount: Int) async throws {
        let layout = try loadLayout(channelCount: channelCount)
        // Front-only orbit: back-of-head disks are never seen, so OCR can't read
        // them; template fitting must fill them in.
        var config = SyntheticScanConfig()
        config.pixelNoise = 1.0
        config.depthNoise = 0.002
        config.azimuthRangeDegrees = -80...80
        let scan = SyntheticScanGenerator.generate(layout: layout, config: config)

        let context = DetectionContext(layout: layout, observations: scan.observations, frameProvider: scan.source)

        let withoutFill = OCRElectrodeDetectionPipeline(recognizer: scan.source, fillsMissingFromTemplate: false)
        let withFill = OCRElectrodeDetectionPipeline(recognizer: scan.source, fillsMissingFromTemplate: true)

        let detectedOnly = try await withoutFill.detectElectrodes(in: context)
        let filledResult = try await withFill.detectElectrodes(in: context)

        // Some electrodes really were unseen.
        #expect(detectedOnly.count < channelCount)
        // Fill adds coverage toward the full net.
        #expect(filledResult.count > detectedOnly.count)

        // Filled electrodes (needs-review, weren't detected) land near truth.
        let detectedLabels = Set(detectedOnly.map(\.label))
        var filledErrors: [Float] = []
        for annotation in filledResult where !detectedLabels.contains(annotation.label) {
            guard let number = Int(annotation.label.dropFirst()), let truth = scan.truth[number] else { continue }
            let predicted = SIMD3<Float>(
                Float(annotation.coordinate.x), Float(annotation.coordinate.y), Float(annotation.coordinate.z)
            )
            filledErrors.append(simd_distance(predicted, truth))
        }
        #expect(!filledErrors.isEmpty)
        // Similarity fit against the idealized template: predictions land within
        // ~1 cm of truth here (synthetic head == template shape).
        let meanFillError = filledErrors.reduce(0, +) / Float(filledErrors.count)
        #expect(meanFillError < 0.01)
    }

    @Test(arguments: channelCounts)
    func reportsAccuracyAcrossNoiseLevels(channelCount: Int) async throws {
        let layout = try loadLayout(channelCount: channelCount)
        let levels: [(String, Float, Float)] = [
            ("clean", 0, 0),
            ("mild", 1.0, 0.001),
            ("noisy", 2.5, 0.004)
        ]

        for (name, pixelNoise, depthNoise) in levels {
            var config = SyntheticScanConfig()
            config.pixelNoise = pixelNoise
            config.depthNoise = depthNoise
            let scan = SyntheticScanGenerator.generate(layout: layout, config: config)
            let annotations = try await run(scan, layout: layout)
            let accuracy = DetectionAccuracy.compare(annotations: annotations, truth: scan.truth)

            print(String(
                format: "[synthetic %d %@] recovered %d/%d  mean %.2f mm  median %.2f mm  max %.2f mm",
                channelCount,
                name,
                accuracy.recoveredCount,
                scan.emitted.count,
                accuracy.meanErrorMeters * 1000,
                accuracy.medianErrorMeters * 1000,
                accuracy.maxErrorMeters * 1000
            ))
            #expect(accuracy.recoveredCount > 0)
        }
    }
}
