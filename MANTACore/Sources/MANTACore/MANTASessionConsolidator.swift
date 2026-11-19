import Foundation

/// Repackages an explicitly linked sequence without registering its AR worlds.
/// Original files are copied into per-source namespaces and never edited.
public enum MANTASessionConsolidator {
    public static func consolidate(_ sources: [URL], to destination: URL,
                                   producer: MANTAProducer) throws -> MANTARawSessionRecoveryResult {
        let fm = FileManager.default
        guard sources.count > 1, !fm.fileExists(atPath: destination.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let loaded = try sources.map { (url: $0.standardizedFileURL.resolvingSymlinksInPath(), session: try MANTAWorkingSessionLoader.load(from: $0)) }
            .sorted { $0.session.createdAt < $1.session.createdAt }
        guard Set(loaded.map { $0.session.id }).count == loaded.count,
              loaded.allSatisfy({ $0.session.layout.id == loaded[0].session.layout.id }),
              zip(loaded, loaded.dropFirst()).allSatisfy({ $1.session.captureRoute?.previousSessionID == $0.session.id }) else {
            throw MANTABundleValidationError.invalidCapture("Select a complete linked sequence of passes from the same recording; unrelated sessions cannot be consolidated automatically.")
        }
        let parent = destination.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(".manta-consolidation-\(UUID())")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var merged = loaded[0].session
        merged.id = UUID()
        merged.captureObservations = []
        merged.capturePasses = []
        merged.captureRoute = nil
        merged.endedAt = loaded.last?.session.endedAt
        merged.lidarMeshFilename = nil
        merged.headCroppedLidarMeshFilename = nil
        merged.headBoundingBox = nil
        merged.photogrammetryModelFilename = nil
        merged.worldAlignmentTransform = nil
        merged.electrodes = []
        merged.fiducials = FiducialKind.cardinal.map { FiducialAnnotation(kind: $0, coordinate: nil, state: .needsReview) }
        merged.modelFiducials = merged.fiducials
        merged.fiducialPlacementEvidence = nil
        merged.lastRawExportedBundleID = nil
        merged.lastExportedBundleID = nil
        merged.acquisitionContext?.captureReview = nil
        var seen = Set<UUID>()
        for source in loaded {
            let prefix = "acquisition/passes/\(source.session.id.uuidString)/"
            var paths = [String]()
            guard let enumerator = fm.enumerator(at: source.url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            for case let file as URL in enumerator {
                let relative = file.standardizedFileURL.resolvingSymlinksInPath().pathComponents.dropFirst(source.url.pathComponents.count).joined(separator: "/")
                if relative == "derivatives" { enumerator.skipDescendants(); continue }
                let values = try file.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw MANTARawSessionRecoveryError.invalidReferencedPath(relative) }
                if values.isDirectory == true { continue }
                let path = prefix + relative
                let target = staging.appendingPathComponent(path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: target)
                paths.append(path)
            }
            func prefixed(_ path: String?) throws -> String? {
                guard let path else { return nil }
                guard !path.hasPrefix("/"), !path.contains("\\"),
                      path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
                    throw MANTARawSessionRecoveryError.invalidReferencedPath(path)
                }
                return prefix + path
            }
            let segmentID = source.session.captureObservations.first?.quality?.motionAssessment?.segmentID ?? source.session.id
            merged.capturePasses?.append(.init(segmentID: segmentID, artifactPaths: paths.sorted()))
            for var observation in source.session.captureObservations {
                guard seen.insert(observation.id).inserted else { throw MANTABundleValidationError.invalidCapture("Duplicate frame across source passes") }
                observation.cameraSnapshotFilename = try prefixed(observation.cameraSnapshotFilename)
                observation.losslessCameraSnapshotFilename = try prefixed(observation.losslessCameraSnapshotFilename)
                observation.compressedCameraSnapshotFilename = try prefixed(observation.compressedCameraSnapshotFilename)
                observation.depthSnapshotFilename = try prefixed(observation.depthSnapshotFilename)
                observation.rawDepthFilename = try prefixed(observation.rawDepthFilename)
                observation.rawConfidenceFilename = try prefixed(observation.rawConfidenceFilename)
                // Legacy passes without motion metadata are still distinct worlds.
                if observation.quality == nil {
                    observation.quality = CaptureQualityMetrics(arFrameTimestamp: 0, worldMappingStatus: "unknown",
                        ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0,
                        darkPixelFraction: 0, brightPixelFraction: 0, sharpnessScore: 0,
                        translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "unknown")
                }
                if observation.quality?.motionAssessment == nil {
                    observation.quality?.motionAssessment = .init(segmentID: segmentID, state: .unassessed)
                }
                merged.captureObservations.append(observation)
            }
        }
        merged.captureObservations.sort { $0.capturedAt < $1.capturedAt }
        try JSONEncoder().encode(merged).write(to: staging.appendingPathComponent("session.json"), options: .atomic)
        return try MANTARawSessionRecovery().recoverDirectoryPackage(from: staging, to: destination, producer: producer)
    }
}
