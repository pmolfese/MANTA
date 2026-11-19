import Foundation
import MANTACore
import Testing
import UIKit
import CoreVideo
@testable import MANTA

@MainActor
struct CaptureReceiptTests {
    private func exportFixture(store: CaptureArtifactStore) throws -> ScanSession {
        var session = ScanSession.newSession(layout: .headMeshOnly)
        session.captureMode = .photogrammetry
        session.acquisitionContext = .init(operatorID: "before-export")
        session.captureObservations = [.init(capturedAt: Date(),
            cameraTransform: [1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1],
            cameraIntrinsics: [100,0,0, 0,100,0, 1,1,1], imageResolution: .init(width: 2, height: 2),
            hasSceneDepth: false, meshAnchorCount: 0, trackingSummary: "Normal", cameraSnapshotFilename: "assets/test.png")]
        try store.writeSession(session)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
            UIColor.gray.setFill(); context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
        }
        try #require(image.pngData()).write(to: store.assetsDirectory(for: session).appendingPathComponent("test.png"))
        return session
    }

    @Test func preparedExportFreezesMetadataAndDrainsMainActorProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = try exportFixture(store: store)
        let job = try store.prepareSessionExport(id: session.id, rawOnly: false)
        defer { try? FileManager.default.removeItem(at: job.outputDirectory) }
        // Later working metadata cannot change this export's context snapshot.
        session.acquisitionContext?.operatorID = "after-preparation"
        try store.writeAcquisitionContext(for: session)
        var updates: [Double] = []
        let result = try await job.execute { fraction, _ in
            MainActor.assertIsolated()
            updates.append(fraction)
        }
        #expect(result.receipt.status == .passed)
        #expect(result.exports.count == 2)
        #expect(updates.last == 1)
        let count = updates.count
        await Task.yield()
        #expect(updates.count == count)
        for export in result.exports {
            let bundle = try MANTABundleValidator().validate(directory: export.url)
            #expect(bundle.integrityWarnings.isEmpty)
            let context = try JSONDecoder().decode(AcquisitionContext.self,
                from: Data(contentsOf: export.url.appendingPathComponent("acquisition/context.json")))
            #expect(context.operatorID == "before-export")
            #expect(bundle.manifest.producer.deviceModel == DeviceHardwareIdentifier.current)
        }
    }

    @Test func exportWorkerRunsOffMainAndCleansPartialPairOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let session = try exportFixture(store: store)
        let job = try store.prepareSessionExport(id: session.id, rawOnly: false)
        var requests = job.requests
        requests[1].files.append(.init(path: "missing.bin", sourceURL: root.appendingPathComponent("absent"),
            mediaType: "application/octet-stream", role: "test"))
        let failing = CaptureBundleExportJob(session: job.session, sourceDirectory: job.sourceDirectory,
            requests: requests, metadata: job.metadata, outputDirectory: job.outputDirectory)
        let succeeded = await Task.detached {
            do {
                _ = try failing.run { _, _ in #expect(!Thread.isMainThread) }
                return true
            } catch { return false }
        }.value
        #expect(!succeeded)
        #expect(!FileManager.default.fileExists(atPath: job.outputDirectory.path))
        #expect(try store.loadSession(id: session.id).captureObservations.count == 1)
        #expect(FileManager.default.fileExists(atPath: store.assetsDirectory(for: session).appendingPathComponent("test.png").path))
    }

    @Test func cancelledExportPreservesSourceAndDoesNotLeaveOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let session = try exportFixture(store: store)
        let job = try store.prepareSessionExport(id: session.id, rawOnly: true)
        let task = Task { try await job.execute { _, _ in } }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled export unexpectedly succeeded") }
        catch { #expect(error is CancellationError) }
        #expect(!FileManager.default.fileExists(atPath: job.outputDirectory.path))
        #expect(try store.loadSession(id: session.id).id == session.id)
    }

    @Test func cancellationDuringFinalizationRemovesUncommittedOutput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let session = try exportFixture(store: store)
        let job = try store.prepareSessionExport(id: session.id, rawOnly: true)
        let cancelled = await Task.detached {
            do {
                _ = try job.run { fraction, _ in
                    if fraction > 0.1 { withUnsafeCurrentTask { $0?.cancel() } }
                }
                return false
            } catch { return error is CancellationError }
        }.value
        #expect(cancelled)
        #expect(!FileManager.default.fileExists(atPath: job.outputDirectory.path))
        #expect(try store.loadSession(id: session.id).lastRawExportedBundleID == nil)
    }

    @Test func exportLocksSessionUntilCommitAndClearsProgressOnFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let fixture = try exportFixture(store: store)
        let suite = "export-lifecycle-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.openSession(id: fixture.id))
        model.exportRawSession(id: fixture.id)
        #expect(model.isExporting)
        #expect(!model.startNewSession(subjectLabel: "blocked"))
        model.deleteSession(id: fixture.id)
        await model.exportTask?.value
        #expect(!model.isExporting && model.exportStage.isEmpty && model.exportProgress == 0)
        let output = try #require(model.exportedBundle?.urls.first)
        defer { try? FileManager.default.removeItem(at: output.deletingLastPathComponent().deletingLastPathComponent()) }
        #expect(model.session.lastRawExportedBundleID != nil)
        #expect(try store.loadSession(id: fixture.id).lastRawExportedBundleID == model.session.lastRawExportedBundleID)
        let priorID = model.session.lastRawExportedBundleID
        // A corrupted image fails validation without publishing a stale share URL.
        try Data("bad-image".utf8).write(to: store.assetsDirectory(for: fixture).appendingPathComponent("test.png"))
        model.exportRawSession(id: fixture.id)
        await model.exportTask?.value
        #expect(!model.isExporting && model.exportedBundle == nil)
        #expect(model.exportProgress == 0 && model.exportStage.isEmpty)
        #expect(model.session.lastRawExportedBundleID == priorID)
        #expect(model.statusMessage.hasPrefix("Export failed:"))
    }

    @Test func checkpointFailurePreventsExportOfStaleSessionMetadata() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        let fixture = try exportFixture(store: store)
        let suite = "export-checkpoint-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = ScanSessionViewModel(artifactStore: store, sessionDefaults: defaults)
        #expect(model.openSession(id: fixture.id))
        let metadataURL = store.sessionMetadataURL(for: fixture.id)
        try FileManager.default.removeItem(at: metadataURL)
        try FileManager.default.createDirectory(at: metadataURL, withIntermediateDirectories: false)
        model.exportRawSession(id: fixture.id)
        await model.exportTask?.value
        #expect(model.captureSaveError != nil)
        #expect(model.statusMessage.hasPrefix("Export stopped:"))
        #expect(!model.isExporting && model.exportedBundle == nil)
        #expect(model.session.lastRawExportedBundleID == nil)
    }

    @Test func rawExportPreservesHeadBoundsCoverageAndSpecificHardware() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MANTABoundsTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try CaptureArtifactStore(rootDirectory: root)
        var session = try exportFixture(store: store)
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
            cameraSnapshotFilename: "assets/test.png",
            quality: CaptureQualityMetrics(
                arFrameTimestamp: 1, worldMappingStatus: "mapped",
                ambientIntensity: nil, ambientColorTemperature: nil,
                meanLuminance: 0.5, darkPixelFraction: 0, brightPixelFraction: 0,
                sharpnessScore: 0.1, translationFromPreviousSampleMeters: nil,
                rotationFromPreviousSampleDegrees: nil,
                coverageSector: "azimuth-0-level"))]
        try store.writeSession(session)

        let exported = try store.exportRawSessionBundle(id: session.id)
        let imported = try MANTABundleValidator().validate(directory: exported.export.url)

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
        let imported = try MANTABundleValidator().validate(directory: result.export.url)

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

        let rawDestination = pair.raw.url
        let raw = try MANTABundleValidator().validate(directory: rawDestination)
        let solved = try MANTABundleValidator().validate(directory: pair.solved.url)
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
