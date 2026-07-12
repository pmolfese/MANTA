import Foundation
import simd

public struct RecognizedElectrodeSample: Equatable, Sendable {
    public var text: String
    public var imageCenter: SIMD2<Float>
    public var confidence: Float
    public var depthMeters: Float

    public init(
        text: String, imageCenter: SIMD2<Float>, confidence: Float, depthMeters: Float
    ) {
        self.text = text
        self.imageCenter = imageCenter
        self.confidence = confidence
        self.depthMeters = depthMeters
    }
}

public struct PortableDetectionFrame: Sendable {
    public var camera: PinholeCamera
    public var samples: [RecognizedElectrodeSample]

    public init(camera: PinholeCamera, samples: [RecognizedElectrodeSample]) {
        self.camera = camera
        self.samples = samples
    }
}

public enum ElectrodeLabelParser {
    public static func parse(_ recognized: String, validNumbers: Set<Int>) -> Int? {
        let tokens = recognized.split { $0.isWhitespace || $0.isNewline }
        let punctuation = CharacterSet.alphanumerics.inverted
        let matches = Set(tokens.compactMap { raw -> Int? in
            let token = String(raw).trimmingCharacters(in: punctuation)
            guard !token.isEmpty, token.allSatisfy(\.isNumber), let value = Int(token),
                  validNumbers.contains(value) else { return nil }
            return value
        })
        return matches.count == 1 ? matches.first : nil
    }
}

public enum ElectrodeAnnotationBuilder {
    public static func build(
        from aggregated: [AggregatedElectrode], layout: ElectrodeLayout,
        confidenceThreshold: Double = 0.6, suspectLabels: Set<String> = []
    ) -> [ElectrodeAnnotation] {
        let definitions = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) })
        return aggregated.compactMap { electrode in
            guard let definition = definitions[electrode.label] else { return nil }
            let confidence = Double(electrode.confidence)
            return ElectrodeAnnotation(
                label: electrode.label, role: definition.role,
                coordinate: Coordinate3D(
                    x: Double(electrode.position.x), y: Double(electrode.position.y),
                    z: Double(electrode.position.z)),
                confidence: confidence,
                state: confidence >= confidenceThreshold
                    && !suspectLabels.contains(electrode.label) ? .detected : .needsReview)
        }
    }
}

public struct PortableElectrodeDetectionOrchestrator: Sendable {
    public var confidenceThreshold: Double
    public var validatesNeighbors: Bool
    public var fillsMissingFromTemplate: Bool

    public init(
        confidenceThreshold: Double = 0.6, validatesNeighbors: Bool = true,
        fillsMissingFromTemplate: Bool = true
    ) {
        self.confidenceThreshold = confidenceThreshold
        self.validatesNeighbors = validatesNeighbors
        self.fillsMissingFromTemplate = fillsMissingFromTemplate
    }

    public func detect(
        layout: ElectrodeLayout, frames: [PortableDetectionFrame]
    ) -> [ElectrodeAnnotation] {
        let validNumbers = Set(layout.electrodes.map(\.number))
        let detections = frames.flatMap { frame in
            frame.samples.compactMap { sample -> LabeledDetection? in
                guard let number = ElectrodeLabelParser.parse(
                    sample.text, validNumbers: validNumbers) else { return nil }
                return LabeledDetection(
                    label: "E\(number)",
                    world: frame.camera.unproject(
                        pixel: sample.imageCenter, depth: sample.depthMeters),
                    quality: sample.confidence)
            }
        }
        let fused = ElectrodeObservationAggregator.aggregate(detections)
        let suspects: Set<String>
        if validatesNeighbors {
            suspects = ElectrodeNeighborValidator.validate(
                positions: Dictionary(uniqueKeysWithValues: fused.map { ($0.label, $0.position) }),
                layout: layout).suspectLabels
        } else {
            suspects = []
        }
        let annotations = ElectrodeAnnotationBuilder.build(
            from: fused, layout: layout, confidenceThreshold: confidenceThreshold,
            suspectLabels: suspects)
        return fillsMissingFromTemplate
            ? ElectrodeTemplateFitter.fillMissing(annotations: annotations, layout: layout)
            : annotations
    }
}
