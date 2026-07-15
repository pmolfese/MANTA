import Foundation

public struct Coordinate3D: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double
    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }
    public static let zero = Coordinate3D(x: 0, y: 0, z: 0)

    public func converted(from source: DistanceUnit, to target: DistanceUnit) -> Coordinate3D {
        Coordinate3D(
            x: source.convert(x, to: target), y: source.convert(y, to: target),
            z: source.convert(z, to: target))
    }
}

public struct Coordinate2D: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
    public static let zero = Coordinate2D(x: 0, y: 0)
}

public enum ElectrodeRole: String, CaseIterable, Codable, Identifiable, Sendable {
    case cardinal = "Cardinal"
    case regular = "Regular"
    public var id: String { rawValue }
}

public enum AnnotationState: String, CaseIterable, Codable, Identifiable, Sendable {
    case detected = "Detected"
    case reviewed = "Reviewed"
    case needsReview = "Needs Review"
    case missing = "Missing"
    public var id: String { rawValue }
}

public struct ElectrodeAnnotation: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var label: String
    public var role: ElectrodeRole
    public var coordinate: Coordinate3D
    public var confidence: Double
    public var state: AnnotationState
    public init(
        id: UUID = UUID(), label: String, role: ElectrodeRole, coordinate: Coordinate3D,
        confidence: Double, state: AnnotationState
    ) {
        self.id = id
        self.label = label
        self.role = role
        self.coordinate = coordinate
        self.confidence = confidence
        self.state = state
    }
}

public enum FiducialKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case nasion = "Nasion"
    case leftPreauricular = "LPA"
    case rightPreauricular = "RPA"
    /// Vertex / Cz. Off the nasion–LPA–RPA plane, so it is not an EEG cardinal
    /// fiducial but an optional stabilizer for world alignment: three coplanar
    /// landmarks admit a mirror-image fit and leave the off-plane rotation
    /// under-constrained, which throws scalp points far off the surface. Cz
    /// breaks that degeneracy. Excluded from capture gating and EEG fiducial
    /// exports (see `cardinal`); used by the manual alignment solver when placed.
    case vertex = "Cz"
    public var id: String { rawValue }

    /// The three EEG cardinal fiducials. Use this — not `allCases` — wherever the
    /// nasion/LPA/RPA anatomical basis is what is meant (capture completion,
    /// head-coordinate frame, EEG fiducial exports). `allCases` additionally
    /// includes `.vertex`, which is only an alignment aid.
    public static let cardinal: [FiducialKind] = [.nasion, .leftPreauricular, .rightPreauricular]

    /// Whether this landmark is one of the three EEG cardinal fiducials.
    public var isCardinal: Bool { Self.cardinal.contains(self) }
}

public struct FiducialAnnotation: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var kind: FiducialKind
    public var coordinate: Coordinate3D?
    public var state: AnnotationState
    public init(
        id: UUID = UUID(), kind: FiducialKind, coordinate: Coordinate3D?, state: AnnotationState
    ) {
        self.id = id
        self.kind = kind
        self.coordinate = coordinate
        self.state = state
    }
}

/// Evidence retained for every fiducial placement or replacement. The final
/// annotation remains convenient for consumers, while this history preserves
/// how the point was obtained so alternative head-frame solvers can audit it.
public struct FiducialPlacementEvidence: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var kind: FiducialKind
    public var placedAt: Date
    public var source: String
    public var hitMethod: String
    public var coordinateSystem: String
    public var coordinate: Coordinate3D
    public var observationID: UUID?
    public var imagePoint: Coordinate2D?
    public var pointCoordinateSpace: String?
    public var rayOrigin: Coordinate3D?
    public var rayDirection: Coordinate3D?

    public init(
        id: UUID = UUID(), kind: FiducialKind, placedAt: Date = Date(),
        source: String, hitMethod: String, coordinateSystem: String,
        coordinate: Coordinate3D, observationID: UUID? = nil,
        imagePoint: Coordinate2D? = nil, pointCoordinateSpace: String? = nil,
        rayOrigin: Coordinate3D? = nil,
        rayDirection: Coordinate3D? = nil
    ) {
        self.id = id
        self.kind = kind
        self.placedAt = placedAt
        self.source = source
        self.hitMethod = hitMethod
        self.coordinateSystem = coordinateSystem
        self.coordinate = coordinate
        self.observationID = observationID
        self.imagePoint = imagePoint
        self.pointCoordinateSpace = pointCoordinateSpace
        self.rayOrigin = rayOrigin
        self.rayDirection = rayDirection
    }
}

