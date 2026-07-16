import Foundation
import Testing
import simd
@testable import MANTACore

struct MultiViewTriangulationTests {
    @Test func recoversPointFromCleanRays() throws {
        let truth = SIMD3<Float>(0.05, -0.10, -0.60)
        // Cameras scattered around, each ray aimed exactly at the truth point.
        let cameras: [SIMD3<Float>] = [
            SIMD3(0.4, 0.1, 0.0), SIMD3(-0.3, 0.2, -0.1),
            SIMD3(0.0, -0.4, 0.2), SIMD3(0.2, 0.3, 0.3)
        ]
        let rays = cameras.map { (origin: $0, direction: truth - $0) }
        let result = try #require(MultiViewTriangulation.triangulate(rays: rays))
        #expect(simd_distance(result.point, truth) < 1e-4)
        #expect(result.rmsMeters < 1e-4)
        #expect(result.rayCount == 4)
    }

    @Test func rmsReflectsDisagreementBetweenRays() throws {
        let truth = SIMD3<Float>(0.0, 0.0, -0.5)
        var rays = [(origin: SIMD3<Float>, direction: SIMD3<Float>)]()
        let cameras: [SIMD3<Float>] = [
            SIMD3(0.3, 0.0, 0.0), SIMD3(-0.3, 0.0, 0.0), SIMD3(0.0, 0.3, 0.0)
        ]
        for camera in cameras { rays.append((camera, truth - camera)) }
        // A fourth ray that points somewhere else entirely (a bad click).
        rays.append((SIMD3(0.0, -0.3, 0.0), SIMD3(0.2, 0.2, -0.5)))
        let result = try #require(MultiViewTriangulation.triangulate(rays: rays))
        #expect(result.rmsMeters > 0.01)   // the outlier ray inflates the residual
    }

    @Test func rejectsParallelRays() {
        let rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = [
            (SIMD3(0, 0, 0), SIMD3(0, 0, -1)),
            (SIMD3(0.1, 0, 0), SIMD3(0, 0, -1))   // parallel, no crossing
        ]
        #expect(MultiViewTriangulation.triangulate(rays: rays) == nil)
    }

    @Test func rejectsTooFewRays() {
        let rays: [(origin: SIMD3<Float>, direction: SIMD3<Float>)] = [
            (SIMD3(0, 0, 0), SIMD3(1, 0, -1))
        ]
        #expect(MultiViewTriangulation.triangulate(rays: rays) == nil)
    }
}
