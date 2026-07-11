//
//  ElectrodeCapOrientationTests.swift
//  MANTATests
//
//  Validates cap-orientation estimation and its reliability gate on the real 128
//  and 256 layouts: a well-spread anchor set recovers the transform and reads as
//  reliable; a cluster of anchors reads as unreliable so filling is declined.
//

import Foundation
import Testing
import simd
@testable import MANTA

struct ElectrodeCapOrientationTests {
    static let channelCounts = [128, 256]

    private func loadLayout(channelCount: Int) throws -> ElectrodeLayout {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MANTA/Resources/Layouts")
        let layouts = try HydroCelLayoutLoader(resourceDirectory: url).loadLayouts()
        return try #require(layouts.first { $0.channelCount == channelCount })
    }

    private func knownSimilarity() -> simd_float4x4 {
        let rotation = simd_float3x3(simd_quatf(angle: 0.8, axis: simd_normalize(SIMD3<Float>(0.1, 1, 0.3))))
        let scale: Float = 0.001
        let translation = SIMD3<Float>(0.2, -0.15, 0.5)
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

    private func worldPositions(_ layout: ElectrodeLayout, transform: simd_float4x4) -> [String: SIMD3<Float>] {
        layout.electrodes.reduce(into: [String: SIMD3<Float>]()) { result, e in
            let p = transform * SIMD4<Float>(templatePosition(e), 1)
            result[e.label] = SIMD3<Float>(p.x, p.y, p.z)
        }
    }

    @Test(arguments: channelCounts)
    func wellSpreadAnchorsAreReliableAndRecoverTransform(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()
        let detected = worldPositions(layout, transform: transform)

        let result = try #require(ElectrodeCapOrientation.estimate(detected: detected, layout: layout))

        #expect(result.isReliable)
        #expect(result.rmsError < 1e-4)
        #expect(result.anchorSpreadRatio > 0.9)
        // Transform recovers a known template point.
        let sample = layout.electrodes[10]
        let predicted = result.transform * SIMD4<Float>(templatePosition(sample), 1)
        #expect(simd_distance(SIMD3<Float>(predicted.x, predicted.y, predicted.z), detected[sample.label]!) < 1e-3)
    }

    @Test(arguments: channelCounts)
    func clusteredAnchorsAreUnreliable(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()
        let world = worldPositions(layout, transform: transform)

        // Take a tight cluster: the electrode nearest the front plus its nearest
        // neighbors by template distance.
        let anchorLabel = layout.electrodes[0].label
        let origin = templatePosition(layout.electrodes[0])
        let clustered = layout.electrodes
            .sorted { simd_distance(templatePosition($0), origin) < simd_distance(templatePosition($1), origin) }
            .prefix(8)
            .reduce(into: [String: SIMD3<Float>]()) { result, e in result[e.label] = world[e.label] }
        _ = anchorLabel

        let result = try #require(ElectrodeCapOrientation.estimate(detected: clustered, layout: layout))
        #expect(result.anchorSpreadRatio < 0.4)
        #expect(!result.isReliable)
    }

    @Test(arguments: channelCounts)
    func fillDeclinesWhenAnchorsUnreliable(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let transform = knownSimilarity()
        let world = worldPositions(layout, transform: transform)

        // A tight cluster of confident detections; everything else missing.
        let origin = templatePosition(layout.electrodes[0])
        let clustered = layout.electrodes
            .sorted { simd_distance(templatePosition($0), origin) < simd_distance(templatePosition($1), origin) }
            .prefix(8)
        let annotations = clustered.map { e in
            ElectrodeAnnotation(
                label: e.label,
                role: e.role,
                coordinate: Coordinate3D(x: Double(world[e.label]!.x), y: Double(world[e.label]!.y), z: Double(world[e.label]!.z)),
                confidence: 0.9,
                state: .detected
            )
        }

        let filled = ElectrodeTemplateFitter.fillMissing(annotations: annotations, layout: layout)
        // Unreliable fit -> nothing filled.
        #expect(filled.count == annotations.count)
    }
}
