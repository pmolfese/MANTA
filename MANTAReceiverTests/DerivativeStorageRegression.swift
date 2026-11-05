import Foundation
import AppKit
import ImageIO
import simd
import MANTACore
@testable import MANTA_Receiver

@main struct Regression {
    @MainActor static func main() throws {
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
        try testAlignmentPolicy(bundle: second)
        try testImageOrientation(root: root)
        // The processed marker must agree with the effective manifest.
        let marker = root.appendingPathComponent("derivatives/receiver/processed.json")
        var json = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as! [String: Any]
        json["sessionID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: json).write(to: marker, options: .atomic)
        do {
            _ = try ReceiverProcessedPackage.load(at: root)
            fatalError("Mismatched processed identity was accepted")
        } catch { /* expected */ }
        if CommandLine.arguments.count > 1 {
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
