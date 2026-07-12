//
//  HeadCoordinateFrameTests.swift
//  MANTATests
//
//  Validates the fiducial-anchored head coordinate system: canonical landmark
//  placement, invariance to world pose, degenerate rejection, and the
//  session-level conversion used by exports.
//

import Foundation
import MANTACore
import Testing
import simd
@testable import MANTA

struct HeadCoordinateFrameTests {
    private func apply(_ t: simd_float4x4, _ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = t * SIMD4<Float>(p, 1)
        return SIMD3<Float>(r.x, r.y, r.z)
    }

    private func rigid(scale: Float, angle: Float, axis: SIMD3<Float>, translation: SIMD3<Float>) -> simd_float4x4 {
        let rot = simd_float3x3(simd_quatf(angle: angle, axis: simd_normalize(axis)))
        return simd_float4x4(
            SIMD4<Float>(scale * rot.columns.0, 0),
            SIMD4<Float>(scale * rot.columns.1, 0),
            SIMD4<Float>(scale * rot.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
    }

    @Test func landmarksMapToCanonicalAxes() throws {
        // Fiducials already in a convenient world frame.
        let nasion = SIMD3<Float>(0, 0.10, 0.02)
        let lpa = SIMD3<Float>(-0.075, 0, 0)
        let rpa = SIMD3<Float>(0.075, 0, 0)

        let transform = try #require(HeadCoordinateFrame.solve(nasion: nasion, leftPreauricular: lpa, rightPreauricular: rpa))

        let headL = apply(transform, lpa)
        let headR = apply(transform, rpa)
        let headN = apply(transform, nasion)

        // Ears sit on the x-axis, symmetric about the origin.
        #expect(headL.x < 0 && abs(headL.y) < 1e-5 && abs(headL.z) < 1e-5)
        #expect(headR.x > 0 && abs(headR.y) < 1e-5 && abs(headR.z) < 1e-5)
        #expect(abs(headL.x + headR.x) < 1e-5)
        // Nasion is anterior (+y), in the x-y plane (z ~ 0).
        #expect(headN.y > 0)
        #expect(abs(headN.z) < 1e-5)
        #expect(abs(headN.x) < 1e-5) // symmetric nasion
    }

    @Test func headCoordinatesAreInvariantToWorldPose() throws {
        let nasion = SIMD3<Float>(0, 0.10, 0.02)
        let lpa = SIMD3<Float>(-0.075, 0, 0)
        let rpa = SIMD3<Float>(0.075, 0, 0)
        let electrode = SIMD3<Float>(0.03, 0.06, 0.09)

        let baseTransform = try #require(HeadCoordinateFrame.solve(nasion: nasion, leftPreauricular: lpa, rightPreauricular: rpa))
        let baseHead = apply(baseTransform, electrode)

        // Move the whole head (fiducials + electrode) by an arbitrary rigid
        // transform; head-frame coordinates must not change.
        let world = rigid(scale: 1, angle: 1.2, axis: SIMD3<Float>(0.3, 1, -0.2), translation: SIMD3<Float>(0.5, -0.3, 1.1))
        let movedTransform = try #require(HeadCoordinateFrame.solve(
            nasion: apply(world, nasion),
            leftPreauricular: apply(world, lpa),
            rightPreauricular: apply(world, rpa)
        ))
        let movedHead = apply(movedTransform, apply(world, electrode))

        #expect(simd_distance(baseHead, movedHead) < 1e-4)
    }

    @Test func degenerateFiducialsReturnNil() {
        // Coincident ears.
        #expect(HeadCoordinateFrame.solve(
            nasion: SIMD3<Float>(0, 0.1, 0),
            leftPreauricular: SIMD3<Float>(0.05, 0, 0),
            rightPreauricular: SIMD3<Float>(0.05, 0, 0)
        ) == nil)

        // Nasion collinear with the ear axis.
        #expect(HeadCoordinateFrame.solve(
            nasion: SIMD3<Float>(0.2, 0, 0),
            leftPreauricular: SIMD3<Float>(-0.075, 0, 0),
            rightPreauricular: SIMD3<Float>(0.075, 0, 0)
        ) == nil)
    }

    @Test func applyConvertsSessionToHeadFrameInMillimeters() throws {
        var session = ScanSession.newSession()
        session.fiducials = [
            FiducialAnnotation(kind: .nasion, coordinate: Coordinate3D(x: 0, y: 0.10, z: 0.02), state: .reviewed),
            FiducialAnnotation(kind: .leftPreauricular, coordinate: Coordinate3D(x: -0.075, y: 0, z: 0), state: .reviewed),
            FiducialAnnotation(kind: .rightPreauricular, coordinate: Coordinate3D(x: 0.075, y: 0, z: 0), state: .reviewed)
        ]
        session.electrodes = [
            ElectrodeAnnotation(label: "E1", role: .regular, coordinate: Coordinate3D(x: 0.075, y: 0, z: 0), confidence: 1, state: .detected)
        ]

        let converted = try #require(HeadCoordinateFrame.apply(to: session))
        #expect(converted.coordinateSpace == .headRASMillimeters)

        // The electrode sits exactly on RPA -> (+halfWidth mm, 0, 0). Ear spacing
        // 0.15 m -> half = 0.075 m -> 75 mm.
        let e = converted.electrodes[0].coordinate
        #expect(abs(e.x - 75) < 1e-2)
        #expect(abs(e.y) < 1e-2)
        #expect(abs(e.z) < 1e-2)
    }

    @Test func applyReturnsNilWhenFiducialsMissing() {
        let session = ScanSession.newSession() // fiducials have nil coordinates
        #expect(HeadCoordinateFrame.apply(to: session) == nil)
    }
}
