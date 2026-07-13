//
//  MANTABundleFormat.swift
//  MANTACore
//
//  Versioned, portable metadata for the .manta capture interchange format.
//

import Foundation

public enum MANTABundleFormat {
    public static let identifier = "org.nih.manta.capture-bundle"
    public static let currentSchemaVersion = "1.0.0"
    public static let supportedMajorVersion = 1
    public static let manifestFilename = "manifest.json"
    public static let manifestSchema = "https://manta.local/schemas/bundle-manifest-1.0.0.json"
    public static let captureSchema = "https://manta.local/schemas/capture-1.0.0.json"
    public static let changeLogSchema = "https://manta.local/schemas/change-log-1.0.0.json"
}

public enum MANTABundleFilename {
    /// PHI-safe archive name in UTC, for example `20260711_133022.manta`.
    public static func timestamped(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "\(formatter.string(from: date)).manta"
    }
}

public struct MANTASemanticVersion: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init?(_ value: String) {
        let core = value.split(separator: "-", maxSplits: 1).first ?? ""
        let parts = core.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              let patch = Int(parts[2]),
              major >= 0, minor >= 0, patch >= 0 else {
            return nil
        }
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

public struct MANTABundleManifest: Codable, Equatable, Sendable {
    public var schema: String
    public var format: String
    public var schemaVersion: String
    public var bundleID: UUID
    public var parentBundleID: UUID?
    public var sessionID: UUID
    public var createdAt: Date
    public var finalizedAt: Date
    public var producer: MANTAProducer
    public var content: MANTAContentReferences
    public var files: [MANTAFileEntry]

    public init(
        schema: String,
        format: String = MANTABundleFormat.identifier,
        schemaVersion: String = MANTABundleFormat.currentSchemaVersion,
        bundleID: UUID,
        parentBundleID: UUID? = nil,
        sessionID: UUID,
        createdAt: Date,
        finalizedAt: Date,
        producer: MANTAProducer,
        content: MANTAContentReferences,
        files: [MANTAFileEntry]
    ) {
        self.schema = schema
        self.format = format
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.parentBundleID = parentBundleID
        self.sessionID = sessionID
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        self.producer = producer
        self.content = content
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case format, schemaVersion, bundleID, parentBundleID, sessionID, createdAt, finalizedAt
        case producer, content, files
    }
}

public struct MANTAProducer: Codable, Equatable, Sendable {
    public var application: String
    public var version: String
    public var build: String
    public var platform: String
    public var operatingSystemVersion: String
    public var deviceModel: String

    public init(
        application: String,
        version: String,
        build: String,
        platform: String,
        operatingSystemVersion: String,
        deviceModel: String
    ) {
        self.application = application
        self.version = version
        self.build = build
        self.platform = platform
        self.operatingSystemVersion = operatingSystemVersion
        self.deviceModel = deviceModel
    }
}

public struct MANTAContentReferences: Codable, Equatable, Sendable {
    public var capture: String
    public var subject: String?
    public var layout: String?
    public var changeLog: String?

    public init(
        capture: String,
        subject: String? = nil,
        layout: String? = nil,
        changeLog: String? = nil
    ) {
        self.capture = capture
        self.subject = subject
        self.layout = layout
        self.changeLog = changeLog
    }
}

public struct MANTAChangeLogDocument: Codable, Equatable, Sendable {
    public var schema: String
    public var schemaVersion: String
    public var bundleID: UUID
    public var parentBundleID: UUID
    public var createdAt: Date
    public var producer: MANTAProducer
    public var changes: [MANTAChangeRecord]

    public init(
        schema: String,
        schemaVersion: String = MANTABundleFormat.currentSchemaVersion,
        bundleID: UUID,
        parentBundleID: UUID,
        createdAt: Date,
        producer: MANTAProducer,
        changes: [MANTAChangeRecord]
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.bundleID = bundleID
        self.parentBundleID = parentBundleID
        self.createdAt = createdAt
        self.producer = producer
        self.changes = changes
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion, bundleID, parentBundleID, createdAt, producer, changes
    }
}

public struct MANTAChangeRecord: Codable, Equatable, Sendable {
    public var id: UUID
    public var changedAt: Date
    public var category: String
    public var summary: String
    public var targets: [String]

