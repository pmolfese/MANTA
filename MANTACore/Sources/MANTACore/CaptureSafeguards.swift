/// Conservative acquisition limits, in decimal bytes. The reserve is headroom,
/// not a guarantee against other processes consuming space concurrently.
public enum CaptureStoragePolicy {
    public static let warningBytes: Int64 = 3_000_000_000
    public static let reserveBytes: Int64 = 1_000_000_000

    public enum State: String, Sendable {
        case ready, warning, stop, unavailable
        public var allowsCapture: Bool { self == .ready || self == .warning }
    }

    public static func evaluate(availableBytes: Int64?) -> State {
        guard let bytes = availableBytes, bytes >= 0 else { return .unavailable }
        if bytes <= reserveBytes { return .stop }
        if bytes < warningBytes { return .warning }
        return .ready
    }
}

public enum CapturePreset: String, CaseIterable, Sendable {
    case baseline = "Baseline RGB-D"
    case validation = "Validation experiments"

    public var selectsBestFrames: Bool { self == .validation }
    public var savesComparisonFrames: Bool { self == .validation }
    public var capturesHighResolutionStills: Bool { self == .validation }

    public static func name(usesDepth: Bool, bestFrames: Bool, comparisonFrames: Bool,
                            highResolutionStills: Bool) -> String {
        guard usesDepth else { return "Custom" }
        if !bestFrames && !comparisonFrames && !highResolutionStills { return baseline.rawValue }
        if bestFrames && comparisonFrames && highResolutionStills { return validation.rawValue }
        return "Custom"
    }
}