/// Structured context collected with every scan. All fields are optional so a
/// technical capture can begin immediately and be annotated as details become
/// available without inventing placeholder values.
public struct AcquisitionContext: Codable, Equatable, Hashable, Sendable {
    public var site: String?
    public var operatorID: String?
    public var netModel: String?
    public var netIdentifier: String?
    public var capSize: String?
    public var acquisitionEquipment: String?
    public var deviceSetup: String?
    public var lighting: String?
    public var capCondition: String?
    public var participantFactors: String?
    public var notes: String?

    public init(
        site: String? = nil, operatorID: String? = nil, netModel: String? = nil,
        netIdentifier: String? = nil, capSize: String? = nil,
        acquisitionEquipment: String? = nil, deviceSetup: String? = nil,
        lighting: String? = nil, capCondition: String? = nil,
        participantFactors: String? = nil, notes: String? = nil
    ) {
        self.site = site
        self.operatorID = operatorID
        self.netModel = netModel
        self.netIdentifier = netIdentifier
        self.capSize = capSize
        self.acquisitionEquipment = acquisitionEquipment
        self.deviceSetup = deviceSetup
        self.lighting = lighting
        self.capCondition = capCondition
        self.participantFactors = participantFactors
        self.notes = notes
    }
}

public struct ElectrodeDefinition: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var number: Int
    public var label: String
    public var role: ElectrodeRole
    public var coordinatePrior: Coordinate3D
    public var displayPosition: Coordinate2D?
    public var neighbors: [Int]
    public var id: Int { number }
    public init(
        number: Int, label: String, role: ElectrodeRole, coordinatePrior: Coordinate3D,
        displayPosition: Coordinate2D?, neighbors: [Int]
    ) {
        self.number = number
        self.label = label
        self.role = role
        self.coordinatePrior = coordinatePrior
        self.displayPosition = displayPosition
        self.neighbors = neighbors
    }
}

public enum CaptureMode: String, CaseIterable, Codable, Equatable, Identifiable, Sendable {
    case lidar = "LiDAR"
    case photogrammetry = "Photogrammetry"
    case both = "Both"
    public var id: String { rawValue }
    public var usesLiDAR: Bool { self != .photogrammetry }
    public var usesPhotogrammetry: Bool { self != .lidar }
}

