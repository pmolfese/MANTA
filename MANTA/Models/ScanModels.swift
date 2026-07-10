//
//  ScanModels.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation

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
    case liveLiDAR = "Live LiDAR"
    case importCapture = "Import"

    var id: String { rawValue }
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
    var captureMode: CaptureMode
    var layout: ElectrodeLayout
    var fiducials: [FiducialAnnotation]
    var electrodes: [ElectrodeAnnotation]
    var captureObservations: [CaptureObservation]

    var reviewedElectrodeCount: Int {
        electrodes.filter { $0.state == .reviewed }.count
    }

    var detectedElectrodeCount: Int {
        electrodes.filter { $0.state == .detected || $0.state == .reviewed }.count
    }

    var fiducialsReady: Bool {
        fiducials.allSatisfy { $0.coordinate != nil }
    }

    static func newSession(layout: ElectrodeLayout = .fallback128) -> ScanSession {
        ScanSession(
            name: "New EEG scan",
            createdAt: Date(),
            captureMode: .liveLiDAR,
            layout: layout,
            fiducials: FiducialKind.allCases.map {
                FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview)
            },
            electrodes: [],
            captureObservations: []
        )
    }
}
