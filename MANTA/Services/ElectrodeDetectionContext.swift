//
//  ElectrodeDetectionContext.swift
//  MANTA
//
//  Inputs and portable orchestration for real electrode detection.
//
//  The strategy is OCR-first: every HydroCel disk is silk-screened with its EGI
//  sensor number (some also carry a 10-20 name like "F4", which we ignore), so
//  we read the number with text recognition and map it straight to the layout
//  label "E{number}". A disk seen across many frames is back-projected through
//  LiDAR depth into the ARKit world frame and fused by
//  ElectrodeObservationAggregator.
//
//  Vision and file IO are kept behind protocols (`TextRecognizing`,
//  `DetectionFrameProvider`) so the pipeline, label parsing, and annotation
//  building are all unit-testable without a device.
//

import CoreGraphics
import Foundation
import simd

/// Everything a detection pipeline consumes for one session.
struct DetectionContext {
    var layout: ElectrodeLayout
    var observations: [CaptureObservation]
    var frameProvider: DetectionFrameProvider
}

/// A single captured frame prepared for detection.
struct DetectionFrame {
    /// RGB image in the camera's native resolution (matches `camera` intrinsics).
    var image: CGImage
    /// Camera model for back-projecting image pixels into the ARKit world frame.
    var camera: PinholeCamera
    /// Metric depth lookup for this frame, when LiDAR depth was captured.
    var depthSampler: DepthSampler?
}

/// Loads a `DetectionFrame` (image + camera + depth) for an observation.
/// Backed by the artifact store on device; stubbed in tests.
protocol DetectionFrameProvider {
    func frame(for observation: CaptureObservation) -> DetectionFrame?
}

/// Provides no frames. Used for previews and when no artifact store is available,
/// so the pipeline simply produces no detections rather than failing.
struct EmptyDetectionFrameProvider: DetectionFrameProvider {
    func frame(for observation: CaptureObservation) -> DetectionFrame? { nil }
}

/// Samples metric depth (meters) at a pixel in the RGB image's coordinate space.
/// Implementations handle RGB->depth resolution scaling and reject
/// invalid/low-confidence samples by returning nil.
protocol DepthSampler {
    func depth(atImagePixel pixel: SIMD2<Float>) -> Float?
}

/// One text item recognized in a frame, with its center already resolved to
/// pixels in the image's native coordinate space.
struct RecognizedText: Equatable {
    var text: String
    var imageCenter: SIMD2<Float>
    var confidence: Float
}

/// Recognizes text in an image. The Vision implementation lives in
/// `VisionTextRecognizer`; tests inject a stub.
protocol TextRecognizing {
    func recognize(in image: CGImage, imageSize: SIMD2<Float>) throws -> [RecognizedText]
}

/// Parses an OCR string into an EGI sensor number.
enum ElectrodeLabelParser {
    /// Extracts the sensor number from a recognized string, validated against the
    /// set of numbers present in the active layout.
    ///
    /// Only pure-digit tokens are treated as sensor numbers, because 10-20 names
    /// always carry a letter. This is deliberately conservative — an ambiguous
    /// read is dropped rather than mislabeled:
    ///   - "31"       -> 31
    ///   - "224 F4"   -> 224   (the 10-20 token "F4" is ignored)
    ///   - "18\nFP2"  -> 18
    ///   - "31."      -> 31    (surrounding punctuation is trimmed)
    ///   - "F4"       -> nil   (no standalone sensor number)
    ///   - "224F4"    -> nil   (merged read; not a clean digit token)
    ///   - "8 31"     -> nil   (two valid numbers; ambiguous)
    static func parse(_ recognized: String, validNumbers: Set<Int>) -> Int? {
        let tokens = recognized.split { $0.isWhitespace || $0.isNewline }
        let nonAlphanumeric = CharacterSet.alphanumerics.inverted

        let matches = Set(tokens.compactMap { raw -> Int? in
            let token = String(raw).trimmingCharacters(in: nonAlphanumeric)
            guard !token.isEmpty, token.allSatisfy(\.isNumber), let value = Int(token) else { return nil }
            return validNumbers.contains(value) ? value : nil
        })
        return matches.count == 1 ? matches.first : nil
    }
}