public struct ElectrodeLayout: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var channelCount: Int
    public var labels: [String]
    public var cardinalLabels: Set<String>
    public var electrodes: [ElectrodeDefinition]
    public var fiducialCoordinatePriors: [FiducialKind: Coordinate3D]
    public var fiducialSensorHints: [FiducialKind: Int]
    public var referenceSensor: Int?
    public var referenceLabel: String?
    /// Coordinate prior for the physical reference/vertex sensor (Cz for the
    /// bundled HydroCel nets). Kept separate from the three anatomical
    /// fiducials so head-coordinate readiness remains Nasion/LPA/RPA-only.
    public var referenceCoordinatePrior: Coordinate3D?
    public var coordinateSpace: CoordinateSpace

    public init(
        id: String, name: String, channelCount: Int,
        labels: [String],
        cardinalLabels: Set<String>, electrodes: [ElectrodeDefinition],
        fiducialCoordinatePriors: [FiducialKind: Coordinate3D],
        fiducialSensorHints: [FiducialKind: Int], referenceSensor: Int?, referenceLabel: String?,
        referenceCoordinatePrior: Coordinate3D? = nil,
        coordinateSpace: CoordinateSpace = .egiLayoutCentimeters
    ) {
        self.id = id
        self.name = name
        self.channelCount = channelCount
        self.labels = labels
        self.cardinalLabels = cardinalLabels
        self.electrodes = electrodes
        self.fiducialCoordinatePriors = fiducialCoordinatePriors
        self.fiducialSensorHints = fiducialSensorHints
        self.referenceSensor = referenceSensor
        self.referenceLabel = referenceLabel
        self.referenceCoordinatePrior = referenceCoordinatePrior
        self.coordinateSpace = coordinateSpace
    }

    /// Explicit acquisition mode for head geometry without an electrode net.
    /// Keeping this as a real, zero-channel layout avoids optional-layout
    /// migrations while making `layoutID: "none"` unambiguous to consumers.
    public static let headMeshOnly = ElectrodeLayout(
        id: "none",
        name: "No Net / Head Mesh Only",
        channelCount: 0,
        labels: [],
        cardinalLabels: [],
        electrodes: [],
        fiducialCoordinatePriors: [:],
        fiducialSensorHints: [:],
        referenceSensor: nil,
        referenceLabel: nil,
        coordinateSpace: .arkitWorldMeters)

    public var hasElectrodeNet: Bool { channelCount > 0 }

    public static let fallback128 = ElectrodeLayout(
        id: "hydrocel-128",
        name: "HydroCel GSN 128",
        channelCount: 128,
        labels: (1...128).map { "E\($0)" },
        cardinalLabels: Set([129, 17, 43, 24, 124, 120, 47, 98, 72, 68, 94].map { "E\($0)" }),
        electrodes: (1...128).map { number in
            ElectrodeDefinition(
                number: number, label: "E\(number)",
                role: [17, 43, 24, 124, 120, 47, 98, 72, 68, 94].contains(number)
                    ? .cardinal : .regular,
                coordinatePrior: .zero, displayPosition: nil, neighbors: [])
        },
        fiducialCoordinatePriors: [:],
        fiducialSensorHints: [.rightPreauricular: 108, .leftPreauricular: 45, .nasion: 17],
        referenceSensor: 129,
        referenceLabel: "VREF"
    )
}

