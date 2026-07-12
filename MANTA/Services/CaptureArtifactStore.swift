//
//  CaptureArtifactStore.swift
//  MANTA
//
//  Created by Codex on 7/10/26.
//

import Foundation
import MANTACore
import simd

#if canImport(CoreImage) && canImport(UIKit)
import Compression
import CoreGraphics
import CoreImage
import CoreVideo
import UIKit
#endif

struct CaptureArtifactStore {
    private let fileManager: FileManager
    let rootDirectory: URL

    init(fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        let documents = try fileManager.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        rootDirectory = documents.appendingPathComponent("MANTA Sessions", isDirectory: true)
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    init(rootDirectory: URL, fileManager: FileManager = .default) throws {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
        try fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
    }

    var availableCapacityBytes: Int64? {
        let values = try? rootDirectory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    func sessionDirectory(for session: ScanSession) throws -> URL {
        let directory = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: assetsDirectory(for: session), withIntermediateDirectories: true)
        return directory
    }

    func assetsDirectory(for session: ScanSession) -> URL {
        rootDirectory
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("assets", isDirectory: true)
    }

    func diagnosticsURL(for session: ScanSession) -> URL {
        rootDirectory
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("diagnostics.json")
    }

    func sessionMetadataURL(for id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("session.json")
    }

    // MARK: - Session persistence

    /// Persists the full session (labels, fiducials, alignment, review state) so
    /// it can be reopened later and reprocessed. Numeric date encoding keeps the
    /// round trip exact. Sessions live on disk keyed by UUID; the subject
    /// label/timestamp are metadata inside the JSON.
    @discardableResult
    func writeSession(_ session: ScanSession) throws -> URL {
        _ = try sessionDirectory(for: session)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(session)
        let url = sessionMetadataURL(for: session.id)
        try data.write(to: url, options: .atomic)
        return url
    }

    func loadSession(id: UUID) throws -> ScanSession {
        let data = try Data(contentsOf: sessionMetadataURL(for: id))
        return try JSONDecoder().decode(ScanSession.self, from: data)
    }

    func deleteSession(id: UUID) throws {
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        if fileManager.fileExists(atPath: directory.path) {
            try fileManager.removeItem(at: directory)
        }
    }

    /// Finalizes an immutable, validated `.manta` snapshot for off-device hand-off.
    /// Mutable working-session files are adapted into the public capture contract;
    /// `session.json` and diagnostics are intentionally not copied into the bundle.
    func exportSessionBundle(id: UUID) throws -> MANTAStoreExportResult {
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CaptureArtifactStoreError.sessionNotFound
        }
        let session = try loadSession(id: id)
        let finalizedAt = Date()
        let bundleID = UUID()
        let capture = makeCaptureDocument(session)
        let sources = bundleFileSources(session, in: directory)
        let changes: [MANTAChangeRecord]
        if session.lastExportedBundleID == nil {
            changes = []
        } else {
            changes = [
                MANTAChangeRecord(
                    changedAt: finalizedAt,
                    category: "session-export",
                    summary: "Exported a revised capture or processing snapshot.",
                    targets: ["capture.json"])
            ]
        }
        let request = MANTABundleFinalizationRequest(
            capture: capture,
            producer: producerMetadata(),
            createdAt: session.createdAt,
            finalizedAt: finalizedAt,
            bundleID: bundleID,
            parentBundleID: session.lastExportedBundleID,
            changes: changes,
            files: sources)
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MANTA Exports", isDirectory: true)
            .appendingPathComponent(bundleID.uuidString, isDirectory: true)
        let finalized = try MANTABundleFinalizer(fileManager: fileManager).finalize(
            request, in: outputDirectory)
        let verificationDirectory = outputDirectory.appendingPathComponent("verified", isDirectory: true)
        _ = try MANTAArchiveImporter(fileManager: fileManager).importBundle(
            at: finalized.archiveURL, to: verificationDirectory)
        try fileManager.removeItem(at: verificationDirectory)
        return MANTAStoreExportResult(url: finalized.archiveURL, bundleID: bundleID)
    }

