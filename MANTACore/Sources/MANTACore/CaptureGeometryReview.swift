import Foundation
import simd

/// Evidence availability, never a surface-completeness or accuracy score.
public struct CaptureGeometryReview: Codable, Equatable, Hashable, Sendable {
    public var observationCount: Int
    public var depthFrameCount: Int
    public var confidenceFrameCount: Int
    public var blurWarningCount: Int
    public var unknownSharpnessCount: Int
    public var motionConsistentCount: Int
    public var motionUnknownCount: Int
    public var motionSuspectCount: Int
    public var headRegionSet: Bool
    public var headMeshRecorded: Bool
    public var environmentMeshRecorded: Bool
    /// Nil means there is no head region, so head-centered views are unknown.
    public var viewSectorCount: Int?

    public init(session: ScanSession) {
        let frames = session.captureObservations
        observationCount = frames.count
        depthFrameCount = frames.filter { $0.rawDepthFilename != nil && $0.rawDepthFormat != nil }.count
        confidenceFrameCount = frames.filter {
            $0.rawDepthFilename != nil && $0.rawDepthFormat != nil
                && $0.rawConfidenceFilename != nil && $0.rawConfidenceFormat != nil
        }.count
        blurWarningCount = frames.filter { $0.quality?.warnings.contains("possible-motion-blur") == true }.count
        unknownSharpnessCount = frames.filter { $0.quality?.sharpnessScore.isFinite != true }.count
        motionConsistentCount = frames.filter { $0.quality?.motionAssessment?.state == .consistent }.count
        motionSuspectCount = frames.filter { $0.quality?.motionAssessment?.state == .suspected }.count
        motionUnknownCount = frames.count - motionConsistentCount - motionSuspectCount
        headRegionSet = session.headBoundingBox != nil
        headMeshRecorded = session.headCroppedLidarMeshFilename != nil
        environmentMeshRecorded = session.lidarMeshFilename != nil
        if let center = session.headBoundingBox?.center {
            viewSectorCount = Set(frames.compactMap { Self.viewSector($0, center: center) }).count
        } else {
            viewSectorCount = nil
        }
    }

    /// Camera-position bins in the capture world's axes, not anatomical labels.
    /// Repeated photos, unknown sharpness, suspect motion, or invalid poses cannot
    /// inflate this count. Depth availability is deliberately reported separately.
    public static func viewSector(_ frame: CaptureObservation, center: Coordinate3D) -> String? {
        guard frame.cameraSnapshotFilename != nil,
              let quality = frame.quality, quality.sharpnessScore.isFinite,
              !quality.warnings.contains("possible-motion-blur"),
              quality.motionAssessment?.state != .suspected,
              let pose = SegmentRegistration.matrix(frame.cameraTransform), SegmentRegistration.rigid(pose),
              [center.x, center.y, center.z].allSatisfy(\.isFinite) else { return nil }
        let offset = SIMD3<Double>(Double(pose[3].x) - center.x,
                                   Double(pose[3].y) - center.y, Double(pose[3].z) - center.z)
        let distance = simd_length(offset)
        guard distance.isFinite, distance > 0.01 else { return nil }
        var azimuth = atan2(offset.x, -offset.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let azimuthBin = Int((azimuth + 22.5) / 45) % 8
        let elevation = asin(max(-1, min(1, offset.y / distance))) * 180 / .pi
        let elevationBin = elevation > 20 ? "upper" : elevation < -20 ? "lower" : "level"
        return "azimuth-\(azimuthBin)-\(elevationBin)"
    }
}
