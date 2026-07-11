//
//  ElectrodeNeighborValidator.swift
//  MANTA
//
//  Geometric sanity check on fused detections using the layout's neighbor graph
//  and coordinate template. Catches OCR misreads that survived fusion: a
//  mislabeled disk sits physically far from where its graph-neighbors expect it,
//  so its detected inter-electrode distances disagree with the template.
//
//  Inter-electrode distances are invariant to the rigid transform between the
//  ARKit world frame and the template, so only a single global scale has to be
//  estimated (the template file's units cancel out). This makes the check
//  identical for the 128- and 256-channel nets — it reads whatever neighbor
//  graph and priors the active layout provides.
//

import Foundation
import simd

enum ElectrodeNeighborValidator {
    struct Result: Equatable {
        /// Labels whose geometry is inconsistent with their neighbors.
        var suspectLabels: Set<String>
        /// Estimated template-units -> world-meters scale (median over pairs).
        var scale: Float
    }

    /// Flags detected electrodes that are geometrically inconsistent with their
    /// neighbors.
    ///
    /// - Parameters:
    ///   - positions: label -> fused world position (meters).
    ///   - layout: provides the neighbor graph and coordinate priors.
    ///   - toleranceMeters: max per-edge distance residual to count a neighbor
    ///     as agreeing.
    ///   - minNeighbors: an electrode needs at least this many detected
    ///     neighbors to be judged; below that it is left alone (too little info).
    ///   - minConsistentFraction: an electrode is a suspect when fewer than this
    ///     fraction of its detected neighbors agree.
    static func validate(
        positions: [String: SIMD3<Float>],
        layout: ElectrodeLayout,
        toleranceMeters: Float = 0.01,
        minNeighbors: Int = 2,
        minConsistentFraction: Float = 0.5
    ) -> Result {
        // Index the layout by label.
        let byLabel = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0) })
        let byNumber = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.number, $0) })

        // Detected adjacent pairs (each once) with their detected/template edge lengths.
        var edgeRatios: [Float] = []
        var detectedEdges: [(label: String, neighborLabel: String, detected: Float, template: Float)] = []

        for (label, definition) in byLabel {
            guard let detectedPosition = positions[label] else { continue }
            let templatePosition = simd(definition.coordinatePrior)

            for neighborNumber in definition.neighbors {
                guard let neighbor = byNumber[neighborNumber] else { continue }
                guard let neighborPosition = positions[neighbor.label] else { continue }

                let detectedDistance = simd_distance(detectedPosition, neighborPosition)
                let templateDistance = simd_distance(templatePosition, simd(neighbor.coordinatePrior))
                guard templateDistance > 1e-6 else { continue }

                detectedEdges.append((label, neighbor.label, detectedDistance, templateDistance))
                // Count each undirected pair once for the scale estimate.
                if definition.number < neighbor.number {
                    edgeRatios.append(detectedDistance / templateDistance)
                }
            }
        }

        let scale = median(edgeRatios)
        guard scale > 0 else { return Result(suspectLabels: [], scale: 0) }

        // Per electrode: fraction of detected neighbors whose edge length agrees
        // with the scaled template.
        var neighborCounts: [String: (consistent: Int, total: Int)] = [:]
        for edge in detectedEdges {
            let expected = scale * edge.template
            let agrees = abs(edge.detected - expected) <= toleranceMeters
            var entry = neighborCounts[edge.label, default: (0, 0)]
            entry.total += 1
            if agrees { entry.consistent += 1 }
            neighborCounts[edge.label] = entry
        }

        var suspects: Set<String> = []
        for (label, counts) in neighborCounts where counts.total >= minNeighbors {
            let fraction = Float(counts.consistent) / Float(counts.total)
            if fraction < minConsistentFraction {
                suspects.insert(label)
            }
        }

        return Result(suspectLabels: suspects, scale: scale)
    }

    private static func simd(_ coordinate: Coordinate3D) -> SIMD3<Float> {
        SIMD3<Float>(Float(coordinate.x), Float(coordinate.y), Float(coordinate.z))
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
