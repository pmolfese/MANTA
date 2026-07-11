//
//  VisionTextRecognizer.swift
//  MANTA
//
//  Vision-backed text recognition for the OCR electrode detector, plus a
//  factory for the default on-device detection pipeline.
//
//  Vision returns bounding boxes in a normalized, bottom-left origin space; we
//  resolve each box center to a pixel in the image's native coordinate space so
//  it can be back-projected with `PinholeCamera`. Recognition runs with the
//  native (`.up`) orientation so those pixel coordinates stay consistent with
//  the stored intrinsics; if real captures need a rotation for accuracy, add it
//  here and map the coordinates back.
//

import CoreGraphics
import Foundation
import MANTACore
import simd

#if canImport(Vision)
import Vision

struct VisionTextRecognizer: TextRecognizing {
    /// Digits only; disks show numbers (and occasional 10-20 letters we ignore).
    var minimumTextHeight: Float = 0.02

    func recognize(in image: CGImage, imageSize: SIMD2<Float>) throws -> [RecognizedText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = minimumTextHeight

        let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
        try handler.perform([request])

        let observations = request.results ?? []
        return observations.compactMap { observation -> RecognizedText? in
            guard let candidate = observation.topCandidates(1).first else { return nil }

            // Vision bbox: normalized, origin bottom-left. Convert center to
            // native image pixels (origin top-left).
            let box = observation.boundingBox
            let centerX = Float(box.midX) * imageSize.x
            let centerY = (1 - Float(box.midY)) * imageSize.y

            return RecognizedText(
                text: candidate.string,
                imageCenter: SIMD2<Float>(centerX, centerY),
                confidence: candidate.confidence
            )
        }
    }
}

enum ElectrodeDetectionFactory {
    /// The default on-device pipeline: Vision OCR feeding the portable fuser.
    static func makeDefaultPipeline() -> ElectrodeDetectionPipeline {
        OCRElectrodeDetectionPipeline(recognizer: VisionTextRecognizer())
    }
}
#else
enum ElectrodeDetectionFactory {
    static func makeDefaultPipeline() -> ElectrodeDetectionPipeline {
        MockElectrodeDetectionPipeline()
    }
}
#endif
