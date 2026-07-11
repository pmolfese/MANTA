//
//  PinholeCameraTests.swift
//  MANTATests
//
//  Locks the project/unproject pair as exact inverses across a range of poses,
//  which is the correctness guarantee the detection back-projection relies on.
//

import Foundation
import Testing
import simd
import MANTACore

struct PinholeCameraTests {
    /// A representative iPad-class intrinsics/pose, flattened as stored on a
    /// CaptureObservation (column-major).
    private func sampleCamera(translation: SIMD3<Float>, angle: Float) -> PinholeCamera {
        let fx: Float = 1600
        let fy: Float = 1600
        let cx: Float = 960
        let cy: Float = 720

        let rotation = simd_float3x3(simd_quatf(angle: angle, axis: simd_normalize(SIMD3<Float>(0.3, 1, 0.2))))
        let cameraToWorld = simd_float4x4(
            SIMD4<Float>(rotation.columns.0, 0),
            SIMD4<Float>(rotation.columns.1, 0),
            SIMD4<Float>(rotation.columns.2, 0),
            SIMD4<Float>(translation, 1)
        )
        return PinholeCamera(fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: cameraToWorld)
    }

    @Test func projectUnprojectRoundTrips() throws {
        let camera = sampleCamera(translation: SIMD3<Float>(0.1, -0.2, 0.3), angle: 0.6)

        // A grid of points in front of the camera (ARKit: negative z in camera space,
        // here expressed via world points that land in front once transformed).
        let localPoints: [SIMD3<Float>] = [
            SIMD3<Float>(0.0, 0.0, -0.5),
            SIMD3<Float>(0.1, 0.05, -0.7),
            SIMD3<Float>(-0.12, 0.2, -1.0),
            SIMD3<Float>(0.25, -0.15, -0.9)
        ]
        let worldPoints: [SIMD3<Float>] = localPoints.map { local in
            let w = camera.cameraToWorld * SIMD4<Float>(local, 1)
            return SIMD3<Float>(w.x, w.y, w.z)
        }

        for world in worldPoints {
            let projected = try #require(camera.project(world))
            let recovered = camera.unproject(pixel: projected.pixel, depth: projected.depth)
            #expect(simd_distance(recovered, world) < 1e-3)
        }
    }

    @Test func pointsBehindCameraDoNotProject() {
        let camera = sampleCamera(translation: .zero, angle: 0)
        // In ARKit camera space the camera looks down -z, so a point at +z is behind it.
        let behind = SIMD3<Float>(0, 0, 0.5)
        #expect(camera.project(behind) == nil)
    }

    @Test func principalRayLandsOnPrincipalPoint() throws {
        let camera = sampleCamera(translation: .zero, angle: 0)
        // A point straight ahead (camera -z) should image at the principal point.
        let ahead = SIMD3<Float>(0, 0, -1.0)
        let projected = try #require(camera.project(ahead))
        #expect(abs(projected.pixel.x - camera.cx) < 1e-2)
        #expect(abs(projected.pixel.y - camera.cy) < 1e-2)
        #expect(abs(projected.depth - 1.0) < 1e-4)
    }

    @Test func initFromFlattenedArraysMatchesDirectInit() throws {
        let intrinsics: [Float] = [1600, 0, 0, 0, 1600, 0, 960, 720, 1]
        let transform: [Float] = [
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0.1, -0.2, 0.3, 1
        ]
        let camera = try #require(PinholeCamera(intrinsics: intrinsics, transform: transform))
        #expect(camera.fx == 1600)
        #expect(camera.fy == 1600)
        #expect(camera.cx == 960)
        #expect(camera.cy == 720)
        #expect(camera.cameraToWorld.columns.3.x == 0.1)
        #expect(camera.cameraToWorld.columns.3.z == 0.3)
    }

    @Test func malformedArraysReturnNil() {
        #expect(PinholeCamera(intrinsics: [1, 2, 3], transform: Array(repeating: 0, count: 16)) == nil)
        let zeroFocal: [Float] = [0, 0, 0, 0, 0, 0, 960, 720, 1]
        #expect(PinholeCamera(intrinsics: zeroFocal, transform: Array(repeating: 0, count: 16)) == nil)
    }
}
