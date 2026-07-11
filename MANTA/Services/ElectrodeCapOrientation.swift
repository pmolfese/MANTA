//
//  ElectrodeCapOrientation.swift
//  MANTA
//
//  Estimates the cap's placement in the world frame and, importantly, whether
//  that estimate is trustworthy enough to place unread electrodes from the
//  template.
//
//  Because detection is OCR-first, electrode labels are read directly, so cap
//  orientation is not needed to *assign* labels (the usual reason cardinals are
//  used). Here it serves two purposes:
//    1. A well-conditioned similarity fit of the template to the detections,
//       reported as an orientation + scale + residual.
//    2. A reliability gate: too few anchors, anchors clustered on one side, a
//       high residual, or cardinals that disagree with the fit all mean the fit
//       would extrapolate badly — so callers can decline to fill rather than
//       emit garbage predicted labels.
//
//  Cardinals (well spread across the head, with known labels) are used as an
//  independent consistency check. Layout-agnostic: reads whatever priors and
//  cardinal set the active layout provides, so it works for 128 and 256.
//

import Foundation
import simd

enum ElectrodeCapOrientation {
    struct Result {
        /// Similarity transform mapping template coordinates into the world frame.
        var transform: simd_float4x4
        /// Cap orientation (rotation component of the fit).
        var rotation: simd_quatf
        /// Estimated template-units -> world-meters scale.
        var scale: Float
        /// RMS residual of the fit over anchors (meters).
        var rmsError: Float
        var anchorCount: Int
        /// Extent of the anchors relative to the whole head (0...~1). Low means
        /// the anchors are clustered and the fit will extrapolate poorly.
        var anchorSpreadRatio: Float
        /// Median residual of detected cardinals after the fit (meters), if any.
        var cardinalConsistency: Float?
        /// Passes the anchor-count, spread, residual, and cardinal-consistency
        /// gates — safe to use for filling missing electrodes.
        var isReliable: Bool
    }

    static func estimate(
        detected: [String: SIMD3<Float>],
        layout: ElectrodeLayout,
        minAnchors: Int = 4,
        minSpreadRatio: Float = 0.4,
        maxRMSMeters: Float = 0.02
    ) -> Result? {
        let templateByLabel = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) { result, electrode in
            let c = electrode.coordinatePrior
            result[electrode.label] = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }

        // Anchors: detected labels that exist in the template.
        var labels: [String] = []
        var source: [SIMD3<Float>] = []
        var target: [SIMD3<Float>] = []
        for (label, worldPosition) in detected {
            guard let templatePosition = templateByLabel[label] else { continue }
            labels.append(label)
            source.append(templatePosition)
            target.append(worldPosition)
        }
        guard source.count >= minAnchors else { return nil }
        guard let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .estimate) else {
            return nil
        }

        let scale = simd_length(fit.transform.columns.0.xyz)
        let rotationMatrix = simd_float3x3(
            fit.transform.columns.0.xyz / scale,
            fit.transform.columns.1.xyz / scale,
            fit.transform.columns.2.xyz / scale
        )
        let rotation = simd_quatf(rotationMatrix)

        // Anchor spread vs. whole-head spread, in template units.
        let headExtent = extent(of: Array(templateByLabel.values))
        let anchorExtent = extent(of: source)
        let spreadRatio = headExtent > 0 ? anchorExtent / headExtent : 0

        // Cardinal consistency: how well detected cardinals agree with the fit.
        var cardinalResiduals: [Float] = []
        for (index, label) in labels.enumerated() where layout.cardinalLabels.contains(label) {
            let predicted = fit.transform * SIMD4<Float>(source[index], 1)
            cardinalResiduals.append(simd_distance(predicted.xyz, target[index]))
        }
        let cardinalConsistency = cardinalResiduals.isEmpty ? nil : median(cardinalResiduals)

        let rmsOK = fit.rmsError.isFinite && fit.rmsError <= maxRMSMeters
        let cardinalOK = (cardinalConsistency ?? 0) <= maxRMSMeters
        let isReliable = source.count >= minAnchors
            && spreadRatio >= minSpreadRatio
            && rmsOK
            && cardinalOK

        return Result(
            transform: fit.transform,
            rotation: rotation,
            scale: scale,
            rmsError: fit.rmsError,
            anchorCount: source.count,
            anchorSpreadRatio: spreadRatio,
            cardinalConsistency: cardinalConsistency,
            isReliable: isReliable
        )
    }

    /// Max distance of a point set from its centroid.
    private static func extent(of points: [SIMD3<Float>]) -> Float {
        guard !points.isEmpty else { return 0 }
        let centroid = points.reduce(SIMD3<Float>(repeating: 0), +) / Float(points.count)
        return points.map { simd_distance($0, centroid) }.max() ?? 0
    }

    private static func median(_ values: [Float]) -> Float {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> { SIMD3<Float>(x, y, z) }
}
