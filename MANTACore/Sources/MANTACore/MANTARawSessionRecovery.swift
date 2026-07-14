import CryptoKit
import Foundation
import simd

public struct MANTARawSessionRecoveryResult: Sendable {
    public var bundle: MANTAValidatedBundle
    public var packageURL: URL

    public init(bundle: MANTAValidatedBundle, packageURL: URL) {
        self.bundle = bundle
        self.packageURL = packageURL
    }
}

public enum MANTARawSessionRecoveryError: LocalizedError, Equatable, Sendable {
    case sourceMissing
    case destinationExists
    case missingSessionMetadata
    case missingReferencedFile(String)
    case invalidReferencedPath(String)

    public var errorDescription: String? {
        switch self {
        case .sourceMissing:
            "The session folder could not be found."
        case .destinationExists:
            "A recovered MANTA package already exists at that location."
        case .missingSessionMetadata:
            "The folder has no session.json to recover."
        case .missingReferencedFile(let path):
            "The session references a missing file: \(path)."
        case .invalidReferencedPath(let path):
            "The session references an unsafe file path: \(path)."
        }
    }
}

public struct MANTARawSessionRecovery {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Recovers an iOS working-session directory into a validated logical RAW
    /// `.manta` directory package. This intentionally does not create a ZIP
    /// transfer archive, so captures larger than the current non-ZIP64 archive
    /// envelope can still be preserved and opened by MANTAReceiver.
    public func recoverDirectoryPackage(
        from sessionDirectory: URL,
        to destinationDirectory: URL,
        producer: MANTAProducer,
        bundleID: UUID = UUID(),
        finalizedAt: Date = Date()
    ) throws -> MANTARawSessionRecoveryResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: sessionDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MANTARawSessionRecoveryError.sourceMissing
        }
        guard !fileManager.fileExists(atPath: destinationDirectory.path) else {
            throw MANTARawSessionRecoveryError.destinationExists
        }

        let sessionURL = sessionDirectory.appendingPathComponent("session.json")
        guard fileManager.fileExists(atPath: sessionURL.path) else {
            throw MANTARawSessionRecoveryError.missingSessionMetadata
        }

        let session = try JSONDecoder().decode(ScanSession.self, from: Data(contentsOf: sessionURL))
        let parent = destinationDirectory.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
        let staging = parent.appendingPathComponent(
            ".manta-recovery-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        var shouldRemoveStaging = true
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: staging)
            }
        }

        var metadata = [(path: String, mediaType: String, role: String)]()
        let capture = makeCaptureDocument(session)
        try write(
            MANTAJSON.canonicalData(capture),
            path: "capture.json",
            mediaType: "application/json",
            role: "capture-metadata",
            to: staging,
            metadata: &metadata)
        let layoutPath: String? = session.layout.hasElectrodeNet
            ? "layouts/recovered-layout.json" : nil
        if let layoutPath {
            try fileManager.createDirectory(
                at: staging.appendingPathComponent(layoutPath).deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try write(
                MANTAJSON.canonicalData(session.layout),
                path: layoutPath,
                mediaType: "application/json",
                role: "layout-definition",
                to: staging,
                metadata: &metadata)
        }

        var paths = Set(metadata.map(\.path))
        for source in try bundleFileSources(session, in: sessionDirectory).sorted(by: { $0.path < $1.path }) {
            try validate(path: source.path)
            guard paths.insert(source.path).inserted else { continue }
            let values = try? source.sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw MANTARawSessionRecoveryError.missingReferencedFile(source.path)
            }
            let destination = staging.appendingPathComponent(source.path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            do {
                try fileManager.linkItem(at: source.sourceURL, to: destination)
            } catch {
                try fileManager.copyItem(at: source.sourceURL, to: destination)
            }
            metadata.append((source.path, source.mediaType, source.role))
        }

        let entries = try metadata.sorted(by: { $0.path < $1.path }).map { item in
            let url = staging.appendingPathComponent(item.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            return MANTAFileEntry(
                path: item.path,
                mediaType: item.mediaType,
                role: item.role,
                size: Int64(values.fileSize ?? 0),
                sha256: try sha256(of: url))
        }
        let manifest = MANTABundleManifest(
            schema: MANTABundleFormat.manifestSchema,
            bundleID: bundleID,
            sessionID: session.id,
            createdAt: session.createdAt,
            finalizedAt: finalizedAt,
            producer: producer,
            content: MANTAContentReferences(capture: "capture.json", layout: layoutPath),
            files: entries)
        try MANTAJSON.canonicalData(manifest).write(
            to: staging.appendingPathComponent(MANTABundleFormat.manifestFilename),
            options: .atomic)

        let validated = try MANTABundleValidator(fileManager: fileManager).validate(directory: staging)
        try fileManager.moveItem(at: staging, to: destinationDirectory)
        shouldRemoveStaging = false
        return MANTARawSessionRecoveryResult(
            bundle: MANTAValidatedBundle(
                rootDirectory: destinationDirectory,
                manifest: validated.manifest,
                capture: validated.capture,
                changeLog: validated.changeLog),
            packageURL: destinationDirectory)
    }

    private func makeCaptureDocument(_ session: ScanSession) -> MANTACaptureDocument {
        let coverageCenter: Coordinate3D? = session.headBoundingBox?.center ?? {
            let points = session.fiducials.compactMap(\.coordinate)
            guard points.count == 3 else { return nil }
            return Coordinate3D(
                x: points.map(\.x).reduce(0, +) / 3,
                y: points.map(\.y).reduce(0, +) / 3,
                z: points.map(\.z).reduce(0, +) / 3)
        }()
        let observations = session.captureObservations.map { observation in
            let depth: MANTADepthArtifact?
            if let path = observation.rawDepthFilename, let format = observation.rawDepthFormat {
                depth = MANTADepthArtifact(
                    path: path,
                    confidencePath: observation.rawConfidenceFilename,
                    dimensions: MANTAImageDimensions(width: format.width, height: format.height),
                    scalarType: format.scalarType.lowercased(),
                    byteOrder: format.byteOrder == "littleEndian" ? "little-endian" : format.byteOrder,
                    units: format.units,
                    layout: format.layout,
                    compression: format.compression,
                    imageMapping: "resolution-scale")
            } else {
                depth = nil
            }
            var quality = observation.quality
            if let coverageCenter, observation.cameraTransform.count == 16 {
                quality?.headCenteredCoverageSector = Self.headCenteredCoverageSector(
                    transform: observation.cameraTransform, center: coverageCenter)
            }
            return MANTACaptureObservation(
                id: observation.id,
                capturedAt: observation.capturedAt,
                imagePath: observation.cameraSnapshotFilename,
                losslessImagePath: observation.losslessCameraSnapshotFilename,
                compressedImagePath: observation.compressedCameraSnapshotFilename,
                imageDimensions: MANTAImageDimensions(
                    width: observation.imageResolution.width,
                    height: observation.imageResolution.height),
                imageOrigin: "top-left",
                imageOrientation: observation.imageOrientation ?? "up",
                intrinsics: observation.cameraIntrinsics.map(Double.init),
                cameraToWorld: observation.cameraTransform.map(Double.init),
                worldCoordinateSystem: "arkit-world",
                depth: depth,
                trackingState: observation.trackingSummary,
                quality: quality)
        }
        let mode: String
        switch session.captureMode {
        case .lidar: mode = "lidar"
        case .photogrammetry: mode = "photogrammetry"
        case .both: mode = "both"
        }
        let reconstruction: MANTAReconstructionReference? = {
            guard session.lidarMeshFilename != nil
                    || session.headCroppedLidarMeshFilename != nil
                    || session.headBoundingBox != nil else {
                return nil
            }
            return MANTAReconstructionReference(
                lidarMeshPath: session.lidarMeshFilename,
                headCroppedLidarMeshPath: session.headCroppedLidarMeshFilename,
                objectCaptureModelPath: nil,
                headBoundingBox: session.headBoundingBox,
                modelToWorld: nil,
                worldCoordinateSystem: "arkit-world")
        }()

        return MANTACaptureDocument(
            schema: MANTABundleFormat.captureSchema,
            sessionID: session.id,
            captureMode: mode,
            layoutID: session.layout.id,
            coordinateSystems: [
                MANTACoordinateSystem(
                    id: "arkit-world",
                    handedness: "right",
                    units: .meters,
                    description: "Right-handed ARKit world frame; camera looks down negative Z.")
            ],
            observations: observations,
            fiducials: session.fiducials.map { fiducial in
                MANTAFiducialSolution(
                    kind: fiducial.kind.rawValue,
                    coordinateSystem: "arkit-world",
                    coordinate: fiducial.coordinate.map { [$0.x, $0.y, $0.z] },
                    state: fiducial.state.rawValue)
            },
            electrodes: nil,
            reconstruction: reconstruction)
    }

    private func bundleFileSources(
        _ session: ScanSession, in directory: URL
    ) throws -> [MANTABundleFileSource] {
        var items = [String: (mediaType: String, role: String)]()
        for observation in session.captureObservations {
            if let path = observation.cameraSnapshotFilename {
                items[path] = (imageMediaType(for: path), "camera-image")
            }
            if let path = observation.losslessCameraSnapshotFilename {
                items[path] = ("image/png", "camera-image-lossless-reference")
            }
            if let path = observation.compressedCameraSnapshotFilename {
                items[path] = (imageMediaType(for: path), "camera-image-compressed-reference")
            }
            if let path = observation.depthSnapshotFilename {
                items[path] = ("image/png", "depth-preview")
            }
            if let path = observation.rawDepthFilename {
                items[path] = ("application/octet-stream", "metric-depth")
            }
            if let path = observation.rawConfidenceFilename {
                items[path] = ("application/octet-stream", "depth-confidence")
            }
        }
        if let path = session.lidarMeshFilename {
            items[path] = ("application/octet-stream", "lidar-mesh")
        }
        if let path = session.headCroppedLidarMeshFilename {
            items[path] = ("application/octet-stream", "lidar-head-mesh")
        }
        for (path, mediaType, role) in [
            ("capture-receipt.json", "application/json", "capture-validation-receipt"),
            ("acquisition/context.json", "application/json", "acquisition-context"),
            ("acquisition/events.jsonl", "application/x-ndjson", "acquisition-event-log"),
            ("acquisition/fiducial-placements.json", "application/json", "fiducial-placement-evidence")
        ] where fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) {
            items[path] = (mediaType, role)
        }
        return try items.map { path, metadata in
            try validate(path: path)
            let sourceURL = directory.appendingPathComponent(path)
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                throw MANTARawSessionRecoveryError.missingReferencedFile(path)
            }
            return MANTABundleFileSource(
                path: path,
                sourceURL: sourceURL,
                mediaType: metadata.mediaType,
                role: metadata.role)
        }
    }

    private func write(
        _ data: Data,
        path: String,
        mediaType: String,
        role: String,
        to root: URL,
        metadata: inout [(path: String, mediaType: String, role: String)]
    ) throws {
        try data.write(to: root.appendingPathComponent(path), options: .atomic)
        metadata.append((path, mediaType, role))
    }

    private func validate(path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MANTARawSessionRecoveryError.invalidReferencedPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MANTARawSessionRecoveryError.invalidReferencedPath(path)
        }
    }

    private func imageMediaType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": "image/png"
        case "heic", "heif": "image/heic"
        default: "image/jpeg"
        }
    }

    private func sha256(of url: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func headCenteredCoverageSector(
        transform: [Float], center: Coordinate3D
    ) -> String? {
        guard transform.count == 16 else { return nil }
        let offset = SIMD3<Double>(
            Double(transform[12]) - center.x,
            Double(transform[13]) - center.y,
            Double(transform[14]) - center.z)
        let distance = simd_length(offset)
        guard distance > 0.01 else { return nil }
        var azimuth = atan2(offset.x, -offset.z) * 180 / .pi
        if azimuth < 0 { azimuth += 360 }
        let azimuthBin = Int((azimuth + 22.5) / 45) % 8
        let elevation = asin(max(-1, min(1, offset.y / distance))) * 180 / .pi
        let elevationBin = elevation > 20 ? "upper" : elevation < -20 ? "lower" : "level"
        return "azimuth-\(azimuthBin)-\(elevationBin)"
    }
}
