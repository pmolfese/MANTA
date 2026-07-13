import Testing
import simd
@testable import MANTACore

struct RobustPointSetCenterTests {
    @Test func agreeingClicksUseLeastSquaresCentroid() throws {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.002, 0, 0), SIMD3(0.004, 0, 0)
        ]
        let result = try #require(RobustPointSetCenter.fit(points))

        #expect(result.method == .leastSquaresCentroid)
        #expect(simd_distance(result.center, SIMD3(0.002, 0, 0)) < 1e-6)
        #expect(result.inlierCount == 3)
        #expect(result.outlierCount == 0)
    }

    @Test func outlyingClickFallsBackToMinimumDistanceObservation() throws {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.003, 0, 0), SIMD3(-0.002, 0, 0),
            SIMD3(0.085, 0, 0)
        ]
        let result = try #require(RobustPointSetCenter.fit(points))

        #expect(result.method == .minimumDistanceObservation)
        #expect(result.center == SIMD3(0.003, 0, 0))
        #expect(result.inlierCount == 3)
        #expect(result.outlierCount == 1)
        #expect(result.maximumInlierDistance < 0.006)
        #expect(result.maximumRawDistance > 0.08)
    }

    @Test func mutuallyInconsistentClicksDoNotPretendToAgree() throws {
        let points: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(0.08, 0, 0), SIMD3(0.16, 0, 0)
        ]
        let result = try #require(RobustPointSetCenter.fit(points))

        #expect(result.method == .minimumDistanceObservation)
        #expect(result.center == SIMD3(0.08, 0, 0))
        #expect(result.inlierCount == 1)
        #expect(result.outlierCount == 2)
    }
}
