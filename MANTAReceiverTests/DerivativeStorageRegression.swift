import Foundation
import Compression
import SwiftUI
import MANTAProcessing
import AppKit
import ImageIO
import CoreVideo
import simd
import MANTACore
@testable import MANTA_Receiver

@main struct Regression {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("manta-derivative-regression-\(UUID())")
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root.appendingPathComponent("reconstruction"), withIntermediateDirectories: true)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.lidarMeshFilename = "reconstruction/lidar_mesh.ply"
        session.headCroppedLidarMeshFilename = "reconstruction/lidar_mesh_head.ply"
        let mesh = ReceiverTriangleMesh(vertices: [SIMD3<Float>(0, 0, 0), SIMD3<Float>(0.01, 0, 0), SIMD3<Float>(0, 0.01, 0)], indices: [0, 1, 2])
        for path in [session.lidarMeshFilename!, session.headCroppedLidarMeshFilename!] {
            try ReceiverSurfaceExporter.writeMeshPLY(mesh, to: root.appendingPathComponent(path))
        }
        try JSONEncoder().encode(session).write(to: root.appendingPathComponent("session.json"))
        let paths = ["session.json", session.lidarMeshFilename!, session.headCroppedLidarMeshFilename!]
        let originals = try paths.map { try Data(contentsOf: root.appendingPathComponent($0)) }
        let producer = MANTAProducer(application: "regression", version: "1", build: "1", platform: "macOS", operatingSystemVersion: "test", deviceModel: "test")
        let raw = try MANTARawSessionRecovery().openDirectoryInPlace(root, producer: producer)
        let indexBefore = try Data(contentsOf: root.appendingPathComponent("derivatives/acquisition/manifest.json"))
        let box = HeadBoundingBox(center: Coordinate3D(x: 0, y: 0, z: 0), widthMeters: 0.4, heightMeters: 0.46, depthMeters: 0.4)
        let edited = try ReceiverProcessedPackage.updateHeadBoundingBox(bundle: raw, boundingBox: box)
        precondition(edited.bundle.capture.reconstruction?.headCroppedLidarMeshPath == "derivatives/receiver/reconstruction/lidar_mesh_head.ply")
        let first = try ReceiverProcessedPackage.load(at: root, verifyIntegrity: true)
        precondition(first.manifest.parentBundleID == raw.manifest.bundleID)
        precondition(first.manifest.bundleID != raw.manifest.bundleID)
        precondition(first.capture.reconstruction?.headBoundingBox == box)
        let updated = try ReceiverProcessedPackage.updateFiducials(bundle: first, fiducials: [])
        let second = try ReceiverProcessedPackage.load(at: root, verifyIntegrity: true)
        precondition(second.manifest.bundleID == updated.bundle.manifest.bundleID)
        precondition(second.changeLog?.changes.count == 2)
        precondition(!second.integrityWarnings.contains { $0.kind == .checksumMismatch || $0.kind == .sizeMismatch })
        for (path, original) in zip(paths, originals) {
            let after = try Data(contentsOf: root.appendingPathComponent(path))
            precondition(after == original, "Changed original \(path)")
        }
        let indexAfter = try Data(contentsOf: root.appendingPathComponent("derivatives/acquisition/manifest.json"))
        precondition(indexBefore == indexAfter)
        precondition(!fm.fileExists(atPath: root.appendingPathComponent("capture.json").path))
        try await testMotionSave(root: root)
        try testAlignmentPolicy(bundle: second)
        try testImageOrientation(root: root)
        try testMultiPassInputs(bundle: raw, root: root)
        // The processed marker must agree with the effective manifest.
        let marker = root.appendingPathComponent("derivatives/receiver/processed.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
        json["sessionID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json).write(to: marker, options: .atomic)
        do {
            _ = try ReceiverProcessedPackage.load(at: root)
            fatalError("Mismatched processed identity was accepted")
        } catch { /* expected */ }
        if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "--lidar-pass-audit" {
            let supplied = URL(fileURLWithPath: CommandLine.arguments[2])
            let source = try MANTABundleValidator().validate(directory: supplied)
            let before = try Data(contentsOf: supplied.appendingPathComponent("capture.json"))
            let passes = try ReceiverArchivedLiDARPass.load(from: source)
            precondition(passes.count == 3)
            let model = ReceiverMotionCorrectionModel(bundle: source)
            precondition(model.passes.map { $0.observations.count }.sorted() == [2, 10, 35])
            precondition(model.passes.filter(\.included).count == 2)
            precondition(model.readiness != nil && model.report == nil)
            if CommandLine.arguments.contains("--automatic-audit") {
                for pass in model.passes where pass.included { model.update(pass.id) { $0.reviewedStable = true } }
                precondition(model.automaticReadiness == nil)
                // Diagnostic only: full intervals are not a claim of human review.
                let start = Date()
                await model.preview(automatic: true)
                print("AUTO AUDIT (full-interval diagnostic, not approved): \(Date().timeIntervalSince(start)) seconds")
                if let report = model.report {
                    print("AUTO accepted: \(report.accepted)")
                    for entry in report.entries {
                        print("AUTO \(entry.segmentID): \(entry.registration.reason); RMS \(String(describing: entry.registration.rmsMeters)); overlap \(String(describing: entry.registration.sourceOverlap))/\(String(describing: entry.registration.referenceOverlap)); rejected frames \(entry.rejectedFrameIDs.count)")
                    }
                } else { print("AUTO input rejected: \(model.error ?? "unknown")") }
                precondition(model.savedPackage == nil)
            }
            let host = NSHostingView(rootView: ReceiverMotionCorrectionWorkspace(store: ReceiverStore(), bundle: source)
                .background(Color(nsColor: .windowBackgroundColor)))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.titled], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: bitmap)
                try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/manta-motion-ui.png"))
            }
            window.orderOut(nil)
            for pass in passes {
                let view = pass.viewerBundle(from: source)
                precondition(view.capture.observations.isEmpty)
                precondition(view.capture.reconstruction?.objectCaptureModelPath == nil)
                precondition(view.capture.reconstruction?.modelToWorld == nil)
                let path = view.capture.reconstruction!.lidarMeshPath!
                let mesh = try ReceiverSurfaceExporter.loadBinaryPLY(supplied.appendingPathComponent(path))
                precondition(!mesh.vertices.isEmpty && !mesh.indices.isEmpty)
                print("PASS: archived LiDAR \(pass.id), \(pass.frameCount) frames, \(mesh.vertices.count) vertices")
            }
            precondition(tryData(supplied.appendingPathComponent("capture.json")) == before)
        } else if CommandLine.arguments.count > 1 {
            let supplied = URL(fileURLWithPath: CommandLine.arguments[1])
            let captureURL = supplied.appendingPathComponent("derivatives/receiver/capture.json")
            let originalCapture = try Data(contentsOf: captureURL)
            let opened = try ReceiverProcessedPackage.load(at: supplied)
            let review = ReceiverAlignmentPolicy.assessment(for: opened)
            if review.rejectsTransform {
                precondition(opened.capture.reconstruction?.modelToWorld == nil)
            }
            precondition(tryData(captureURL) == originalCapture)
            print("Capture audit (read only): \(review.message)")
            let changes = opened.capture.observations.filter {
                ReceiverStoredImageOrientation.displayOrientation(for: $0) != ReceiverStoredImageOrientation($0.imageOrientation)
            }
            print("Orientation audit: \(changes.count)/\(opened.capture.observations.count) display tags corrected from camera-pose evidence; files unchanged")
        }
        print("PASS: saved crop and fiducial edits, reopened twice, stable derivative lineage, unchanged source/index bytes")
    }


    @MainActor static func testMotionSave(root: URL) async throws {
        let first = try fixture(in: root, offset: 0)
        let second = try fixture(in: root, offset: 0.09)
        let sources = [first, second].map { URL(fileURLWithPath: $0.bundlePath) }
        let before = try sources.map { try Data(contentsOf: $0.appendingPathComponent("capture.json")) }
        let request = StableSegmentRecoveryRequest(acquisitionGroupID: "receiver-regression", segments: [first, second])
        let preview = try StableSegmentRecovery.run(request, output: root.appendingPathComponent("preview"))
        precondition(preview.accepted)
        let output = root.appendingPathComponent("corrected")
        let package = try ReceiverMotionCorrectionModel.saveReviewed(request: request, report: preview, output: output)
        let store = ReceiverStore()
        await store.importArchive(from: package)
        guard let reopened = store.bundle else { fatalError(store.errorMessage ?? "Failed reopening corrected capture") }
        precondition(reopened.capture.observations.count == 8)
        precondition(reopened.integrityWarnings.isEmpty)
        try CaptureMotionPolicy.requireStationary(reopened.capture.observations.map(\.quality))
        let cloud = try ReceiverDepthFusion.fuse(.init(rootDirectory: package, observations: reopened.capture.observations,
            declaredBounds: reopened.capture.reconstruction?.headBoundingBox, headMeshURL: nil, fiducialCoordinates: []))
        precondition(!cloud.points.isEmpty)
        precondition(FileManager.default.fileExists(atPath: output.appendingPathComponent("corrected-depth.ply").path))
        for (i, source) in sources.enumerated() { precondition(tryData(source.appendingPathComponent("capture.json")) == before[i]) }
        var automatic = request
        automatic.automaticAlignment = true
        for index in automatic.segments.indices { automatic.segments[index].landmarks = [] }
        let autoPreview = try StableSegmentRecovery.run(automatic, output: root.appendingPathComponent("automatic-preview"))
        precondition(autoPreview.accepted)
        let autoOutput = root.appendingPathComponent("automatic-corrected")
        let autoPackage = try ReceiverMotionCorrectionModel.saveReviewed(request: automatic, report: autoPreview, output: autoOutput)
        await store.importArchive(from: autoPackage)
        precondition(store.bundle?.capture.observations.count == 8 && store.errorMessage == nil)
        precondition(FileManager.default.fileExists(atPath: autoOutput.appendingPathComponent("corrected-depth.ply").path))
        for (i, source) in sources.enumerated() { precondition(tryData(source.appendingPathComponent("capture.json")) == before[i]) }
        print("PASS: manual and automatic corrections saved atomically, reopened, fused corrected depth, preserved originals")
    }

    private static func fixture(in root: URL, offset: Double, movedFrame: Bool = false, distantStill: Bool = false) throws -> StableSegmentRecoveryRequest.Segment {
        let segmentID = UUID()
        let staging = root.appendingPathComponent(segmentID.uuidString)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let values: [Float] = (0..<1024).map { i in
            let x = Float(i % 32) / 31
            let y = Float(i / 32) / 31
            return 0.47 + 0.025 * sin(x * 5) + 0.02 * cos(y * 4)
        }
        let depthData = values.withUnsafeBytes { Data($0) }
        let depthURL = staging.appendingPathComponent("depth.zlib")
        let confidenceURL = staging.appendingPathComponent("confidence.zlib")
        let imageURL = staging.appendingPathComponent("image.png")
        try compressed(depthData).write(to: depthURL)
        try compressed(Data(repeating: 2, count: 1024)).write(to: confidenceURL)
        // Image pixels are not decoded by registration. Keep a real tiny PNG as provenance.
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aF4sAAAAASUVORK5CYII=")!.write(to: imageURL)
        var observations: [MANTACaptureObservation] = []
        for index in 0..<4 {
            var pose = matrix_identity_float4x4
            pose.columns.3.x = Float(offset)
            if movedFrame && index == 2 { pose.columns.3.z = 0.1 }
            var quality = CaptureQualityMetrics(arFrameTimestamp: Double(index), worldMappingStatus: "mapped",
                ambientIntensity: nil, ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0,
                brightPixelFraction: 0, sharpnessScore: 1, translationFromPreviousSampleMeters: nil,
                rotationFromPreviousSampleDegrees: nil, coverageSector: "front")
            quality.motionAssessment = .init(segmentID: segmentID, state: .suspected)
            let time = distantStill && index == 3 ? 100.0 : Double(index) * 0.2
            observations.append(.init(id: UUID(), capturedAt: Date(timeIntervalSince1970: time), imagePath: "image.png",
                imageDimensions: .init(width: 32, height: 32), intrinsics: [120,0,0, 0,120,0, 16,16,1],
                cameraToWorld: SegmentRegistration.flatten(pose).map(Double.init),
                depth: index < 3 ? .init(path: "depth.zlib", confidencePath: "confidence.zlib", dimensions: .init(width: 32, height: 32)) : nil,
                trackingState: "normal", quality: quality))
        }
        let capture = MANTACaptureDocument(schema: MANTABundleFormat.captureSchema, sessionID: UUID(), captureMode: "both",
            layoutID: "hydrocel-128", coordinateSystems: [.init(id: "arkit-world", handedness: "right", units: .meters, description: "synthetic")],
            observations: observations)
        let package = try MANTABundleFinalizer().finalize(.init(capture: capture,
            producer: .init(application: "test", version: "1", build: "1", platform: "test", operatingSystemVersion: "test", deviceModel: "test"),
            createdAt: Date(), finalizedAt: Date(), files: [
                .init(path: "image.png", sourceURL: imageURL, mediaType: "image/png", role: "camera-image"),
                .init(path: "depth.zlib", sourceURL: depthURL, mediaType: "application/octet-stream", role: "metric-depth"),
                .init(path: "confidence.zlib", sourceURL: confidenceURL, mediaType: "application/octet-stream", role: "depth-confidence")
            ]), in: staging, preferDirectoryPackage: true)
        let landmarks: [[Float]] = [[-0.05, -0.05, -0.5], [0.05,-0.05,-0.5], [0,0.05,-0.48], [0,0,-0.44]]
        return .init(bundlePath: package.archiveURL.path, segmentID: segmentID, observationIDs: observations.map(\.id), reviewedStable: true,
            headBounds: .init(center: .init(x: offset, y: 0, z: -0.45)),
            landmarks: landmarks.enumerated().map { index, p in .init(name: "landmark-\(index)", coordinate: [p[0] + Float(offset),p[1],p[2]]) })
    }

    private static func compressed(_ data: Data) throws -> Data {
        var buffer = Data(count: data.count * 2 + 128)
        let capacity = buffer.count
        let count = buffer.withUnsafeMutableBytes { dst in data.withUnsafeBytes { src in
            compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity,
                src.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB)
        } }
        precondition(count > 0)
        return buffer.prefix(count)
    }

    @MainActor static func testAlignmentPolicy(bundle: MANTAValidatedBundle) throws {
        precondition(ReceiverAlignmentPolicy.acceptsAutomatic(symmetricRMS: 0.009))
        precondition(ReceiverAlignmentPolicy.acceptsAutomatic(symmetricRMS: 0.010))
        for invalid in [nil, Float.nan, .infinity, -0.001, 0.0101, 0.0467636] as [Float?] {
            precondition(!ReceiverAlignmentPolicy.acceptsAutomatic(symmetricRMS: invalid))
        }
        var capture = bundle.capture
        capture.reconstruction?.objectCaptureModelPath = "derivatives/receiver/reconstruction/macos_medium.usdz"
        capture.reconstruction?.modelToWorld = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        let candidate = MANTAValidatedBundle(rootDirectory: bundle.rootDirectory, manifest: bundle.manifest,
            capture: capture, changeLog: bundle.changeLog)
        let evidence = bundle.rootDirectory.appendingPathComponent("derivatives/receiver/reconstruction/macos_medium_diagnostics.json")
        let legacy = Data("{\"alignmentAccepted\":true,\"alignmentSymmetricRMSMeters\":0.0467636}".utf8)
        try legacy.write(to: evidence)
        precondition(ReceiverAlignmentPolicy.assessment(for: candidate).rejectsTransform)
        let filtered = ReceiverAlignmentPolicy.applying(to: candidate)
        precondition(filtered.capture.reconstruction?.modelToWorld == nil)
        precondition(candidate.capture.reconstruction?.modelToWorld != nil)
        precondition(tryData(evidence) == legacy)
        precondition(ReceiverAlignmentPolicy.assessment(for: filtered).message.contains("46.8"))
        try Data("{\"alignmentAccepted\":true,\"alignmentSymmetricRMSMeters\":0.009}".utf8).write(to: evidence)
        precondition(ReceiverAlignmentPolicy.assessment(for: candidate) == .automatic(0.009))
        try Data("{\"alignmentAccepted\":false,\"alignmentSymmetricRMSMeters\":0.009}".utf8).write(to: evidence)
        precondition(ReceiverAlignmentPolicy.assessment(for: candidate).rejectsTransform)
        // An explicit later manual alignment wins over old automatic diagnostics.
        var log = bundle.changeLog!
        log.changes.append(MANTAChangeRecord(changedAt: Date(), category: "manual-world-alignment", summary: "Reviewed", targets: ["capture.json"]))
        log.changes.append(MANTAChangeRecord(changedAt: Date(), category: "manual-fiducial-correction", summary: "Reviewed", targets: ["capture.json"]))
        let manual = MANTAValidatedBundle(rootDirectory: bundle.rootDirectory, manifest: bundle.manifest, capture: capture, changeLog: log)
        precondition(ReceiverAlignmentPolicy.assessment(for: manual) == .manual)
        precondition(ReceiverAlignmentPolicy.applying(to: manual).capture.reconstruction?.modelToWorld != nil)
        // A new preview must not inherit the previous model's manual approval.
        precondition(ReceiverAlignmentPolicy.assessment(for: manual, modelURLOverride: bundle.rootDirectory.appendingPathComponent(capture.reconstruction!.objectCaptureModelPath!)).rejectsTransform)
        try Data("invalid".utf8).write(to: evidence)
        precondition(ReceiverAlignmentPolicy.assessment(for: candidate).rejectsTransform)
        try FileManager.default.removeItem(at: evidence)
        precondition(ReceiverAlignmentPolicy.assessment(for: candidate) == .unverified)

        let display = ReceiverDisplaySettings()
        display.showLiDAR = true
        display.showFusedDepth = true
        display.photogrammetryBinding.wrappedValue = true
        precondition(display.showPhotogrammetry && !display.showLiDAR && !display.showFusedDepth)
        display.fusedDepthBinding.wrappedValue = true
        precondition(display.showFusedDepth && !display.showPhotogrammetry)
        display.updateCapabilities(defaultLiDARChoice: .headRegion, lidarChoices: [.headRegion], photogrammetryAvailable: true, fusedDepthAvailable: true, hasAnnotations: false, annotationsSpatiallyValid: true, canOverlay: true)
        display.photogrammetryBinding.wrappedValue = true
        precondition(display.showPhotogrammetry && display.showFusedDepth)
        display.updateCapabilities(defaultLiDARChoice: .headRegion, lidarChoices: [.headRegion], photogrammetryAvailable: true, fusedDepthAvailable: true, hasAnnotations: false, annotationsSpatiallyValid: true, canOverlay: false)
        precondition(display.showPhotogrammetry && !display.showFusedDepth)
        print("PASS: 10 mm boundary, historical rejection, manual provenance, missing/invalid evidence, depth/photo exclusion")
    }

    @MainActor static func testMultiPassInputs(bundle: MANTAValidatedBundle, root: URL) throws {
        let identity: [Double] = [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1]
        let depths: [Float] = [0.5, 0.6]
        try depths.withUnsafeBytes { Data($0) }.write(to: root.appendingPathComponent("sample.depth"))
        var capture = bundle.capture
        capture.observations = (0..<2).map { _ in
            var quality = CaptureQualityMetrics(arFrameTimestamp: 0, worldMappingStatus: "mapped", ambientIntensity: nil,
                ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
                sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil, coverageSector: "test")
            quality.motionAssessment = .init(segmentID: UUID(), state: .suspected)
            return MANTACaptureObservation(id: UUID(), capturedAt: Date(), imagePath: "orientation-fixture.png",
                imageDimensions: .init(width: 4, height: 2), intrinsics: [100,0,0, 0,100,0, 2,1,1],
                cameraToWorld: identity,
                depth: MANTADepthArtifact(path: "sample.depth", dimensions: .init(width: 2, height: 1),
                    scalarType: "float32", byteOrder: "little-endian", units: .meters, layout: "rowMajorNoPadding", compression: "none", imageMapping: "resolution-scale"),
                trackingState: "Normal", quality: quality)
        }
        let input = MANTAValidatedBundle(rootDirectory: root, manifest: bundle.manifest, capture: capture, changeLog: nil)
        for mode in [ReceiverPhotogrammetryInputMode.imagesOnly, .depthGuided] {
            let prepared = try ReceiverReconstructionWorkflow.prepare(bundle: input, detail: .medium, inputMode: mode)
            defer { ReceiverReconstructionWorkflow.removeWorkspace(prepared) }
            precondition(prepared.inputMode == mode && prepared.imageCount == 2 && prepared.independentPasses)
            if mode == .depthGuided {
                precondition(prepared.sampleDescriptors.allSatisfy { !$0.includeGravity && $0.depthURL != nil })
                let samples = Array(ReceiverPhotogrammetrySampleSequence(descriptors: prepared.sampleDescriptors))
                precondition(samples.count == 2)
                for sample in samples {
                    precondition(sample.gravity == nil && sample.camera == nil)
                    precondition(sample.depthDataMap != nil)
                    precondition(CVPixelBufferGetWidth(sample.depthDataMap!) == 2)
                }
            }
        }
        do {
            try CaptureMotionPolicy.requireStationary(capture.observations.map(\.quality))
            fatalError("Unregistered metric fusion was accepted")
        } catch { /* independent Object Capture does not authorize world-space fusion */ }
        print("PASS: multi-pass RGB and depth prepare; samples retain depth and omit AR pose/gravity; fusion stays gated")
    }

    @MainActor static func testImageOrientation(root: URL) throws {
        let identity: [Double] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
        var observation = MANTACaptureObservation(id: UUID(), capturedAt: Date(), imageDimensions: .init(width: 4, height: 2), imageOrientation: "down", intrinsics: [], cameraToWorld: identity, trackingState: "Normal")
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .up)
        observation.imageOrientation = "up"
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .up)
        var inverted = identity
        inverted[0] = -1; inverted[5] = -1
        observation.cameraToWorld = inverted
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .down)
        observation.imageOrientation = "down"
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .down)
        observation.imageOrientation = "right"
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .right)
        observation.imageOrientation = "down"
        observation.cameraToWorld = identity
        observation.worldCoordinateSystem = "other-world"
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .down)
        observation.worldCoordinateSystem = "arkit-world"
        observation.cameraToWorld = []
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .down)
        // Looking straight down: no reliable projected gravity direction.
        observation.cameraToWorld = [1, 0, 0, 0, 0, 0, -1, 0, 0, 1, 0, 0, 0, 0, 0, 1]
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .down)
        observation.cameraToWorld = inverted
        var quality = CaptureQualityMetrics(arFrameTimestamp: 0, worldMappingStatus: "mapped", ambientIntensity: nil,
            ambientColorTemperature: nil, meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
            sharpnessScore: 1, translationFromPreviousSampleMeters: nil, rotationFromPreviousSampleDegrees: nil,
            coverageSector: "test")
        quality.motionCorrection = .init(runID: UUID(), sourceBundleID: UUID(), sourceSegmentID: UUID(), referenceSegmentID: UUID(), transform: matrix_identity_float4x4, originalCameraToWorld: identity)
        observation.quality = quality
        precondition(ReceiverStoredImageOrientation.displayOrientation(for: observation) == .up)

        // Render an asymmetric image through the actual loader. For every EXIF
        // rotation, markers and inverse click coordinates must hit the same pixel.
        var pixels: [UInt8] = []
        for i in 0..<8 {
            let gray = UInt8(20 + i * 25)
            pixels.append(contentsOf: [gray, gray, gray, 255])
        }
        let cg = CGImage(width: 4, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let url = root.appendingPathComponent("orientation-fixture.png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, nil)
        precondition(CGImageDestinationFinalize(destination))
        let before = try Data(contentsOf: url)
        let rawSize = CGSize(width: 4, height: 2)
        for orientation in [ReceiverStoredImageOrientation.up, .down, .left, .right] {
            let loaded = ReceiverOrientedFrameImage.load(from: url, orientation: orientation)!
            let rendered = loaded.image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
            let bitmap = NSBitmapImageRep(cgImage: rendered)
            let displaySize = orientation.displaySize(for: rawSize)
            precondition(rendered.width == Int(displaySize.width) && rendered.height == Int(displaySize.height))
            for y in 0..<2 { for x in 0..<4 {
                let raw = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                let displayed = orientation.displayPoint(raw, rawSize: rawSize)
                let back = orientation.rawPoint(displayed, rawSize: rawSize)
                precondition(back == raw)
                let color = bitmap.colorAt(x: Int(displayed.x), y: Int(displayed.y))!.usingColorSpace(.deviceRGB)!
                precondition(abs(color.redComponent * 255 - Double(20 + (y * 4 + x) * 25)) < 3)
            } }
        }
        precondition(tryData(url) == before)
        print("PASS: legacy landscape repair, pose fallbacks, original-pose recovery, four rendered orientations and landmark pixel round trips")
    }

    private static func tryData(_ url: URL) -> Data { try! Data(contentsOf: url) }

}