    public init(
        id: UUID = UUID(),
        changedAt: Date,
        category: String,
        summary: String,
        targets: [String] = []
    ) {
        self.id = id
        self.changedAt = changedAt
        self.category = category
        self.summary = summary
        self.targets = targets
    }
}

public struct MANTAFileEntry: Codable, Equatable, Sendable {
    public var path: String
    public var mediaType: String
    public var role: String
    public var size: Int64
    public var sha256: String

    public init(path: String, mediaType: String, role: String, size: Int64, sha256: String) {
        self.path = path
        self.mediaType = mediaType
        self.role = role
        self.size = size
        self.sha256 = sha256
    }
}

public struct MANTACaptureDocument: Codable, Equatable, Sendable {
    public var schema: String
    public var schemaVersion: String
    public var sessionID: UUID
    public var captureMode: String
    public var layoutID: String
    public var coordinateSystems: [MANTACoordinateSystem]
    public var observations: [MANTACaptureObservation]
    /// Placed anatomical landmarks (nasion/LPA/RPA) in a declared coordinate
    /// system. Optional and additive: older bundles omit it.
    public var fiducials: [MANTAFiducialSolution]?
    /// Solved electrode positions in a declared coordinate system. Optional and
    /// additive so the receiver can re-read the solution alongside raw capture.
    public var electrodes: [MANTAElectrodeSolution]?
    /// Optional reconstructed surfaces and the transform required to display
    /// model-space ObjectCapture assets with ARKit-world annotations.
    public var reconstruction: MANTAReconstructionReference?

    public init(
        schema: String,
        schemaVersion: String = MANTABundleFormat.currentSchemaVersion,
        sessionID: UUID,
        captureMode: String,
        layoutID: String,
        coordinateSystems: [MANTACoordinateSystem],
        observations: [MANTACaptureObservation],
        fiducials: [MANTAFiducialSolution]? = nil,
        electrodes: [MANTAElectrodeSolution]? = nil,
        reconstruction: MANTAReconstructionReference? = nil
    ) {
        self.schema = schema
        self.schemaVersion = schemaVersion
        self.sessionID = sessionID
        self.captureMode = captureMode
        self.layoutID = layoutID
        self.coordinateSystems = coordinateSystems
        self.observations = observations
        self.fiducials = fiducials
        self.electrodes = electrodes
        self.reconstruction = reconstruction
    }

    enum CodingKeys: String, CodingKey {
        case schema = "$schema"
        case schemaVersion, sessionID, captureMode, layoutID, coordinateSystems, observations
        case fiducials, electrodes, reconstruction
    }
}

public struct MANTAReconstructionReference: Codable, Equatable, Sendable {
    public var lidarMeshPath: String?
    public var objectCaptureModelPath: String?
    /// Column-major 4x4 transform from ObjectCapture model coordinates to the
    /// coordinate system identified by `worldCoordinateSystem`.
    public var modelToWorld: [Double]?
    public var worldCoordinateSystem: String

    public init(
        lidarMeshPath: String? = nil,
        objectCaptureModelPath: String? = nil,
        modelToWorld: [Double]? = nil,
        worldCoordinateSystem: String = "arkit-world"
    ) {
        self.lidarMeshPath = lidarMeshPath
        self.objectCaptureModelPath = objectCaptureModelPath
        self.modelToWorld = modelToWorld
        self.worldCoordinateSystem = worldCoordinateSystem
    }
}

/// A placed anatomical landmark in a declared coordinate system. `coordinate`
/// is nil when the landmark has not been marked.
public struct MANTAFiducialSolution: Codable, Equatable, Sendable {
    public var kind: String
    public var coordinateSystem: String
    public var coordinate: [Double]?
    public var state: String

