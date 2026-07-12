//
//  ElectrodeObservationAggregator.swift
//  MANTA
//
//  Fuses per-frame electrode detections into one stable 3D position per channel.
//
//  A single electrode is seen in many captured frames, each producing a noisy
//  back-projected world point (OCR read + depth unprojection). This groups those
//  observations by channel label, rejects outliers, and produces a robust center
//  plus a confidence that reflects how many frames agreed and how tightly.
//
//  Pure and unit-testable: it operates on world-space points only, with no
//  dependency on Vision, ARKit, or file IO.
//

import Foundation
import simd

/// One back-projected detection of a labeled electrode in a single frame.
public struct LabeledDetection: Equatable, Sendable {
    /// Channel label as read from the disk, e.g. "E31" or "31".
    public var label: String
    /// Back-projected position in the ARKit world frame (meters).
    public var world: SIMD3<Float>
    /// Per-observation quality in 0...1 (e.g. OCR confidence × depth confidence).
    public var quality: Float

    public init(label: String, world: SIMD3<Float>, quality: Float = 1) {
        self.label = label
        self.world = world
        self.quality = quality
    }
}

/// A fused electrode position with a quality estimate.
public struct AggregatedElectrode: Equatable, Sendable {
    public var label: String
    /// Robust center of the inlier observations, in the ARKit world frame.
    public var position: SIMD3<Float>
    /// Number of inlier observations that contributed to `position`.
    public var observationCount: Int
    /// RMS distance of inliers from `position`, in meters.
    public var spread: Float
    /// Fused confidence in 0...1.
    public var confidence: Float

    public init(label: String, position: SIMD3<Float>, observationCount: Int, spread: Float, confidence: Float) {
        self.label = label
        self.position = position
        self.observationCount = observationCount
        self.spread = spread
        self.confidence = confidence
    }
}

public enum ElectrodeObservationAggregator {
    /// Fuses detections per channel label.
    ///
    /// - Parameters:
    ///   - detections: all per-frame detections across the whole session.
    ///   - outlierThreshold: max distance (meters) from the group median for an
    ///     observation to count as an inlier. Also the spread scale at which a
    ///     group's confidence is fully penalized.
    ///   - saturationCount: observation count at which the count contribution to
    ///     confidence saturates.
    /// - Returns: one entry per distinct label, sorted by label.
    public static func aggregate(
        _ detections: [LabeledDetection],
        outlierThreshold: Float = 0.02,
        saturationCount: Int = 5
    ) -> [AggregatedElectrode] {
        let groups = Dictionary(grouping: detections, by: { $0.label })

        var results: [AggregatedElectrode] = []
        results.reserveCapacity(groups.count)

        for (label, group) in groups {
            guard let aggregated = fuse(label: label,
                                        group: group,
                                        outlierThreshold: outlierThreshold,
                                        saturationCount: saturationCount) else {
                continue
            }
            results.append(aggregated)
        }

        return results.sorted { $0.label < $1.label }
    }

    private static func fuse(
        label: String,
        group: [LabeledDetection],
        outlierThreshold: Float,
        saturationCount: Int
    ) -> AggregatedElectrode? {
        guard !group.isEmpty else { return nil }

        let median = componentWiseMedian(group.map(\.world))

        // Inliers are within the threshold of the group median. A group always
        // keeps at least its closest observation so a tight pair isn't discarded.
        var inliers = group.filter { simd_distance($0.world, median) <= outlierThreshold }
        if inliers.isEmpty {
            let closest = group.min { simd_distance($0.world, median) < simd_distance($1.world, median) }
            inliers = closest.map { [$0] } ?? []
        }
        guard !inliers.isEmpty else { return nil }

        // Quality-weighted mean of the inliers.
        var weightSum: Float = 0
        var weighted = SIMD3<Float>(repeating: 0)
        for inlier in inliers {
            let weight = max(inlier.quality, 1e-4)
            weighted += inlier.world * weight
            weightSum += weight
        }
        let position = weighted / weightSum

        // RMS distance of inliers from the fused center.
        let variance = inliers.reduce(Float(0)) { partial, inlier in
            let d = simd_distance(inlier.world, position)
            return partial + d * d
        } / Float(inliers.count)
        let spread = sqrt(variance)

        let averageQuality = inliers.reduce(Float(0)) { $0 + $1.quality } / Float(inliers.count)
        let countFactor = min(1, Float(inliers.count) / Float(max(saturationCount, 1)))
        let spreadFactor = max(0, 1 - spread / outlierThreshold)
        let confidence = clamp(averageQuality * (0.5 + 0.5 * countFactor) * (0.5 + 0.5 * spreadFactor))

        return AggregatedElectrode(
            label: label,
            position: position,
            observationCount: inliers.count,
            spread: spread,
            confidence: confidence
        )
    }

    private static func componentWiseMedian(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        SIMD3<Float>(
            median(points.map(\.x)),
            median(points.map(\.y)),
            median(points.map(\.z))
        )
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        if sorted.count % 2 == 0 {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
    }

    private static func clamp(_ value: Float) -> Float {
        min(1, max(0, value))
    }
}
