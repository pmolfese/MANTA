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
import MANTACore
import simd

/// Everything a detection pipeline consumes for one session.
nonisolated struct DetectionContext {
    var layout: ElectrodeLayout
    var observations: [CaptureObservation]
    var frameProvider: DetectionFrameProvider
}

/// A single captured frame prepared for detection.
nonisolated struct DetectionFrame {
    /// RGB image in the camera's native resolution (matches `camera` intrinsics).
    var image: CGImage
    /// Camera model for back-projecting image pixels into the ARKit world frame.
    var camera: PinholeCamera
    /// Metric depth lookup for this frame, when LiDAR depth was captured.
    var depthSampler: DepthSampler?
}

/// Loads a `DetectionFrame` (image + camera + depth) for an observation.
/// Backed by the artifact store on device; stubbed in tests.
nonisolated protocol DetectionFrameProvider {
    func frame(for observation: CaptureObservation) -> DetectionFrame?
}

/// Provides no frames. Used for previews and when no artifact store is available,
/// so the pipeline simply produces no detections rather than failing.
nonisolated struct EmptyDetectionFrameProvider: DetectionFrameProvider {
    func frame(for observation: CaptureObservation) -> DetectionFrame? { nil }
}

/// Samples metric depth (meters) at a pixel in the RGB image's coordinate space.
/// Implementations handle RGB->depth resolution scaling and reject
/// invalid/low-confidence samples by returning nil.
nonisolated protocol DepthSampler {
    func depth(atImagePixel pixel: SIMD2<Float>) -> Float?
}

/// One text item recognized in a frame, with its center already resolved to
/// pixels in the image's native coordinate space.
nonisolated struct RecognizedText: Equatable {
    var text: String
    var imageCenter: SIMD2<Float>
    var confidence: Float
}

/// Recognizes text in an image. The Vision implementation lives in
/// `VisionTextRecognizer`; tests inject a stub.
nonisolated protocol TextRecognizing {
    func recognize(in image: CGImage, imageSize: SIMD2<Float>) throws -> [RecognizedText]
}

/// Portable detection pipeline: OCR -> back-project -> fuse -> annotate.
/// Depends only on the injected `TextRecognizing` and frame provider, so it is
/// fully testable without Vision, ARKit, or file IO.
nonisolated struct OCRElectrodeDetectionPipeline: ElectrodeDetectionPipeline {
    var recognizer: TextRecognizing
    var confidenceThreshold: Double = 0.6
    /// When true, flags geometrically inconsistent reads (likely misreads) as
    /// needs-review via the neighbor graph.
    var validatesNeighbors: Bool = true
    /// When true, fills electrodes OCR could not read by fitting the coordinate
    /// template to the confident detections (added as needs-review).
    var fillsMissingFromTemplate: Bool = true

    func detectElectrodes(in context: DetectionContext) async throws -> [ElectrodeAnnotation] {
        let detections = try detectRaw(in: context)
        let fused = ElectrodeObservationAggregator.aggregate(detections)
        let suspects: Set<String>
        if validatesNeighbors {
            suspects = ElectrodeNeighborValidator.validate(
                positions: Dictionary(uniqueKeysWithValues: fused.map { ($0.label, $0.position) }),
                layout: context.layout).suspectLabels
        } else {
            suspects = []
        }
        let annotations = ElectrodeAnnotationBuilder.build(
            from: fused, layout: context.layout, confidenceThreshold: confidenceThreshold,
            suspectLabels: suspects)
        return fillsMissingFromTemplate
            ? ElectrodeTemplateFitter.fillMissing(annotations: annotations, layout: context.layout)
            : annotations
    }

    /// Produces the per-frame evidence used by both incremental live detection
    /// and the comprehensive final solver.
    func detectRaw(in context: DetectionContext) throws -> [LabeledDetection] {
        var detections = [LabeledDetection]()
        let validNumbers = Set(context.layout.electrodes.map(\.number))

        for observation in context.observations {
            guard let frame = context.frameProvider.frame(for: observation) else { continue }
            let imageSize = SIMD2<Float>(
                Float(observation.imageResolution.width),
                Float(observation.imageResolution.height)
            )

            let samples = try recognizer.recognize(in: frame.image, imageSize: imageSize)
                .compactMap { item -> LabeledDetection? in
                    guard let depth = frame.depthSampler?.depth(atImagePixel: item.imageCenter)
                    else { return nil }
                    guard let number = ElectrodeLabelParser.parse(
                        item.text, validNumbers: validNumbers) else { return nil }
                    return LabeledDetection(
                        label: "E\(number)",
                        world: frame.camera.unproject(pixel: item.imageCenter, depth: depth),
                        quality: item.confidence)
                }
            detections.append(contentsOf: samples)
        }
        return detections
    }
}
