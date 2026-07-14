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
import ImageIO
import UIKit
#endif

struct CaptureArtifactStore: @unchecked Sendable {
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

    func acquisitionDirectory(for session: ScanSession) -> URL {
        rootDirectory
            .appendingPathComponent(session.id.uuidString, isDirectory: true)
            .appendingPathComponent("acquisition", isDirectory: true)
    }

    @discardableResult
    func appendAcquisitionEvent(_ event: AcquisitionEvent, for session: ScanSession) throws -> URL {
        let directory = acquisitionDirectory(for: session)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("events.jsonl")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(event)
        data.append(0x0A)
        if fileManager.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.synchronize()
        } else {
            try data.write(to: url, options: .atomic)
        }
        return url
    }

    @discardableResult
    func writeAcquisitionContext(for session: ScanSession) throws -> URL? {
        let context = session.acquisitionContext ?? AcquisitionContext(netModel: session.layout.name)
        let directory = acquisitionDirectory(for: session)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("context.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(context).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    func writeFiducialPlacementEvidence(for session: ScanSession) throws -> URL? {
        guard let evidence = session.fiducialPlacementEvidence, !evidence.isEmpty else { return nil }
        let directory = acquisitionDirectory(for: session)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fiducial-placements.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(evidence).write(to: url, options: .atomic)
        return url
    }

    @discardableResult
    func writeCaptureReceipt(for session: ScanSession) throws -> (url: URL, receipt: CaptureReceipt) {
        let directory = try sessionDirectory(for: session)
        let receipt = CaptureReceiptBuilder.build(session: session, sessionDirectory: directory)
        let url = directory.appendingPathComponent("capture-receipt.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(receipt).write(to: url, options: .atomic)
        return (url, receipt)
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

    /// Creates paired immutable snapshots: acquisition evidence without solver
    /// outputs, and the complete solved/reviewed state. Both are deeply checked
    /// before finalization and independently re-imported afterward.
    func exportSessionBundles(id: UUID) throws -> MANTAStoreExportPair {
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CaptureArtifactStoreError.sessionNotFound
        }
        let session = try loadSession(id: id)
        let finalizedAt = Date()
        _ = try writeAcquisitionContext(for: session)
        _ = try writeFiducialPlacementEvidence(for: session)
        let receiptResult = try writeCaptureReceipt(for: session)
        guard receiptResult.receipt.status != .failed else {
            throw CaptureArtifactStoreError.captureReceiptFailed
        }

        let raw = try finalizeSessionBundle(
            session, directory: directory, finalizedAt: finalizedAt, variant: .raw)
        let solved = try finalizeSessionBundle(
            session, directory: directory, finalizedAt: finalizedAt, variant: .solved)
        return MANTAStoreExportPair(raw: raw, solved: solved, receipt: receiptResult.receipt)
    }

    /// Seals acquisition evidence without requiring or including any solver,
    /// reconstruction, review, or final-coordinate output.
    func exportRawSessionBundle(
        id: UUID,
        progress: (@Sendable (Double, String) -> Void)? = nil
    ) throws -> MANTAStoreValidatedExportResult {
        progress?(0.01, "Preparing acquisition")
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CaptureArtifactStoreError.sessionNotFound
        }
        let session = try loadSession(id: id)
        progress?(0.04, "Writing acquisition metadata")
        _ = try writeAcquisitionContext(for: session)
        _ = try writeFiducialPlacementEvidence(for: session)
        let receiptResult = try writeCaptureReceipt(for: session)
        progress?(0.10, "Capture validation complete")
        guard receiptResult.receipt.status != .failed else {
            throw CaptureArtifactStoreError.captureReceiptFailed
        }
        let export = try finalizeSessionBundle(
            session, directory: directory, finalizedAt: Date(), variant: .raw,
            progress: progress, verifyFinalArchive: false)
        return MANTAStoreValidatedExportResult(export: export, receipt: receiptResult.receipt)
    }

    /// Single solved export retained for programmatic callers and compatibility.
    /// The acquisition UI uses `exportSessionBundles`, which adds the deep gate
    /// and paired raw snapshot.
    func exportSessionBundle(id: UUID) throws -> MANTAStoreExportResult {
        let directory = rootDirectory.appendingPathComponent(id.uuidString, isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw CaptureArtifactStoreError.sessionNotFound
        }
        let session = try loadSession(id: id)
        _ = try writeAcquisitionContext(for: session)
        _ = try writeFiducialPlacementEvidence(for: session)
        return try finalizeSessionBundle(
            session, directory: directory, finalizedAt: Date(), variant: .solved)
    }

    private func finalizeSessionBundle(
        _ session: ScanSession, directory: URL, finalizedAt: Date,
        variant: MANTAExportVariant,
        progress: (@Sendable (Double, String) -> Void)? = nil,
        verifyFinalArchive: Bool = true
    ) throws -> MANTAStoreExportResult {
        let bundleID = UUID()
        let capture = makeCaptureDocument(session, variant: variant)
        let layout = layoutReferenceSources(for: session)
        let sources = bundleFileSources(session, in: directory, variant: variant) + layout.sources
        let parentBundleID = variant == .raw
            ? session.lastRawExportedBundleID : session.lastExportedBundleID
        let changes: [MANTAChangeRecord]
        if parentBundleID == nil {
            changes = []
        } else {
            changes = [
                MANTAChangeRecord(
                    changedAt: finalizedAt,
                    category: variant == .raw ? "raw-capture-export" : "solved-session-export",
                    summary: variant == .raw
                        ? "Exported a revised immutable acquisition snapshot."
                        : "Exported a revised capture and processing snapshot.",
                    targets: ["capture.json"])
            ]
        }
        let request = MANTABundleFinalizationRequest(
            capture: capture,
            producer: producerMetadata(),
            createdAt: session.createdAt,
            finalizedAt: finalizedAt,
            bundleID: bundleID,
            parentBundleID: parentBundleID,
            changes: changes,
            files: sources,
            layoutPath: layout.layoutPath,
            filenameTag: variant.rawValue)
        let outputDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("MANTA Exports", isDirectory: true)
            .appendingPathComponent(bundleID.uuidString, isDirectory: true)
        let finalized = try MANTABundleFinalizer(fileManager: fileManager).finalize(
            request, in: outputDirectory
        ) { fraction, stage in
            progress?(0.10 + fraction * 0.70, stage)
        }
        if verifyFinalArchive {
            progress?(0.82, "Verifying archive")
            let verificationDirectory = outputDirectory.appendingPathComponent(
                "verified", isDirectory: true)
            if finalized.container == .archive {
                _ = try MANTAArchiveImporter(fileManager: fileManager).importBundle(
                    at: finalized.archiveURL, to: verificationDirectory)
                try fileManager.removeItem(at: verificationDirectory)
            } else {
                _ = try MANTABundleValidator(fileManager: fileManager).validate(
                    directory: finalized.archiveURL)
            }
        } else {
            progress?(0.92, "Sealing archive")
        }
        progress?(1.0, "Raw bundle ready")
        return MANTAStoreExportResult(
            url: finalized.archiveURL, bundleID: bundleID, container: finalized.container)
    }

    private func makeCaptureDocument(
        _ session: ScanSession, variant: MANTAExportVariant = .solved
    ) -> MANTACaptureDocument {
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
        // Fiducials and electrodes are persisted in the ARKit world frame (meters),
        // matching the declared coordinate system, so a receiver can re-derive the
        // head frame from the same landmarks the operator placed.
        let fiducials = variant == .solved ? session.fiducials.map({ fiducial in
            MANTAFiducialSolution(
                kind: fiducial.kind.rawValue,
                coordinateSystem: "arkit-world",
                coordinate: fiducial.coordinate.map { [$0.x, $0.y, $0.z] },
                state: fiducial.state.rawValue)
        }) : []
        let electrodes = variant == .solved ? session.electrodes.map({ electrode in
            MANTAElectrodeSolution(
                label: electrode.label,
                role: electrode.role.rawValue,
                coordinateSystem: "arkit-world",
                coordinate: [electrode.coordinate.x, electrode.coordinate.y, electrode.coordinate.z],
                confidence: electrode.confidence,
                state: electrode.state.rawValue)
        }) : []
        let reconstruction: MANTAReconstructionReference? = {
            let objectModel = variant == .solved ? session.photogrammetryModelFilename : nil
            guard session.lidarMeshFilename != nil
                    || session.headCroppedLidarMeshFilename != nil
                    || objectModel != nil
                    || session.headBoundingBox != nil else {
                return nil
            }
            return MANTAReconstructionReference(
                lidarMeshPath: session.lidarMeshFilename,
                headCroppedLidarMeshPath: session.headCroppedLidarMeshFilename,
                objectCaptureModelPath: objectModel,
                headBoundingBox: session.headBoundingBox,
                modelToWorld: variant == .solved ? session.worldAlignmentTransform?.map(Double.init) : nil,
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
            fiducials: fiducials.isEmpty ? nil : fiducials,
            electrodes: electrodes.isEmpty ? nil : electrodes,
            reconstruction: reconstruction)
    }

    private func bundleFileSources(
        _ session: ScanSession, in directory: URL, variant: MANTAExportVariant
    ) -> [MANTABundleFileSource] {
        var items = [String: (mediaType: String, role: String)]()
        for observation in session.captureObservations {
            if let path = observation.cameraSnapshotFilename {
                let mediaType = imageMediaType(for: path)
                items[path] = (mediaType, "camera-image")
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
        if variant == .solved, let path = session.photogrammetryModelFilename {
            items[path] = ("model/vnd.usdz+zip", "photogrammetry-model")
        }
        for path in variant == .solved
            ? ["reconstruction/poses.json", "reconstruction/diagnostics.json"] : [] {
            if fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) {
                items[path] = ("application/json", "reconstruction-metadata")
            }
        }
        let runsDirectory = directory.appendingPathComponent("runs", isDirectory: true)
        if variant == .solved, let enumerator = fileManager.enumerator(
            at: runsDirectory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) {
            for case let file as URL in enumerator where file.pathExtension.lowercased() == "json" {
                let relative = file.path.replacingOccurrences(
                    of: runsDirectory.path + "/", with: "")
                items["runs/\(relative)"] =
                    ("application/json", "electrode-detection-run")
            }
        }
        for (path, mediaType, role) in [
            ("capture-receipt.json", "application/json", "capture-validation-receipt"),
            ("acquisition/context.json", "application/json", "acquisition-context"),
            ("acquisition/events.jsonl", "application/x-ndjson", "acquisition-event-log"),
            ("acquisition/fiducial-placements.json", "application/json", "fiducial-placement-evidence")
        ] where fileManager.fileExists(atPath: directory.appendingPathComponent(path).path) {
            items[path] = (mediaType, role)
        }
        return items.map { path, metadata in
            MANTABundleFileSource(
                path: path,
                sourceURL: directory.appendingPathComponent(path),
                mediaType: metadata.mediaType,
                role: metadata.role)
        }
    }

    private func imageMediaType(for path: String) -> String {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "png": "image/png"
        case "heic", "heif": "image/heic"
        default: "image/jpeg"
        }
    }

    private func layoutReferenceSources(
        for session: ScanSession, bundle: Bundle = .main
    ) -> (sources: [MANTABundleFileSource], layoutPath: String?) {
        guard session.layout.hasElectrodeNet else { return ([], nil) }
        let filenames = [
            "coordinates_128.xml", "coordinates_256.xml",
            "sensorLayout_128.xml", "sensorLayout_256.xml",
            "HydroCelLayoutMetadata.json"
        ]
        let sources = filenames.compactMap { filename -> MANTABundleFileSource? in
            let components = filename.split(separator: ".", maxSplits: 1).map(String.init)
            guard components.count == 2 else { return nil }
            let source = ["Layouts", "Resources/Layouts"].compactMap { subdirectory in
                bundle.url(forResource: components[0], withExtension: components[1], subdirectory: subdirectory)
            }.first ?? bundle.url(forResource: components[0], withExtension: components[1])
            guard let source else { return nil }
            return MANTABundleFileSource(
                path: "layouts/source/\(filename)", sourceURL: source,
                mediaType: components[1] == "xml" ? "application/xml" : "application/json",
                role: filename.hasPrefix("sensorLayout")
                    ? "layout-topology-reference"
                    : (components[1] == "xml" ? "layout-coordinate-reference" : "layout-metadata"))
        }
        let selected = "layouts/source/coordinates_\(session.layout.channelCount).xml"
        return (sources, sources.contains(where: { $0.path == selected }) ? selected : nil)
    }

    private func producerMetadata() -> MANTAProducer {
        let info = Bundle.main.infoDictionary ?? [:]
        #if canImport(UIKit)
        let platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        let operatingSystemVersion = UIDevice.current.systemVersion
        let deviceModel = DeviceHardwareIdentifier.current
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
    func writeLiDARMeshSnapshot(
        _ snapshot: LiDARMeshSnapshot, for session: ScanSession,
        filename: String = "lidar_mesh.ply"
    ) throws -> String {
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
        try data.write(to: reconstruction.appendingPathComponent(filename), options: .atomic)
        return "reconstruction/\(filename)"
    }

    /// Reads back a mesh persisted by `writeLiDARMeshSnapshot`, so the head
    /// surface can be shown (and tapped for fiducials) after a session is
    /// reopened with the cameras off. Returns nil when no mesh was persisted or
    /// the file cannot be parsed.
    func loadLiDARMeshSnapshot(for session: ScanSession) -> LiDARMeshSnapshot? {
        guard let relativePath = session.lidarMeshFilename else { return nil }
        let sessionDir = rootDirectory.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let url = sessionDir.appendingPathComponent(relativePath)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.parseBinaryLittleEndianPLY(data)
    }

    /// Parses the specific binary-little-endian PLY layout written above:
    /// float32 xyz vertices followed by `uchar(3) + uint32×3` faces.
    static func parseBinaryLittleEndianPLY(_ data: Data) -> LiDARMeshSnapshot? {
        let marker = Data("end_header\n".utf8)
        guard let headerRange = data.range(of: marker) else { return nil }
        let header = String(decoding: data[data.startIndex..<headerRange.lowerBound], as: UTF8.self)

        var vertexCount = 0
        var faceCount = 0
        for line in header.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.count == 3, fields[0] == "element" else { continue }
            if fields[1] == "vertex" { vertexCount = Int(fields[2]) ?? 0 }
            if fields[1] == "face" { faceCount = Int(fields[2]) ?? 0 }
        }
        guard vertexCount > 0 else { return nil }

        let bytes = [UInt8](data[headerRange.upperBound...])
        var offset = 0

        func readFloat() -> Float? {
            guard offset + 4 <= bytes.count else { return nil }
            let bits = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return Float(bitPattern: bits)
        }
        func readUInt32() -> UInt32? {
            guard offset + 4 <= bytes.count else { return nil }
            let value = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            offset += 4
            return value
        }

        var vertices = [SIMD3<Float>]()
        vertices.reserveCapacity(vertexCount)
        for _ in 0..<vertexCount {
            guard let x = readFloat(), let y = readFloat(), let z = readFloat() else { return nil }
            vertices.append(SIMD3(x, y, z))
        }

        var triangleIndices = [UInt32]()
        triangleIndices.reserveCapacity(faceCount * 3)
        for _ in 0..<faceCount {
            guard offset < bytes.count, bytes[offset] == 3 else { break }
            offset += 1
            guard let a = readUInt32(), let b = readUInt32(), let c = readUInt32() else { break }
            triangleIndices.append(contentsOf: [a, b, c])
        }

        return LiDARMeshSnapshot(vertices: vertices, triangleIndices: triangleIndices)
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
    func writeCameraSnapshot(
        pixelBuffer: CVPixelBuffer, observationID: UUID, for session: ScanSession,
        includeCompressedImage: Bool = false
    ) throws -> CameraSnapshotArtifact {
        _ = try sessionDirectory(for: session)
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let context = CIContext()

        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            throw CaptureArtifactStoreError.imageEncodingFailed
        }

        // The permanent solver input is lossless. HEIC is an optional comparison
        // encoding; JPEG remains its automatic fallback when HEIC is unavailable.
        let primaryPath = try writeLosslessPNGSnapshot(
            cgImage: cgImage, observationID: observationID, for: session)
        let compressedPath = includeCompressedImage
            ? try writeCompressedSnapshot(
                cgImage: cgImage, observationID: observationID, for: session)
            : nil
        return CameraSnapshotArtifact(
            primaryFilename: primaryPath, compressedFilename: compressedPath)
    }

    /// Writes the frame as HEIC at the highest quality the encoder exposes.
    /// Returns `nil` (rather than throwing) when HEIC is unsupported so the caller
    /// can fall back to JPEG.
    private func writeHEICSnapshot(
        cgImage: CGImage, observationID: UUID, for session: ScanSession
    ) throws -> String? {
        let filename = "camera_\(observationID.uuidString).heic"
        let url = assetsDirectory(for: session).appendingPathComponent(filename)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.heic" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, cgImage,
            [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        try data.write(to: url, options: .atomic)
        return "assets/\(filename)"
    }

    private func writeLosslessPNGSnapshot(
        cgImage: CGImage, observationID: UUID, for session: ScanSession
    ) throws -> String {
        let filename = "camera_\(observationID.uuidString).png"
        let url = assetsDirectory(for: session).appendingPathComponent(filename)
        guard let data = UIImage(cgImage: cgImage).pngData() else {
            throw CaptureArtifactStoreError.imageEncodingFailed
        }
        try data.write(to: url, options: .atomic)
        return "assets/\(filename)"
    }

    private func writeCompressedSnapshot(
        cgImage: CGImage, observationID: UUID, for session: ScanSession
    ) throws -> String {
        if let heicPath = try writeHEICSnapshot(
            cgImage: cgImage, observationID: observationID, for: session
        ) {
            return heicPath
        }
        let filename = "camera_\(observationID.uuidString)_compressed.jpg"
        let url = assetsDirectory(for: session).appendingPathComponent(filename)
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.95) else {
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
    case captureReceiptFailed

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
        case .captureReceiptFailed:
            return "Deep capture validation failed. Review capture-receipt.json before exporting."
        }
    }
}

enum MANTAExportVariant: String {
    case raw
    case solved
}

struct MANTAStoreExportResult: Sendable {
    var url: URL
    var bundleID: UUID
    var container: MANTAFinalizedBundle.Container = .archive
}

struct MANTAStoreExportPair: Sendable {
    var raw: MANTAStoreExportResult
    var solved: MANTAStoreExportResult
    var receipt: CaptureReceipt
}

struct MANTAStoreValidatedExportResult: Sendable {
    var export: MANTAStoreExportResult
    var receipt: CaptureReceipt
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

struct CameraSnapshotArtifact {
    var primaryFilename: String
    var compressedFilename: String?
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