    private func makeCaptureDocument(_ session: ScanSession) -> MANTACaptureDocument {
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
            return MANTACaptureObservation(
                id: observation.id,
                capturedAt: observation.capturedAt,
                imagePath: observation.cameraSnapshotFilename,
                imageDimensions: MANTAImageDimensions(
                    width: observation.imageResolution.width,
                    height: observation.imageResolution.height),
                imageOrigin: "top-left",
                imageOrientation: "up",
                intrinsics: observation.cameraIntrinsics.map(Double.init),
                cameraToWorld: observation.cameraTransform.map(Double.init),
                worldCoordinateSystem: "arkit-world",
                depth: depth,
                trackingState: observation.trackingSummary,
                quality: observation.quality)
        }
        let mode: String
        switch session.captureMode {
        case .lidar: mode = "lidar"
        case .photogrammetry: mode = "photogrammetry"
        case .both: mode = "both"
        }
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
            observations: observations)
    }

    private func bundleFileSources(_ session: ScanSession, in directory: URL) -> [MANTABundleFileSource] {
        var items = [String: (mediaType: String, role: String)]()
        for observation in session.captureObservations {
            if let path = observation.cameraSnapshotFilename {
                items[path] = ("image/jpeg", "camera-image")
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
        if let path = session.photogrammetryModelFilename {
            items[path] = ("model/vnd.usdz+zip", "photogrammetry-model")
        }
        for path in ["reconstruction/poses.json", "reconstruction/diagnostics.json"] {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) {
                items[path] = ("application/json", "reconstruction-metadata")
            }
        }
        let runsDirectory = directory.appendingPathComponent("runs", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: runsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "json" {
                let relative = file.path.replacingOccurrences(
                    of: runsDirectory.path + "/", with: "")
                items["runs/\(relative)"] =
                    ("application/json", "electrode-detection-run")
            }
        }
        return items.map { path, metadata in
            MANTABundleFileSource(
                path: path,
                sourceURL: directory.appendingPathComponent(path),
                mediaType: metadata.mediaType,
                role: metadata.role)
        }
    }

    private func producerMetadata() -> MANTAProducer {
        let info = Bundle.main.infoDictionary ?? [:]
        #if canImport(UIKit)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        let operatingSystemVersion = UIDevice.current.systemVersion
        let deviceModel = UIDevice.current.model
        #else
        let platform = "Apple"
        let operatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let deviceModel = "unknown"
        #endif
        return MANTAProducer(
            application: info["CFBundleDisplayName"] as? String ?? "MANTA",
            version: info["CFBundleShortVersionString"] as? String ?? "0",
            build: info["CFBundleVersion"] as? String ?? "0",
            platform: platform,
            operatingSystemVersion: operatingSystemVersion,
            deviceModel: deviceModel)
    }

    /// Lightweight summaries of all persisted sessions, newest first. Sorting is
    /// always by capture time so the library stays date-ordered regardless of
    /// subject labels.
    func listSessionSummaries() -> [SessionSummary] {
        guard let entries = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        let summaries: [SessionSummary] = entries.compactMap { directory in
            guard UUID(uuidString: directory.lastPathComponent) != nil else { return nil }
            let metadata = directory.appendingPathComponent("session.json")
            guard let data = try? Data(contentsOf: metadata),
                  let session = try? decoder.decode(ScanSession.self, from: data) else {
                return nil
            }
            return SessionSummary(session: session)
        }

        return summaries.sorted { $0.createdAt > $1.createdAt }
    }

    func reconstructionDirectory(for session: ScanSession) -> URL {
        rootDirectory
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("reconstruction", isDirectory: true)
    }

    func runsDirectory(for session: ScanSession) -> URL {
        rootDirectory
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("runs", isDirectory: true)
    }

    @discardableResult
    func writeDetectionDiagnostics(
        _ diagnostics: DetectionRunDiagnostics, for session: ScanSession
    ) throws -> URL {
        let root = runsDirectory(for: session)
        let directory = root.appendingPathComponent(
            diagnostics.mode == .live ? "live-current" : diagnostics.id.uuidString,
            isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("run.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(diagnostics).write(to: url, options: .atomic)
        return url
    }

    /// Relative path (from the session directory) of the reconstructed model.
    var reconstructionModelRelativePath: String { "reconstruction/model.usdz" }

    func reconstructionModelURL(for session: ScanSession) -> URL {
        reconstructionDirectory(for: session).appendingPathComponent("model.usdz")
    }

    @discardableResult
    func writeReconstructionDiagnostics(
        _ diagnostics: ReconstructionDiagnostics, for session: ScanSession
    ) throws -> URL {
        let directory = reconstructionDirectory(for: session)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("diagnostics.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(diagnostics).write(to: url, options: .atomic)
        return url
    }

    /// Persists a world-space LiDAR mesh point cloud as little-endian Float32 XYZ triples.
    /// Returns the path relative to the session directory.
    @discardableResult
    func writeLiDARMesh(_ points: [SIMD3<Float>], for session: ScanSession) throws -> String {
        _ = try sessionDirectory(for: session)
        let reconstruction = reconstructionDirectory(for: session)
        try fileManager.createDirectory(at: reconstruction, withIntermediateDirectories: true)

        var floats = [Float]()
        floats.reserveCapacity(points.count * 3)
        for point in points {
            floats.append(point.x)
            floats.append(point.y)
            floats.append(point.z)
        }

        let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
        let filename = "lidar_mesh.f32"
        try data.write(to: reconstruction.appendingPathComponent(filename), options: .atomic)
        return "reconstruction/\(filename)"
    }

    /// Persists the complete ARKit mesh as binary little-endian PLY so deferred
    /// solvers retain both world-space vertices and triangle topology.
    @discardableResult
    func writeLiDARMeshSnapshot(_ snapshot: LiDARMeshSnapshot, for session: ScanSession) throws -> String {
        _ = try sessionDirectory(for: session)
        let reconstruction = reconstructionDirectory(for: session)
        try fileManager.createDirectory(at: reconstruction, withIntermediateDirectories: true)
        let faceCount = snapshot.triangleIndices.count / 3
        let header = """
            ply
            format binary_little_endian 1.0
            comment MANTA ARKit world-space mesh; coordinates are meters
            element vertex \(snapshot.vertices.count)
            property float x
            property float y
            property float z
            element face \(faceCount)
            property list uchar uint vertex_indices
            end_header
            """ + "\n"
        var data = Data(header.utf8)
        data.reserveCapacity(data.count + snapshot.vertices.count * 12 + faceCount * 13)
        for vertex in snapshot.vertices {
            data.appendLittleEndian(vertex.x.bitPattern)
            data.appendLittleEndian(vertex.y.bitPattern)
            data.appendLittleEndian(vertex.z.bitPattern)
        }
        for face in 0..<faceCount {
            data.append(3)
            data.appendLittleEndian(snapshot.triangleIndices[face * 3])
            data.appendLittleEndian(snapshot.triangleIndices[face * 3 + 1])
            data.appendLittleEndian(snapshot.triangleIndices[face * 3 + 2])
        }
        let filename = "lidar_mesh.ply"
        try data.write(to: reconstruction.appendingPathComponent(filename), options: .atomic)
        return "reconstruction/\(filename)"
    }

    /// Collects the captured RGB frames into a dedicated input folder and writes the pose manifest.
    /// Returns the folder to feed to photogrammetry plus the manifest of ARKit camera poses.
    func prepareReconstructionInput(for session: ScanSession) throws -> (imagesDirectory: URL, manifest: ReconstructionManifest) {
        _ = try sessionDirectory(for: session)
        let reconstruction = reconstructionDirectory(for: session)
        let inputDirectory = reconstruction.appendingPathComponent("input", isDirectory: true)

        // Start clean so stale frames don't leak into a new run.
        if fileManager.fileExists(atPath: inputDirectory.path) {
            try fileManager.removeItem(at: inputDirectory)
        }
        try fileManager.createDirectory(at: inputDirectory, withIntermediateDirectories: true)

        let sessionDir = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
        var poses: [ReconstructionPose] = []

        for observation in session.captureObservations {
            guard let relativePath = observation.cameraSnapshotFilename else { continue }
            let source = sessionDir.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            let filename = source.lastPathComponent
            let destination = inputDirectory.appendingPathComponent(filename)
            try? fileManager.removeItem(at: destination)
            try fileManager.copyItem(at: source, to: destination)
            poses.append(ReconstructionPose(imageFilename: filename, cameraTransform: observation.cameraTransform))
        }

        let manifest = ReconstructionManifest(poses: poses)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: reconstruction.appendingPathComponent("poses.json"), options: .atomic)

        return (inputDirectory, manifest)
    }

    @discardableResult
    func writeDiagnostics(for session: ScanSession, scanStatus: LiveScanStatus) throws -> URL {
        _ = try sessionDirectory(for: session)
        let export = CaptureDiagnosticsExport(session: session, scanStatus: scanStatus)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        let url = diagnosticsURL(for: session)
        try data.write(to: url, options: .atomic)
        return url
    }

    #if canImport(CoreImage) && canImport(UIKit)
    func writeCameraSnapshot(pixelBuffer: CVPixelBuffer, observationID: UUID, for session: ScanSession) throws -> String {
        _ = try sessionDirectory(for: session)
        let filename = "camera_\(observationID.uuidString).jpg"
        let url = assetsDirectory(for: session).appendingPathComponent(filename)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureArtifactStoreError.imageEncodingFailed
        }

        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.88) else {
            throw CaptureArtifactStoreError.imageEncodingFailed
        }

        try data.write(to: url, options: .atomic)
        return "assets/\(filename)"
    }

    func writeDepthSnapshot(
        depthMap: CVPixelBuffer,
        confidenceMap: CVPixelBuffer?,
        observationID: UUID,
        for session: ScanSession
    ) throws -> DepthSnapshotArtifact {
        _ = try sessionDirectory(for: session)
        let filename = "depth_\(observationID.uuidString).png"
        let url = assetsDirectory(for: session).appendingPathComponent(filename)
        let summary = try makeDepthPNG(depthMap: depthMap, destinationURL: url)
        let rawDepth = try writeRawDepth(depthMap: depthMap, observationID: observationID, for: session)
        let rawConfidence = try confidenceMap.map {
            try writeRawConfidence(confidenceMap: $0, observationID: observationID, for: session)
        }

        return DepthSnapshotArtifact(
            filename: "assets/\(filename)",
            rawDepthFilename: rawDepth.filename,
            rawDepthFormat: rawDepth.format,
            rawConfidenceFilename: rawConfidence?.filename,
            rawConfidenceFormat: rawConfidence?.format,
            confidenceSummary: rawConfidence?.summary,
            summary: summary
        )
    }

    private func makeDepthPNG(depthMap: CVPixelBuffer, destinationURL: URL) throws -> DepthSnapshotSummary {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw CaptureArtifactStoreError.depthEncodingFailed
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let rowStride = bytesPerRow / MemoryLayout<Float32>.stride
        let values = baseAddress.assumingMemoryBound(to: Float32.self)

        var minimum = Float.greatestFiniteMagnitude
        var maximum: Float = 0
        var total: Float = 0
        var validCount = 0

        for y in 0..<height {
            let row = y * rowStride
            for x in 0..<width {
                let value = values[row + x]
                guard value.isFinite, value > 0 else {
                    continue
                }

                minimum = min(minimum, value)
                maximum = max(maximum, value)
                total += value
                validCount += 1
            }
        }

        guard validCount > 0, maximum > minimum else {
            throw CaptureArtifactStoreError.depthEncodingFailed
        }

        let scale = Float(UInt8.max) / (maximum - minimum)
        var grayscale = [UInt8](repeating: 0, count: width * height)

        for y in 0..<height {
            let row = y * rowStride
            for x in 0..<width {
                let value = values[row + x]
                guard value.isFinite, value > 0 else {
                    continue
                }

                let normalized = max(0, min(Float(UInt8.max), (value - minimum) * scale))
                grayscale[y * width + x] = UInt8(normalized)
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard
            let provider = CGDataProvider(data: Data(grayscale) as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let data = UIImage(cgImage: image).pngData()
        else {
            throw CaptureArtifactStoreError.depthEncodingFailed
        }

        try data.write(to: destinationURL, options: .atomic)

        return DepthSnapshotSummary(
            width: width,
            height: height,
            validPixelCount: validCount,
            minimumDepth: minimum,
            maximumDepth: maximum,
            meanDepth: total / Float(validCount)
        )
    }

    private func writeRawDepth(depthMap: CVPixelBuffer, observationID: UUID, for session: ScanSession) throws -> RawDepthArtifact {
        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthMap) else {
            throw CaptureArtifactStoreError.rawDepthEncodingFailed
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthMap)
        let rowStride = bytesPerRow / MemoryLayout<Float32>.stride
        let values = baseAddress.assumingMemoryBound(to: Float32.self)
        var depthValues = [Float32]()
        depthValues.reserveCapacity(width * height)

        for y in 0..<height {
            let row = y * rowStride
            for x in 0..<width {
                depthValues.append(values[row + x])
            }
        }

        let data = depthValues.withUnsafeBufferPointer { buffer in
            Data(buffer: UnsafeBufferPointer(start: buffer.baseAddress, count: buffer.count))
        }
        let compressed = try compress(data)
        let filename = "depth_\(observationID.uuidString).f32.zlib"
        try compressed.write(to: assetsDirectory(for: session).appendingPathComponent(filename), options: .atomic)

        let format = RawDepthFormat(
            width: width,
            height: height,
            scalarType: "Float32",
            byteOrder: "littleEndian",
            units: .meters,
            layout: "rowMajorNoPadding",
            compression: "zlib"
        )
        return RawDepthArtifact(filename: "assets/\(filename)", format: format)
    }

    private func writeRawConfidence(
        confidenceMap: CVPixelBuffer,
        observationID: UUID,
        for session: ScanSession
    ) throws -> RawConfidenceArtifact {
        CVPixelBufferLockBaseAddress(confidenceMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(confidenceMap) else {
            throw CaptureArtifactStoreError.rawConfidenceEncodingFailed
        }

        let width = CVPixelBufferGetWidth(confidenceMap)
        let height = CVPixelBufferGetHeight(confidenceMap)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(confidenceMap)
        let values = baseAddress.assumingMemoryBound(to: UInt8.self)
        var confidenceValues = [UInt8]()
        confidenceValues.reserveCapacity(width * height)
        var lowCount = 0
        var mediumCount = 0
        var highCount = 0
        var unknownCount = 0

        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let value = values[row + x]
                confidenceValues.append(value)

                switch value {
                case 0:
                    lowCount += 1
                case 1:
                    mediumCount += 1
                case 2:
                    highCount += 1
                default:
                    unknownCount += 1
                }
            }
        }

        let data = Data(confidenceValues)
        let compressed = try compress(data)
        let filename = "confidence_\(observationID.uuidString).u8.zlib"
        try compressed.write(to: assetsDirectory(for: session).appendingPathComponent(filename), options: .atomic)

        let format = RawConfidenceFormat(
            width: width,
            height: height,
            scalarType: "UInt8",
            valueMapping: [
                "0": "low",
                "1": "medium",
                "2": "high"
            ],
            layout: "rowMajorNoPadding",
            compression: "zlib"
        )
        let summary = ConfidenceMapSummary(
            width: width,
            height: height,
            lowConfidenceCount: lowCount,
            mediumConfidenceCount: mediumCount,
            highConfidenceCount: highCount,
            unknownConfidenceCount: unknownCount
        )

        return RawConfidenceArtifact(filename: "assets/\(filename)", format: format, summary: summary)
    }

    private func compress(_ data: Data) throws -> Data {
        try data.withUnsafeBytes { sourceBuffer in
            guard let sourcePointer = sourceBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return Data()
            }

            var destination = [UInt8](repeating: 0, count: data.count + max(1024, data.count / 100 + 64))
            let compressedSize = compression_encode_buffer(
                &destination,
                destination.count,
                sourcePointer,
                data.count,
                nil,
                COMPRESSION_ZLIB
            )

            guard compressedSize > 0 else {
                throw CaptureArtifactStoreError.compressionFailed
            }

            return Data(destination.prefix(compressedSize))
        }
    }
    #endif
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}

