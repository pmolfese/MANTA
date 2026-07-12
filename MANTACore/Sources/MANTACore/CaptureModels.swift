import Foundation

public struct ImageResolution: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct DepthSnapshotSummary: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var validPixelCount: Int
    public var minimumDepth: Float
    public var maximumDepth: Float
    public var meanDepth: Float
    public init(
        width: Int, height: Int, validPixelCount: Int, minimumDepth: Float, maximumDepth: Float,
        meanDepth: Float
    ) {
        self.width = width
        self.height = height
        self.validPixelCount = validPixelCount
        self.minimumDepth = minimumDepth
        self.maximumDepth = maximumDepth
        self.meanDepth = meanDepth
    }
}

public struct RawDepthFormat: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var scalarType: String
    public var byteOrder: String
    public var units: DistanceUnit
    public var layout: String
    public var compression: String
    public init(
        width: Int, height: Int, scalarType: String, byteOrder: String, units: DistanceUnit,
        layout: String,
        compression: String
    ) {
        self.width = width
        self.height = height
        self.scalarType = scalarType
        self.byteOrder = byteOrder
        self.units = units
        self.layout = layout
        self.compression = compression
    }
}

public struct ConfidenceMapSummary: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var lowConfidenceCount: Int
    public var mediumConfidenceCount: Int
    public var highConfidenceCount: Int
    public var unknownConfidenceCount: Int
    public init(
        width: Int, height: Int, lowConfidenceCount: Int, mediumConfidenceCount: Int,
        highConfidenceCount: Int, unknownConfidenceCount: Int
    ) {
        self.width = width
        self.height = height
        self.lowConfidenceCount = lowConfidenceCount
        self.mediumConfidenceCount = mediumConfidenceCount
        self.highConfidenceCount = highConfidenceCount
        self.unknownConfidenceCount = unknownConfidenceCount
    }
}

public struct RawConfidenceFormat: Codable, Equatable, Hashable, Sendable {
    public var width: Int
    public var height: Int
    public var scalarType: String
    public var valueMapping: [String: String]
    public var layout: String
    public var compression: String
    public init(
        width: Int, height: Int, scalarType: String, valueMapping: [String: String], layout: String,
        compression: String
    ) {
        self.width = width
        self.height = height
        self.scalarType = scalarType
        self.valueMapping = valueMapping
        self.layout = layout
        self.compression = compression
    }
}

public struct CaptureObservation: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var cameraTransform: [Float]
    public var cameraIntrinsics: [Float]
    public var imageResolution: ImageResolution
    public var hasSceneDepth: Bool
    public var meshAnchorCount: Int
    public var trackingSummary: String
    public var cameraSnapshotFilename: String?
    public var depthSnapshotFilename: String?
    public var rawDepthFilename: String?
    public var rawDepthFormat: RawDepthFormat?
    public var rawConfidenceFilename: String?
    public var rawConfidenceFormat: RawConfidenceFormat?
    public var confidenceSummary: ConfidenceMapSummary?
    public var depthSummary: DepthSnapshotSummary?
    public var quality: CaptureQualityMetrics?

    public init(
        id: UUID = UUID(), capturedAt: Date, cameraTransform: [Float], cameraIntrinsics: [Float],
        imageResolution: ImageResolution, hasSceneDepth: Bool, meshAnchorCount: Int,
        trackingSummary: String, cameraSnapshotFilename: String? = nil,
        depthSnapshotFilename: String? = nil, rawDepthFilename: String? = nil,
        rawDepthFormat: RawDepthFormat? = nil, rawConfidenceFilename: String? = nil,
        rawConfidenceFormat: RawConfidenceFormat? = nil,
        confidenceSummary: ConfidenceMapSummary? = nil,
        depthSummary: DepthSnapshotSummary? = nil,
        quality: CaptureQualityMetrics? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.cameraTransform = cameraTransform
        self.cameraIntrinsics = cameraIntrinsics
        self.imageResolution = imageResolution
        self.hasSceneDepth = hasSceneDepth
        self.meshAnchorCount = meshAnchorCount
        self.trackingSummary = trackingSummary
        self.cameraSnapshotFilename = cameraSnapshotFilename
        self.depthSnapshotFilename = depthSnapshotFilename
        self.rawDepthFilename = rawDepthFilename
        self.rawDepthFormat = rawDepthFormat
        self.rawConfidenceFilename = rawConfidenceFilename
        self.rawConfidenceFormat = rawConfidenceFormat
        self.confidenceSummary = confidenceSummary
        self.depthSummary = depthSummary
        self.quality = quality
    }
}

public struct CaptureQualityMetrics: Codable, Equatable, Hashable, Sendable {
    public var arFrameTimestamp: Double
    public var worldMappingStatus: String
    public var ambientIntensity: Double?
    public var ambientColorTemperature: Double?
    public var meanLuminance: Double
    public var darkPixelFraction: Double
    public var brightPixelFraction: Double
    public var sharpnessScore: Double
    public var translationFromPreviousSampleMeters: Double?
    public var rotationFromPreviousSampleDegrees: Double?
    public var coverageSector: String
    public var validDepthFraction: Double?
    public var highConfidenceDepthFraction: Double?
    public var warnings: [String]

    public init(
        arFrameTimestamp: Double, worldMappingStatus: String,
        ambientIntensity: Double?, ambientColorTemperature: Double?,
        meanLuminance: Double, darkPixelFraction: Double, brightPixelFraction: Double,
        sharpnessScore: Double, translationFromPreviousSampleMeters: Double?,
        rotationFromPreviousSampleDegrees: Double?, coverageSector: String,
        validDepthFraction: Double? = nil, highConfidenceDepthFraction: Double? = nil,
        warnings: [String] = []
    ) {
        self.arFrameTimestamp = arFrameTimestamp
        self.worldMappingStatus = worldMappingStatus
        self.ambientIntensity = ambientIntensity
        self.ambientColorTemperature = ambientColorTemperature
        self.meanLuminance = meanLuminance
        self.darkPixelFraction = darkPixelFraction
        self.brightPixelFraction = brightPixelFraction
        self.sharpnessScore = sharpnessScore
        self.translationFromPreviousSampleMeters = translationFromPreviousSampleMeters
        self.rotationFromPreviousSampleDegrees = rotationFromPreviousSampleDegrees
        self.coverageSector = coverageSector
        self.validDepthFraction = validDepthFraction
        self.highConfidenceDepthFraction = highConfidenceDepthFraction
        self.warnings = warnings
    }
}
