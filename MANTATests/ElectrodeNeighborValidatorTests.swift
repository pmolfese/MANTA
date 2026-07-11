//
//  ElectrodeNeighborValidatorTests.swift
//  MANTATests
//
//  Validates the neighbor-graph consistency check against the real 128 and 256
//  neighbor graphs: a template-consistent detection set has no suspects, and a
//  single displaced (misread) electrode is flagged while its neighbors are not.
//

import Foundation
import Testing
import simd
@testable import MANTA

struct ElectrodeNeighborValidatorTests {
    static let channelCounts = [128, 256]

    private func loadLayout(channelCount: Int) throws -> ElectrodeLayout {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MANTA/Resources/Layouts")
        let layouts = try HydroCelLayoutLoader(resourceDirectory: url).loadLayouts()
        return try #require(layouts.first { $0.channelCount == channelCount })
    }

    /// Template positions mapped into a world frame via a known similarity
    /// transform (rotation + scale + translation), scaled to a ~9 cm head.
    private func worldPositions(for layout: ElectrodeLayout) -> [String: SIMD3<Float>] {
        let raw = layout.electrodes.reduce(into: [String: SIMD3<Float>]()) { result, electrode in
            let c = electrode.coordinatePrior
            result[electrode.label] = SIMD3<Float>(Float(c.x), Float(c.y), Float(c.z))
        }
        let centroid = raw.values.reduce(SIMD3<Float>(repeating: 0), +) / Float(raw.count)
        let radius = raw.values.map { simd_distance($0, centroid) }.max() ?? 1
        let scale = Float(0.09) / radius

        let rotation = simd_float3x3(simd_quatf(angle: 0.5, axis: simd_normalize(SIMD3<Float>(0.2, 1, 0.3))))
        let translation = SIMD3<Float>(0.3, -0.1, 0.6)

        return raw.mapValues { rotation * (($0 - centroid) * scale) + translation }
    }

    @Test(arguments: channelCounts)
    func consistentSetHasNoSuspects(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        let positions = worldPositions(for: layout)

        let result = ElectrodeNeighborValidator.validate(positions: positions, layout: layout)

        #expect(result.suspectLabels.isEmpty)
        #expect(result.scale > 0)
    }

    @Test(arguments: channelCounts)
    func displacedElectrodeIsFlagged(channelCount: Int) throws {
        let layout = try loadLayout(channelCount: channelCount)
        var positions = worldPositions(for: layout)

        // Pick an electrode with several neighbors and displace it far (as a
        // misread would place it), e.g. across the head.
        let victim = try #require(layout.electrodes.first { $0.neighbors.count >= 3 })
        let elsewhere = try #require(
            layout.electrodes.first { simd_distance(
                SIMD3<Float>(Float($0.coordinatePrior.x), Float($0.coordinatePrior.y), Float($0.coordinatePrior.z)),
                SIMD3<Float>(Float(victim.coordinatePrior.x), Float(victim.coordinatePrior.y), Float(victim.coordinatePrior.z))
            ) > 0.1 }
        )
        positions[victim.label] = positions[elsewhere.label]! + SIMD3<Float>(0.001, 0, 0)

        let result = ElectrodeNeighborValidator.validate(positions: positions, layout: layout)

        #expect(result.suspectLabels.contains(victim.label))
        // The victim's neighbors should mostly remain consistent (only one of
        // their edges is broken), so they are not themselves flagged.
        let neighborLabels = Set(victim.neighbors.compactMap { number in
            layout.electrodes.first { $0.number == number }?.label
        })
        let flaggedNeighbors = result.suspectLabels.intersection(neighborLabels)
        #expect(flaggedNeighbors.count <= 1)
    }
}
