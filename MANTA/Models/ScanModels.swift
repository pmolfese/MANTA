//
//  ScanModels.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import MANTACore

struct Coordinate3D: Codable, Equatable, Hashable {
    var x: Double
    var y: Double
    var z: Double

    static let zero = Coordinate3D(x: 0, y: 0, z: 0)
}

struct Coordinate2D: Codable, Equatable, Hashable {
    var x: Double
    var y: Double

    static let zero = Coordinate2D(x: 0, y: 0)
}

enum ElectrodeRole: String, CaseIterable, Codable, Identifiable {
    case cardinal = "Cardinal"
    case regular = "Regular"

    var id: String { rawValue }
}

enum AnnotationState: String, CaseIterable, Codable, Identifiable {
    case detected = "Detected"
    case reviewed = "Reviewed"
    case needsReview = "Needs Review"
    case missing = "Missing"

    var id: String { rawValue }
}

struct ElectrodeAnnotation: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var label: String
    var role: ElectrodeRole
    var coordinate: Coordinate3D
    var confidence: Double
    var state: AnnotationState
}

enum FiducialKind: String, CaseIterable, Codable, Identifiable {
    case nasion = "Nasion"
    case leftPreauricular = "LPA"
    case rightPreauricular = "RPA"

    var id: String { rawValue }
}

struct FiducialAnnotation: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var kind: FiducialKind
    var coordinate: Coordinate3D?
    var state: AnnotationState
}

struct ElectrodeDefinition: Identifiable, Codable, Equatable, Hashable {
    var number: Int
    var label: String
    var role: ElectrodeRole
    var coordinatePrior: Coordinate3D
    var displayPosition: Coordinate2D?
    var neighbors: [Int]

    var id: Int { number }
}

enum CaptureMode: String, CaseIterable, Codable, Equatable, Identifiable {
    case lidar = "LiDAR"
    case photogrammetry = "Photogrammetry"
    case both = "Both"

    var id: String { rawValue }

    /// Whether this mode records LiDAR scene depth and reconstructs a mesh in real time.
    var usesLiDAR: Bool {
        switch self {
        case .lidar, .both:
            return true
        case .photogrammetry:
            return false
        }
    }

    /// Whether this mode collects the RGB frame set needed for offline photogrammetry.
    var usesPhotogrammetry: Bool {
        switch self {
        case .photogrammetry, .both:
            return true
        case .lidar:
            return false
        }
    }
}

struct ElectrodeLayout: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var channelCount: Int
    var labels: [String]
    var cardinalLabels: Set<String>
    var electrodes: [ElectrodeDefinition]
    var fiducialCoordinatePriors: [FiducialKind: Coordinate3D]
    var fiducialSensorHints: [FiducialKind: Int]
    var referenceSensor: Int?
    var referenceLabel: String?

    static let fallback128 = ElectrodeLayout(
        name: "HydroCel GSN 128",
        channelCount: 128,
        labels: (1...128).map { "E\($0)" },
        cardinalLabels: [129, 17, 43, 24, 124, 120, 47, 98, 72, 68, 94].map { "E\($0)" }.asSet,
        electrodes: (1...128).map { number in
            ElectrodeDefinition(
                number: number,
                label: "E\(number)",
                role: [17, 43, 24, 124, 120, 47, 98, 72, 68, 94].contains(number) ? .cardinal : .regular,
                coordinatePrior: .zero,
                displayPosition: nil,
                neighbors: []
            )
        },
        fiducialCoordinatePriors: [:],
        fiducialSensorHints: [
            .rightPreauricular: 108,
            .leftPreauricular: 45,
            .nasion: 17
        ],
        referenceSensor: 129,
        referenceLabel: "VREF"
    )
}

private extension Array where Element: Hashable {
    var asSet: Set<Element> {
        Set(self)
    }
}

struct ScanSession: Identifiable, Codable, Equatable {
    var id = UUID()
    var name: String
    var createdAt: Date
    /// Editable subject identifier (name / MRN). The immutable `createdAt`
    /// timestamp is always kept paired with it, so a session can never lose its
    /// date/time no matter how it is renamed.
    var subjectLabel: String? = nil
    var captureMode: CaptureMode
    var layout: ElectrodeLayout
    var fiducials: [FiducialAnnotation]
    var electrodes: [ElectrodeAnnotation]
    var captureObservations: [CaptureObservation]

    /// Relative path (inside the session directory) of the reconstructed photogrammetry model, once available.
    var photogrammetryModelFilename: String? = nil

    /// Rigid transform (column-major 4x4) mapping the photogrammetry model's frame into the ARKit world frame.
    /// Identity means the model is already expressed in ARKit world coordinates.
    var worldAlignmentTransform: [Float]? = nil

    /// Strategy used to register the photogrammetry model into the ARKit world frame.
    var alignmentStrategy: WorldAlignmentStrategy = .icp

    /// How ICP is seeded before iterating.
    var alignmentSeed: AlignmentSeed = .coarsePCA

    /// Fiducials marked on the reconstructed model (source frame). Coordinates are nil until placed.
    var modelFiducials: [FiducialAnnotation] = FiducialKind.allCases.map {
        FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview)
    }

    /// True once all model-frame fiducials have been placed.
    var modelFiducialsReady: Bool {
        !modelFiducials.isEmpty && modelFiducials.allSatisfy { $0.coordinate != nil }
    }

    /// Relative path of the persisted LiDAR mesh point cloud (world-space Float32 XYZ), when captured.
    var lidarMeshFilename: String? = nil

    var hasReconstructedModel: Bool {
        photogrammetryModelFilename != nil
    }

    var reviewedElectrodeCount: Int {
        electrodes.filter { $0.state == .reviewed }.count
    }

    var detectedElectrodeCount: Int {
        electrodes.filter { $0.state == .detected || $0.state == .reviewed }.count
    }

    var fiducialsReady: Bool {
        fiducials.allSatisfy { $0.coordinate != nil }
    }

    /// Sortable/default identifier derived from the capture time, e.g.
    /// `2026-07-11_143022`. Always present; independent of any renaming.
    var timestampName: String {
        ScanSession.timestampFormatter.string(from: createdAt)
    }

    /// Human-facing title: the subject label paired with the timestamp, or just
    /// the timestamp when unlabeled. The timestamp is always included.
    var displayName: String {
        if let label = trimmedSubjectLabel {
            return "\(label) · \(timestampName)"
        }
        return timestampName
    }

    /// Filesystem-safe name with the timestamp kept at the end, for export
    /// bundles: `MRN123_2026-07-11_143022`.
    var fileSafeName: String {
        guard let label = trimmedSubjectLabel else { return timestampName }
        let sanitized = label.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return "\(String(sanitized))_\(timestampName)"
    }

    private var trimmedSubjectLabel: String? {
        guard let label = subjectLabel?.trimmingCharacters(in: .whitespacesAndNewlines),
              !label.isEmpty else { return nil }
        return label
    }

    static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return formatter
    }()

    static func newSession(layout: ElectrodeLayout = .fallback128) -> ScanSession {
        var session = ScanSession(
            name: "",
            createdAt: Date(),
            captureMode: .both,
            layout: layout,
            fiducials: FiducialKind.allCases.map {
                FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview)
            },
            electrodes: [],
            captureObservations: []
        )
        session.name = session.displayName
        return session
    }
}
