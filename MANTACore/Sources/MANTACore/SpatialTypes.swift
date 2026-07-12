import Foundation

public enum DistanceUnit: String, CaseIterable, Codable, Sendable {
    case meters
    case centimeters
    case millimeters

    private var metersPerUnit: Double {
        switch self {
        case .meters: 1
        case .centimeters: 0.01
        case .millimeters: 0.001
        }
    }

    public func convert(_ value: Double, to target: DistanceUnit) -> Double {
        value * metersPerUnit / target.metersPerUnit
    }
}

public struct CoordinateFrameID: RawRepresentable, Codable, Hashable, Sendable {
    public var rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public static let arkitWorld = CoordinateFrameID(rawValue: "arkit-world")
    public static let headRAS = CoordinateFrameID(rawValue: "head-ras")
    public static let egiLayout = CoordinateFrameID(rawValue: "egi-layout")
    public static let photogrammetryModel = CoordinateFrameID(rawValue: "photogrammetry-model")
}

public struct CoordinateSpace: Codable, Equatable, Hashable, Sendable {
    public var frame: CoordinateFrameID
    public var unit: DistanceUnit

    public init(frame: CoordinateFrameID, unit: DistanceUnit) {
        self.frame = frame
        self.unit = unit
    }

    public static let arkitWorldMeters = CoordinateSpace(frame: .arkitWorld, unit: .meters)
    public static let headRASMillimeters = CoordinateSpace(frame: .headRAS, unit: .millimeters)
    public static let egiLayoutCentimeters = CoordinateSpace(frame: .egiLayout, unit: .centimeters)
    public static let photogrammetryModelMeters = CoordinateSpace(
        frame: .photogrammetryModel, unit: .meters)
}
