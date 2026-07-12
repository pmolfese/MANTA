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
}

enum LiveElectrodeDetectionWorker {
    /// Runs off the capture actor. It only reads artifacts that were atomically
    /// written before this work was queued.
    nonisolated static func detect(
        observation: CaptureObservation, session: ScanSession, sessionDirectory: URL
    ) throws -> [LabeledDetection] {
        let provider = CaptureArtifactFrameProvider(sessionDirectory: sessionDirectory)
        let context = DetectionContext(
            layout: session.layout,
            observations: [observation],
            frameProvider: provider)
        return try OCRElectrodeDetectionPipeline(
            recognizer: VisionTextRecognizer(),
            confidenceThreshold: 0.45,
            validatesNeighbors: false,
            fillsMissingFromTemplate: false
        ).detectRaw(in: context)
    }
}
