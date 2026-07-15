//
//  WorldAlignmentTests.swift
//  MANTATests
//
//  Validates that the alignment solvers recover a known transform from synthetic data.
//

import Foundation
import Testing
import simd
@testable import MANTACore

struct WorldAlignmentTests {
    /// Applies a similarity transform (rotation, scale, translation) to a point.
    private func apply(_ transform: simd_float4x4, _ point: SIMD3<Float>) -> SIMD3<Float> {
        let r = transform * SIMD4<Float>(point, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    private func knownTransform(scale: Float, axis: SIMD3<Float>, angle: Float, translation: SIMD3<Float>) -> simd_float4x4 {
        let q = simd_quatf(angle: angle, axis: simd_normalize(axis))
        let rotation = simd_float3x3(q)
        let c0 = scale * rotation.columns.0
        let c1 = scale * rotation.columns.1
        let c2 = scale * rotation.columns.2
        return simd_float4x4(
            SIMD4<Float>(c0, 0),
            SIMD4<Float>(c1, 0),
            SIMD4<Float>(c2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    private func maxError(_ transform: simd_float4x4, source: [SIMD3<Float>], target: [SIMD3<Float>]) -> Float {
        var worst: Float = 0
        for (s, t) in zip(source, target) {
            worst = max(worst, simd_length(apply(transform, s) - t))
        }
        return worst
    }

    @Test func fiducialFitRecoversRigidTransform() throws {
        let source: [SIMD3<Float>] = [
            SIMD3(0, 95, 20), SIMD3(-78, 0, 0), SIMD3(78, 0, 0), SIMD3(0, 0, 90)
        ]
        let truth = knownTransform(scale: 1, axis: SIMD3(0.2, 1, 0.3), angle: 0.7, translation: SIMD3(12, -5, 30))
        let target = source.map { apply(truth, $0) }

        let result = try #require(AbsoluteOrientation.fit(source: source, target: target, scale: .rigid))
        #expect(result.rmsError < 1e-3)
        #expect(maxError(result.transform, source: source, target: target) < 1e-2)
    }

    @Test func fiducialFitRecoversScale() throws {
        let source: [SIMD3<Float>] = [
            SIMD3(0, 95, 20), SIMD3(-78, 0, 0), SIMD3(78, 0, 0), SIMD3(10, -30, 60)
        ]
        let truth = knownTransform(scale: 2.5, axis: SIMD3(1, 0.5, -0.2), angle: -1.1, translation: SIMD3(-4, 8, 15))
        let target = source.map { apply(truth, $0) }

        let result = try #require(AbsoluteOrientation.fit(source: source, target: target, scale: .estimate))
        #expect(maxError(result.transform, source: source, target: target) < 1e-2)
    }

    @Test func fiducialFitRecoversScaleFromExactlyThreeLandmarks() throws {
        // Manual Receiver alignment has exactly the Nasion/LPA/RPA triangle.
        // Lock down the rank-two three-point case under a general 3D rotation.
        let source: [SIMD3<Float>] = [
            SIMD3(0, 0.52, 0.11),
            SIMD3(-0.43, -0.08, -0.02),
            SIMD3(0.46, -0.06, 0.01)
        ]
        let truth = knownTransform(
            scale: 0.19,
            axis: SIMD3(0.3, 0.9, -0.2),
            angle: 1.35,
            translation: SIMD3(-0.42, 0.16, -1.08))
        let target = source.map { apply(truth, $0) }

        let result = try #require(
            AbsoluteOrientation.fit(source: source, target: target, scale: .estimate))

        #expect(result.rmsError < 1e-5)
        #expect(maxError(result.transform, source: source, target: target) < 1e-4)
    }

    @Test func fiducialFitReturnsNilWhenUnderdetermined() {
        let source: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0)]
        let target = source
        #expect(AbsoluteOrientation.fit(source: source, target: target, scale: .rigid) == nil)
    }

    @Test func robustFitExcludesASingleBadLandmarkWhenAFourthIsPresent() throws {
        // A well-conditioned tetrahedron (no 3-point subset near-degenerate),
        // so the fit isn't confounded by the coplanar ambiguity itself.
        let source: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.1, 0, 0), SIMD3(0, 0.1, 0), SIMD3(0.03, 0.03, 0.1)
        ]
        let truth = knownTransform(
            scale: 0.44, axis: SIMD3(0.2, 1, -0.1), angle: 0.7, translation: SIMD3(0.05, -0.28, -0.6))
        var target = source.map { apply(truth, $0) }
        // Corrupt one landmark (index 2) the way a bad depth click does: a
        // large, isolated offset on just that one point.
        target[2] += SIMD3(0.15, -0.08, 0.06)

        let plain = try #require(AbsoluteOrientation.fit(source: source, target: target, scale: .estimate))
        let robust = try #require(AbsoluteOrientation.fitRobust(source: source, target: target, scale: .estimate))

        // The plain least-squares fit is dragged off by the bad point across the
        // whole transform, including at the good landmarks.
        #expect(maxError(plain.transform, source: source, target: target) > 0.01)
        // The robust fit identifies and drops the corrupted landmark...
        #expect(robust.excludedIndex == 2)
        // ...and recovers a transform that exactly matches truth at the good
        // points (3 clean points determine a similarity transform exactly).
        let goodSource = [source[0], source[1], source[3]]
        let goodTruthTarget = goodSource.map { apply(truth, $0) }
        #expect(maxError(robust.result.transform, source: goodSource, target: goodTruthTarget) < 0.001)
    }

