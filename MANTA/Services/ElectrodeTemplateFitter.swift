//
//  ElectrodeTemplateFitter.swift
//  MANTA
//
//  Places electrodes that OCR could not read (hair-occluded, glare, back of the
//  head) by fitting the coordinate template to the confidently-detected points
//  and predicting the missing labels' positions.
//
//  The fit is a similarity transform (rigid + uniform scale) via Horn's absolute
//  orientation, reusing `AbsoluteOrientation` from world alignment. Similarity is
//  the conservative baseline: robust with sparse/noisy anchors and hard to
//  overfit. If real-head residuals prove too high, an affine variant can be
//  added behind the same entry point.
//
//  Fill-only: detected positions are never moved; this only adds predictions for
//  labels that have no detection yet. It reads whatever priors the active layout
//  provides, so it works unchanged for the 128- and 256-channel nets.
//

import Foundation
import simd

enum ElectrodeTemplateFitter {
    struct Result {
        /// Similarity transform mapping template coordinates into the world frame.
        var transform: simd_float4x4
        /// RMS residual of the fit over the anchor electrodes (meters).
        var rmsError: Float
        /// Predicted world positions for labels that had no detection.
        var filled: [String: SIMD3<Float>]
        /// Number of detected electrodes used as fit anchors.
        var anchorCount: Int
    }

    /// Fits the template to the detected electrodes and predicts missing ones.
    ///
    /// - Parameters:
    ///   - detected: label -> world position for confidently-detected electrodes
    ///     (anchors). Suspect / low-confidence detections should be excluded by
    ///     the caller.
    ///   - layout: provides the coordinate template and the full label set.
    ///   - minAnchors: minimum anchors required for a stable fit.
    /// - Returns: the fit and predicted positions, or nil if there are too few
    ///   anchors or the fit fails.
    static func fit(
        detected: [String: SIMD3<Float>],
        layout: ElectrodeLayout,
        minAnchors: Int = 4
    ) -> Result? {
        let templateByLabel = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) { result, electrode in
            let c = electrode.coordinatePrior
            result[electrode.label] = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }

        // Anchors: labels present in both the detections and the template.
        var source: [SIMD3<Float>] = []
        var target: [SIMD3<Float>] = []
        for (label, worldPosition) in detected {
            guard let templatePosition = templateByLabel[label] else { continue }
            source.append(templatePosition)
            target.append(worldPosition)
        }
        guard source.count >= minAnchors else { return nil }

        guard let fit = AbsoluteOrientation.fit(source: source, target: target, scale: .estimate) else {
            return nil
        }

        var filled: [String: SIMD3<Float>] = [:]
        for (label, templatePosition) in templateByLabel where detected[label] == nil {
            let predicted = fit.transform * SIMD4<Float>(templatePosition, 1)
            filled[label] = SIMD3<Float>(predicted.x, predicted.y, predicted.z)
        }

        return Result(
            transform: fit.transform,
            rmsError: fit.rmsError,
            filled: filled,
            anchorCount: source.count
        )
    }

    /// Appends template-predicted electrodes for labels missing from
    /// `annotations`. Anchors are the confidently-`.detected` annotations; filled
    /// electrodes are added as low-confidence `.needsReview` so the reviewer
    /// confirms or nudges them. Detected annotations are returned unchanged.
    static func fillMissing(
        annotations: [ElectrodeAnnotation],
        layout: ElectrodeLayout,
        minAnchors: Int = 4
    ) -> [ElectrodeAnnotation] {
        let anchors = annotations
            .filter { $0.state == .detected }
            .reduce(into: [String: SIMD3<Float>]()) { result, annotation in
                result[annotation.label] = SIMD3<Float>(
                    Float(annotation.coordinate.x),
                    Float(annotation.coordinate.y),
                    Float(annotation.coordinate.z)
                )
            }

        guard let result = fit(detected: anchors, layout: layout, minAnchors: minAnchors) else {
            return annotations
        }

        let existingLabels = Set(annotations.map(\.label))
        let rolesByLabel = Dictionary(uniqueKeysWithValues: layout.electrodes.map { ($0.label, $0.role) })

        var output = annotations
        for (label, position) in result.filled where !existingLabels.contains(label) {
            output.append(
                ElectrodeAnnotation(
                    label: label,
                    role: rolesByLabel[label] ?? .regular,
                    coordinate: Coordinate3D(x: Double(position.x), y: Double(position.y), z: Double(position.z)),
                    confidence: 0,
                    state: .needsReview
                )
            )
        }
        return output
    }
}