enum CaptureArtifactStoreError: LocalizedError {
    case imageEncodingFailed
    case depthEncodingFailed
    case rawDepthEncodingFailed
    case rawConfidenceEncodingFailed
    case compressionFailed
    case sessionNotFound
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .imageEncodingFailed:
            return "Camera snapshot could not be encoded."
        case .depthEncodingFailed:
            return "Depth snapshot could not be encoded."
        case .rawDepthEncodingFailed:
            return "Raw depth data could not be encoded."
        case .rawConfidenceEncodingFailed:
            return "Raw confidence data could not be encoded."
        case .compressionFailed:
            return "Capture data could not be compressed."
        case .sessionNotFound:
            return "That session could not be found on disk."
        case .exportFailed:
            return "The session bundle could not be created."
        }
    }
}

struct MANTAStoreExportResult {
    var url: URL
    var bundleID: UUID
}

/// Lightweight, list-friendly view of a persisted session (no observation array).
struct SessionSummary: Identifiable, Equatable {
    var id: UUID
    var subjectLabel: String?
    var createdAt: Date
    var displayName: String
    var timestampName: String
    var observationCount: Int
    var detectedElectrodeCount: Int
    var hasReconstructedModel: Bool

    init(session: ScanSession) {
        id = session.id
        subjectLabel = session.subjectLabel
        createdAt = session.createdAt
        displayName = session.displayName
        timestampName = session.timestampName
        observationCount = session.captureObservations.count
        detectedElectrodeCount = session.detectedElectrodeCount
        hasReconstructedModel = session.hasReconstructedModel
    }
}

