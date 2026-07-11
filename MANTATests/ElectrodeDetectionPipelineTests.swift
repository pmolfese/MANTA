//
//  ElectrodeDetectionPipelineTests.swift
//  MANTATests
//
//  Covers the device-independent parts of OCR detection: label parsing,
//  annotation building, and the full OCR -> back-project -> fuse -> annotate
//  flow driven by a stub recognizer and fake frame provider.
//

import CoreGraphics
import Foundation
import Testing
import simd
import MANTACore
@testable import MANTA

struct ElectrodeDetectionPipelineTests {
    private let valid = Set(1...256)

    // MARK: - Label parsing

    @Test func parsesPlainNumber() {
        #expect(ElectrodeLabelParser.parse("31", validNumbers: valid) == 31)
    }

    @Test func ignoresTenTwentyNameToken() {
        #expect(ElectrodeLabelParser.parse("224 F4", validNumbers: valid) == 224)
        #expect(ElectrodeLabelParser.parse("18\nFP2", validNumbers: valid) == 18)
    }

    @Test func trimsSurroundingPunctuation() {
        #expect(ElectrodeLabelParser.parse("31.", validNumbers: valid) == 31)
        #expect(ElectrodeLabelParser.parse("(5)", validNumbers: valid) == 5)
    }

    @Test func rejectsStandaloneName() {
        #expect(ElectrodeLabelParser.parse("F4", validNumbers: valid) == nil)
        #expect(ElectrodeLabelParser.parse("Fp1", validNumbers: valid) == nil)
    }

    @Test func rejectsMergedAndAmbiguousReads() {
        #expect(ElectrodeLabelParser.parse("224F4", validNumbers: valid) == nil)
        #expect(ElectrodeLabelParser.parse("8 31", validNumbers: valid) == nil)
    }

    @Test func rejectsOutOfRangeNumber() {
        #expect(ElectrodeLabelParser.parse("999", validNumbers: valid) == nil)
    }

    // MARK: - Annotation building

    @Test func buildsAnnotationsForKnownLabelsWithRoleAndState() {
        let layout = ElectrodeLayout.fallback128  // E1...E128, E17 is cardinal
        let aggregated = [
            AggregatedElectrode(label: "E17", position: SIMD3(0.1, 0.2, 0.3), observationCount: 6, spread: 0.001, confidence: 0.9),
            AggregatedElectrode(label: "E42", position: SIMD3(0, 0, 0), observationCount: 2, spread: 0.01, confidence: 0.4),
            AggregatedElectrode(label: "E900", position: SIMD3(0, 0, 0), observationCount: 1, spread: 0, confidence: 0.5)
        ]

        let annotations = ElectrodeAnnotationBuilder.build(from: aggregated, layout: layout, confidenceThreshold: 0.6)

        // E900 isn't in the layout, so it's dropped.
        #expect(annotations.count == 2)

        let e17 = try! #require(annotations.first { $0.label == "E17" })
        #expect(e17.role == .cardinal)
        #expect(e17.state == .detected)
        #expect(abs(e17.coordinate.x - 0.1) < 1e-6)

        let e42 = try! #require(annotations.first { $0.label == "E42" })
        #expect(e42.role == .regular)
        #expect(e42.state == .needsReview)  // below threshold
    }

    // MARK: - End-to-end pipeline (stub OCR + fake frames)

    private func makeImage() -> CGImage {
        let context = CGContext(
            data: nil, width: 4, height: 4, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private func makeObservation() -> CaptureObservation {
        // Identity camera: intrinsics fx=fy=100, principal point (50,50); identity pose.
        CaptureObservation(
            capturedAt: Date(),
            cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
            cameraIntrinsics: [100,0,0, 0,100,0, 50,50,1],
            imageResolution: ImageResolution(width: 100, height: 100),
            hasSceneDepth: true,
            meshAnchorCount: 0,
            trackingSummary: "Normal",
            cameraSnapshotFilename: "x.jpg",
            depthSnapshotFilename: nil,
            rawDepthFilename: nil,
            rawDepthFormat: nil,
            rawConfidenceFilename: nil,
            rawConfidenceFormat: nil,
            confidenceSummary: nil,
            depthSummary: nil
        )
    }

    /// Returns the same recognized items for every frame.
    private struct StubRecognizer: TextRecognizing {
        var items: [RecognizedText]
        func recognize(in image: CGImage, imageSize: SIMD2<Float>) throws -> [RecognizedText] { items }
    }

    private struct FixedDepthSampler: DepthSampler {
        var value: Float
        func depth(atImagePixel pixel: SIMD2<Float>) -> Float? { value }
    }

    private struct FakeFrameProvider: DetectionFrameProvider {
        var image: CGImage
        var depth: Float
        func frame(for observation: CaptureObservation) -> DetectionFrame? {
            guard let camera = PinholeCamera(intrinsics: observation.cameraIntrinsics, transform: observation.cameraTransform) else {
                return nil
            }
            return DetectionFrame(image: image, camera: camera, depthSampler: FixedDepthSampler(value: depth))
        }
    }

    @Test func endToEndDetectsAndFusesAcrossFrames() async throws {
        let layout = ElectrodeLayout.fallback128
        // Principal-point read at depth 0.5 unprojects to (0,0,-0.5) in world.
        let recognizer = StubRecognizer(items: [
            RecognizedText(text: "17", imageCenter: SIMD2(50, 50), confidence: 0.95)
        ])
        let provider = FakeFrameProvider(image: makeImage(), depth: 0.5)
        let observations = [makeObservation(), makeObservation(), makeObservation()]
        let context = DetectionContext(layout: layout, observations: observations, frameProvider: provider)

        let pipeline = OCRElectrodeDetectionPipeline(recognizer: recognizer)
        let annotations = try await pipeline.detectElectrodes(in: context)

        #expect(annotations.count == 1)
        let e17 = try #require(annotations.first)
        #expect(e17.label == "E17")
        #expect(e17.role == .cardinal)
        #expect(abs(e17.coordinate.z - (-0.5)) < 1e-3)
        #expect(abs(e17.coordinate.x) < 1e-3)
        #expect(e17.state == .detected)
    }

    @Test func endToEndSkipsUnreadableAndDepthlessReads() async throws {
        let layout = ElectrodeLayout.fallback128
        let recognizer = StubRecognizer(items: [
            RecognizedText(text: "F4", imageCenter: SIMD2(50, 50), confidence: 0.9),   // no number
            RecognizedText(text: "999", imageCenter: SIMD2(50, 50), confidence: 0.9)   // out of range
        ])
        let provider = FakeFrameProvider(image: makeImage(), depth: 0.5)
        let context = DetectionContext(layout: layout, observations: [makeObservation()], frameProvider: provider)

        let annotations = try await OCRElectrodeDetectionPipeline(recognizer: recognizer).detectElectrodes(in: context)
        #expect(annotations.isEmpty)
    }
}
