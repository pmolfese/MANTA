import Foundation
import MANTACore
import Testing
import UIKit
import CoreVideo
@testable import MANTA

@MainActor
struct CaptureReceiptTests {
    @Test func rawExportPreservesHeadBoundsCoverageAndSpecificHardware() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTABoundsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.captureMode = .lidar
        let bounds = HeadBoundingBox(
            center: Coordinate3D(x: 0, y: 0, z: -0.5),
            widthMeters: 0.4, heightMeters: 0.46, depthMeters: 0.4)
        session.headBoundingBox = bounds
        let snapshot = LiDARMeshSnapshot(
            vertices: [
                SIMD3<Float>(-0.05, 0, -0.5),
                SIMD3<Float>(0.05, 0, -0.5),
                SIMD3<Float>(0, 0.05, -0.5)
            ],
            triangleIndices: [0, 1, 2])
        session.lidarMeshFilename = try store.writeLiDARMeshSnapshot(snapshot, for: session)
        session.captureObservations = [CaptureObservation(
            capturedAt: Date(),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0.5, 0, -0.5, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 1, trackingSummary: "Normal",
            quality: CaptureQualityMetrics(
                arFrameTimestamp: 1, worldMappingStatus: "mapped",
                ambientIntensity: nil, ambientColorTemperature: nil,
                meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
                sharpnessScore: 0.1, translationFromPreviousSampleMeters: nil,
                rotationFromPreviousSampleDegrees: nil,
                coverageSector: "azimuth-0-level"))]
        try store.writeSession(session)

        let exported = try store.exportRawSessionBundle(id: session.id)
        let imported = try MANTAArchiveImporter().importBundle(
            at: exported.export.url,
            to: root.appendingPathComponent("imported", isDirectory: true))

