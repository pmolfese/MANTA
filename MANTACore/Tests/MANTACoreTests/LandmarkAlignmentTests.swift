import Foundation
import Testing
import simd
@testable import MANTACore

struct LandmarkAlignmentTests {
    // Four non-coplanar model landmarks resembling nasion / LPA / RPA / Cz.
    private let model: [SIMD3<Float>] = [
        SIMD3(0.00, 0.02, 0.10),   // nasion (front)
        SIMD3(-0.07, 0.00, 0.00),  // LPA
        SIMD3(0.07, 0.00, 0.00),   // RPA
        SIMD3(0.00, 0.09, 0.02)    // Cz (off-plane)
    ]

    @Test func affineFitRecoversKnownAffineMap() throws {
        // A genuinely non-similarity map: different scale per axis + shear + shift.
        let a = simd_float3x3(
            SIMD3(1.3, 0.0, 0.0),
            SIMD3(0.2, 0.8, 0.0),
            SIMD3(0.0, 0.1, 1.1))
        let t = SIMD3<Float>(0.5, -0.3, 0.2)
        let target = model.map { a * $0 + t }

        let result = try #require(AffineLandmarkFit.fit(source: model, target: target))
        #expect(result.rmsError < 1e-4)
        for i in model.indices {
            let mapped = result.transform * SIMD4<Float>(model[i], 1)
            #expect(simd_distance(SIMD3(mapped.x, mapped.y, mapped.z), target[i]) < 1e-4)
        }
    }

    @Test func affineBeatsSimilarityOnNonUniformDistortion() throws {
        // Squash one axis so the sets are no longer similar (like a depth bias
        // that compresses depth-into-screen distances but not lateral ones).
        let target = model.map { SIMD3($0.x, $0.y, $0.z * 0.5) }
        let affine = try #require(
            AbsoluteOrientation.fit(source: model, target: target, model: .affine))
        let similarity = try #require(
            AbsoluteOrientation.fit(source: model, target: target, model: .similarity))
        #expect(affine.rmsError < similarity.rmsError)
        #expect(affine.rmsError < 1e-4)   // affine explains a pure squash exactly
    }

    @Test func rigidModelLocksScaleToOne() throws {
        let target = model.map { $0 * 2.0 + SIMD3(0.1, 0.1, 0.1) }
        let rigid = try #require(
            AbsoluteOrientation.fit(source: model, target: target, model: .rigid))
        let scale = simd_length(SIMD3(
            rigid.transform.columns.0.x, rigid.transform.columns.0.y, rigid.transform.columns.0.z))
        #expect(abs(scale - 1.0) < 1e-4)   // scale not allowed to grow to 2
    }

    @Test func plausibilityFlagsTheMisclickedLandmark() {
        // Target is a correctly-scaled copy of the model, except RPA is dragged
        // 4 cm off - a single bad correspondence.
        var target = model.map { $0 * 0.5 }
        target[2] += SIMD3(0.04, 0.0, 0.0)

        let scores = LandmarkPlausibilityAnalyzer.evaluate(source: model, target: target)
        #expect(scores.count == 4)
        let rpa = scores[2]
        #expect(rpa?.isLikelyOutlier == true)
        // The bad landmark's geometry error should dominate the good ones'.
        let rpaError = rpa?.geometryErrorMeters ?? 0
        for i in [0, 1, 3] {
            #expect((scores[i]?.geometryErrorMeters ?? 0) < rpaError)
            #expect(scores[i]?.isLikelyOutlier == false)
        }
    }

    @Test func plausibilityPassesAConsistentSet() {
        // A uniformly scaled + shifted copy is perfectly self-consistent.
        let target = model.map { $0 * 0.23 + SIMD3(0.05, -0.19, -0.6) }
        let scores = LandmarkPlausibilityAnalyzer.evaluate(source: model, target: target)
        for score in scores {
            #expect((score?.geometryErrorMeters ?? 1) < 1e-4)
            #expect(score?.isLikelyOutlier == false)
            #expect(abs((score?.edgeRatioSpread ?? 0) - 1.0) < 1e-3)
        }
    }

    @Test func symmetricRMSRejectsScaleCollapse() {
        // A big target head; a source that has collapsed to a tiny blob near the
        // target centroid. One-way forward RMS is small (every tiny-blob point is
        // near some target point) but the reverse RMS is large.
        var target = [SIMD3<Float>]()
        for x in stride(from: Float(-0.1), through: 0.1, by: 0.02) {
            for y in stride(from: Float(-0.1), through: 0.1, by: 0.02) {
                target.append(SIMD3(x, y, 0))
            }
        }
        let blob = (0..<50).map { _ in
            SIMD3<Float>(Float.random(in: -0.005...0.005), Float.random(in: -0.005...0.005), 0)
        }
        let symmetric = SurfaceAlignmentMetrics.symmetricRMS(
            transform: matrix_identity_float4x4, source: blob, target: target)
        // Collapse must not look good: symmetric RMS stays large (reverse penalty).
        #expect(symmetric > 0.03)
    }

    @Test func symmetricRMSNearZeroForAlignedClouds() {
        let cloud = (0..<200).map { _ in
            SIMD3<Float>(Float.random(in: -0.1...0.1), Float.random(in: -0.1...0.1), Float.random(in: -0.05...0.05))
        }
        let rms = SurfaceAlignmentMetrics.symmetricRMS(
            transform: matrix_identity_float4x4, source: cloud, target: cloud)
        #expect(rms < 1e-5)
    }
}
