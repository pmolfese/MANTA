import Foundation
import MANTACore

struct DetectionRunDiagnostics: Codable, Sendable {
    enum Mode: String, Codable, Sendable { case live, finalized }

    var id: UUID
    var mode: Mode
    var startedAt: Date
    var completedAt: Date
    var engine: String
    var engineVersion: String
    var processedFrameIDs: [UUID]
    var rawDetectionCount: Int?
    var directlyLocalizedElectrodeCount: Int
    var templatePredictedElectrodeCount: Int
    var suspectLabels: [String]
    var templateFitRMSMillimeters: Double?
    var templateAnchorCount: Int?
    var electrodes: [ElectrodeAnnotation]
    var producer: [String: String]? = nil
    var parameters: [String: String]? = nil
}

nonisolated struct LiveDetectionEvidence: Codable, Sendable {
    let observationID: UUID
    let sightings: [LiveLabelSighting]
}

nonisolated struct LiveDetectionResult: Sendable {
    let sightings: [LiveLabelSighting]
    let detections: [LabeledDetection]
}

enum LiveElectrodeDetectionWorker {
    nonisolated static func detect(
        observation: CaptureObservation, session: ScanSession, sessionDirectory: URL
    ) throws -> LiveDetectionResult {
        let provider = CaptureArtifactFrameProvider(sessionDirectory: sessionDirectory)
        guard let frame = provider.frame(for: observation) else {
            throw NSError(domain: "MANTA.LiveOCR", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Saved image or calibration could not be decoded."])
        }
        let valid = Set(session.layout.electrodes.map(\.number))
        // Smaller text is expected in full-resolution stills. This remains an
        // experimental OCR setting, not a calibrated recognition confidence.
        let items = try VisionTextRecognizer(minimumTextHeight: 0.005).recognize(in: frame.image,
            imageSize: SIMD2(Float(observation.imageResolution.width), Float(observation.imageResolution.height)))
        var sightings: [LiveLabelSighting] = []
        var detections: [LabeledDetection] = []
        for item in items {
            let text = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let number = Int(text), valid.contains(number), item.confidence >= 0.75 else { continue }
            sightings.append(.init(label: "E\(number)", confidence: item.confidence,
                imageX: item.imageCenter.x, imageY: item.imageCenter.y))
        }
        let duplicates = Set(Dictionary(grouping: sightings, by: \.label).filter { $0.value.count > 1 }.keys)
        for index in sightings.indices {
            sightings[index].ambiguous = duplicates.contains(sightings[index].label)
            let sighting = sightings[index]
            guard !sighting.ambiguous,
                  observation.quality?.motionAssessment?.state != .insufficientEvidence,
                  observation.quality?.motionAssessment?.state != .suspected,
                  let depth = frame.depthSampler?.depth(atImagePixel: SIMD2(sighting.imageX, sighting.imageY)) else { continue }
            detections.append(LabeledDetection(label: sighting.label,
                world: frame.camera.unproject(pixel: SIMD2(sighting.imageX, sighting.imageY), depth: depth), quality: sighting.confidence))
        }
        let directory = sessionDirectory.appendingPathComponent("acquisition/live-labels")
        try FileManager().createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(LiveDetectionEvidence(observationID: observation.id, sightings: sightings))
            .write(to: directory.appendingPathComponent(observation.id.uuidString + ".json"), options: .atomic)
        return LiveDetectionResult(sightings: sightings, detections: detections)
    }
}
