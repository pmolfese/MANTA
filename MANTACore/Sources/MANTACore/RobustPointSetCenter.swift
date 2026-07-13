import Foundation
import simd

/// A representative point for repeated observations of the same physical
/// landmark. The centroid is the least-squares solution when the observations
/// agree. If they do not, the medoid is the observed point with the lowest
/// total squared distance to the set, so an outlier cannot pull the result into
/// empty space between surfaces.
public struct RobustPointSetCenterResult: Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case singleObservation = "single-observation"
        case leastSquaresCentroid = "least-squares-centroid"
        case minimumDistanceObservation = "minimum-distance-observation"
    }

    public var center: SIMD3<Float>
    public var method: Method
    public var totalCount: Int
    public var inlierCount: Int
    public var rmsInlierDistance: Float
    public var maximumInlierDistance: Float
    public var maximumRawDistance: Float

    public var outlierCount: Int { totalCount - inlierCount }

    public init(
        center: SIMD3<Float>,
        method: Method,
        totalCount: Int,
        inlierCount: Int,
        rmsInlierDistance: Float,
        maximumInlierDistance: Float,
        maximumRawDistance: Float
    ) {
        self.center = center
        self.method = method
        self.totalCount = totalCount
        self.inlierCount = inlierCount
        self.rmsInlierDistance = rmsInlierDistance
        self.maximumInlierDistance = maximumInlierDistance
        self.maximumRawDistance = maximumRawDistance
    }
}

public enum RobustPointSetCenter {
    /// Fits a center to repeated metric observations. `agreementRadius` is a
    /// radial tolerance in the same units as the points (meters for MANTA).
    public static func fit(
        _ points: [SIMD3<Float>], agreementRadius: Float = 0.025
    ) -> RobustPointSetCenterResult? {
        guard !points.isEmpty,
              agreementRadius.isFinite, agreementRadius > 0,
              points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite }) else {
            return nil
        }

        if points.count == 1 {
            return RobustPointSetCenterResult(
                center: points[0], method: .singleObservation,
                totalCount: 1, inlierCount: 1,
                rmsInlierDistance: 0, maximumInlierDistance: 0,
                maximumRawDistance: 0)
        }

        let centroid = points.reduce(.zero, +) / Float(points.count)
        let centroidDistances = points.map { simd_distance($0, centroid) }
        let centroidMaximum = centroidDistances.max() ?? 0

        let center: SIMD3<Float>
        let method: RobustPointSetCenterResult.Method
        if centroidMaximum <= agreementRadius {
            center = centroid
            method = .leastSquaresCentroid
        } else {
            // For squared distance, the observation with minimum total cost is
            // also the observation closest to the least-squares centroid.
            center = points.min {
                simd_length_squared($0 - centroid) < simd_length_squared($1 - centroid)
            } ?? centroid
            method = .minimumDistanceObservation
        }

        let distances = points.map { simd_distance($0, center) }
        let inlierDistances = distances.filter { $0 <= agreementRadius }
        let sumSquared = inlierDistances.reduce(Float.zero) { $0 + $1 * $1 }
        let rms = inlierDistances.isEmpty
            ? .infinity : (sumSquared / Float(inlierDistances.count)).squareRoot()

        return RobustPointSetCenterResult(
            center: center,
            method: method,
            totalCount: points.count,
            inlierCount: inlierDistances.count,
            rmsInlierDistance: rms,
            maximumInlierDistance: inlierDistances.max() ?? .infinity,
            maximumRawDistance: distances.max() ?? 0)
    }
}