/// Builds review-ready `ElectrodeAnnotation`s from fused detections.
enum ElectrodeAnnotationBuilder {
    /// - Parameters:
    ///   - aggregated: fused world-space positions, one per detected label.
    ///   - layout: active layout, providing role and the valid label set.
    ///   - confidenceThreshold: at/above this a detection is `.detected`,
    ///     below it is `.needsReview` so the reviewer looks at it.
    ///   - suspectLabels: labels flagged as geometrically inconsistent by the
    ///     neighbor validator; these are forced to `.needsReview` regardless of
    ///     confidence.
    ///
    /// Positions are in the ARKit world frame (meters). Conversion into the
    /// fiducial-anchored head frame used for export happens separately (TODO §3).
    static func build(
        from aggregated: [AggregatedElectrode],
        layout: ElectrodeLayout,
        confidenceThreshold: Double = 0.6,
        suspectLabels: Set<String> = []
    ) -> [ElectrodeAnnotation] {
        let definitionsByLabel = Dictionary(
            uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) }
        )

        return aggregated.compactMap { electrode in
            guard let definition = definitionsByLabel[electrode.label] else { return nil }
            let confidence = Double(electrode.confidence)
            let passesConfidence = confidence >= confidenceThreshold
            let isSuspect = suspectLabels.contains(electrode.label)

            return ElectrodeAnnotation(
                label: electrode.label,
                role: definition.role,
                coordinate: Coordinate3D(
                    x: Double(electrode.position.x),
                    y: Double(electrode.position.y),
                    z: Double(electrode.position.z)
                ),
                confidence: confidence,
                state: (passesConfidence && !isSuspect) ? .detected : .needsReview
            )
        }
    }
}

/// Portable detection pipeline: OCR -> back-project -> fuse -> annotate.
/// Depends only on the injected `TextRecognizing` and frame provider, so it is
/// fully testable without Vision, ARKit, or file IO.
struct OCRElectrodeDetectionPipeline: ElectrodeDetectionPipeline {
    var recognizer: TextRecognizing
    var confidenceThreshold: Double = 0.6
    /// When true, flags geometrically inconsistent reads (likely misreads) as
    /// needs-review via the neighbor graph.
    var validatesNeighbors: Bool = true
    /// When true, fills electrodes OCR could not read by fitting the coordinate
    /// template to the confident detections (added as needs-review).
    var fillsMissingFromTemplate: Bool = true

    func detectElectrodes(in context: DetectionContext) async throws -> [ElectrodeAnnotation] {
        let validNumbers = Set(context.layout.electrodes.map(\.number))
        var detections: [LabeledDetection] = []

        for observation in context.observations {
            guard let frame = context.frameProvider.frame(for: observation) else { continue }
            let imageSize = SIMD2<Float>(
                Float(observation.imageResolution.width),
                Float(observation.imageResolution.height)
            )

            let recognized = try recognizer.recognize(in: frame.image, imageSize: imageSize)
            for item in recognized {
                guard let number = ElectrodeLabelParser.parse(item.text, validNumbers: validNumbers) else { continue }
                guard let depth = frame.depthSampler?.depth(atImagePixel: item.imageCenter) else { continue }

                let world = frame.camera.unproject(pixel: item.imageCenter, depth: depth)
                detections.append(
                    LabeledDetection(label: "E\(number)", world: world, quality: item.confidence)
                )
            }
        }

        let fused = ElectrodeObservationAggregator.aggregate(detections)

        var suspects: Set<String> = []
        if validatesNeighbors {
            let positions = Dictionary(uniqueKeysWithValues: fused.map { ($0.label, $0.position) })
            suspects = ElectrodeNeighborValidator.validate(positions: positions, layout: context.layout).suspectLabels
        }

        let annotations = ElectrodeAnnotationBuilder.build(
            from: fused,
            layout: context.layout,
            confidenceThreshold: confidenceThreshold,
            suspectLabels: suspects
        )

        guard fillsMissingFromTemplate else { return annotations }
        return ElectrodeTemplateFitter.fillMissing(annotations: annotations, layout: context.layout)
    }
}
