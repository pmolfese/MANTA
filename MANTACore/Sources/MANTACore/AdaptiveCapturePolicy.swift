import Foundation

/// Experimental capture gates. Thresholds require physical-device validation.
public enum AdaptiveCapturePolicy {
    public static func shouldSample(elapsed: Double, minimumGap: Double, sharpness: Double,
                                    translation: Double, rotationDegrees: Double, newSector: Bool) -> Bool {
        guard [elapsed, minimumGap, sharpness, translation, rotationDegrees].allSatisfy(\.isFinite),
              elapsed >= max(0.25, minimumGap), sharpness >= 0.025 else { return false }
        return newSector || translation >= 0.02 || rotationDegrees >= 5 || elapsed >= max(3, minimumGap)
    }
    public static func canTakeStill(stableSeconds: Double, sharpness: Double, fresh: Bool, sectorSaved: Bool) -> Bool {
        fresh && !sectorSaved && stableSeconds >= 0.3 && sharpness.isFinite && sharpness >= 0.025
    }
}

public struct LiveLabelSighting: Codable, Equatable, Sendable {
    public var label: String
    public var confidence: Float
    public var imageX: Float
    public var imageY: Float
    public var ambiguous: Bool
    public init(label: String, confidence: Float, imageX: Float, imageY: Float, ambiguous: Bool = false) {
        self.label = label; self.confidence = confidence; self.imageX = imageX; self.imageY = imageY; self.ambiguous = ambiguous
    }
}

public struct LiveLabelCoverage: Sendable {
    private var views: [String: [UUID: [Float]]] = [:]
    public private(set) var ambiguousLabels: Set<String> = []
    public var seenLabels: Set<String> { Set(views.keys).subtracting(ambiguousLabels) }
    public var supportedLabels: Set<String> {
        Set(views.filter { $0.value.count >= 2 }.keys).subtracting(ambiguousLabels)
    }
    public init() {}
    public mutating func markAmbiguous(_ labels: Set<String>) { ambiguousLabels.formUnion(labels) }
    public mutating func ingest(_ sightings: [LiveLabelSighting], observationID: UUID, pose: [Float]) {
        guard pose.count == 16, pose.allSatisfy(\.isFinite) else { return }
        for (label, items) in Dictionary(grouping: sightings, by: \.label) {
            guard items.count == 1, let item = items.first, !item.ambiguous else {
                ambiguousLabels.insert(label); continue
            }
            guard item.confidence.isFinite, item.confidence >= 0.75 else { continue }
            // Count distinct camera views, never repeated processing of one image.
            let previous = views[label] ?? [:]
            guard previous[observationID] == nil, previous.count < 3 else { continue }
            let isDistinct = previous.values.allSatisfy { other in
                let distance = sqrt((12...14).reduce(Float(0)) { $0 + pow(pose[$1] - other[$1], 2) })
                let dot = min(Float(1), max(-1, pose[8] * other[8] + pose[9] * other[9] + pose[10] * other[10]))
                return distance >= 0.02 || acos(dot) * 180 / .pi >= 5
            }
            if isDistinct { views[label, default: [:]][observationID] = pose }
        }
    }
}
