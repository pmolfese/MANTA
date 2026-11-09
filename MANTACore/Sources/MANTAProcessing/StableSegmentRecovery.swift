#if os(macOS)
import Foundation
import CryptoKit
import Compression
import simd
import MANTACore

public struct StableSegmentRecoveryRequest: Codable, Sendable {
    public struct Landmark: Codable, Sendable {
        public var name: String
        public var coordinate: [Float]
        public init(name: String, coordinate: [Float]) { self.name = name; self.coordinate = coordinate }
    }
    public struct Segment: Codable, Sendable {
        public var bundlePath: String
        public var segmentID: UUID
        public var observationIDs: [UUID]
        public var reviewedStable: Bool
        public var headBounds: HeadBoundingBox
        public var landmarks: [Landmark]
        public init(bundlePath: String, segmentID: UUID, observationIDs: [UUID], reviewedStable: Bool,
                    headBounds: HeadBoundingBox, landmarks: [Landmark]) {
            self.bundlePath = bundlePath; self.segmentID = segmentID; self.observationIDs = observationIDs
            self.reviewedStable = reviewedStable; self.headBounds = headBounds; self.landmarks = landmarks
        }
    }
    public var automaticAlignment: Bool?
    public var acquisitionGroupID: String
    public var segments: [Segment]
    public init(acquisitionGroupID: String, segments: [Segment], automaticAlignment: Bool = false) {
        self.automaticAlignment = automaticAlignment ? true : nil
        self.acquisitionGroupID = acquisitionGroupID; self.segments = segments
    }
}

public struct StableSegmentRecoveryReport: Codable, Sendable {
    public struct Entry: Codable, Sendable {
        public var segmentID: UUID
        public var bundleID: UUID
        public var captureSHA256: String
        public var manifestSHA256: String
        public var observationIDs: [UUID]
        public var registration: SegmentRegistrationResult
        public var rejectedFrameIDs: [UUID]
        public var integrityWarnings: [String]
        public var previewPoints: [[Float]]?
        public var selectedPayloadSHA256: String?
    }
    public var runID: UUID
    public var createdAt: Date
    public var acquisitionGroupID: String
    public var accepted: Bool
    public var referenceSegmentID: UUID
    public var entries: [Entry]
    public var note: String
    public var requestSHA256: String?
}

