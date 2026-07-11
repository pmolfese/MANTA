//
//  PinholeCamera.swift
//  MANTA
//
//  Projection/unprojection between image pixels and ARKit world coordinates.
//
//  This is the geometric core of real electrode detection: a 2D detection in a
//  captured frame plus its metric depth becomes a 3D point in the same ARKit
//  world frame as the LiDAR mesh, so detections from many frames can be fused.
//
//  Conventions (ARKit):
//    - Camera space: +x right, +y up, +z toward the viewer. The camera looks
//      down -z, so points in front of the camera have negative z.
//    - `camera.intrinsics` operate in the vision pinhole frame (+x right,
//      +y down, +z forward into the scene), so y and z are flipped when
//      crossing between the two frames.
//    - Depth is metric distance in meters along the viewing axis, matching the
//      values ARKit stores in `sceneDepth.depthMap`.
//
//  The pure `project`/`unproject` pair are exact inverses, which is what the
//  unit tests lock down; the absolute sign conventions above can only be
//  confirmed against a real device capture.
//

import Foundation
import simd

struct PinholeCamera: Equatable {
    /// Focal lengths in pixels.
    var fx: Float
    var fy: Float
    /// Principal point in pixels.
    var cx: Float
    var cy: Float
    /// Camera-to-world transform (ARKit `camera.transform`).
    var cameraToWorld: simd_float4x4

    init(fx: Float, fy: Float, cx: Float, cy: Float, cameraToWorld: simd_float4x4) {
        self.fx = fx
        self.fy = fy
        self.cx = cx
        self.cy = cy
        self.cameraToWorld = cameraToWorld
    }

    /// Builds a camera from the flattened intrinsics (column-major 3x3) and
    /// camera transform (column-major 4x4) stored on a `CaptureObservation`.
    /// Returns nil if either array is the wrong length or the focal length is
    /// degenerate.
    init?(intrinsics: [Float], transform: [Float]) {
        guard intrinsics.count == 9, transform.count == 16 else { return nil }

        // Column-major 3x3: columns are [0,1,2], [3,4,5], [6,7,8].
        let fx = intrinsics[0]      // col0.row0
        let fy = intrinsics[4]      // col1.row1
        let cx = intrinsics[6]      // col2.row0
        let cy = intrinsics[7]      // col2.row1
        guard fx != 0, fy != 0 else { return nil }

        let cameraToWorld = simd_float4x4(
            SIMD4<Float>(transform[0], transform[1], transform[2], transform[3]),
            SIMD4<Float>(transform[4], transform[5], transform[6], transform[7]),
            SIMD4<Float>(transform[8], transform[9], transform[10], transform[11]),
            SIMD4<Float>(transform[12], transform[13], transform[14], transform[15])
        )

        self.init(fx: fx, fy: fy, cx: cx, cy: cy, cameraToWorld: cameraToWorld)
    }

    /// Projects a world point to a pixel plus its metric depth (distance along
    /// the viewing axis). Returns nil when the point is on or behind the image
    /// plane.
    func project(_ worldPoint: SIMD3<Float>) -> (pixel: SIMD2<Float>, depth: Float)? {
        let camera = cameraToWorld.inverse * SIMD4<Float>(worldPoint, 1)

        // ARKit camera space -> vision pinhole frame (flip y and z).
        let forward = -camera.z
        guard forward > 0 else { return nil }

        let u = fx * (camera.x / forward) + cx
        let v = fy * (-camera.y / forward) + cy
        return (SIMD2<Float>(u, v), forward)
    }

    /// Unprojects a pixel at the given metric depth back to an ARKit world point.
    func unproject(pixel: SIMD2<Float>, depth: Float) -> SIMD3<Float> {
        // Pixel -> normalized ray in the vision pinhole frame.
        let nx = (pixel.x - cx) / fx
        let ny = (pixel.y - cy) / fy

        // Scale by depth, then flip y and z back into ARKit camera space.
        let camera = SIMD4<Float>(nx * depth, -ny * depth, -depth, 1)
        let world = cameraToWorld * camera
        return SIMD3<Float>(world.x, world.y, world.z)
    }
}
