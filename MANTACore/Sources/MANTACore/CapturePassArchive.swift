import Foundation

/// A coordinate-world boundary inside one acquisition. Frames remain in the
/// session; the snapshot preserves the previous pass's mesh and landmarks.
public struct CapturePassArchive: Codable, Equatable, Sendable {
    public var segmentID: UUID
    public var artifactPaths: [String]

    public init(segmentID: UUID, artifactPaths: [String]) {
        self.segmentID = segmentID
        self.artifactPaths = artifactPaths
    }

    public static func save(session: ScanSession, segmentID: UUID, in root: URL) throws -> Self {
        let prefix = "acquisition/passes/\(segmentID.uuidString)/"
        let directory = root.appendingPathComponent(prefix)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var snapshot = session
        snapshot.capturePasses = nil
        snapshot.captureObservations = session.captureObservations.filter {
            $0.quality?.motionAssessment?.segmentID == segmentID
        }
        var paths = [String]()
        func preserve(_ path: String?, name: String) throws -> String? {
            guard let path else { return nil }
            let source = root.appendingPathComponent(path).standardizedFileURL.resolvingSymlinksInPath()
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
                  source.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
                throw MANTARawSessionRecoveryError.invalidReferencedPath(path)
            }
            let target = prefix + name
            try Data(contentsOf: source).write(to: root.appendingPathComponent(target), options: .atomic)
            paths.append(target)
            return target
        }
        snapshot.lidarMeshFilename = try preserve(session.lidarMeshFilename, name: "lidar_mesh.ply")
        snapshot.headCroppedLidarMeshFilename = try preserve(session.headCroppedLidarMeshFilename, name: "lidar_mesh_head.ply")
        snapshot.photogrammetryModelFilename = nil
        snapshot.worldAlignmentTransform = nil
        let metadata = prefix + "session.json"
        try JSONEncoder().encode(snapshot).write(to: root.appendingPathComponent(metadata), options: .atomic)
        paths.append(metadata)
        return Self(segmentID: segmentID, artifactPaths: paths)
    }
}