    public init(kind: String, coordinateSystem: String, coordinate: [Double]?, state: String) {
        self.kind = kind
        self.coordinateSystem = coordinateSystem
        self.coordinate = coordinate
        self.state = state
    }
}

/// A solved electrode position in a declared coordinate system.
public struct MANTAElectrodeSolution: Codable, Equatable, Sendable {
    public var label: String
    public var role: String
    public var coordinateSystem: String
    public var coordinate: [Double]
    public var confidence: Double
    public var state: String

    public init(
        label: String, role: String, coordinateSystem: String,
        coordinate: [Double], confidence: Double, state: String
    ) {
        self.label = label
        self.role = role
        self.coordinateSystem = coordinateSystem
        self.coordinate = coordinate
        self.confidence = confidence
        self.state = state
    }
}

public struct MANTACoordinateSystem: Codable, Equatable, Sendable {
    public var id: String
    public var handedness: String
    public var units: DistanceUnit
    public var description: String

    public init(id: String, handedness: String, units: DistanceUnit, description: String) {
        self.id = id
        self.handedness = handedness
        self.units = units
        self.description = description
    }
}

public struct MANTAImageDimensions: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct MANTACaptureObservation: Codable, Equatable, Sendable {
    public var id: UUID
    public var capturedAt: Date
    public var imagePath: String?
    public var imageDimensions: MANTAImageDimensions
    public var imageOrigin: String
    public var imageOrientation: String
    public var intrinsics: [Double]
    public var cameraToWorld: [Double]
    public var worldCoordinateSystem: String
    public var depth: MANTADepthArtifact?
    public var trackingState: String
    public var quality: CaptureQualityMetrics?

    public init(
        id: UUID,
        capturedAt: Date,
        imagePath: String? = nil,
        imageDimensions: MANTAImageDimensions,
        imageOrigin: String = "top-left",
        imageOrientation: String = "up",
        intrinsics: [Double],
        cameraToWorld: [Double],
        worldCoordinateSystem: String = "arkit-world",
        depth: MANTADepthArtifact? = nil,
        trackingState: String,
        quality: CaptureQualityMetrics? = nil
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.imagePath = imagePath
        self.imageDimensions = imageDimensions
        self.imageOrigin = imageOrigin
        self.imageOrientation = imageOrientation
        self.intrinsics = intrinsics
        self.cameraToWorld = cameraToWorld
        self.worldCoordinateSystem = worldCoordinateSystem
        self.depth = depth
        self.trackingState = trackingState
        self.quality = quality
    }
}

public struct MANTADepthArtifact: Codable, Equatable, Sendable {
    public var path: String
    public var confidencePath: String?
    public var dimensions: MANTAImageDimensions
    public var scalarType: String
    public var byteOrder: String
    public var units: DistanceUnit
    public var layout: String
    public var compression: String
    public var imageMapping: String

    public init(
        path: String,
        confidencePath: String? = nil,
        dimensions: MANTAImageDimensions,
        scalarType: String = "float32",
        byteOrder: String = "little-endian",
        units: DistanceUnit = .meters,
        layout: String = "row-major",
        compression: String = "zlib",
        imageMapping: String = "resolution-scale"
    ) {
        self.path = path
        self.confidencePath = confidencePath
        self.dimensions = dimensions
        self.scalarType = scalarType
        self.byteOrder = byteOrder
        self.units = units
        self.layout = layout
        self.compression = compression
        self.imageMapping = imageMapping
    }
}

public enum MANTAJSON {
    public static func canonicalData<T: Encodable>(_ value: T) throws -> Data {
        try makeEncoder().encode(value)
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) {
                return date
            }
            let wholeSeconds = ISO8601DateFormatter()
            wholeSeconds.formatOptions = [.withInternetDateTime]
            if let date = wholeSeconds.date(from: string) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an RFC 3339/ISO 8601 date."
            )
        }
        return decoder
    }

    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            try container.encode(formatter.string(from: date))
        }
        return encoder
    }
}
