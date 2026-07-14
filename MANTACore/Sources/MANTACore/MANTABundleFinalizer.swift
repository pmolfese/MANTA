import CryptoKit
import Foundation

public struct MANTABundleFileSource: Sendable {
    public var path: String
    public var sourceURL: URL
    public var mediaType: String
    public var role: String

    public init(path: String, sourceURL: URL, mediaType: String, role: String) {
        self.path = path
        self.sourceURL = sourceURL
        self.mediaType = mediaType
        self.role = role
    }
}

public struct MANTABundleFinalizationRequest: Sendable {
    public var capture: MANTACaptureDocument
    public var producer: MANTAProducer
    public var createdAt: Date
    public var finalizedAt: Date
    public var bundleID: UUID
    public var parentBundleID: UUID?
    public var changes: [MANTAChangeRecord]
    public var files: [MANTABundleFileSource]
    public var layoutPath: String?
    public var filenameTag: String?

    public init(
        capture: MANTACaptureDocument,
        producer: MANTAProducer,
        createdAt: Date,
        finalizedAt: Date,
        bundleID: UUID = UUID(),
        parentBundleID: UUID? = nil,
        changes: [MANTAChangeRecord] = [],
        files: [MANTABundleFileSource] = [], layoutPath: String? = nil,
        filenameTag: String? = nil
    ) {
        self.capture = capture
        self.producer = producer
        self.createdAt = createdAt
        self.finalizedAt = finalizedAt
        self.bundleID = bundleID
        self.parentBundleID = parentBundleID
        self.changes = changes
        self.files = files
        self.layoutPath = layoutPath
        self.filenameTag = filenameTag
    }
}

public struct MANTAFinalizedBundle: Sendable {
    public enum Container: String, Sendable {
        case archive
        case directoryPackage
    }

    public var archiveURL: URL
    public var manifest: MANTABundleManifest
    public var container: Container

    public init(
        archiveURL: URL, manifest: MANTABundleManifest,
        container: Container = .archive
    ) {
        self.archiveURL = archiveURL
        self.manifest = manifest
        self.container = container
    }
}

public enum MANTABundleFinalizationError: LocalizedError, Equatable, Sendable {
    case destinationExists(String)
    case duplicatePath(String)
    case reservedPath(String)
    case invalidPath(String)
    case missingSource(String)
    case invalidLineage

    public var errorDescription: String? {
        switch self {
        case .destinationExists(let name): "A finalized bundle already exists at \(name)."
        case .duplicatePath(let path): "The bundle contains duplicate path \(path)."
        case .reservedPath(let path): "The supplied file uses reserved bundle path \(path)."
        case .invalidPath(let path): "The supplied bundle path is unsafe: \(path)."
        case .missingSource(let path): "The source file is missing or not regular: \(path)."
        case .invalidLineage: "A parent bundle and at least one described change are required together."
        }
    }
}

