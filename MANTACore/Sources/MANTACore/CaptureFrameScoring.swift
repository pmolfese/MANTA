import Foundation

/// Provisional, dimensionless ranking within a bounded capture window. It is not
/// a quality threshold. Device validation is required before enabling by default.
public enum CaptureFrameScoring {
    public static func score(sharpness: Double, angularSpeedDegrees: Double,
                             translationMeters: Double, rotationDegrees: Double) -> Double {
        guard [sharpness, angularSpeedDegrees, translationMeters, rotationDegrees].allSatisfy(\.isFinite) else { return 0 }
        let novelty = min(1, max(0, translationMeters) / 0.03 + max(0, rotationDegrees) / 10)
        return log1p(max(0, sharpness)) * (0.5 + 0.5 * novelty)
            / (1 + max(0, angularSpeedDegrees) / 45)
    }
}