public struct ScanSession: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var name: String
    public var createdAt: Date
    public var subjectLabel: String?
    public var captureMode: CaptureMode
    public var layout: ElectrodeLayout
    public var fiducials: [FiducialAnnotation]
    public var electrodes: [ElectrodeAnnotation]
    public var captureObservations: [CaptureObservation]
    public var coordinateSpace: CoordinateSpace
    public var photogrammetryModelFilename: String?
    public var worldAlignmentTransform: [Float]?
    public var alignmentStrategy: WorldAlignmentStrategy
    public var alignmentSeed: AlignmentSeed
    public var modelFiducials: [FiducialAnnotation]
    public var modelCoordinateSpace: CoordinateSpace
    public var lidarMeshFilename: String?
    public var headCroppedLidarMeshFilename: String?
    public var headBoundingBox: HeadBoundingBox?
    public var lastExportedBundleID: UUID?
    public var lastRawExportedBundleID: UUID?
    public var acquisitionContext: AcquisitionContext?
    public var fiducialPlacementEvidence: [FiducialPlacementEvidence]?

    public init(
        id: UUID = UUID(), name: String, createdAt: Date, subjectLabel: String? = nil,
        captureMode: CaptureMode, layout: ElectrodeLayout, fiducials: [FiducialAnnotation],
        electrodes: [ElectrodeAnnotation], captureObservations: [CaptureObservation],
        coordinateSpace: CoordinateSpace = .arkitWorldMeters,
        photogrammetryModelFilename: String? = nil, worldAlignmentTransform: [Float]? = nil,
        alignmentStrategy: WorldAlignmentStrategy = .icp, alignmentSeed: AlignmentSeed = .coarsePCA,
        modelFiducials: [FiducialAnnotation] = FiducialKind.cardinal.map {
            FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview)
        }, modelCoordinateSpace: CoordinateSpace = .photogrammetryModelMeters,
        lidarMeshFilename: String? = nil, lastExportedBundleID: UUID? = nil,
        headCroppedLidarMeshFilename: String? = nil,
        headBoundingBox: HeadBoundingBox? = nil,
        lastRawExportedBundleID: UUID? = nil,
        acquisitionContext: AcquisitionContext? = nil,
        fiducialPlacementEvidence: [FiducialPlacementEvidence]? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.subjectLabel = subjectLabel
        self.captureMode = captureMode
        self.layout = layout
        self.fiducials = fiducials
        self.electrodes = electrodes
        self.captureObservations = captureObservations
        self.coordinateSpace = coordinateSpace
        self.photogrammetryModelFilename = photogrammetryModelFilename
        self.worldAlignmentTransform = worldAlignmentTransform
        self.alignmentStrategy = alignmentStrategy
        self.alignmentSeed = alignmentSeed
        self.modelFiducials = modelFiducials
        self.modelCoordinateSpace = modelCoordinateSpace
        self.lidarMeshFilename = lidarMeshFilename
        self.headCroppedLidarMeshFilename = headCroppedLidarMeshFilename
        self.headBoundingBox = headBoundingBox
        self.lastExportedBundleID = lastExportedBundleID
        self.lastRawExportedBundleID = lastRawExportedBundleID
        self.acquisitionContext = acquisitionContext
        self.fiducialPlacementEvidence = fiducialPlacementEvidence
    }

    public var modelFiducialsReady: Bool {
        !modelFiducials.isEmpty && modelFiducials.allSatisfy { $0.coordinate != nil }
    }
    public var hasReconstructedModel: Bool { photogrammetryModelFilename != nil }
    public var reviewedElectrodeCount: Int { electrodes.filter { $0.state == .reviewed }.count }
    public var detectedElectrodeCount: Int {
        electrodes.filter { $0.state == .detected || $0.state == .reviewed }.count
    }
    public var fiducialsReady: Bool { fiducials.allSatisfy { $0.coordinate != nil } }

    public var timestampName: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter.string(from: createdAt)
    }

    public var displayName: String {
        trimmedSubjectLabel.map { "\($0) · \(timestampName)" } ?? timestampName
    }

    /// Legacy internal-session name. Finalized `.manta` uses the PHI-free timestamp policy.
    public var fileSafeName: String {
        guard let label = trimmedSubjectLabel else { return timestampName }
        let sanitized = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "\(String(sanitized))_\(timestampName)"
    }

    private var trimmedSubjectLabel: String? {
        guard let label = subjectLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
            !label.isEmpty
        else { return nil }
        return label
    }

    public static func newSession(layout: ElectrodeLayout = .fallback128) -> ScanSession {
        var session = ScanSession(
            name: "", createdAt: Date(), captureMode: .both, layout: layout,
            fiducials: FiducialKind.cardinal.map {
                FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview)
            }, electrodes: [], captureObservations: [])
        session.name = session.displayName
        return session
    }
}

/// Axis-aligned region of interest in the ARKit world frame. The complete mesh
/// remains raw evidence; this box produces the focused head mesh used for live
/// review and downstream head-specific processing.
public struct HeadBoundingBox: Codable, Equatable, Sendable {
    public var center: Coordinate3D
    public var widthMeters: Double
    public var heightMeters: Double
    public var depthMeters: Double

    public init(
        center: Coordinate3D, widthMeters: Double = 0.40,
        heightMeters: Double = 0.46, depthMeters: Double = 0.40
    ) {
        self.center = center
        self.widthMeters = widthMeters
        self.heightMeters = heightMeters
        self.depthMeters = depthMeters
    }
}
