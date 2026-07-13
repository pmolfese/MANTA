//
//  MANTABundleValidator.swift
//  MANTACore
//
//  Strict validation of an already-extracted logical .manta bundle directory.
//

import CryptoKit
import Foundation

public struct MANTAValidatedBundle: Sendable {
    public let rootDirectory: URL
    public let manifest: MANTABundleManifest
    public let capture: MANTACaptureDocument
    public let changeLog: MANTAChangeLogDocument?

    public init(
        rootDirectory: URL,
        manifest: MANTABundleManifest,
        capture: MANTACaptureDocument,
        changeLog: MANTAChangeLogDocument?
    ) {
        self.rootDirectory = rootDirectory
        self.manifest = manifest
        self.capture = capture
        self.changeLog = changeLog
    }
}

public enum MANTABundleValidationError: LocalizedError, Equatable, Sendable {
    case manifestMissing
    case unreadable(String)
    case invalidMetadata(String)
    case unsupportedFormat(String)
    case invalidSchemaVersion(String)
    case unsupportedMajorVersion(Int)
    case invalidPath(String)
    case duplicatePath(String)
    case undeclaredFile(String)
    case missingFile(String)
    case nonRegularFile(String)
    case invalidSize(String)
    case sizeMismatch(path: String, expected: Int64, actual: Int64)
    case invalidHash(String)
    case hashMismatch(String)
    case inconsistentSessionID
    case invalidLineage(String)
    case invalidCapture(String)

    public var errorDescription: String? {
        switch self {
        case .manifestMissing: "The bundle has no root manifest.json."
        case .unreadable(let path): "The bundle file could not be read: \(path)."
        case .invalidMetadata(let reason): "Bundle metadata is invalid: \(reason)."
        case .unsupportedFormat(let format): "Unsupported bundle format: \(format)."
        case .invalidSchemaVersion(let version): "Invalid schema version: \(version)."
        case .unsupportedMajorVersion(let major): "Unsupported schema major version: \(major)."
        case .invalidPath(let path): "Unsafe or non-canonical bundle path: \(path)."
        case .duplicatePath(let path): "Duplicate bundle path: \(path)."
        case .undeclaredFile(let path): "Bundle contains an undeclared file: \(path)."
        case .missingFile(let path): "A declared bundle file is missing: \(path)."
        case .nonRegularFile(let path): "Bundle entry is not a regular file: \(path)."
        case .invalidSize(let path): "Bundle entry has an invalid size: \(path)."
        case .sizeMismatch(let path, let expected, let actual):
            "Size mismatch for \(path): expected \(expected), found \(actual)."
        case .invalidHash(let path): "Bundle entry has an invalid SHA-256 value: \(path)."
        case .hashMismatch(let path): "SHA-256 mismatch for \(path)."
        case .inconsistentSessionID: "The manifest and capture document session IDs differ."
        case .invalidLineage(let reason): "Bundle lineage is invalid: \(reason)."
        case .invalidCapture(let reason): "Capture metadata is invalid: \(reason)."
        }
    }
}

public struct MANTABundleValidator {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func validate(directory rootDirectory: URL) throws -> MANTAValidatedBundle {
        try validate(directory: rootDirectory, verifyFileHashes: true)
    }

    /// Internal fast path for the finalizer, which has just computed every hash
    /// while building the manifest. External callers always receive full hash
    /// verification through the public overload above.
    func validate(
        directory rootDirectory: URL,
        verifyFileHashes: Bool
    ) throws -> MANTAValidatedBundle {
        let root = rootDirectory.standardizedFileURL
        let manifestURL = root.appendingPathComponent(MANTABundleFormat.manifestFilename)
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            throw MANTABundleValidationError.manifestMissing
        }

        let manifest: MANTABundleManifest = try decode(manifestURL, displayPath: MANTABundleFormat.manifestFilename)
        try validateVersion(manifest.schemaVersion)
        guard manifest.format == MANTABundleFormat.identifier else {
            throw MANTABundleValidationError.unsupportedFormat(manifest.format)
        }

        let declaredPaths = try validateFiles(
            manifest.files, in: root, verifyFileHashes: verifyFileHashes)
        try validateContentReferences(manifest.content, declaredPaths: declaredPaths)
        try rejectUndeclaredFiles(in: root, declaredPaths: declaredPaths)

        let captureURL = root.appendingPathComponent(manifest.content.capture)
        let capture: MANTACaptureDocument = try decode(captureURL, displayPath: manifest.content.capture)
        try validateVersion(capture.schemaVersion)
        guard capture.sessionID == manifest.sessionID else {
            throw MANTABundleValidationError.inconsistentSessionID
        }
        try validateCapture(capture, declaredPaths: declaredPaths)

        let changeLog = try validateLineage(manifest, in: root)