public struct MANTABundleFinalizer {
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func finalize(
        _ request: MANTABundleFinalizationRequest,
        in outputDirectory: URL,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> MANTAFinalizedBundle {
        progress?(0.01, "Preparing archive")
        guard (request.parentBundleID == nil) == request.changes.isEmpty else {
            throw MANTABundleFinalizationError.invalidLineage
        }

        try fileManager.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let archiveURL = outputDirectory.appendingPathComponent(
            MANTABundleFilename.timestamped(for: request.finalizedAt, tag: request.filenameTag))
        guard !fileManager.fileExists(atPath: archiveURL.path) else {
            throw MANTABundleFinalizationError.destinationExists(archiveURL.lastPathComponent)
        }

        var shouldRemoveStaging = true
        let staging = outputDirectory.appendingPathComponent(
            ".manta-\(UUID().uuidString).partial", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer {
            if shouldRemoveStaging {
                try? fileManager.removeItem(at: staging)
            }
        }

        var metadata = [(path: String, mediaType: String, role: String)]()
        try write(
            MANTAJSON.canonicalData(request.capture),
            path: "capture.json",
            mediaType: "application/json",
            role: "capture-metadata",
            to: staging,
            metadata: &metadata)

        if let parentBundleID = request.parentBundleID {
            let log = MANTAChangeLogDocument(
                schema: MANTABundleFormat.changeLogSchema,
                bundleID: request.bundleID,
                parentBundleID: parentBundleID,
                createdAt: request.finalizedAt,
                producer: request.producer,
                changes: request.changes)
            try write(
                MANTAJSON.canonicalData(log),
                path: "log_manta.json",
                mediaType: "application/json",
                role: "bundle-change-log",
                to: staging,
                metadata: &metadata)
        }

        var paths = Set(metadata.map(\.path))
        let sortedSources = request.files.sorted(by: { $0.path < $1.path })
        for (index, source) in sortedSources.enumerated() {
            try validate(path: source.path)
            guard source.path != MANTABundleFormat.manifestFilename,
                  source.path != "capture.json", source.path != "log_manta.json" else {
                throw MANTABundleFinalizationError.reservedPath(source.path)
            }
            guard paths.insert(source.path).inserted else {
                throw MANTABundleFinalizationError.duplicatePath(source.path)
            }
            let values = try? source.sourceURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                throw MANTABundleFinalizationError.missingSource(source.path)
            }
            let destination = staging.appendingPathComponent(source.path)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fileManager.copyItem(at: source.sourceURL, to: destination)
            metadata.append((source.path, source.mediaType, source.role))
            progress?(
                0.05 + 0.30 * Double(index + 1) / Double(max(1, sortedSources.count)),
                "Staging files")
        }

        let sortedMetadata = metadata.sorted(by: { $0.path < $1.path })
        var crc32ByPath = [String: UInt32]()
        let entries = try sortedMetadata.enumerated().map { index, item in
            let url = staging.appendingPathComponent(item.path)
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            let digests = try digests(of: url)
            crc32ByPath[item.path] = digests.crc32
            let entry = MANTAFileEntry(
                path: item.path,
                mediaType: item.mediaType,
                role: item.role,
                size: Int64(values.fileSize ?? 0),
                sha256: digests.sha256)
            progress?(
                0.35 + 0.25 * Double(index + 1) / Double(max(1, sortedMetadata.count)),
                "Hashing files")
            return entry
        }

        let manifest = MANTABundleManifest(
            schema: MANTABundleFormat.manifestSchema,
            bundleID: request.bundleID,
            parentBundleID: request.parentBundleID,
            sessionID: request.capture.sessionID,
            createdAt: request.createdAt,
            finalizedAt: request.finalizedAt,
            producer: request.producer,
            content: MANTAContentReferences(
                capture: "capture.json",
                layout: request.layoutPath,
                changeLog: request.parentBundleID == nil ? nil : "log_manta.json"),
            files: entries)
        try MANTAJSON.canonicalData(manifest).write(
            to: staging.appendingPathComponent(MANTABundleFormat.manifestFilename), options: .atomic)

        progress?(0.64, "Validating staged bundle")
        // SHA-256 was just computed from every staged byte above. Repeating the
        // hashes here adds a full payload pass without increasing assurance.
        _ = try MANTABundleValidator(fileManager: fileManager).validate(
            directory: staging, verifyFileHashes: false)
        progress?(0.76, "Creating archive")
        do {
            try MANTADeterministicZIP(fileManager: fileManager).write(
                directory: staging, to: archiveURL, precomputedCRC32: crc32ByPath)
            progress?(1.0, "Archive created")
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: archiveURL.path)
            return MANTAFinalizedBundle(archiveURL: archiveURL, manifest: manifest)
        } catch {
            progress?(0.90, "Saving directory package")
            if fileManager.fileExists(atPath: archiveURL.path) {
                try fileManager.removeItem(at: archiveURL)
            }
            try fileManager.moveItem(at: staging, to: archiveURL)
            shouldRemoveStaging = false
            progress?(1.0, "Directory package created")
            return MANTAFinalizedBundle(
                archiveURL: archiveURL, manifest: manifest, container: .directoryPackage)
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
            throw MANTABundleFinalizationError.invalidPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw MANTABundleFinalizationError.invalidPath(path)
        }
    }

    private func digests(of url: URL) throws -> (sha256: String, crc32: UInt32) {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        var hasher = SHA256()
        var crc = MANTACRC32()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            hasher.update(data: chunk)
            crc.update(chunk)
        }
        return (
            hasher.finalize().map { String(format: "%02x", $0) }.joined(),
            crc.finalize())
    }
}
