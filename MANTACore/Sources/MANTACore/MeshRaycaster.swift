//
//  MeshRaycaster.swift
//  MANTACore
//
//  Ray/triangle-mesh intersection used to place fiducials on the reconstructed
//  head surface.
//
//  A tap becomes a world-space ray (origin + direction). This finds the nearest
//  point where that ray enters the LiDAR mesh. The routine is deliberately pure
//  geometry so the same code serves the live path (ray from the ARKit camera)
//  and the offline path (ray from the 3D model view's virtual camera), and can
//  be unit-tested without ARKit or SceneKit.
//

import Foundation
import simd

public enum MeshRaycaster {
    /// Nearest forward intersection of a ray with a triangle mesh, or nil if the
    /// ray misses every face.
    ///
    /// - Parameters:
    ///   - origin: ray origin in the same frame as `vertices` (ARKit world meters).
    ///   - direction: ray direction; need not be normalized.
    ///   - vertices: mesh vertices.
    ///   - triangleIndices: flat triples indexing `vertices` (length a multiple of 3).
    /// - Returns: the closest hit point strictly in front of `origin`.
    ///
    /// Triangles are treated as double-sided because reconstructed head-mesh
    /// winding is not guaranteed, so a fiducial tap lands whether the tapped
    /// facet faces toward or away from the camera.
    public static func firstHit(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        vertices: [SIMD3<Float>],
        triangleIndices: [UInt32]
    ) -> SIMD3<Float>? {
        let length = simd_length(direction)
        guard length > 1e-6 else { return nil }
        let dir = direction / length

        let epsilon: Float = 1e-7
        var nearestDistance = Float.greatestFiniteMagnitude
        var nearestHit: SIMD3<Float>?
        let triangleCount = triangleIndices.count / 3

        vertices.withUnsafeBufferPointer { vertexBuffer in
            triangleIndices.withUnsafeBufferPointer { indexBuffer in
                for triangle in 0..<triangleCount {
                    let i0 = Int(indexBuffer[triangle * 3])
                    let i1 = Int(indexBuffer[triangle * 3 + 1])
                    let i2 = Int(indexBuffer[triangle * 3 + 2])
                    guard i0 < vertexBuffer.count, i1 < vertexBuffer.count,
                          i2 < vertexBuffer.count else { continue }

                    // Möller–Trumbore.
                    let v0 = vertexBuffer[i0]
                    let edge1 = vertexBuffer[i1] - v0
                    let edge2 = vertexBuffer[i2] - v0
                    let pvec = simd_cross(dir, edge2)
                    let determinant = simd_dot(edge1, pvec)
                    if abs(determinant) < epsilon { continue } // ray parallel to triangle

                    let inverseDeterminant = 1 / determinant
                    let tvec = origin - v0
                    let u = simd_dot(tvec, pvec) * inverseDeterminant
                    if u < 0 || u > 1 { continue }

                    let qvec = simd_cross(tvec, edge1)
                    let v = simd_dot(dir, qvec) * inverseDeterminant
                    if v < 0 || u + v > 1 { continue }

                    let distance = simd_dot(edge2, qvec) * inverseDeterminant
                    if distance > epsilon, distance < nearestDistance {
                        nearestDistance = distance
                        nearestHit = origin + dir * distance
                    }
                }
            }
        }

        return nearestHit
    }
}