        return MANTAValidatedBundle(
            rootDirectory: root,
            manifest: manifest,
            capture: capture,
            changeLog: changeLog
        )
    }

    private func decode<T: Decodable>(_ url: URL, displayPath: String) throws -> T {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            throw MANTABundleValidationError.unreadable(displayPath)
        }
        do {
            return try MANTAJSON.makeDecoder().decode(T.self, from: data)
        } catch {
            throw MANTABundleValidationError.invalidMetadata("\(displayPath): \(error.localizedDescription)")
        }
    }

    private func validateVersion(_ string: String) throws {
        guard let version = MANTASemanticVersion(string) else {
            throw MANTABundleValidationError.invalidSchemaVersion(string)
        }
        guard version.major == MANTABundleFormat.supportedMajorVersion else {
            throw MANTABundleValidationError.unsupportedMajorVersion(version.major)
        }
    }

    private func validateFiles(
        _ entries: [MANTAFileEntry], in root: URL, verifyFileHashes: Bool
    ) throws -> Set<String> {
        var paths = Set<String>()
        for entry in entries {
            try validateRelativePath(entry.path)
            guard paths.insert(entry.path).inserted else {
                throw MANTABundleValidationError.duplicatePath(entry.path)
            }
            guard entry.size >= 0 else {
                throw MANTABundleValidationError.invalidSize(entry.path)
            }
            guard entry.sha256.count == 64,
                  entry.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else {
                throw MANTABundleValidationError.invalidHash(entry.path)
            }

            let url = root.appendingPathComponent(entry.path)
            guard fileManager.fileExists(atPath: url.path) else {
                throw MANTABundleValidationError.missingFile(entry.path)
            }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw MANTABundleValidationError.nonRegularFile(entry.path)
            }
            let actualSize = Int64(values.fileSize ?? -1)
            guard actualSize == entry.size else {
                throw MANTABundleValidationError.sizeMismatch(
                    path: entry.path,
                    expected: entry.size,
                    actual: actualSize
                )
            }
            if verifyFileHashes, try sha256(of: url) != entry.sha256 {
                throw MANTABundleValidationError.hashMismatch(entry.path)
            }
        }
        return paths
    }

    private func validateContentReferences(_ content: MANTAContentReferences, declaredPaths: Set<String>) throws {
        let references = [content.capture, content.subject, content.layout, content.changeLog].compactMap { $0 }
        for path in references {
            try validateRelativePath(path)
            guard declaredPaths.contains(path) else {
                throw MANTABundleValidationError.missingFile(path)
            }
        }
    }

    private func validateLineage(
        _ manifest: MANTABundleManifest,
        in root: URL
    ) throws -> MANTAChangeLogDocument? {
        switch (manifest.parentBundleID, manifest.content.changeLog) {
        case (nil, nil):
            return nil
        case (.some, nil):
            throw MANTABundleValidationError.invalidLineage("a parent bundle requires log_manta.json")
        case (nil, .some):
            throw MANTABundleValidationError.invalidLineage("a change log requires parentBundleID")
        case let (.some(parentBundleID), .some(path)):
            let log: MANTAChangeLogDocument = try decode(
                root.appendingPathComponent(path),
                displayPath: path
            )
            try validateVersion(log.schemaVersion)
            guard log.bundleID == manifest.bundleID else {
                throw MANTABundleValidationError.invalidLineage("change-log bundleID does not match manifest")
            }
            guard log.parentBundleID == parentBundleID else {
                throw MANTABundleValidationError.invalidLineage("change-log parentBundleID does not match manifest")
            }
            guard !log.changes.isEmpty,
                  log.changes.allSatisfy({ !$0.category.isEmpty && !$0.summary.isEmpty }) else {
                throw MANTABundleValidationError.invalidLineage("change log must contain a described change")
            }
            guard Set(log.changes.map(\.id)).count == log.changes.count else {
                throw MANTABundleValidationError.invalidLineage("change IDs must be unique")
            }
            return log
        }
    }

    private func validateCapture(_ capture: MANTACaptureDocument, declaredPaths: Set<String>) throws {
        guard !capture.layoutID.isEmpty else {
            throw MANTABundleValidationError.invalidCapture("layoutID must not be empty")
        }
        guard Set(capture.coordinateSystems.map(\.id)).count == capture.coordinateSystems.count,
              capture.coordinateSystems.contains(where: { $0.id == "arkit-world" }) else {
            throw MANTABundleValidationError.invalidCapture("coordinate systems must be unique and include arkit-world")
        }
        guard Set(capture.observations.map(\.id)).count == capture.observations.count else {
            throw MANTABundleValidationError.invalidCapture("observation IDs must be unique")
        }

        for observation in capture.observations {
            guard observation.imageDimensions.width > 0, observation.imageDimensions.height > 0 else {
                throw MANTABundleValidationError.invalidCapture("image dimensions must be positive")
            }
            guard observation.intrinsics.count == 9,
                  observation.cameraToWorld.count == 16,
                  observation.intrinsics.allSatisfy(\.isFinite),
                  observation.cameraToWorld.allSatisfy(\.isFinite) else {
                throw MANTABundleValidationError.invalidCapture("camera matrices have invalid shape or values")
            }
            guard capture.coordinateSystems.contains(where: { $0.id == observation.worldCoordinateSystem }) else {
                throw MANTABundleValidationError.invalidCapture("observation references an unknown coordinate system")
            }
            for path in [
                observation.imagePath, observation.losslessImagePath,
                observation.compressedImagePath, observation.depth?.path,
                observation.depth?.confidencePath
            ].compactMap({ $0 }) {
                try validateRelativePath(path)
                guard declaredPaths.contains(path) else {
                    throw MANTABundleValidationError.missingFile(path)
                }
            }
            if let depth = observation.depth,
               (depth.dimensions.width <= 0 || depth.dimensions.height <= 0) {
                throw MANTABundleValidationError.invalidCapture("depth dimensions must be positive")
            }
        }

        let systemIDs = Set(capture.coordinateSystems.map(\.id))
        for fiducial in capture.fiducials ?? [] {
            guard systemIDs.contains(fiducial.coordinateSystem) else {
                throw MANTABundleValidationError.invalidCapture("fiducial references an unknown coordinate system")
            }
            if let coordinate = fiducial.coordinate,
               coordinate.count != 3 || !coordinate.allSatisfy(\.isFinite) {
                throw MANTABundleValidationError.invalidCapture("fiducial coordinate must be three finite values")
            }
        }
        guard Set((capture.electrodes ?? []).map(\.label)).count == (capture.electrodes ?? []).count else {
            throw MANTABundleValidationError.invalidCapture("electrode labels must be unique")
        }
        for electrode in capture.electrodes ?? [] {
            guard systemIDs.contains(electrode.coordinateSystem) else {
                throw MANTABundleValidationError.invalidCapture("electrode references an unknown coordinate system")
            }
            guard electrode.coordinate.count == 3, electrode.coordinate.allSatisfy(\.isFinite) else {
                throw MANTABundleValidationError.invalidCapture("electrode coordinate must be three finite values")
            }
        }
        if let reconstruction = capture.reconstruction {
            guard systemIDs.contains(reconstruction.worldCoordinateSystem) else {
                throw MANTABundleValidationError.invalidCapture(
                    "reconstruction references an unknown coordinate system")
            }
            for path in [
                reconstruction.lidarMeshPath, reconstruction.headCroppedLidarMeshPath,
                reconstruction.objectCaptureModelPath
            ].compactMap({ $0 }) {
                guard declaredPaths.contains(path) else {
                    throw MANTABundleValidationError.invalidCapture(
                        "reconstruction references undeclared file \(path)")
                }
            }
            if let transform = reconstruction.modelToWorld,
               (transform.count != 16 || !transform.allSatisfy(\.isFinite)) {
                throw MANTABundleValidationError.invalidCapture(
                    "modelToWorld must contain 16 finite column-major values")
            }
            if let bounds = reconstruction.headBoundingBox {
                let center = bounds.center
                guard center.x.isFinite, center.y.isFinite, center.z.isFinite,
                      bounds.widthMeters.isFinite, bounds.widthMeters > 0,
                      bounds.heightMeters.isFinite, bounds.heightMeters > 0,
                      bounds.depthMeters.isFinite, bounds.depthMeters > 0 else {
                    throw MANTABundleValidationError.invalidCapture(
                        "headBoundingBox must contain a finite center and positive finite dimensions")
                }
            }
        }
    }

    private func validateRelativePath(_ path: String) throws {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw MANTABundleValidationError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MANTABundleValidationError.invalidPath(path)
        }
    }

    private func rejectUndeclaredFiles(in root: URL, declaredPaths: Set<String>) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw MANTABundleValidationError.unreadable(root.lastPathComponent)
        }

        var allowed = declaredPaths
        allowed.insert(MANTABundleFormat.manifestFilename)
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            let rootPath = comparableFileSystemPath(root)
            let filePath = comparableFileSystemPath(url)
            guard filePath.hasPrefix(rootPath + "/") else {
                throw MANTABundleValidationError.invalidPath(url.path)
            }
            let relative = String(filePath.dropFirst(rootPath.count + 1))
            if values.isSymbolicLink == true {
                throw MANTABundleValidationError.nonRegularFile(relative)
            }
            if values.isRegularFile == true, !allowed.contains(relative) {
                throw MANTABundleValidationError.undeclaredFile(relative)
            }
        }
    }

    /// Foundation may spell the same macOS temporary path as either `/var/...`
    /// or `/private/var/...`. Normalize that system alias before deriving a
    /// relative archive path; this does not follow bundle-contained symlinks.
    private func comparableFileSystemPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        if path.hasPrefix("/private/var/") {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    private func sha256(of url: URL) throws -> String {
        guard let stream = InputStream(url: url) else {
            throw MANTABundleValidationError.unreadable(url.lastPathComponent)
        }
        stream.open()
        defer { stream.close() }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 {
                throw MANTABundleValidationError.unreadable(url.lastPathComponent)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
