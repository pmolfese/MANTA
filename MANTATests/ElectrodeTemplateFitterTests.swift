//
//  ElectrodeTemplateFitterTests.swift
//  MANTATests
//
//  Validates similarity template fitting + fill-missing on the real 128 and 256
//  templates: from a partial set of anchors it recovers the transform and
//  predicts the dropped electrodes' positions, and it declines when anchors are
//  too few.
//

import Foundation
import Testing
import simd
@testable import MANTA

struct ElectrodeTemplateFitterTests {
    static let channelCounts = [128, 256]

    private func loadLayout(channelCount: Int) throws -> ElectrodeLayout {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MANTA/Resources/Layouts")
        let layouts = try HydroCelLayoutLoader(resourceDirectory: url).loadLayouts()
        return try #require(layouts.first { $0.channelCount == channelCount })
    }

    private func knownSimilarity() -> simd_float4x4 {
        let rotation = simd_float3x3(simd_quatf(angle: 0.7, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.4))))
        let scale: Float = 0.001 // template units (mm-ish) -> meters
        let translation = SIMD3<Float>(0.3, -0.1, 0.6)
        return simd_float4x4(
            SIMD4<Float>(scale * rotation.columns.0, 0),
            SIMD4<Float>(scale * rotation.columns.1, 0),
            SIMD4<Float>(scale * rotation.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    private func templatePosition(_ e: ElectrodeDefinition) -> SIMD3<Float> {
        SIMD3<Float>(Float(e.coordinatePrior.x), Float(e.coordinatePrior.y), Float(e.coordinatePrior.z))
    }

    @Test(arguments: channelCounts)
    func fillsDroppedElectrodesFromAnchors(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()

        // World truth for every electrode.
        let worldTruth = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) { result, e in
            let p = transform * SIMD4<Float>(templatePosition(e), 1)
            result[e.label] = SIMD3<Float>(p.x, p.y, p.z)
        }

        // Detected = 70% of electrodes (every electrode whose number isn't a
        // multiple of 3 is "read"); the rest are occluded.
        var detected: [String: SIMD3<Float>] = [:]
        var dropped: [String] = []
        for e in layout.electrodes {
            if e.number % 3 == 0 { dropped.append(e.label) } else { detected[e.label] = worldTruth[e.label] }
        }

        let result = try #require(ElectrodeTemplateFitter.fit(detected: detected, layout: layout))

        #expect(result.anchorCount == detected.count)
        #expect(result.rmsError < 1e-4)
        #expect(result.filled.count == dropped.count)

        // Every dropped electrode is predicted essentially on its true position.
        for label in dropped {
            let predicted = try #require(result.filled[label])
            #expect(simd_distance(predicted, worldTruth[label]!) < 1e-3)
        }
    }

    @Test(arguments: channelCounts)
    func declinesWithTooFewAnchors(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()
        let anchors = layout.electrodes.prefix(3).reduce(into: [String: SIMD3<Float>]()) { result, e in
            let p = transform * SIMD4<Float>(templatePosition(e), 1)
            result[e.label] = SIMD3<Float>(p.x, p.y, p.z)
        }

        #expect(ElectrodeTemplateFitter.fit(detected: anchors, layout: layout, minAnchors: 4) == nil)
    }

    @Test(arguments: channelCounts)
    func fillMissingAddsNeedsReviewWithoutMovingDetections(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()

        var annotations: [ElectrodeAnnotation] = []
        var expectedFilled = 0
        for e in layout.electrodes {
            if e.number % 4 == 0 {
                expectedFilled += 1 // leave these missing
                continue
            }
            let p = transform * SIMD4<Float>(templatePosition(e), 1)
            annotations.append(ElectrodeAnnotation(
                label: e.label,
                role: e.role,
                coordinate: Coordinate3D(x: Double(p.x), y: Double(p.y), z: Double(p.z)),
                confidence: 0.9,
                state: .detected
            ))
        }
        let detectedBefore = annotations.filter { $0.state == .detected }

        let filled = ElectrodeTemplateFitter.fillMissing(annotations: annotations, layout: layout)

        #expect(filled.count == annotations.count + expectedFilled)
        // Detected annotations are unchanged.
        let detectedAfter = filled.filter { $0.state == .detected }
        #expect(detectedAfter == detectedBefore)
        // Added electrodes are needs-review.
        let added = filled.filter { annotation in !annotations.contains(where: { $0.label == annotation.label }) }
        #expect(added.allSatisfy { $0.state == .needsReview })
    }
}