struct DepthSnapshotArtifact {
    var filename: String
    var rawDepthFilename: String
    var rawDepthFormat: RawDepthFormat
    var rawConfidenceFilename: String?
    var rawConfidenceFormat: RawConfidenceFormat?
    var confidenceSummary: ConfidenceMapSummary?
    var summary: DepthSnapshotSummary
}

struct RawDepthArtifact {
    var filename: String
    var format: RawDepthFormat
}

struct RawConfidenceArtifact {
    var filename: String
    var format: RawConfidenceFormat
    var summary: ConfidenceMapSummary
}

struct CaptureDiagnosticsExport: Codable, Equatable {
    var exportedAt: Date
    var sessionID: UUID
    var sessionName: String
    var createdAt: Date
    var layoutName: String
    var channelCount: Int
    var referenceSensor: Int?
    var referenceLabel: String?
    var capturedObservationCount: Int
    var detectedElectrodeCount: Int
    var reviewedElectrodeCount: Int
    var scanStatus: LiveScanStatusSnapshot
    var observations: [CaptureObservation]

    init(session: ScanSession, scanStatus: LiveScanStatus) {
        exportedAt = Date()
        sessionID = session.id
        sessionName = session.name
        createdAt = session.createdAt
        layoutName = session.layout.name
        channelCount = session.layout.channelCount
        referenceSensor = session.layout.referenceSensor
        referenceLabel = session.layout.referenceLabel
        capturedObservationCount = session.captureObservations.count
        detectedElectrodeCount = session.detectedElectrodeCount
        reviewedElectrodeCount = session.reviewedElectrodeCount
        self.scanStatus = LiveScanStatusSnapshot(status: scanStatus)
        observations = session.captureObservations
    }
}

struct LiveScanStatusSnapshot: Codable, Equatable {
    var isSupported: Bool
    var isRunning: Bool
    var trackingSummary: String
    var frameCount: Int
    var sampledFrameCount: Int
    var meshAnchorCount: Int
    var hasSceneDepth: Bool
    var lastSampledAt: Date?
    var message: String

    init(status: LiveScanStatus) {
        isSupported = status.isSupported
        isRunning = status.isRunning
        trackingSummary = status.trackingSummary
        frameCount = status.frameCount
        sampledFrameCount = status.sampledFrameCount
        meshAnchorCount = status.meshAnchorCount
        hasSceneDepth = status.hasSceneDepth
        lastSampledAt = status.lastSampledAt
        message = status.message
    }
}