    @Test func robustFitLeavesAConsistentThreePointSetUnchanged() throws {
        // With exactly 3 points there's no redundancy to detect an outlier, so
        // fitRobust must behave exactly like plain fit - never drop a point.
        let source: [SIMD3<Float>] = [SIMD3(0.05, -0.19, -0.55), SIMD3(0.14, -0.22, -0.60), SIMD3(0, -0.21, -0.64)]
        let target = source
        let robust = try #require(AbsoluteOrientation.fitRobust(source: source, target: target, scale: .rigid))
        #expect(robust.excludedIndex == nil)
    }

    @Test func icpConvergesFromIdentitySeed() throws {
        // A small point cloud on a sphere-ish shell.
        var cloud: [SIMD3<Float>] = []
        for i in 0..<40 {
            let a = Float(i) * 0.31
            cloud.append(SIMD3(cos(a) * 50, sin(a) * 40, Float(i) - 20))
        }
        let truth = knownTransform(scale: 1, axis: SIMD3(0.1, 1, 0.2), angle: 0.25, translation: SIMD3(5, -3, 8))
        let target = cloud.map { apply(truth, $0) }

        let result = ICP.align(
            source: cloud,
            target: target,
            seed: matrix_identity_float4x4,
            scaleMode: .rigid,
            maxIterations: 60,
            tolerance: 1e-6
        )
        // Exact correspondence exists, so ICP should drive residual near zero.
        #expect(result.rmsError < 0.5)
    }

    @Test func coarsePCASeedEnablesICPUnderLargeRotation() throws {
        // A head-like ellipsoid shell with distinct semi-axes (90/75/65 mm), sampled evenly.
        var cloud: [SIMD3<Float>] = []
        let count = 240
        let golden = Float.pi * (1 + sqrt(5))
        for i in 0..<count {
            let phi = acos(1 - 2 * (Float(i) + 0.5) / Float(count))
            let theta = golden * Float(i)
            cloud.append(SIMD3(
                sin(phi) * cos(theta) * 90,
                sin(phi) * sin(theta) * 75,
                cos(phi) * 65
            ))
        }
        // Large rotation and an arbitrary (photogrammetry-like) scale change.
        let truth = knownTransform(scale: 1.3, axis: SIMD3(0.2, 1, 0.1), angle: 2.4, translation: SIMD3(40, -25, 15))
        let target = cloud.map { apply(truth, $0) }

        var input = WorldAlignmentInput()
        input.seed = .coarsePCA
        input.sourceCloud = cloud
        input.targetCloud = target

        let result = WorldAlignmentSolver.solve(strategy: .icp, input: input)
        // Coarse PCA + scale-aware ICP should register the surfaces despite the big rotation/scale.
        #expect(result.rmsError < 3.0)
    }

    @Test func seededICPDoesNotCollapseEstablishedScale() throws {
        var source = [SIMD3<Float>]()
        for x in 0..<8 {
            for y in 0..<5 {
                for z in 0..<6 where (x + y + z).isMultiple(of: 3) {
                    source.append(SIMD3(Float(x) * 0.04, Float(y) * 0.05, Float(z) * 0.03))
                }
            }
        }
        let truth = knownTransform(
            scale: 1.7, axis: SIMD3(0.3, 1, -0.2), angle: 1.2,
            translation: SIMD3(0.2, -0.4, 0.1))
        let target = source.map { apply(truth, $0) }

        var input = WorldAlignmentInput()
        input.seed = .coarsePCA
        input.sourceCloud = source
        input.targetCloud = target
        let result = WorldAlignmentSolver.solve(strategy: .icp, input: input)

        let solvedScale = simd_length(SIMD3(
            result.transform.columns.0.x,
            result.transform.columns.0.y,
            result.transform.columns.0.z))
        #expect(abs(solvedScale - 1.7) < 0.02)
    }

    @Test func pcaSeedReturnsFiniteResidual() throws {
        let cloud: [SIMD3<Float>] = (0..<30).map { SIMD3(Float($0), Float($0) * 0.5, Float(($0 % 5)) * 2) }
        let truth = knownTransform(scale: 1, axis: SIMD3(0, 0, 1), angle: 0.6, translation: SIMD3(2, 3, 1))
        let target = cloud.map { apply(truth, $0) }
        let seeded = CoarseAlignment.pca(source: cloud, target: target)
        #expect(seeded != nil)
        #expect(seeded!.rmsError.isFinite)
    }

    @Test func solverDispatchesByStrategy() throws {
        let source: [SIMD3<Float>] = [
            SIMD3(0, 95, 20), SIMD3(-78, 0, 0), SIMD3(78, 0, 0), SIMD3(0, 0, 90)
        ]
        let truth = knownTransform(scale: 1, axis: SIMD3(0, 1, 0), angle: 0.5, translation: SIMD3(3, 4, 5))
        let target = source.map { apply(truth, $0) }

        var input = WorldAlignmentInput()
        input.sourceLandmarks = source
        input.targetLandmarks = target

        let result = WorldAlignmentSolver.solve(strategy: .fiducial, input: input)
        #expect(maxError(result.transform, source: source, target: target) < 1e-2)
    }
}
