//
//  MultiViewTriangulation.swift
//  MANTACore
//
//  Depth-free 3D point recovery from several camera rays. Clicking the same
//  landmark in multiple photos gives one ray per view; the landmark is where
//  those rays best intersect. Unlike reading a single frame's depth map - which
//  on a grazing surface (a cap-covered vertex) grabs the nearest electrode or the
//  silhouette - triangulation uses only the camera geometry, so a systematic
//  per-frame depth bias cannot corrupt it.
//

import Foundation
import simd

public enum MultiViewTriangulation {
    public struct Result: Equatable, Sendable {
        /// The least-squares intersection point, in the rays' shared world frame.
        public var point: SIMD3<Float>
        /// RMS perpendicular distance from `point` to the input rays, in meters.
        /// A large value means the rays don't agree - the clicks disagree across
        /// views, so the point is unreliable.
        public var rmsMeters: Float
        /// Number of rays that contributed.
        public var rayCount: Int

        public init(point: SIMD3<Float>, rmsMeters: Float, rayCount: Int) {
            self.point = point
            self.rmsMeters = rmsMeters
            self.rayCount = rayCount
        }
    }

    /// Least-squares closest point to a bundle of rays. Each ray is an origin and
    /// a direction (need not be normalized). Returns nil with fewer than 2 usable
    /// rays or when the rays are near-parallel (degenerate, no stable crossing).
    ///
    /// Minimizes Σ dist(point, rayᵢ)². For a unit direction dᵢ the squared
    /// perpendicular distance is (x−oᵢ)ᵀ(I − dᵢdᵢᵀ)(x−oᵢ), so the optimum solves
    /// (Σ Aᵢ) x = Σ Aᵢ oᵢ with Aᵢ = I − dᵢdᵢᵀ.
    public static func triangulate(
        rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)]
    ) -> Result? {
        var normalized = [(origin: SIMD3<Double>, direction: SIMD3<Double>)]()
        for ray in rays {
            let length = simd_length(ray.direction)
            guard length > 1e-9 else { continue }
            normalized.append((SIMD3<Double>(ray.origin), SIMD3<Double>(ray.direction) / Double(length)))
        }
        guard normalized.count >= 2 else { return nil }

        var a = simd_double3x3(0)
        var b = SIMD3<Double>(repeating: 0)
        let identity = matrix_identity_double3x3
        for ray in normalized {
            let d = ray.direction
            // Outer product d dᵀ.
            let outer = simd_double3x3(d * d.x, d * d.y, d * d.z)
            let projection = identity - outer
            a += projection
            b += projection * ray.origin
        }

        guard let inverse = invert(a) else { return nil }
        let solution = inverse * b
        let point = SIMD3<Float>(solution)

        var sumSquared = 0.0
        for ray in normalized {
            let delta = solution - ray.origin
            let along = simd_dot(delta, ray.direction)
            let perpendicular = delta - along * ray.direction
            sumSquared += simd_length_squared(perpendicular)
        }
        let rms = Float((sumSquared / Double(normalized.count)).squareRoot())
        return Result(point: point, rmsMeters: rms, rayCount: normalized.count)
    }

    /// Inverts a 3x3 matrix, returning nil when it is singular / ill-conditioned
    /// (rays effectively parallel, so no stable intersection).
    private static func invert(_ m: simd_double3x3) -> simd_double3x3? {
        let determinant = m.determinant
        guard determinant.isFinite, abs(determinant) > 1e-12 else { return nil }
        return m.inverse
    }
}