public enum StableSegmentRecovery {
    private struct Loaded {
        var bundle: MANTAValidatedBundle
        var spec: StableSegmentRecoveryRequest.Segment
        var observations: [MANTACaptureObservation]
        var points: [SIMD3<Float>]
        var frames: [UUID: [SIMD3<Float>]]
        var landmarks: [SIMD3<Float>]
    }
    private static func payloadHash(_ segment: Loaded) throws -> String {
        var paths = Set<String>()
        for observation in segment.observations {
            for path in [observation.imagePath, observation.losslessImagePath, observation.compressedImagePath,
                         observation.depth?.path, observation.depth?.confidencePath].compactMap({ $0 }) { paths.insert(path) }
        }
        var digest = SHA256()
        for path in paths.sorted() {
            digest.update(data: Data(path.utf8))
            digest.update(data: Data(try hash(segment.bundle.rootDirectory.appendingPathComponent(path)).utf8))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func manifestURL(for root: URL) -> URL {
        let standard = root.appendingPathComponent("manifest.json")
        return FileManager.default.fileExists(atPath: standard.path) ? standard
            : root.appendingPathComponent("derivatives/acquisition/manifest.json")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "MANTA.SegmentRecovery", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Reference segment is first. Inputs are directory packages; output must not
    /// exist and must be outside every original package. Report-only is the default.
    public static func run(_ request: StableSegmentRecoveryRequest, output: URL, emitDerived: Bool = false, approvedPreview: StableSegmentRecoveryReport? = nil) throws -> StableSegmentRecoveryReport {
        guard (2...8).contains(request.segments.count), !request.acquisitionGroupID.isEmpty,
              Set(request.segments.map(\.segmentID)).count == request.segments.count else {
            throw failure("Provide 2–8 uniquely identified segments of the same person/net, with an acquisitionGroupID.")
        }
        let destination = output.standardizedFileURL.resolvingSymlinksInPath()
        for segment in request.segments {
            let source = URL(fileURLWithPath: segment.bundlePath).standardizedFileURL.resolvingSymlinksInPath()
            guard destination.path != source.path, !destination.path.hasPrefix(source.path + "/") else {
                throw failure("Recovery output must be outside original packages.")
            }
        }
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw failure("Output already exists; no files were overwritten.") }
        let automatic = request.automaticAlignment == true
        let names = automatic ? [] : request.segments[0].landmarks.map(\.name)
        guard automatic || (names.count >= 3 && names.count <= 32 && Set(names).count == names.count && names.allSatisfy({ !$0.isEmpty })) else {
            throw failure("Provide at least three uniquely named, matched, noncollinear head landmarks.")
        }
        let loaded = try request.segments.map { try load($0, landmarkNames: names) }
        guard Set(loaded.map { $0.bundle.capture.layoutID }).count == 1,
              Set(loaded.flatMap { $0.observations.map(\.id) }).count == loaded.reduce(0, { $0 + $1.observations.count }) else {
            throw failure("Layouts differ or observation identities repeat across selected segments.")
        }
        let reference = loaded[0]
        var entries: [StableSegmentRecoveryReport.Entry] = []
        var transforms: [simd_float4x4] = []
        for segment in loaded {
            let registration: SegmentRegistrationResult
            if automatic {
                // Every third depth frame is withheld from fitting. All frames, including
                // the withheld ones, must pass the agreement checks below.
                func fittingPoints(_ value: Loaded) -> [SIMD3<Float>] {
                    value.observations.filter { value.frames[$0.id] != nil }.enumerated()
                        .filter { $0.offset % 3 != 2 }.flatMap { value.frames[$0.element.id] ?? [] }
                }
                registration = segment.spec.segmentID == reference.spec.segmentID
                    ? SegmentRegistration.referenceIdentity(points: reference.points)
                    : SegmentRegistration.solveAutomatic(source: fittingPoints(segment), reference: fittingPoints(reference))
            } else {
                registration = SegmentRegistration.solve(source: segment.points, reference: reference.points,
                    sourceLandmarks: segment.landmarks, referenceLandmarks: reference.landmarks)
            }
            let transform = registration.referenceFromSource.flatMap(SegmentRegistration.matrix)
            let rejected = segment.frames.filter { frameID, points in
                guard let transform else { return true }
                let comparison = segment.spec.segmentID == reference.spec.segmentID
                    ? reference.frames.filter { $0.key != frameID }.sorted { $0.key.uuidString < $1.key.uuidString }.flatMap(\.value)
                    : reference.points
                return !SegmentRegistration.frameAgrees(points: points, reference: comparison, transform: transform)
            }.keys.sorted { $0.uuidString < $1.uuidString }
            transforms.append(transform ?? matrix_identity_float4x4) // Never used unless all gates pass.
            entries.append(.init(segmentID: segment.spec.segmentID, bundleID: segment.bundle.manifest.bundleID,
                captureSHA256: try hash(segment.bundle.rootDirectory.appendingPathComponent(segment.bundle.manifest.content.capture)),
                manifestSHA256: try hash(manifestURL(for: segment.bundle.rootDirectory)),
                observationIDs: segment.observations.map(\.id), registration: registration, rejectedFrameIDs: rejected,
                integrityWarnings: segment.bundle.integrityWarnings.map(\.message),
                previewPoints: segment.points.map { [$0.x, $0.y, $0.z] },
                selectedPayloadSHA256: try payloadHash(segment)))
        }
        var report = StableSegmentRecoveryReport(runID: UUID(), createdAt: Date(), acquisitionGroupID: request.acquisitionGroupID,
            accepted: entries.allSatisfy { $0.registration.accepted && $0.rejectedFrameIDs.isEmpty },
            referenceSegmentID: reference.spec.segmentID, entries: entries,
            note: "Experimental rigid recovery of explicitly reviewed stable intervals. Reference head coordinates equal the first segment's ARKit world in meters. Residuals share input depth and are not independent accuracy measurements. No scale fitting, deformation correction, or automatic interval selection.")
        if automatic { report.note += " Automatic geometry-only multistart registration; every third depth frame withheld from fitting. Ambiguity checks are heuristic, not calibrated confidence." }
        report.requestSHA256 = SHA256.hash(data: try MANTAJSON.canonicalData(request)).map { String(format: "%02x", $0) }.joined()
        if let approvedPreview {
            guard emitDerived, approvedPreview.accepted, report.accepted,
                  approvedPreview.requestSHA256 == report.requestSHA256,
                  approvedPreview.entries.count == report.entries.count,
                  zip(approvedPreview.entries, report.entries).allSatisfy({ old, new in
                      old.segmentID == new.segmentID && old.bundleID == new.bundleID
                        && old.captureSHA256 == new.captureSHA256 && old.manifestSHA256 == new.manifestSHA256
                        && old.selectedPayloadSHA256 == new.selectedPayloadSHA256
                        && old.observationIDs == new.observationIDs && old.rejectedFrameIDs == new.rejectedFrameIDs
                        && old.registration.referenceFromSource == new.registration.referenceFromSource
                  }) else { throw failure("The source or correction changed since preview. Run and review a new preview before saving.") }
            report.runID = approvedPreview.runID
            report.createdAt = approvedPreview.createdAt
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        try MANTAJSON.canonicalData(request).write(to: destination.appendingPathComponent("request.json"), options: .withoutOverwriting)
        let reportURL = destination.appendingPathComponent("registration.json")
        try MANTAJSON.canonicalData(report).write(to: reportURL, options: .withoutOverwriting)
        if emitDerived && report.accepted {
            try derive(loaded, transforms: transforms, report: report, reportURL: reportURL, output: destination)
        }
        return report
    }

    private static func load(_ spec: StableSegmentRecoveryRequest.Segment, landmarkNames: [String]) throws -> Loaded {
        guard spec.reviewedStable, !spec.observationIDs.isEmpty, spec.observationIDs.count <= 256,
              Set(spec.observationIDs).count == spec.observationIDs.count,
              spec.landmarks.count == landmarkNames.count, Set(spec.landmarks.map(\.name)) == Set(landmarkNames),
              spec.landmarks.allSatisfy({ $0.coordinate.count == 3 && $0.coordinate.allSatisfy(\.isFinite) }),
              [spec.headBounds.widthMeters, spec.headBounds.heightMeters, spec.headBounds.depthMeters].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
              [spec.headBounds.center.x, spec.headBounds.center.y, spec.headBounds.center.z].allSatisfy({ $0.isFinite && abs($0) <= 1_000 }) else {
            throw failure("Invalid segment selection, bounds, or landmarks; reviewedStable must be explicitly true.")
        }
        let directory = URL(fileURLWithPath: spec.bundlePath)
        let validator = MANTABundleValidator()
        let bundle = try FileManager.default.fileExists(atPath: directory.appendingPathComponent("manifest.json").path)
            ? validator.validate(directory: directory)
            : validator.validateWorkingIndex(directory: directory, verifyIntegrity: true)
        guard bundle.capture.coordinateSystems.contains(where: { $0.id == "arkit-world" && $0.units == .meters }) else {
            throw failure("Source ARKit coordinates must explicitly use meters.")
        }
        let wanted = Set(spec.observationIDs)
        let observations = bundle.capture.observations.filter { wanted.contains($0.id) }.sorted { $0.capturedAt < $1.capturedAt }
        guard observations.count == wanted.count else { throw failure("Selected observation IDs are missing.") }
        var fusion = MetricDepthPointCloudAccumulator(configuration: .init(voxelSizeMeters: 0.006, minimumConfidence: 2))
        var frames: [UUID: [SIMD3<Float>]] = [:]
        for (index, observation) in observations.enumerated() {
            guard observation.imageOrigin == "top-left", observation.worldCoordinateSystem == "arkit-world", observation.quality?.motionCorrection == nil, observation.quality?.liveMotionCorrection == nil,
                  observation.quality?.motionAssessment == nil || observation.quality?.motionAssessment?.segmentID == spec.segmentID,
                  let pose = SegmentRegistration.matrix(observation.cameraToWorld.map(Float.init)), SegmentRegistration.rigid(pose) else {
                throw failure("Coordinate world, source segment identity, or camera pose is invalid; already corrected inputs are not supported.")
            }
            guard observation.depth != nil else { continue }
            let frame = try depthFrame(observation, root: bundle.rootDirectory, frameID: index)
            var one = MetricDepthPointCloudAccumulator(configuration: .init(voxelSizeMeters: 0.006, minimumConfidence: 2))
            _ = one.ingest(frame, inside: spec.headBounds)
            let points = one.snapshot(maximumPoints: 512).points
            guard points.count >= 20 else { throw failure("Selected depth frame has too little high-confidence head evidence: \(observation.id)") }
            frames[observation.id] = points
            _ = fusion.ingest(frame, inside: spec.headBounds)
        }
        guard frames.count >= 3 else { throw failure("Each stable segment needs at least three supported depth frames.") }
        // RGB-only stills need nearby selected depth evidence in the reviewed interval.
        let depthTimes = observations.filter { frames[$0.id] != nil }.map(\.capturedAt)
        for observation in observations where observation.depth == nil {
            guard depthTimes.contains(where: { abs($0.timeIntervalSince(observation.capturedAt)) <= 1 }) else {
                throw failure("RGB-only frame lacks selected depth evidence within one second: \(observation.id)")
            }
        }
        let landmarks = landmarkNames.map { name -> SIMD3<Float> in
            let p = spec.landmarks.first { $0.name == name }!.coordinate; return SIMD3(p[0], p[1], p[2])
        }
        return Loaded(bundle: bundle, spec: spec, observations: observations,
                      points: fusion.snapshot(maximumPoints: 2048).points, frames: frames, landmarks: landmarks)
    }

    private static func depthFrame(_ observation: MANTACaptureObservation, root: URL, frameID: Int) throws -> MetricDepthPointFrame {
        guard let depth = observation.depth, depth.scalarType.lowercased() == "float32",
              depth.units == .meters, depth.byteOrder == "little-endian", depth.compression == "zlib",
              depth.imageMapping == "resolution-scale", ["row-major", "rowMajorNoPadding"].contains(depth.layout), let confidencePath = depth.confidencePath,
              (1...512).contains(depth.dimensions.width), (1...512).contains(depth.dimensions.height) else {
            throw failure("Recovery requires bounded little-endian Float32 zlib metric depth and its confidence map.")
        }
        let count = depth.dimensions.width * depth.dimensions.height
        let raw = try decompress(root.appendingPathComponent(depth.path), count: count * 4)
        let confidence = try decompress(root.appendingPathComponent(confidencePath), count: count)
        let values = raw.withUnsafeBytes { bytes in (0..<count).map { bytes.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) } }
        return .init(depthValues: values, confidenceValues: Array(confidence), depthWidth: depth.dimensions.width,
            depthHeight: depth.dimensions.height, imageWidth: observation.imageDimensions.width,
            imageHeight: observation.imageDimensions.height, intrinsics: observation.intrinsics.map(Float.init),
            cameraToWorld: observation.cameraToWorld.map(Float.init), frameID: frameID)
    }
    private static func decompress(_ url: URL, count: Int) throws -> Data {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 4_194_304 else { throw failure("Depth artifact exceeds bounded decoder limits.") }
        let source = try Data(contentsOf: url)
        var result = Data(count: count + 1)
        let decoded = result.withUnsafeMutableBytes { dst in source.withUnsafeBytes { src in
            compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, count + 1,
                src.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_ZLIB)
        } }
        guard decoded == count else { throw failure("Depth/confidence decompression size mismatch.") }
        result.removeLast()
        return result
    }
    private static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func derive(_ segments: [Loaded], transforms: [simd_float4x4], report: StableSegmentRecoveryReport,
                               reportURL: URL, output: URL) throws {
        var files: [String: MANTABundleFileSource] = [:]
        var observations: [MANTACaptureObservation] = []
        let reference = segments[0]
        for (index, segment) in segments.enumerated() {
            let prefix = "sources/\(index)/"
            func copy(_ path: String?, role: String, media: String = "application/octet-stream") -> String? {
                guard let path else { return nil }
                let mapped = prefix + path
                files[mapped] = .init(path: mapped, sourceURL: segment.bundle.rootDirectory.appendingPathComponent(path), mediaType: media, role: role)
                return mapped
            }
            _ = copy(segment.bundle.manifest.content.capture, role: "original-capture-metadata", media: "application/json")
            let originalManifest = FileManager.default.fileExists(atPath: segment.bundle.rootDirectory.appendingPathComponent("manifest.json").path)
                ? "manifest.json" : "derivatives/acquisition/manifest.json"
            _ = copy(originalManifest, role: "original-manifest", media: "application/json")
            for original in segment.observations {
                var derived = original
                derived.imagePath = copy(original.imagePath, role: "camera-image")
                derived.losslessImagePath = copy(original.losslessImagePath, role: "camera-image-lossless-reference")
                derived.compressedImagePath = copy(original.compressedImagePath, role: "camera-image-compressed-reference")
                if var depth = original.depth {
                    depth.path = copy(depth.path, role: "metric-depth")!
                    depth.confidencePath = copy(depth.confidencePath, role: "depth-confidence")
                    derived.depth = depth
                }
                let pose = SegmentRegistration.matrix(original.cameraToWorld.map(Float.init))!
                derived.cameraToWorld = SegmentRegistration.flatten(SegmentRegistration.camera(pose, referenceFromSource: transforms[index])).map(Double.init)
                // Legacy frames lack quality. Do not invent sharpness or motion evidence.
                guard var quality = original.quality else { throw failure("Derived packages currently require captured quality metadata; report-only registration remains available for legacy frames.") }
                quality.coverageSector = "recovered-unclassified"
                quality.headCenteredCoverageSector = nil
                quality.translationFromPreviousSampleMeters = nil
                quality.rotationFromPreviousSampleDegrees = nil
                quality.warnings.append("Experimental stable-segment recovery; geometric gates are uncalibrated. See recovery/registration.json.")
                quality.motionCorrection = .init(runID: report.runID, sourceBundleID: segment.bundle.manifest.bundleID,
                    sourceSegmentID: segment.spec.segmentID, referenceSegmentID: reference.spec.segmentID,
                    transform: transforms[index], originalCameraToWorld: original.cameraToWorld)
                derived.quality = quality
                observations.append(derived)
            }
        }
        files["recovery/registration.json"] = .init(path: "recovery/registration.json", sourceURL: reportURL, mediaType: "application/json", role: "segment-registration")
        files["recovery/request.json"] = .init(path: "recovery/request.json", sourceURL: output.appendingPathComponent("request.json"), mediaType: "application/json", role: "reviewed-segment-selection")
        var layoutPath: String?
        if let path = reference.bundle.manifest.content.layout {
            layoutPath = "recovery/layout.json"
            files[layoutPath!] = .init(path: layoutPath!, sourceURL: reference.bundle.rootDirectory.appendingPathComponent(path), mediaType: "application/json", role: "electrode-layout")
        }
        // Do not mix source fused surfaces, inferred coordinates, stale coverage,
        // or fiducials from unreviewed time intervals. Rebuild depth from corrected
        // cameras; place final fiducials on the final recovered surface.
        let capture = MANTACaptureDocument(schema: MANTABundleFormat.captureSchema, sessionID: UUID(),
            captureMode: reference.bundle.capture.captureMode, layoutID: reference.bundle.capture.layoutID,
            coordinateSystems: [.init(id: "arkit-world", handedness: "right", units: .meters,
                description: "Canonical reference-head frame, fixed to first reviewed segment's original ARKit world; experimental rigid segment recovery.")],
            observations: observations.sorted { $0.capturedAt < $1.capturedAt },
            reconstruction: .init(headBoundingBox: reference.spec.headBounds))
        let producer = MANTAProducer(application: "manta-recover-segments", version: "1", build: "1", platform: "macOS",
            operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString, deviceModel: "Mac")
        _ = try MANTABundleFinalizer().finalize(.init(capture: capture, producer: producer,
            createdAt: report.createdAt, finalizedAt: Date(), parentBundleID: reference.bundle.manifest.bundleID,
            changes: [.init(changedAt: Date(), category: "experimental-segment-recovery",
                summary: "Explicitly reviewed stable segments registered rigidly; raw source poses retained; regenerate surfaces and final fiducials. See recovery/registration.json for all source bundle identities.")],
            files: Array(files.values), layoutPath: layoutPath, filenameTag: "recovered-experimental"),
            in: output, preferDirectoryPackage: true)
    }
}
#endif