        #expect(imported.capture.reconstruction?.headBoundingBox == bounds)
        #expect(imported.capture.observations.first?.quality?.headCenteredCoverageSector != nil)
        #expect(imported.manifest.producer.deviceModel == DeviceHardwareIdentifier.current)
        #expect(imported.manifest.producer.deviceModel != "iPad")
    }

    @Test func headMeshOnlyRawExportDeclaresNoNetAndOmitsLayoutFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTAHeadMeshTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.captureMode = .photogrammetry
        session.captureObservations = [CaptureObservation(
            capturedAt: Date(),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal",
            cameraSnapshotFilename: "assets/camera-mesh-only.png")]
        try store.writeSession(session)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2, height: 2), format: format
        ).image { context in
            UIColor.gray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let imageURL = root.appendingPathComponent(session.id.uuidString)
            .appendingPathComponent("assets/camera-mesh-only.png")
        try #require(image.pngData()).write(to: imageURL)

        let result = try store.exportRawSessionBundle(id: session.id)
        let destination = root.appendingPathComponent("imported", isDirectory: true)
        let imported = try MANTAArchiveImporter().importBundle(
            at: result.export.url, to: destination)

        #expect(imported.capture.layoutID == "none")
        #expect(imported.manifest.content.layout == nil)
        #expect(!imported.manifest.files.contains { $0.path.hasPrefix("layouts/") })
    }

    @Test func dualImageCaptureWritesLosslessPrimaryAndCompressedCompanion() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTADualImageTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = ScanSession.newSession()
        session.captureMode = .photogrammetry

        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, 4, 4, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer)
        #expect(result == kCVReturnSuccess)
        let pixelBuffer = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(base, 0x7f, CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let observationID = UUID()
        let artifact = try store.writeCameraSnapshot(
            pixelBuffer: pixelBuffer, observationID: observationID, for: session,
            includeCompressedImage: true)
        #expect(URL(fileURLWithPath: artifact.primaryFilename).pathExtension.lowercased() == "png")
        #expect(["heic", "jpg"].contains(URL(
            fileURLWithPath: try #require(artifact.compressedFilename)
        ).pathExtension.lowercased()))

        session.captureObservations = [CaptureObservation(
            id: observationID,
            capturedAt: Date(),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 4, height: 4),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal",
            cameraSnapshotFilename: artifact.primaryFilename,
            compressedCameraSnapshotFilename: artifact.compressedFilename)]
        #expect(try store.writeCaptureReceipt(for: session).receipt.status == .passed)
    }

    @Test func deepReceiptAndPairedExportPreserveRawBoundary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTAReceiptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = ScanSession.newSession()
        session.captureMode = .photogrammetry
        session.acquisitionContext = AcquisitionContext(
            site: "Test Lab", operatorID: "operator-1", netModel: session.layout.name)

        let observation = CaptureObservation(
            capturedAt: Date(),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal",
            cameraSnapshotFilename: "assets/camera-test.jpg",
            losslessCameraSnapshotFilename: "assets/camera-test_lossless.png")
        session.captureObservations = [observation]
        session.electrodes = [ElectrodeAnnotation(
            label: "E1", role: .regular, coordinate: .zero,
            confidence: 0.9, state: .detected)]
        try store.writeSession(session)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        let imageURL = root.appendingPathComponent(session.id.uuidString)
            .appendingPathComponent("assets/camera-test.jpg")
        try #require(image.jpegData(compressionQuality: 0.9)).write(to: imageURL)
        let losslessURL = root.appendingPathComponent(session.id.uuidString)
            .appendingPathComponent("assets/camera-test_lossless.png")
        try #require(image.pngData()).write(to: losslessURL)

        let pair = try store.exportSessionBundles(id: session.id)
        #expect(pair.receipt.status == .passed)
        #expect(pair.raw.url.lastPathComponent.hasSuffix("_raw.manta"))
        #expect(pair.solved.url.lastPathComponent.hasSuffix("_solved.manta"))

        let rawDestination = root.appendingPathComponent("raw", isDirectory: true)
        let solvedDestination = root.appendingPathComponent("solved", isDirectory: true)
        let raw = try MANTAArchiveImporter().importBundle(at: pair.raw.url, to: rawDestination)
        let solved = try MANTAArchiveImporter().importBundle(at: pair.solved.url, to: solvedDestination)
        #expect(raw.capture.electrodes?.isEmpty != false)
        #expect(solved.capture.electrodes?.count == 1)
        #expect(raw.capture.observations.first?.losslessImagePath == "assets/camera-test_lossless.png")
        #expect(FileManager.default.fileExists(
            atPath: rawDestination.appendingPathComponent("assets/camera-test_lossless.png").path))
        #expect(FileManager.default.fileExists(
            atPath: rawDestination.appendingPathComponent("capture-receipt.json").path))
        #expect(FileManager.default.fileExists(
            atPath: rawDestination.appendingPathComponent("acquisition/context.json").path))

        let standaloneRaw = try store.exportRawSessionBundle(id: session.id)
        #expect(standaloneRaw.receipt.status == .passed)
        #expect(standaloneRaw.export.url.lastPathComponent.hasSuffix("_raw.manta"))
    }

    @Test func corruptedImageFailsDeepReceipt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTAReceiptTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = ScanSession.newSession()
        session.captureMode = .photogrammetry
        session.captureObservations = [CaptureObservation(
            capturedAt: Date(),
            cameraTransform: [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1],
            cameraIntrinsics: [100, 0, 0, 0, 100, 0, 1, 1, 1],
            imageResolution: ImageResolution(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal",
            cameraSnapshotFilename: "assets/corrupt.jpg")]
        try store.writeSession(session)
        try Data("not-a-jpeg".utf8).write(
            to: root.appendingPathComponent(session.id.uuidString)
                .appendingPathComponent("assets/corrupt.jpg"))

        let receipt = try store.writeCaptureReceipt(for: session).receipt
        #expect(receipt.status == .failed)
        #expect(receipt.checks.contains { $0.code == "image-decode-or-dimensions" })
    }
}
